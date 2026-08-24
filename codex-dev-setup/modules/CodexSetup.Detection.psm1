Set-StrictMode -Version Latest

function Invoke-CapturedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 20,
        [AllowNull()][Text.Encoding]$OutputEncoding,
        [AllowNull()][string]$StandardInput
    )
    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) {
        return [pscustomobject]@{ available = $false; exitCode = $null; output = ''; error = 'command-not-found' }
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $resolved.Source
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $null -ne $StandardInput
        $psi.CreateNoWindow = $true
        if ($null -ne $OutputEncoding) {
            $psi.StandardOutputEncoding = $OutputEncoding
            $psi.StandardErrorEncoding = $OutputEncoding
        }
        foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        if ($null -ne $StandardInput) {
            $process.StandardInput.Write($StandardInput)
            $process.StandardInput.Close()
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $stopwatch.Stop()
            Write-SetupLog -Level Warning -Message '命令版本探测超时' -Data @{ command=$Command; elapsedMs=$stopwatch.ElapsedMilliseconds }
            return [pscustomobject]@{ available = $true; exitCode = $null; output = ''; error = 'timeout'; elapsedMs=$stopwatch.ElapsedMilliseconds }
        }
        $output = (($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result) -replace "`0", '').Trim()
        $stopwatch.Stop()
        Write-SetupLog -Level Debug -Message '命令版本探测完成' -Data @{ command=$Command; exitCode=$process.ExitCode; elapsedMs=$stopwatch.ElapsedMilliseconds }
        return [pscustomobject]@{ available = $true; exitCode = $process.ExitCode; output = $output; error = $null; elapsedMs=$stopwatch.ElapsedMilliseconds }
    }
    catch {
        $stopwatch.Stop()
        Write-SetupLog -Level Warning -Message '命令版本探测失败' -Data @{ command=$Command; elapsedMs=$stopwatch.ElapsedMilliseconds; error=$_.Exception.Message }
        return [pscustomobject]@{ available = $true; exitCode = $null; output = ''; error = $_.Exception.Message; elapsedMs=$stopwatch.ElapsedMilliseconds }
    }
}

function Test-IsAppExecutionAlias {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace('/', '\')
    if ($normalized -notmatch '(?i)\\Microsoft\\WindowsApps\\') { return $false }
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length -eq 0
    }
    catch {
        return $true
    }
}

function Get-CommandInfoSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$VersionArguments = @('--version'),
        [AllowNull()][string]$PackageId,
        [switch]$SkipVersionProbe,
        [switch]$SkipAppExecutionAliasProbe
    )
    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($PackageId)) {
        $resolvedPath = Resolve-SetupCommandPath -Name $Name -PackageId $PackageId
        if ($resolvedPath) { $commands = @(Get-Command $resolvedPath -ErrorAction SilentlyContinue) }
    }
    if ($commands.Count -eq 0) {
        return [pscustomobject]@{
            installed = $false
            version = $null
            path = $null
            allPaths = @()
            appExecutionAlias = $false
            versionProbeSkipped = $false
            probeError = $null
        }
    }
    $allPaths = @($commands | ForEach-Object Source | Where-Object { $_ } | Select-Object -Unique)
    $realCommands = @($commands | Where-Object { -not (Test-IsAppExecutionAlias -Path $_.Source) })
    if ($realCommands.Count -gt 0) { $commands = $realCommands }
    $isAppExecutionAlias = Test-IsAppExecutionAlias -Path $commands[0].Source
    if ($SkipAppExecutionAliasProbe -and $isAppExecutionAlias) {
        return [pscustomobject]@{
            installed=$false; version=$null; path=$commands[0].Source; allPaths=$allPaths
            appExecutionAlias=$true; versionProbeSkipped=$true; probeError='app-execution-alias-only'
        }
    }
    $probeSkipped = $SkipVersionProbe -or ($SkipAppExecutionAliasProbe -and $isAppExecutionAlias)
    $probe = if ($probeSkipped) { $null } else { Invoke-CapturedCommand -Command $commands[0].Source -Arguments $VersionArguments }
    $versionLine = if ($null -ne $probe -and $probe.output) { ($probe.output -split "`r?`n" | Select-Object -First 1).Trim() } else { $null }
    return [pscustomobject]@{
        installed = $true
        version   = $versionLine
        path      = $commands[0].Source
        allPaths  = $allPaths
        appExecutionAlias = $isAppExecutionAlias
        versionProbeSkipped = $probeSkipped
        probeError = if ($null -ne $probe) { $probe.error } else { $null }
    }
}

function New-UnavailableCommandInfo {
    param([AllowNull()][string]$Error)
    return [pscustomobject]@{
        installed=$false; version=$null; path=$null; allPaths=@()
        appExecutionAlias=$false; versionProbeSkipped=$false; probeError=$Error
    }
}

function Invoke-DetectionStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 6)][int]$Index,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][scriptblock]$Fallback,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Issues,
        [AllowNull()][scriptblock]$ResultSummary
    )
    Write-Host "[$Index/6] $Name……" -ForegroundColor Cyan
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $Operation
        $timer.Stop()
        $summaryText = $null
        if ($null -ne $ResultSummary) {
            try { $summaryText = [string](& $ResultSummary $value) }
            catch {
                Write-SetupLog -Level Debug -Message '检测结果摘要生成失败，已使用通用完成提示' -Data @{ stage=$Index; name=$Name; error=$_.Exception.Message }
            }
        }
        if ([string]::IsNullOrWhiteSpace($summaryText)) { $summaryText = '完成' }
        Write-SetupWrappedText -Text ("$summaryText（{0:N1}s）" -f $timer.Elapsed.TotalSeconds) `
            -FirstIndent '      ' -ContinuationIndent '      ' -ForegroundColor DarkGreen
        Write-SetupLog -Level Debug -Message '检测阶段完成' -Data @{ stage=$Index; name=$Name; elapsedMs=$timer.ElapsedMilliseconds }
        return $value
    }
    catch {
        $timer.Stop()
        $message = ConvertTo-RedactedText $_.Exception.Message
        $Issues.Add([pscustomobject]@{ stage=$Index; name=$Name; error=$message; severity='Warning' })
        Write-Host ("      部分失败（{0:N1}s）：{1}" -f $timer.Elapsed.TotalSeconds, $message) -ForegroundColor Yellow
        Write-SetupLog -Level Warning -Message '检测阶段部分失败' -Data @{ stage=$Index; name=$Name; elapsedMs=$timer.ElapsedMilliseconds; error=$message }
        return & $Fallback $message
    }
}

function Get-HealthLabel {
    param([Parameter(Mandatory)][int]$Score)
    if ($Score -ge 90) { return '状态良好' }
    if ($Score -ge 75) { return '基本可用' }
    if ($Score -ge 60) { return '建议优化' }
    return '关键组件缺失'
}

function Get-ToolInstallationRoot {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Path
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -match '(?i)^(.*\\Git)\\(?:cmd|bin)\\git\.exe$') {
        return $matches[1].TrimEnd('\').ToLowerInvariant()
    }
    if ($Tool -eq 'codex' -and $fullPath -match '(?i)\\(?:Programs\\OpenAI\\Codex\\bin|WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\resources)\\codex(?:\.exe)?$') {
        return 'openai-codex-desktop'
    }
    if ($fullPath -match '(?i)^(.*\\AppData\\Roaming\\npm)\\') {
        return ("{0}::{1}" -f $matches[1].TrimEnd('\').ToLowerInvariant(), $Tool.ToLowerInvariant())
    }
    if ($fullPath -match '(?i)^(.*\\WindowsApps\\[^\\]+)\\') {
        return $matches[1].TrimEnd('\').ToLowerInvariant()
    }
    return (Split-Path -Parent $fullPath).TrimEnd('\').ToLowerInvariant()
}

function Get-WindowsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    return [pscustomobject]@{
        caption       = $os.Caption
        version       = $os.Version
        build         = $os.BuildNumber
        architecture  = $os.OSArchitecture
        isWindows11   = [int]$os.BuildNumber -ge 22000
        isAdministrator = $isAdmin
        editionId     = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    }
}

function Get-DetectionProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        if ($InputObject.PSObject.Properties.Name -contains $name) {
            return $InputObject.$name
        }
    }
    return $Default
}

function Get-WindowsPackageDetection {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source
    )
    $catalogState = [string](Get-DetectionProperty $Catalog @('state') 'Unknown')
    $packageStates = Get-DetectionProperty $Catalog @('packageStates')
    $key = "$Source|$PackageId"
    $state = Get-DetectionProperty $packageStates @($key)
    if ($catalogState -ne 'Known' -or $null -eq $state) {
        $catalogError = [string](Get-DetectionProperty $Catalog @('error') '')
        $state = [pscustomobject]@{
            state='Unknown'; installed=$false; version=$null
            error=$(if ($catalogError) { $catalogError } else { "缺少 $key 的精确软件包查询结果。" })
        }
    }
    return [pscustomobject]@{
        state=[string]$state.state; installed=[bool]$state.installed; packageId=$PackageId; source=$Source
        version=$state.version; name=$null; error=$state.error
    }
}

function Get-WslFeatureInfo {
    $command = Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
    if (-not $command) {
        return [pscustomobject]@{ state='Unknown'; enabled=$null; error='无法查询 Windows WSL 可选功能。' }
    }
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction Stop
        $state = [string]$feature.State
        return [pscustomobject]@{ state=$state; enabled=($state -eq 'Enabled'); error=$null }
    }
    catch {
        return [pscustomobject]@{ state='Unknown'; enabled=$null; error=$_.Exception.Message }
    }
}

function Get-WslDefaultVersion {
    $registryPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss'
    try {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
        if ($item.PSObject.Properties.Name -notcontains 'DefaultVersion') { return 2 }
        $value = $item.DefaultVersion
        if ([int]$value -notin @(1, 2)) { return $null }
        return [int]$value
    }
    catch [System.Management.Automation.ItemNotFoundException] { return 2 }
    catch { return $null }
}

function Get-WslInfo {
    param([Parameter(Mandatory)][string]$Distribution)

    $feature = Get-WslFeatureInfo
    $command = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $state = if ($feature.enabled -eq $false) { 'FeatureDisabled' } else { 'Unknown' }
        return [pscustomobject]@{
            state=$state; installed=$false; version=$null; distros=@(); distribution=$Distribution
            defaultDistribution=$null; defaultVersion=$null; distributionInstalled=$false; distributionVersion=$null; distributionWsl2=$false
            feature=$feature; detail=''; error=$(if ($state -eq 'Unknown') { $feature.error } else { $null })
        }
    }
    if ($feature.enabled -eq $false) {
        return [pscustomobject]@{
            state='FeatureDisabled'; installed=$false; version=$null; distros=@(); distribution=$Distribution
            defaultDistribution=$null; defaultVersion=$null; distributionInstalled=$false; distributionVersion=$null; distributionWsl2=$false
            feature=$feature; detail=''; error=$null
        }
    }
    $versionResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--version') -OutputEncoding ([Text.Encoding]::Unicode)
    $defaultVersion = Get-WslDefaultVersion
    $listResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--list', '--verbose') -OutputEncoding ([Text.Encoding]::Unicode)
    $quietResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--list', '--quiet') -OutputEncoding ([Text.Encoding]::Unicode)
    if ($listResult.exitCode -ne 0 -or $quietResult.exitCode -ne 0) {
        $errors = @(
            if ($listResult.exitCode -ne 0) { "wsl --list --verbose 退出码 $($listResult.exitCode)" }
            if ($quietResult.exitCode -ne 0) { "wsl --list --quiet 退出码 $($quietResult.exitCode)" }
            $listResult.error
            $quietResult.error
        ) | Where-Object { $_ }
        return [pscustomobject]@{
            state='Unknown'; installed=$true; version=($versionResult.output -split "`r?`n" | Select-Object -First 1)
            distros=@(); distribution=$Distribution; defaultDistribution=$null; defaultVersion=$defaultVersion
            distributionInstalled=$false; distributionVersion=$null; distributionWsl2=$false
            feature=$feature; detail=$listResult.output
            error=($errors -join '；')
        }
    }
    $distros = if ($quietResult.exitCode -eq 0) {
        @($quietResult.output -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('*').Trim() } | Where-Object { $_ })
    } else { @() }
    $distributionInstalled = $Distribution -in $distros
    $defaultDistribution = $null
    if ($listResult.exitCode -eq 0 -and $listResult.output -match '(?im)^\s*\*\s+(\S+)\s+\S+\s+[12]\s*$') {
        $defaultDistribution = $matches[1]
    }
    $distributionVersion = $null
    if ($distributionInstalled) {
        $escaped = [regex]::Escape($Distribution)
        $versionMatch = [regex]::Match($listResult.output, "(?im)^\s*\*?\s*$escaped\s+\S+\s+([12])\s*$")
        if (-not $versionMatch.Success) {
            return [pscustomobject]@{
                state='Unknown'; installed=$true; version=($versionResult.output -split "`r?`n" | Select-Object -First 1)
                distros=$distros; distribution=$Distribution; defaultDistribution=$defaultDistribution; defaultVersion=$defaultVersion
                distributionInstalled=$true; distributionVersion=$null; distributionWsl2=$false
                feature=$feature; detail=$listResult.output; error="无法确认 $Distribution 的 WSL 版本。"
            }
        }
        $distributionVersion = [int]$versionMatch.Groups[1].Value
    }
    $state = if ($distros.Count -eq 0) {
        'NoDistribution'
    }
    elseif (-not $distributionInstalled) {
        'TargetMissing'
    }
    elseif ($distributionVersion -eq 1) {
        'UnsupportedWsl1'
    }
    else {
        'Ready'
    }
    return [pscustomobject]@{
        state      = $state
        installed  = $true
        version    = ($versionResult.output -split "`r?`n" | Select-Object -First 1)
        distros    = $distros
        distribution = $Distribution
        defaultDistribution = $defaultDistribution
        defaultVersion = $defaultVersion
        distributionInstalled = $distributionInstalled
        distributionVersion = $distributionVersion
        distributionWsl2 = $distributionVersion -eq 2
        feature     = $feature
        detail     = $listResult.output
        error      = $null
    }
}

function Get-IniFileValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $currentSection = ''
    $sectionCount = 0
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            $currentSection = $matches[1].Trim()
            if ($currentSection -ieq $Section) { $sectionCount++ }
            continue
        }
        if ($currentSection -ieq $Section -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*([^;#]*?)\s*(?:[;#].*)?$')) {
            $values.Add($matches[1].Trim().Trim('"'))
        }
    }
    if ($sectionCount -gt 1) { throw ".wslconfig 重复定义 [$Section]。" }
    if ($values.Count -gt 1) { throw ".wslconfig 在 [$Section] 中重复定义 $Key。" }
    return $(if ($values.Count -eq 1) { $values[0] } else { $null })
}

function ConvertTo-IniBoolean {
    param([AllowNull()][string]$Value, [bool]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value -match '^(?i:true|1|yes|on)$'
}

function Get-WslNetworkInfo {
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    try {
        $networkingModeValue = Get-IniFileValue -Path $path -Section 'wsl2' -Key 'networkingMode'
        $networkingMode = if ($networkingModeValue) { $networkingModeValue.ToLowerInvariant() } else { 'nat' }
        $dnsTunneling = ConvertTo-IniBoolean (Get-IniFileValue -Path $path -Section 'wsl2' -Key 'dnsTunneling') $true
        $autoProxy = ConvertTo-IniBoolean (Get-IniFileValue -Path $path -Section 'wsl2' -Key 'autoProxy') $true
        $firewall = ConvertTo-IniBoolean (Get-IniFileValue -Path $path -Section 'wsl2' -Key 'firewall') $true
        return [pscustomobject]@{
            wslConfigPath=$path
            wslConfigExists=(Test-Path -LiteralPath $path -PathType Leaf)
            networkingMode=$networkingMode
            mirroredConfigured=($networkingMode -eq 'mirrored')
            dnsTunneling=$dnsTunneling
            autoProxy=$autoProxy
            firewall=$firewall
            error=$null
        }
    }
    catch {
        return [pscustomobject]@{
            wslConfigPath=$path; wslConfigExists=(Test-Path -LiteralPath $path -PathType Leaf)
            networkingMode='unknown'; mirroredConfigured=$false; dnsTunneling=$null; autoProxy=$null; firewall=$null
            error=$_.Exception.Message
        }
    }
}

function Get-PathDiagnostics {
    $scopes = [ordered]@{
        User    = [Environment]::GetEnvironmentVariable('Path', 'User')
        Machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        Process = [Environment]::GetEnvironmentVariable('Path', 'Process')
    }
    $entries = @()
    foreach ($scope in $scopes.Keys) {
        $index = 0
        foreach ($raw in @($scopes[$scope] -split ';')) {
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($raw.Trim()).TrimEnd('\')
            $isRemote = $expanded.StartsWith('\\', [StringComparison]::Ordinal)
            $entries += [pscustomobject]@{
                scope = $scope; index = $index; raw = $raw.Trim(); normalized = $expanded.ToLowerInvariant()
                remote = $isRemote
                exists = if ($isRemote) { $null } else { Test-Path -LiteralPath $expanded }
            }
            $index++
        }
    }
    $persistentEntries = @($entries | Where-Object scope -ne 'Process')
    $duplicates = @($persistentEntries | Group-Object normalized | Where-Object Count -gt 1 | ForEach-Object {
        [pscustomobject]@{ normalized = $_.Name; count = $_.Count; locations = @($_.Group | ForEach-Object { "$($_.scope)[$($_.index)]" }) }
    })
    $missing = @($persistentEntries | Where-Object { $_.exists -eq $false })
    $conflicts = @()
    $duplicateEntrypoints = @()
    $appAliases = @()
    foreach ($tool in @('git', 'gh', 'pwsh', 'rg', 'fd', 'jq', 'node', 'npm', 'pnpm', 'python', 'py', 'uv', 'fnm', 'docker', 'codex')) {
        $found = @(Get-Command $tool -All -ErrorAction SilentlyContinue | ForEach-Object Source | Where-Object { $_ } | Select-Object -Unique)
        if ($found.Count -eq 0) { continue }
        $records = @($found | ForEach-Object {
            $isAlias = Test-IsAppExecutionAlias -Path $_
            [pscustomobject]@{
                path = $_
                appExecutionAlias = $isAlias
                installationRoot = if ($isAlias) { $null } else { Get-ToolInstallationRoot -Tool $tool -Path $_ }
            }
        })
        $aliases = @($records | Where-Object appExecutionAlias)
        if ($aliases.Count -gt 0) {
            $appAliases += [pscustomobject]@{ tool=$tool; paths=@($aliases.path) }
        }
        $real = @($records | Where-Object { -not $_.appExecutionAlias })
        $installations = @($real | Group-Object installationRoot)
        if ($installations.Count -gt 1) {
            $conflicts += [pscustomobject]@{
                tool = $tool
                paths = @($real.path)
                installationRoots = @($installations.Name)
            }
        }
        elseif ($real.Count -gt 1) {
            $duplicateEntrypoints += [pscustomobject]@{
                tool = $tool
                paths = @($real.path)
                installationRoot = $installations[0].Name
            }
        }
    }
    return [pscustomobject]@{
        entries = $entries
        duplicates = $duplicates
        missing = $missing
        conflicts = $conflicts
        duplicateEntrypoints = $duplicateEntrypoints
        appAliases = $appAliases
    }
}

function Get-ProjectRecommendation {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ProjectPath,
        [Parameter(Mandatory)][ValidateSet('WslFirst', 'WindowsNative')][string]$ConfiguredEnvironmentMode,
        [Parameter(Mandatory)][string]$WslProjects,
        [Parameter(Mandatory)][string]$WslDistribution
    )

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        return [pscustomobject]@{
            path=$null; exists=$false; recommendedEnvironmentMode=$ConfiguredEnvironmentMode
            configuredEnvironmentMode=$ConfiguredEnvironmentMode
            matchesConfiguredMode=$true
            locationCompatible=$null
            confidence='none'; recommendationOnly=$true; reasons=@()
        }
    }
    $isWslUnc = $ProjectPath -match '^\\\\wsl(?:\$|\.localhost)\\'
    $escapedDistribution = [regex]::Escape($WslDistribution)
    if ($WslProjects -ne '~/code') { throw 'WSL 项目根必须是 ~/code。' }
    $isTargetWslHome = $ProjectPath -match "(?i)^\\\\wsl(?:\$|\.localhost)\\$escapedDistribution\\home\\[^\\]+\\code(?:\\|$)"
    $isWindowsLocal = $ProjectPath -match '^[A-Za-z]:\\'
    $locationCompatible = if ($ConfiguredEnvironmentMode -eq 'WslFirst') { $isTargetWslHome } else { $isWindowsLocal -and -not $isWslUnc }
    $exists = Test-Path -LiteralPath $ProjectPath
    $reasons = @()
    $windowsScore = 0
    $wslScore = 0
    if ($isTargetWslHome) { $wslScore += 5; $reasons += "项目位于 $WslDistribution 的 ~/code 工作区。" }
    elseif ($isWslUnc) { $reasons += "项目不在 $WslDistribution 的 ~/code 工作区中。" }
    if ($isWindowsLocal) { $windowsScore += 2; $reasons += '项目位于 Windows 本地文件系统。' }
    if ($ProjectPath -match '(?i)\\(OneDrive|Dropbox|Google Drive)\\') { $reasons += '同步目录可能放大文件监听和权限摩擦。' }

    if ($exists) {
        $nativePatterns = @('*.vcxproj', '*.wapproj')
        foreach ($pattern in $nativePatterns) {
            if (Get-ChildItem -LiteralPath $ProjectPath -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
                $windowsScore += 4; $reasons += "检测到 Windows 原生项目标记 $pattern。"
            }
        }
        $csproj = Get-ChildItem -LiteralPath $ProjectPath -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 5
        foreach ($file in $csproj) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($text -match '(?i)UseWPF|UseWindowsForms|TargetFramework[^<]*-windows|WinUI') {
                $windowsScore += 6; $reasons += "检测到 Windows 专属 .NET 项目：$($file.Name)。"; break
            }
        }
        $crossMarkers = @('package.json', 'pyproject.toml', 'uv.lock', 'Dockerfile', 'compose.yaml', 'docker-compose.yml', 'go.mod', 'Cargo.toml', 'Makefile')
        foreach ($marker in $crossMarkers) {
            if (Test-Path -LiteralPath (Join-Path $ProjectPath $marker)) {
                $wslScore += 2; $reasons += "检测到跨平台/Linux 工具链标记 $marker。"
            }
        }
    }
    if ($windowsScore -eq 0 -and $wslScore -eq 0) { $wslScore = 1; $reasons += '未检测到 Windows 专属标记，按跨平台项目处理。' }
    $recommendedMode = if ($windowsScore -gt $wslScore) { 'WindowsNative' } else { 'WslFirst' }
    $confidence = if ([math]::Abs($windowsScore - $wslScore) -ge 4) { 'high' } else { 'medium' }
    return [pscustomobject]@{
        path=$ProjectPath; exists=$exists; recommendedEnvironmentMode=$recommendedMode
        configuredEnvironmentMode=$ConfiguredEnvironmentMode
        matchesConfiguredMode=($ConfiguredEnvironmentMode -eq $recommendedMode)
        locationCompatible=$locationCompatible
        confidence=$confidence; recommendationOnly=$true
        windowsScore=$windowsScore; wslScore=$wslScore; reasons=$reasons
    }
}

function Get-SetupTextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Get-WslToolchainInfo {
    param(
        [AllowNull()]$WslInfo,
        [Parameter(Mandatory)]$Config,
        [switch]$Skip
    )
    if ($Skip) {
        $distro = if ($null -ne $WslInfo) { $WslInfo.distribution } else { [string]$Config.wsl.distribution }
        return [pscustomobject]@{
            available=$false; distro=$distro; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
            requiredCommandNames=@(); missingRequiredCommands=@(); nonNativeCommands=@()
            aptPackagesMissing=@(); codeRootExists=$null; managedBlockReady=$null; globalAgentsReady=$null
            codexConfigReady=$null; verifyCommandReady=$null; gitBaselinePresent=$null; uvManagedPythonReady=$null; readiness='Unknown'; environmentReady=$false; sudoAvailable=$null; sudoMode=$null
            githubAuthStatus=$null
            error=$null; skipped=$true; reason='快速检测未启动 WSL 发行版。'
        }
    }
    if ($null -eq $WslInfo -or -not $WslInfo.distributionWsl2) {
        $distro = if ($null -ne $WslInfo) { $WslInfo.distribution } else { [string]$Config.wsl.distribution }
        return [pscustomobject]@{
            available=$false; distro=$distro; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
            requiredCommandNames=@(); missingRequiredCommands=@(); nonNativeCommands=@()
            aptPackagesMissing=@(); codeRootExists=$null; managedBlockReady=$null; globalAgentsReady=$null
            codexConfigReady=$null; verifyCommandReady=$null; gitBaselinePresent=$null; uvManagedPythonReady=$null; readiness='NotReady'; environmentReady=$false; sudoAvailable=$null; sudoMode=$null
            githubAuthStatus=$null
            error=$null; skipped=$false; reason="没有可用的 WSL2 发行版 $distro。"
        }
    }
    $packageConfiguration = Get-WslPackageConfiguration -Config $Config
    $distro = $WslInfo.distribution
    $codeRoot = Resolve-WslUserPath -Distro $distro -Path ([string]$Config.paths.wslProjects)
    $agentsTemplatePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates\global\AGENTS.wsl.md.template'))
    $verifySourcePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wsl\verify.sh'))
    $globalAgentsHash = (Get-FileHash -LiteralPath $agentsTemplatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $verifyScriptHash = (Get-FileHash -LiteralPath $verifySourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $managedBlockLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '# >>> CodexDevSetup:WSL >>>',
        'export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"',
        'fnm_path=$(command -v fnm 2>/dev/null || true)',
        'if [[ -n $fnm_path && $fnm_path != /mnt/* ]]; then eval "$(fnm env --shell bash)"; fi',
        'unset fnm_path'
    )) { $managedBlockLines.Add($line) }
    foreach ($alias in $packageConfiguration.aliases) {
        $managedBlockLines.Add("alias $($alias.name)='$($alias.target)'")
    }
    $managedBlockLines.Add('# <<< CodexDevSetup:WSL <<<')
    $managedBlockHash = Get-SetupTextSha256 (($managedBlockLines -join "`n") + "`n")
    $toolScriptText = @'
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
if command -v fnm >/dev/null 2>&1; then
  fnm_path="$(command -v fnm)"
  case "$fnm_path" in
    /mnt/[a-zA-Z]/*) ;;
    *) eval "$(fnm env --shell bash)" >/dev/null 2>&1 || true ;;
  esac
fi

report_tool() {
  local tool="$1" version tool_path
  if command -v "$tool" >/dev/null 2>&1; then
    tool_path="$(command -v "$tool")"
    case "$tool_path" in
      /mnt/[a-zA-Z]/*)
        printf 'tool:%s=windows-path\n' "$tool"
        return
        ;;
    esac
    if version=$("$tool" --version 2>&1); then
      version=$(printf '%s\n' "$version" | head -n 1)
      printf 'tool:%s=%s\n' "$tool" "$version"
    else
      printf 'tool:%s=unavailable\n' "$tool"
    fi
  else
    printf 'tool:%s=missing\n' "$tool"
  fi
}

for tool in "$@"; do
  report_tool "$tool"
done

if command -v gh >/dev/null 2>&1; then
  gh_path="$(command -v gh)"
  case "$gh_path" in
    /mnt/[a-zA-Z]/*) printf 'state:ghAuth=windows-path\n' ;;
    *)
      if gh auth status >/dev/null 2>&1; then
        printf 'state:ghAuth=authenticated\n'
      else
        printf 'state:ghAuth=unauthenticated\n'
      fi
      ;;
  esac
else
  printf 'state:ghAuth=missing\n'
fi

if command -v git >/dev/null 2>&1 \
  && [[ "$(git config --global --get core.autocrlf 2>/dev/null || true)" == input ]] \
  && [[ "$(git config --global --get core.safecrlf 2>/dev/null || true)" == warn ]] \
  && [[ "$(git config --global --get init.defaultBranch 2>/dev/null || true)" == main ]] \
  && [[ "$(git config --global --get fetch.prune 2>/dev/null || true)" == true ]] \
  && [[ "$(git config --global --get pull.ff 2>/dev/null || true)" == only ]]; then
  printf 'state:gitBaseline=ready\n'
else
  printf 'state:gitBaseline=missing\n'
fi
'@

    $stateScriptText = @'
code_root="$1"
managed_block_hash="$2"
global_agents_hash="$3"
verify_script_hash="$4"
approval_policy="$5"
sandbox_mode="$6"
web_search="$7"
check_for_update="$8"
network_access="$9"
verify_docker="${10}"
verify_python="${11}"
shift 11
for package in "$@"; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    printf 'package:%s=installed|%s\n' "$package" "$version"
  else
    printf 'package:%s=missing\n' "$package"
  fi
done

export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
uv_managed_python_ready() {
  local uv_path managed_root interpreter version
  uv_path=$(command -v uv 2>/dev/null) || return 1
  uv_path=$(readlink -f -- "$uv_path" 2>/dev/null) || return 1
  [[ $uv_path != /mnt/* ]] || return 1
  managed_root=$(uv python dir 2>/dev/null) || return 1
  managed_root=$(readlink -f -- "$managed_root" 2>/dev/null) || return 1
  [[ $managed_root != /mnt/* ]] || return 1
  interpreter=$(UV_PYTHON_DOWNLOADS=never uv python find --managed-python --no-project 3.12 2>/dev/null) || return 1
  interpreter=$(readlink -f -- "$interpreter" 2>/dev/null) || return 1
  [[ $interpreter != /mnt/* ]] || return 1
  [[ $interpreter == "$managed_root"/* ]] || return 1
  version=$("$interpreter" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) || return 1
  [[ $version == 3.12 ]]
}
if [[ $verify_python == 1 ]]; then
  if uv_managed_python_ready; then
    printf 'state:uvManagedPython=ready\n'
  else
    printf 'state:uvManagedPython=missing\n'
  fi
else
  printf 'state:uvManagedPython=not-required\n'
fi

if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  printf 'state:sudo=passwordless\n'
elif command -v sudo >/dev/null 2>&1; then
  printf 'state:sudo=interactive\n'
else
  printf 'state:sudo=missing\n'
fi
if [[ -d "$code_root" ]]; then
  printf 'state:codeRoot=present\n'
else
  printf 'state:codeRoot=missing\n'
fi
managed_block_count=$(grep -Fc '# >>> CodexDevSetup:WSL >>>' "$HOME/.bashrc" 2>/dev/null || true)
managed_block_end_count=$(grep -Fc '# <<< CodexDevSetup:WSL <<<' "$HOME/.bashrc" 2>/dev/null || true)
managed_block_actual=$(awk '
  $0 == "# >>> CodexDevSetup:WSL >>>" { active=1 }
  active { print }
  $0 == "# <<< CodexDevSetup:WSL <<<" { exit }
' "$HOME/.bashrc" 2>/dev/null | sha256sum | cut -d " " -f 1)
if [[ $managed_block_count == 1 && $managed_block_end_count == 1 && $managed_block_actual == "$managed_block_hash" ]]; then
  printf 'state:managedShellBlock=ready\n'
else
  printf 'state:managedShellBlock=stale\n'
fi
if [[ -f "$HOME/.codex/AGENTS.md" && $(sha256sum "$HOME/.codex/AGENTS.md" | cut -d " " -f 1) == "$global_agents_hash" ]]; then
  printf 'state:globalAgents=ready\n'
else
  printf 'state:globalAgents=stale\n'
fi

toml_value_is() {
  local section="$1" key="$2" expected="$3" file="$4"
  awk -v target_section="$section" -v target_key="$key" -v expected="$expected" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { current_section=""; matches=0 }
    /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/ {
      current_section=$0
      sub(/[[:space:]]*#.*$/, "", current_section)
      sub(/^[[:space:]]*\[/, "", current_section)
      sub(/\][[:space:]]*$/, "", current_section)
      current_section=trim(current_section)
      next
    }
    {
      if (current_section != target_section) next
      line=$0
      if (line !~ "^[[:space:]]*" target_key "[[:space:]]*=") next
      sub("^[[:space:]]*" target_key "[[:space:]]*=[[:space:]]*", "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      if (trim(line) == expected) matches++
    }
    END { exit(matches == 1 ? 0 : 1) }
  ' "$file"
}

codex_config="$HOME/.codex/config.toml"
if [[ -f $codex_config ]] \
  && toml_value_is '' approval_policy "\"$approval_policy\"" "$codex_config" \
  && toml_value_is '' sandbox_mode "\"$sandbox_mode\"" "$codex_config" \
  && toml_value_is '' web_search "\"$web_search\"" "$codex_config" \
  && toml_value_is '' check_for_update_on_startup "$check_for_update" "$codex_config" \
  && toml_value_is sandbox_workspace_write network_access "$network_access" "$codex_config"; then
  printf 'state:codexConfig=ready\n'
else
  printf 'state:codexConfig=stale\n'
fi

verify_destination="$HOME/.local/lib/codex-dev-setup/verify.sh"
verify_wrapper="$HOME/.local/bin/codex-env-check"
if [[ -x $verify_destination && -x $verify_wrapper \
  && $(sha256sum "$verify_destination" | cut -d " " -f 1) == "$verify_script_hash" \
  && $(grep -Fc -- "exec $verify_destination" "$verify_wrapper") == 1 \
  && $(grep -Fc -- "--code-root $code_root" "$verify_wrapper") == 1 \
  && $(grep -Fc -- "--expected-distro ${WSL_DISTRO_NAME:-}" "$verify_wrapper") == 1 \
  && $(grep -Fc -- '--command pwsh' "$verify_wrapper") == 1 \
  && $(grep -Fc -- '--command rg' "$verify_wrapper") == 1 \
  && $(grep -Fc -- '"$@"' "$verify_wrapper") == 1 ]] \
  && { [[ $verify_python == 0 ]] || [[ $(grep -Fc -- '--uv-managed-python 3.12' "$verify_wrapper") == 1 ]]; } \
  && { [[ $verify_docker == 0 ]] || [[ $(grep -Fc -- '--command docker' "$verify_wrapper") == 1 ]]; }; then
  printf 'state:environmentCheck=ready\n'
else
  printf 'state:environmentCheck=stale\n'
fi
'@
    $requiredCommandNames = [System.Collections.Generic.List[string]]::new()
    [void]$requiredCommandNames.Add('git')
    [void]$requiredCommandNames.Add('pwsh')
    [void]$requiredCommandNames.Add('rg')
    if ($Config.toolchains.node.enabled) {
        foreach ($name in @('node', 'npm', 'fnm')) { [void]$requiredCommandNames.Add($name) }
    }
    if ($Config.wsl.installPnpm) { [void]$requiredCommandNames.Add('pnpm') }
    if ($Config.toolchains.python.enabled) {
        foreach ($name in @('python3', 'uv')) { [void]$requiredCommandNames.Add($name) }
    }
    if ($Config.wsl.installCodexCli) { [void]$requiredCommandNames.Add('codex') }
    if ($Config.toolchains.docker.enabled) { [void]$requiredCommandNames.Add('docker') }
    $probeCommandNames = @($packageConfiguration.commandNames + @($requiredCommandNames) | Sort-Object -Unique)
    $toolArguments = @('-d', $distro, '--', 'bash', '-s', '--') + $probeCommandNames
    $toolResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments $toolArguments `
        -StandardInput $toolScriptText -TimeoutSeconds 30 -OutputEncoding ([Text.Encoding]::UTF8)
    $stateArguments = @(
        '-d', $distro, '--', 'bash', '-s', '--', $codeRoot, $managedBlockHash, $globalAgentsHash, $verifyScriptHash,
        [string]$Config.codex.approvalPolicy, [string]$Config.codex.sandboxMode, [string]$Config.codex.webSearch,
        $Config.codex.checkForUpdateOnStartup.ToString().ToLowerInvariant(),
        $Config.codex.networkAccess.ToString().ToLowerInvariant(),
        $(if ($Config.toolchains.docker.enabled) { '1' } else { '0' }),
        $(if ($Config.toolchains.python.enabled) { '1' } else { '0' })
    ) + @($packageConfiguration.packageNames)
    $stateResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments $stateArguments `
        -StandardInput $stateScriptText -TimeoutSeconds 30 -OutputEncoding ([Text.Encoding]::UTF8)
    $toolValues = [ordered]@{}
    $packageValues = [ordered]@{}
    $stateValues = [ordered]@{}
    foreach ($line in @(($toolResult.output, $stateResult.output -join [Environment]::NewLine) -split "`r?`n")) {
        if ($line -match '^tool:([^=]+)=(.*)$') {
            $toolValues[$matches[1]] = $matches[2]
        }
        elseif ($line -match '^package:([^=]+)=(.*)$') {
            $packageName = $matches[1]
            $packageResult = $matches[2]
            if ($packageResult -match '^installed\|(.*)$') {
                $packageValues[$packageName] = [pscustomobject]@{ status='installed'; version=$matches[1] }
            }
            else {
                $packageValues[$packageName] = [pscustomobject]@{ status=$packageResult; version=$null }
            }
        }
        elseif ($line -match '^state:([^=]+)=(.*)$') {
            $stateValues[$matches[1]] = $matches[2]
        }
    }
    $aptPackagesMissing = @($packageConfiguration.packageNames | Where-Object {
        -not $packageValues.Contains($_) -or $packageValues[$_].status -ne 'installed'
    })
    $missingRequiredCommands = @($requiredCommandNames | Where-Object {
        -not $toolValues.Contains($_) -or [string]$toolValues[$_] -in @('missing', 'unavailable', '')
    })
    $uvManagedPythonReady = -not $Config.toolchains.python.enabled -or $stateValues['uvManagedPython'] -eq 'ready'
    if (-not $uvManagedPythonReady) { $missingRequiredCommands += 'uv-managed-python-3.12' }
    $nonNativeCommands = @($requiredCommandNames | Where-Object {
        $toolValues.Contains($_) -and [string]$toolValues[$_] -eq 'windows-path'
    })
    $toolchainAvailable = $toolResult.exitCode -eq 0 -and $stateResult.exitCode -eq 0
    $codeRootExists = $stateValues['codeRoot'] -eq 'present'
    $managedBlockReady = $stateValues['managedShellBlock'] -eq 'ready'
    $globalAgentsReady = $stateValues['globalAgents'] -eq 'ready'
    $codexConfigReady = $stateValues['codexConfig'] -eq 'ready'
    $verifyCommandReady = $stateValues['environmentCheck'] -eq 'ready'
    $gitBaselinePresent = $stateValues['gitBaseline'] -eq 'ready'
    $environmentReady = $toolchainAvailable -and $codeRootExists -and $managedBlockReady -and
        $globalAgentsReady -and $codexConfigReady -and $verifyCommandReady -and
        (-not $Config.wsl.configureGit -or $gitBaselinePresent) -and
        $aptPackagesMissing.Count -eq 0 -and $missingRequiredCommands.Count -eq 0 -and $nonNativeCommands.Count -eq 0
    return [pscustomobject]@{
        available=$toolchainAvailable
        distro=$distro
        tools=[pscustomobject]$toolValues
        packages=[pscustomobject]$packageValues
        requiredCommandNames=@($requiredCommandNames)
        missingRequiredCommands=$missingRequiredCommands
        nonNativeCommands=$nonNativeCommands
        aptPackagesMissing=$aptPackagesMissing
        codeRootExists=$codeRootExists
        managedBlockReady=$managedBlockReady
        globalAgentsReady=$globalAgentsReady
        codexConfigReady=$codexConfigReady
        verifyCommandReady=$verifyCommandReady
        gitBaselinePresent=$gitBaselinePresent
        uvManagedPythonReady=$uvManagedPythonReady
        readiness=$(if ($environmentReady) { 'Ready' } else { 'NotReady' })
        environmentReady=$environmentReady
        sudoAvailable=($stateValues['sudo'] -eq 'passwordless')
        sudoMode=$(if ($stateValues.Contains('sudo')) { [string]$stateValues['sudo'] } else { 'unknown' })
        githubAuthStatus=$(if ($stateValues.Contains('ghAuth')) { $stateValues['ghAuth'] } else { 'unknown' })
        error=@($toolResult.error, $stateResult.error | Where-Object { $_ }) -join '; '
        skipped=$false
        reason=$null
    }
}

function Get-CodexSetupDetection {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ProjectPath,
        [switch]$DeepWsl,
        [Parameter(Mandatory)]$Config
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    $isWslFirst = $Config.environmentMode -eq 'WslFirst'
    $targetLabel = if ($isWslFirst) { "WSL2 $($Config.wsl.distribution)" } else { 'Windows 原生开发环境' }
    Write-SetupStatus -Kind Info -Message "开始$(if ($DeepWsl -and $isWslFirst) { '完整' } else { '快速' })环境检测；目标：$targetLabel。"

    $windows = Invoke-DetectionStage -Index 1 -Name '检测 Windows 与权限' -Issues $issues -Operation {
        Get-WindowsInfo
    } -Fallback {
        param($message)
        [pscustomobject]@{ caption='检测失败'; version=$null; build=$null; architecture=$null; isWindows11=$false; isAdministrator=$false; editionId=$null; error=$message }
    } -ResultSummary {
        param($value)
        $windowsText = if ($value.isWindows11) { 'Windows 11' } else { [string]$value.caption }
        $permissionText = if ($value.isAdministrator) { '管理员权限' } else { '标准权限（推荐）' }
        "$windowsText；$permissionText"
    }

    $apps = Invoke-DetectionStage -Index 2 -Name '检测 Codex Desktop 与 Terminal' -Issues $issues -Operation {
        $catalog = Get-WindowsPackageCatalog
        $packageStates = [ordered]@{}
        if ($catalog.state -eq 'Known') {
            foreach ($target in @(
                @('winget', 'GitHub.cli'), @('winget', 'Microsoft.WindowsTerminal'), @('winget', 'Git.Git'),
                @('msstore', '9PLM9XGG6VKS'), @('winget', 'Docker.DockerDesktop'), @('winget', 'Microsoft.PowerShell'),
                @('winget', 'BurntSushi.ripgrep.MSVC'), @('winget', 'sharkdp.fd'), @('winget', 'jqlang.jq'),
                @('winget', 'OpenJS.NodeJS.LTS'), @('winget', 'astral-sh.uv')
            )) {
                $packageStates["$($target[0])|$($target[1])"] = Get-WindowsPackageState -PackageId $target[1] -Source $target[0] -Catalog $catalog
            }
        }
        $catalog | Add-Member -NotePropertyName packageStates -NotePropertyValue ([pscustomobject]$packageStates) -Force
        [pscustomobject]@{
            catalog=$catalog
            terminal=Get-WindowsPackageDetection -Catalog $catalog -PackageId 'Microsoft.WindowsTerminal' -Source winget
            codex=Get-WindowsPackageDetection -Catalog $catalog -PackageId '9PLM9XGG6VKS' -Source msstore
            terminalCommand=Get-CommandInfoSafe 'wt.exe' -SkipVersionProbe
        }
    } -Fallback {
        param($message)
        [pscustomobject]@{
            catalog=[pscustomobject]@{ state='Unknown'; complete=$false; packages=@(); packageStates=[pscustomobject]@{}; error=$message }
            terminal=[pscustomobject]@{ state='Unknown'; installed=$false; packageId='Microsoft.WindowsTerminal'; source='winget'; version=$null; name=$null; error=$message }
            codex=[pscustomobject]@{ state='Unknown'; installed=$false; packageId='9PLM9XGG6VKS'; source='msstore'; version=$null; name=$null; error=$message }
            terminalCommand=New-UnavailableCommandInfo -Error $message
        }
    } -ResultSummary {
        param($value)
        $codexText = if ($value.codex.state -eq 'Unknown') {
            '无法确认 Codex Desktop 包状态'
        }
        elseif ($value.codex.installed) { 'Codex Desktop 已安装' }
        else { 'Codex Desktop 包未安装' }
        $terminalText = if ($value.terminal.state -eq 'Unknown') {
            '无法确认 Windows Terminal 包状态'
        }
        elseif ($value.terminal.installed) { 'Windows Terminal 已安装' }
        elseif ($value.terminalCommand.installed) { 'Windows Terminal 包未登记，但 wt 命令可执行' }
        else { 'Windows Terminal 包未安装' }
        "$codexText；$terminalText"
    }

    $tools = Invoke-DetectionStage -Index 3 -Name '检测 Windows 侧组件与 PATH' -Issues $issues -Operation {
        $notRequired = New-UnavailableCommandInfo -Error 'not-required-in-wsl-first'
        $python = if ($isWslFirst) {
            $notRequired
        }
        else {
            $value = Get-CommandInfoSafe 'python.exe' -VersionArguments @('--version') -SkipAppExecutionAliasProbe
            $value
        }
        $dockerDesktop = if ($Config.toolchains.docker.enabled) {
            Get-CommandInfoSafe 'docker.exe' -VersionArguments @('--version')
        }
        else { $notRequired }
        [pscustomobject]@{
            powershell7=Get-CommandInfoSafe 'pwsh.exe' -VersionArguments @('--version')
            winget=Get-CommandInfoSafe 'winget.exe' -VersionArguments @('--version')
            git=Get-CommandInfoSafe 'git.exe' -VersionArguments @('--version')
            githubCli=Get-CommandInfoSafe 'gh.exe' -VersionArguments @('--version')
            ripgrep=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'rg.exe' -VersionArguments @('--version') -PackageId 'BurntSushi.ripgrep.MSVC' })
            fd=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'fd.exe' -VersionArguments @('--version') -PackageId 'sharkdp.fd' })
            jq=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'jq.exe' -VersionArguments @('--version') -PackageId 'jqlang.jq' })
            node=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'node.exe' -VersionArguments @('--version') })
            npm=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'npm.cmd' -VersionArguments @('--version') })
            pnpm=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'pnpm.cmd' -VersionArguments @('--version') })
            python=$python
            pythonLauncher=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'py.exe' -VersionArguments @('--version') })
            uv=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'uv.exe' -VersionArguments @('--version') -PackageId 'astral-sh.uv' })
            dockerDesktop=$dockerDesktop
            docker=$(if ($isWslFirst) { $notRequired } else { $dockerDesktop })
            codexCli=$(if ($isWslFirst) { $notRequired } else { Get-CommandInfoSafe 'codex.exe' -SkipVersionProbe })
            path=Get-PathDiagnostics
        }
    } -Fallback {
        param($message)
        $missing = New-UnavailableCommandInfo -Error $message
        [pscustomobject]@{
            powershell7=$missing; winget=$missing; git=$missing; githubCli=$missing; ripgrep=$missing; fd=$missing; jq=$missing
            node=$missing; npm=$missing; pnpm=$missing
            python=$missing; pythonLauncher=$missing; uv=$missing; dockerDesktop=$missing; docker=$missing; codexCli=$missing
            path=[pscustomobject]@{ entries=@(); duplicates=@(); missing=@(); conflicts=@(); duplicateEntrypoints=@(); appAliases=@(); error=$message }
        }
    } -ResultSummary {
        param($value)
        $commonTools = [ordered]@{ 'PowerShell 7'=$value.powershell7; 'WinGet'=$value.winget }
        if ($Config.windows.installUiGit) { $commonTools['Git UI 后端'] = $value.git }
        if ($Config.windows.installGitHubCli) { $commonTools['GitHub CLI'] = $value.githubCli }
        if ($Config.toolchains.docker.enabled) { $commonTools['Docker Desktop'] = $value.dockerDesktop }
        if (-not $isWslFirst) {
            $commonTools['ripgrep'] = $value.ripgrep; $commonTools['fd'] = $value.fd; $commonTools['jq'] = $value.jq
            if ($Config.toolchains.node.enabled) {
                $commonTools['Node.js'] = $value.node; $commonTools['npm'] = $value.npm
            }
            if ($Config.toolchains.python.enabled) { $commonTools['Python'] = $value.python; $commonTools['uv'] = $value.uv }
        }
        $missingToolNames = @($commonTools.GetEnumerator() | Where-Object { -not $_.Value.installed } | ForEach-Object Key)
        $availableCount = $commonTools.Count - $missingToolNames.Count
        $toolText = if ($missingToolNames.Count -eq 0) {
            "$($commonTools.Count) 项常用工具均可用"
        }
        else {
            "常用工具 $availableCount/$($commonTools.Count)；缺少 $($missingToolNames -join '、')"
        }
        $pathText = if ($isWslFirst) {
            '开发工具 PATH 以 WSL 完整检测为准'
        }
        else {
            $pathConflictCount = @($value.path.conflicts).Count
            $pathMissingCount = @($value.path.missing).Count
            $pathFindings = @()
            if ($pathConflictCount -gt 0) { $pathFindings += "$pathConflictCount 组命令冲突" }
            if ($pathMissingCount -gt 0) { $pathFindings += "$pathMissingCount 个无效目录" }
            if ($pathFindings.Count -eq 0) { 'PATH 无需处理' } else { "PATH：$($pathFindings -join '，')" }
        }
        "$toolText；$pathText"
    }

    $wsl = if ($isWslFirst) {
        Invoke-DetectionStage -Index 4 -Name '检测 WSL 发行版' -Issues $issues -Operation {
            Get-WslInfo -Distribution ([string]$Config.wsl.distribution)
        } -Fallback {
            param($message)
            [pscustomobject]@{
                state='Unknown'; installed=$false; version=$null; distros=@(); distribution=[string]$Config.wsl.distribution
                defaultDistribution=$null; defaultVersion=$null; distributionInstalled=$false; distributionVersion=$null; distributionWsl2=$false
                feature=[pscustomobject]@{ state='Unknown'; enabled=$null; error=$message }; detail=''; error=$message
            }
        } -ResultSummary {
            param($value)
            if ($value.state -in @('Unknown', 'Unavailable')) { return $value.error }
            if ($value.state -eq 'Ready') {
            $defaultText = if ($value.defaultDistribution -eq $value.distribution) {
                '且为默认发行版'
            }
            elseif ([string]::IsNullOrWhiteSpace([string]$value.defaultDistribution)) {
                '未识别默认发行版'
            }
            else {
                "默认发行版为 $($value.defaultDistribution)"
            }
            "$($value.distribution) 可用；运行于 WSL2；$defaultText"
            }
            elseif ($value.state -eq 'UnsupportedWsl1') { "$($value.distribution) 正在使用不受支持的 WSL1" }
            elseif ($value.state -eq 'TargetMissing') { "WSL2 可用；尚未安装 $($value.distribution)" }
            elseif ($value.state -eq 'NoDistribution') { 'WSL2 可用；尚未安装 Linux 发行版' }
            elseif ($value.state -eq 'FeatureDisabled') { 'Windows WSL 可选功能尚未启用' }
            else { $value.error }
        }
    }
    else {
        Write-Host '[4/6] 跳过 WSL 检测：当前选择 Windows 原生开发。' -ForegroundColor DarkGray
        [pscustomobject]@{
            state='NotApplicable'; installed=$false; version=$null; distros=@(); distribution=[string]$Config.wsl.distribution
            defaultDistribution=$null; defaultVersion=$null; distributionInstalled=$false; distributionVersion=$null; distributionWsl2=$false
            feature=[pscustomobject]@{ state='NotApplicable'; enabled=$null; error=$null }; detail=''; error=$null; skipped=$true
        }
    }
    $wslNetwork = if ($isWslFirst) {
        Get-WslNetworkInfo
    }
    else {
        [pscustomobject]@{
            wslConfigPath=$null; wslConfigExists=$false; networkingMode='not-required'; mirroredConfigured=$false
            dnsTunneling=$null; autoProxy=$null; firewall=$null; error=$null; skipped=$true
        }
    }
    if ($isWslFirst) {
        $networkSummary = if ($wslNetwork.mirroredConfigured) { 'mirrored' } else { $wslNetwork.networkingMode }
        Write-Host "      网络：$networkSummary；DNS 隧道 $($wslNetwork.dnsTunneling)；自动代理 $($wslNetwork.autoProxy)" -ForegroundColor DarkGray
    }

    if ($DeepWsl -and $isWslFirst) {
        $wslTools = Invoke-DetectionStage -Index 5 -Name '检测 WSL 工具链（可能需要 5–10 秒）' -Issues $issues -Operation {
            Get-WslToolchainInfo -WslInfo $wsl -Config $Config
        } -Fallback {
            param($message)
            [pscustomobject]@{
                available=$false; distro=$wsl.distribution; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
                requiredCommandNames=@(); missingRequiredCommands=@(); nonNativeCommands=@()
                aptPackagesMissing=@(); codeRootExists=$null; managedBlockReady=$null; globalAgentsReady=$null
                codexConfigReady=$null; verifyCommandReady=$null; gitBaselinePresent=$null; uvManagedPythonReady=$null; readiness='Unknown'; environmentReady=$false; sudoAvailable=$null; sudoMode=$null
                githubAuthStatus=$null
                error=$message; skipped=$false; reason='WSL 工具链检测失败。'
            }
        } -ResultSummary {
            param($value)
            if (-not $value.available) { return $value.reason }
            $requiredToolNames = @($value.requiredCommandNames)
            $missingToolNames = @($value.missingRequiredCommands + $value.nonNativeCommands | Select-Object -Unique)
            $availableToolCount = $requiredToolNames.Count - $missingToolNames.Count
            $toolText = if ($missingToolNames.Count -eq 0) {
                "$($requiredToolNames.Count) 项主要 Linux 工具均可用"
            }
            else {
                "主要 Linux 工具 $availableToolCount/$($requiredToolNames.Count) 可用；未检测到 $($missingToolNames -join '、')"
            }
            $missingPackageCount = @($value.aptPackagesMissing).Count
            $packageText = if ($missingPackageCount -eq 0) { '已启用的软件包组齐全' } else { "还需准备 $missingPackageCount 个已配置软件包" }
            $authText = switch ([string]$value.githubAuthStatus) {
                'authenticated' { 'Linux gh 已登录' }
                'unauthenticated' { 'Linux gh 尚未登录' }
                'missing' { 'Linux gh 尚未安装' }
                'windows-path' { '仅发现 Windows gh' }
                default { 'Linux gh 登录状态未知' }
            }
            "$($value.distro) 可访问；$toolText；$packageText；$authText"
        }
    }
    else {
        $skipReason = if ($isWslFirst) { '快速检测未启动 WSL/Linux。' } else { 'WindowsNative 模式不使用 WSL 工具链。' }
        Write-Host "[5/6] 跳过 WSL 工具链：$skipReason" -ForegroundColor DarkGray
        Write-SetupLog -Level Debug -Message $skipReason
        $wslTools = Get-WslToolchainInfo -WslInfo $wsl -Config $Config -Skip
        $wslTools.reason = $skipReason
    }

    $project = Invoke-DetectionStage -Index 6 -Name '生成项目建议与健康摘要' -Issues $issues -Operation {
        Get-ProjectRecommendation -ProjectPath $ProjectPath -ConfiguredEnvironmentMode $Config.environmentMode `
            -WslProjects $Config.paths.wslProjects -WslDistribution $Config.wsl.distribution
    } -Fallback {
        param($message)
        [pscustomobject]@{
            path=$ProjectPath; exists=$false; recommendedEnvironmentMode=$Config.environmentMode
            configuredEnvironmentMode=$Config.environmentMode; matchesConfiguredMode=$true; confidence='low'
            recommendationOnly=$true; locationCompatible=$false; reasons=@("项目建议检测失败：$message")
        }
    } -ResultSummary {
        param($value)
        $recommendedText = if ($value.recommendedEnvironmentMode -eq 'WindowsNative') { 'Windows 原生开发环境' } else { 'WSL/Linux 开发环境' }
        $matchText = if ($value.matchesConfiguredMode) { '与配置一致' } else { '仅提示，不会切换配置' }
        "项目建议 $recommendedText；$matchText"
    }

    $probedWindowsTools = @($tools.powershell7, $tools.winget, $tools.git, $tools.githubCli)
    if ($Config.toolchains.docker.enabled) { $probedWindowsTools += $tools.dockerDesktop }
    if (-not $isWslFirst) {
        $probedWindowsTools += @($tools.ripgrep, $tools.fd, $tools.jq, $tools.node, $tools.npm, $tools.pnpm, $tools.python, $tools.uv)
    }
    foreach ($entry in $probedWindowsTools) {
        if ($entry.probeError) {
            $issues.Add([pscustomobject]@{ stage=3; name='命令版本探测'; error=$entry.probeError; severity='Warning' })
        }
    }
    if ($apps.catalog.error) { $issues.Add([pscustomobject]@{ stage=2; name='Windows 软件包清单'; error=$apps.catalog.error; severity='Warning' }) }
    if ($isWslFirst -and $wsl.error) { $issues.Add([pscustomobject]@{ stage=4; name='WSL'; error=$wsl.error; severity='Warning' }) }
    if ($wslNetwork.error) { $issues.Add([pscustomobject]@{ stage=4; name='WSL 网络'; error=$wslNetwork.error; severity='Warning' }) }
    if (-not $wslTools.skipped -and $wslTools.error) { $issues.Add([pscustomobject]@{ stage=5; name='WSL 工具链'; error=$wslTools.error; severity='Warning' }) }

    $result = [ordered]@{
        detectedAt=(Get-Date).ToString('o')
        detectionMode=$(if ($DeepWsl -and $isWslFirst) { '完整' } else { '快速' })
        environmentMode=$Config.environmentMode
        desktopSettings=[pscustomobject]@{
            detectable=$false
            agentEnvironment=$(if ($isWslFirst) { 'Windows Subsystem for Linux' } else { 'Windows Native' })
            terminalShell=$(if ($isWslFirst) { 'WSL' } else { 'PowerShell' })
            restartRequired=$true
            verificationCommand=$(if ($isWslFirst) { 'codex-env-check' } else { 'Get-Command git,node,python,codex' })
        }
        windows=$windows
        codexDesktop=$apps.codex
        windowsTerminal=[pscustomobject]@{ command=$apps.terminalCommand; app=$apps.terminal }
        windowsPackageCatalog=$apps.catalog
        powershell7=$tools.powershell7
        winget=$tools.winget
        git=$tools.git
        githubCli=$tools.githubCli
        ripgrep=$tools.ripgrep
        fd=$tools.fd
        jq=$tools.jq
        node=$tools.node
        npm=$tools.npm
        pnpm=$tools.pnpm
        python=$tools.python
        pythonLauncher=$tools.pythonLauncher
        uv=$tools.uv
        dockerDesktop=$tools.dockerDesktop
        docker=$tools.docker
        codexCli=$tools.codexCli
        wsl=$wsl
        wslNetwork=$wslNetwork
        wslTools=$wslTools
        path=$tools.path
        project=$project
        issues=@($issues)
        partial=$issues.Count -gt 0
    }
    $score = 100
    if (-not $windows.isWindows11) { $score -= 25 }
    foreach ($required in @($result.powershell7, $result.winget)) { if (-not $required.installed) { $score -= 10 } }
    if ($Config.windows.installDesktop -and -not $result.codexDesktop.installed) { $score -= 15 }
    if ($Config.windows.installTerminal -and -not $result.windowsTerminal.app.installed) { $score -= 10 }
    if ($Config.windows.installUiGit -and -not $result.git.installed) { $score -= 5 }
    if ($Config.windows.installGitHubCli -and -not $result.githubCli.installed) { $score -= 5 }
    if ($isWslFirst) {
        if (-not $wsl.distributionWsl2) { $score -= 25 }
        elseif ($wsl.defaultDistribution -ne $wsl.distribution) { $score -= 10 }
        if ($DeepWsl -and $wslTools.available) {
            $score -= [math]::Min(30, (@($wslTools.missingRequiredCommands).Count + @($wslTools.nonNativeCommands).Count) * 5)
            if (-not $wslTools.codeRootExists) { $score -= 5 }
            if (-not $wslTools.globalAgentsReady) { $score -= 5 }
            if (-not $wslTools.verifyCommandReady) { $score -= 5 }
        }
        elseif ($DeepWsl) { $score -= 20 }
    }
    else {
        if ($Config.toolchains.node.enabled) {
            foreach ($required in @($result.node, $result.npm)) { if (-not $required.installed) { $score -= 5 } }
        }
        if ($Config.toolchains.python.enabled) {
            foreach ($required in @($result.python, $result.uv)) { if (-not $required.installed) { $score -= 5 } }
        }
        if ($Config.toolchains.docker.enabled -and -not $result.docker.installed) { $score -= 5 }
    }
    if (-not $isWslFirst -and $result.path.conflicts.Count -gt 0) {
        $score -= [math]::Min(15, $result.path.conflicts.Count * 3)
    }
    $result.healthScore = [math]::Max(0, $score)
    $result.healthLabel = if ($isWslFirst -and $wslTools.readiness -eq 'Unknown') { '尚未完整检查' } else { Get-HealthLabel -Score $result.healthScore }
    $object = [pscustomobject]$result
    Write-SetupLog -Message '环境检测完成' -Data $object
    return $object
}

Export-ModuleMember -Function @(
    'Get-CodexSetupDetection', 'Get-ProjectRecommendation', 'Invoke-CapturedCommand',
    'Get-CommandInfoSafe', 'Test-IsAppExecutionAlias', 'Get-PathDiagnostics',
    'Get-HealthLabel', 'Get-ToolInstallationRoot', 'Get-WslToolchainInfo', 'Invoke-DetectionStage',
    'Get-WslNetworkInfo'
)
