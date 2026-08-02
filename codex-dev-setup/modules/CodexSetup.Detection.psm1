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
        # WindowsApps aliases can be reparse points that cannot be inspected from
        # every security context. Their location is enough to treat them safely.
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
    $isAppExecutionAlias = Test-IsAppExecutionAlias -Path $commands[0].Source
    $probeSkipped = $SkipVersionProbe -or ($SkipAppExecutionAliasProbe -and $isAppExecutionAlias)
    $probe = if ($probeSkipped) { $null } else { Invoke-CapturedCommand -Command $commands[0].Source -Arguments $VersionArguments }
    $versionLine = if ($null -ne $probe -and $probe.output) { ($probe.output -split "`r?`n" | Select-Object -First 1).Trim() } else { $null }
    return [pscustomobject]@{
        installed = $true
        version   = $versionLine
        path      = $commands[0].Source
        allPaths  = @($commands | ForEach-Object Source | Where-Object { $_ } | Select-Object -Unique)
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
        # The Desktop bootstrap and its Store package can both expose Codex's
        # bundled CLI. They are one product deployment, not competing CLIs.
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

function Get-AppxDetection {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [AllowNull()][object[]]$Packages
    )
    try {
        if ($null -eq $Packages) { $Packages = @(Get-AppxPackage -ErrorAction Stop) }
        $matches = @($Packages | Where-Object {
            $_.Name -match $Pattern -or $_.PackageFullName -match $Pattern
        })
        return [pscustomobject]@{
            installed = $matches.Count -gt 0
            packages = @($matches | Select-Object Name, Version, PackageFullName)
            error = $null
        }
    }
    catch {
        return [pscustomobject]@{ installed = $false; packages = @(); error = $_.Exception.Message }
    }
}

function Get-WindowsFeatureState {
    param([Parameter(Mandatory)][string]$FeatureName)
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return [pscustomobject]@{ state = [string]$feature.State; available = $true; error = $null }
    }
    catch {
        return [pscustomobject]@{ state = 'Unknown'; available = $false; error = $_.Exception.Message }
    }
}

function Get-WslInfo {
    $command = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        return [pscustomobject]@{ installed = $false; version = $null; distros = @(); ubuntu = $false; ubuntuName = $null; ubuntuWsl2 = $false; detail = ''; error = $null }
    }
    $versionResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--version') -OutputEncoding ([Text.Encoding]::Unicode)
    $listResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--list', '--verbose') -OutputEncoding ([Text.Encoding]::Unicode)
    $quietResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('--list', '--quiet') -OutputEncoding ([Text.Encoding]::Unicode)
    $distros = if ($quietResult.exitCode -eq 0) {
        @($quietResult.output -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('*').Trim() } | Where-Object { $_ })
    } else { @() }
    $ubuntuNames = @($distros | Where-Object { $_ -match '^Ubuntu(?:-|$)' })
    $ubuntuWsl2 = $false
    if ($ubuntuNames.Count -gt 0 -and $listResult.exitCode -eq 0) {
        foreach ($name in $ubuntuNames) {
            $escaped = [regex]::Escape($name)
            if ($listResult.output -match "(?im)^\s*\*?\s*$escaped\s+\S+\s+2\s*$") { $ubuntuWsl2 = $true; break }
        }
    }
    return [pscustomobject]@{
        installed  = $true
        version    = ($versionResult.output -split "`r?`n" | Select-Object -First 1)
        distros    = $distros
        ubuntu     = $ubuntuNames.Count -gt 0
        ubuntuName = $ubuntuNames | Select-Object -First 1
        ubuntuWsl2 = $ubuntuWsl2
        detail     = $listResult.output
        error      = @($versionResult.error, $listResult.error, $quietResult.error | Where-Object { $_ }) -join '; '
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
                # A disconnected network path can make startup appear frozen. Report it
                # separately and do not contact the remote host during a local health check.
                exists = if ($isRemote) { $null } else { Test-Path -LiteralPath $expanded }
            }
            $index++
        }
    }
    # Process PATH normally contains the merged User + Machine PATH. Including it in
    # duplicate counts would report nearly every valid entry twice.
    $persistentEntries = @($entries | Where-Object scope -ne 'Process')
    $duplicates = @($persistentEntries | Group-Object normalized | Where-Object Count -gt 1 | ForEach-Object {
        [pscustomobject]@{ normalized = $_.Name; count = $_.Count; locations = @($_.Group | ForEach-Object { "$($_.scope)[$($_.index)]" }) }
    })
    $missing = @($persistentEntries | Where-Object { $_.exists -eq $false })
    $conflicts = @()
    $duplicateEntrypoints = @()
    $appAliases = @()
    foreach ($tool in @('git', 'gh', 'pwsh', 'node', 'npm', 'python', 'py', 'uv', 'fnm', 'codex')) {
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
        # Compatibility for older planning/reporting consumers.
        shadowedTools = $conflicts
    }
}

function Get-ProjectRecommendation {
    [CmdletBinding()]
    param([AllowNull()][string]$ProjectPath)

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        return [pscustomobject]@{ path = $null; exists = $false; agent = 'WSL'; terminal = 'WSL'; confidence = 'medium'; reasons = @('新建 Web/Python 项目默认推荐 Linux-native 工具链与 WSL 的 ~/code。') }
    }
    $isWslUnc = $ProjectPath -match '^\\\\wsl\$\\'
    $exists = Test-Path -LiteralPath $ProjectPath
    $reasons = @()
    $windowsScore = 0
    $wslScore = 0
    if ($isWslUnc) { $wslScore += 5; $reasons += '项目位于 WSL 文件系统。' }
    if ($ProjectPath -match '^[A-Za-z]:\\') { $windowsScore += 2; $reasons += '项目位于 Windows 文件系统。' }
    if ($ProjectPath -match '(?i)\\(OneDrive|Dropbox|Google Drive)\\') { $reasons += '同步目录可能放大文件监听和权限摩擦。' }

    if ($exists) {
        $nativePatterns = @('*.sln', '*.vcxproj', '*.wapproj', '*.psd1', '*.psm1')
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
    $agent = if ($windowsScore -gt $wslScore) { 'WindowsNative' } else { 'WSL' }
    $confidence = if ([math]::Abs($windowsScore - $wslScore) -ge 4) { 'high' } else { 'medium' }
    return [pscustomobject]@{
        path = $ProjectPath; exists = $exists; agent = $agent
        terminal = if ($agent -eq 'WSL') { 'WSL' } else { 'PowerShell7' }
        confidence = $confidence; windowsScore = $windowsScore; wslScore = $wslScore; reasons = $reasons
    }
}

function Get-WslToolchainInfo {
    param(
        [AllowNull()]$WslInfo,
        [switch]$Skip
    )
    if ($Skip) {
        $distro = if ($null -ne $WslInfo) { $WslInfo.ubuntuName } else { $null }
        return [pscustomobject]@{
            available=$false; distro=$distro; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
            aptPackagesMissing=@(); codeRootExists=$null; managedBlockPresent=$null; managedBlockSharesCodexHome=$null; sudoAvailable=$null
            error=$null; skipped=$true; reason='快速检测未启动 WSL 发行版。'
        }
    }
    if ($null -eq $WslInfo -or -not $WslInfo.ubuntuWsl2) {
        return [pscustomobject]@{
            available=$false; distro=$null; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
            aptPackagesMissing=@(); codeRootExists=$null; managedBlockPresent=$null; managedBlockSharesCodexHome=$null; sudoAvailable=$null
            error=$null; skipped=$false; reason='没有可用的 WSL2 Ubuntu。'
        }
    }
    $distro = $WslInfo.ubuntuName
    # Keep this in sync with wsl/setup.sh. The additional package and shell
    # state means planning can omit work that a WSL environment already has,
    # rather than treating every full detection as a request to rerun apt.
    $toolScriptText = @'
# This probe runs in a non-interactive shell, where .bashrc is not loaded.
# Include the locations managed by setup.sh and activate fnm so previously
# installed user tools are reported accurately.
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$PATH"
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
    # A command can be visible through PATH but still be non-executable. Keep
    # that state distinct from an installed Linux-native tool.
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

for tool in git gh node npm python3 uv fnm jq rg fd fdfind; do
  report_tool "$tool"
done
'@

    $stateScriptText = @'
for package in git curl ca-certificates build-essential unzip zip jq ripgrep fd-find; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    printf 'package:%s=installed\n' "$package"
  else
    printf 'package:%s=missing\n' "$package"
  fi
done

if command -v sudo >/dev/null 2>&1; then
  printf 'state:sudo=available\n'
else
  printf 'state:sudo=missing\n'
fi
if [[ -d "$HOME/code" ]]; then
  printf 'state:codeRoot=present\n'
else
  printf 'state:codeRoot=missing\n'
fi
if [[ -f "$HOME/.bashrc" ]] && grep -Fq '# >>> CodexDevSetup:WSL >>>' "$HOME/.bashrc"; then
  printf 'state:managedShellBlock=present\n'
  if awk '
    $0 == "# >>> CodexDevSetup:WSL >>>" { inside=1; next }
    $0 == "# <<< CodexDevSetup:WSL <<<" { inside=0 }
    inside && /^export CODEX_HOME=/ { found=1 }
    END { exit !found }
  ' "$HOME/.bashrc"; then
    printf 'state:managedBlockSharesCodexHome=present\n'
  else
    printf 'state:managedBlockSharesCodexHome=missing\n'
  fi
else
  printf 'state:managedShellBlock=missing\n'
  printf 'state:managedBlockSharesCodexHome=not-managed\n'
fi
'@
    # Pass the script over stdin instead of as a wsl.exe command-line argument.
    # The latter can consume Bash variable references such as "$t" while
    # reconstructing the Linux command line. Linux process output is UTF-8,
    # unlike wsl.exe's own --version/--list output which is UTF-16.
    $toolResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('-d', $distro, '--', 'bash', '-s') `
        -StandardInput $toolScriptText -TimeoutSeconds 30 -OutputEncoding ([Text.Encoding]::UTF8)
    # Keep the package and shell-state probe separate from executable version
    # probes. A broken Windows shim inherited through PATH must not prevent us
    # from learning whether apt or sudo is actually needed.
    $stateResult = Invoke-CapturedCommand -Command 'wsl.exe' -Arguments @('-d', $distro, '--', 'bash', '-s') `
        -StandardInput $stateScriptText -TimeoutSeconds 30 -OutputEncoding ([Text.Encoding]::UTF8)
    $toolValues = [ordered]@{}
    $packageValues = [ordered]@{}
    $stateValues = [ordered]@{}
    foreach ($line in @(($toolResult.output, $stateResult.output -join [Environment]::NewLine) -split "`r?`n")) {
        if ($line -match '^tool:([^=]+)=(.*)$') {
            $toolValues[$matches[1]] = $matches[2]
        }
        elseif ($line -match '^package:([^=]+)=(.*)$') {
            $packageValues[$matches[1]] = $matches[2]
        }
        elseif ($line -match '^state:([^=]+)=(.*)$') {
            $stateValues[$matches[1]] = $matches[2]
        }
    }
    $aptPackagesMissing = @($packageValues.GetEnumerator() | Where-Object Value -ne 'installed' | ForEach-Object Key)
    return [pscustomobject]@{
        available=($toolResult.exitCode -eq 0 -and $stateResult.exitCode -eq 0)
        distro=$distro
        tools=[pscustomobject]$toolValues
        packages=[pscustomobject]$packageValues
        aptPackagesMissing=$aptPackagesMissing
        codeRootExists=($stateValues['codeRoot'] -eq 'present')
        managedBlockPresent=($stateValues['managedShellBlock'] -eq 'present')
        managedBlockSharesCodexHome=$(if ($stateValues['managedBlockSharesCodexHome'] -eq 'not-managed') { $null } else { $stateValues['managedBlockSharesCodexHome'] -eq 'present' })
        sudoAvailable=($stateValues['sudo'] -eq 'available')
        error=@($toolResult.error, $stateResult.error | Where-Object { $_ }) -join '; '
        skipped=$false
        reason=$null
    }
}

function Get-CodexSetupDetection {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ProjectPath,
        [switch]$DeepWsl
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    Write-SetupStatus -Kind Info -Message "开始$(if ($DeepWsl) { '完整' } else { '快速' })环境检测。"

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
        $packages = @(Get-AppxPackage -ErrorAction Stop)
        [pscustomobject]@{
            packages=$packages
            terminal=Get-AppxDetection -Pattern 'Microsoft\.WindowsTerminal' -Packages $packages
            codex=Get-AppxDetection -Pattern '(?i)ChatGPT|OpenAI' -Packages $packages
            terminalCommand=Get-CommandInfoSafe 'wt.exe' -SkipVersionProbe
        }
    } -Fallback {
        param($message)
        [pscustomobject]@{
            packages=@()
            terminal=[pscustomobject]@{ installed=$false; packages=@(); error=$message }
            codex=[pscustomobject]@{ installed=$false; packages=@(); error=$message }
            terminalCommand=New-UnavailableCommandInfo -Error $message
        }
    } -ResultSummary {
        param($value)
        $codexText = if ($value.codex.installed) { 'Codex Desktop 可用' } else { '未检测到 Codex Desktop' }
        $terminalText = if ($value.terminal.installed -or $value.terminalCommand.installed) { 'Windows Terminal 可用' } else { '未检测到 Windows Terminal' }
        "$codexText；$terminalText"
    }

    $tools = Invoke-DetectionStage -Index 3 -Name '检测 Windows 开发工具与 PATH' -Issues $issues -Operation {
        $python = Get-CommandInfoSafe 'python.exe' -VersionArguments @('--version') -SkipAppExecutionAliasProbe
        if (-not $python.version -and $python.appExecutionAlias) {
            $pythonPackage = $apps.packages | Where-Object Name -Match '^PythonSoftwareFoundation\.Python' |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($pythonPackage) { $python.version = "Python package $($pythonPackage.Version)" }
        }
        [pscustomobject]@{
            powershell7=Get-CommandInfoSafe 'pwsh.exe' -VersionArguments @('--version')
            winget=Get-CommandInfoSafe 'winget.exe' -VersionArguments @('--version')
            git=Get-CommandInfoSafe 'git.exe' -VersionArguments @('--version')
            githubCli=Get-CommandInfoSafe 'gh.exe' -VersionArguments @('--version')
            node=Get-CommandInfoSafe 'node.exe' -VersionArguments @('--version')
            npm=Get-CommandInfoSafe 'npm.cmd' -VersionArguments @('--version')
            fnm=Get-CommandInfoSafe 'fnm.exe' -VersionArguments @('--version') -PackageId 'Schniz.fnm'
            python=$python
            pythonLauncher=Get-CommandInfoSafe 'py.exe' -VersionArguments @('--version')
            uv=Get-CommandInfoSafe 'uv.exe' -VersionArguments @('--version') -PackageId 'astral-sh.uv'
            codexCli=Get-CommandInfoSafe 'codex.exe' -SkipVersionProbe
            windowsSandboxFeature=Get-WindowsFeatureState 'Containers-DisposableClientVM'
            path=Get-PathDiagnostics
        }
    } -Fallback {
        param($message)
        $missing = New-UnavailableCommandInfo -Error $message
        [pscustomobject]@{
            powershell7=$missing; winget=$missing; git=$missing; githubCli=$missing; node=$missing; npm=$missing
            fnm=$missing; python=$missing; pythonLauncher=$missing; uv=$missing; codexCli=$missing
            windowsSandboxFeature=[pscustomobject]@{ state='Unknown'; available=$false; error=$message }
            path=[pscustomobject]@{ entries=@(); duplicates=@(); missing=@(); conflicts=@(); duplicateEntrypoints=@(); appAliases=@(); shadowedTools=@(); error=$message }
        }
    } -ResultSummary {
        param($value)
        $commonTools = [ordered]@{
            'PowerShell 7'=$value.powershell7; 'WinGet'=$value.winget; 'Git'=$value.git; 'GitHub CLI'=$value.githubCli
            'Node.js'=$value.node; 'Python'=$value.python; 'fnm'=$value.fnm; 'uv'=$value.uv
        }
        $missingToolNames = @($commonTools.GetEnumerator() | Where-Object { -not $_.Value.installed } | ForEach-Object Key)
        $availableCount = $commonTools.Count - $missingToolNames.Count
        $toolText = if ($missingToolNames.Count -eq 0) {
            "$($commonTools.Count) 项常用工具均可用"
        }
        else {
            "常用工具 $availableCount/$($commonTools.Count)；缺少 $($missingToolNames -join '、')"
        }
        $pathConflictCount = @($value.path.conflicts).Count
        $pathMissingCount = @($value.path.missing).Count
        $pathFindings = @()
        if ($pathConflictCount -gt 0) { $pathFindings += "$pathConflictCount 组命令冲突" }
        if ($pathMissingCount -gt 0) { $pathFindings += "$pathMissingCount 个无效目录" }
        $pathText = if ($pathFindings.Count -eq 0) { 'PATH 无需处理' } else { "PATH：$($pathFindings -join '，')" }
        "$toolText；$pathText"
    }

    $wsl = Invoke-DetectionStage -Index 4 -Name '检测 WSL 发行版' -Issues $issues -Operation {
        Get-WslInfo
    } -Fallback {
        param($message)
        [pscustomobject]@{ installed=$false; version=$null; distros=@(); ubuntu=$false; ubuntuName=$null; ubuntuWsl2=$false; detail=''; error=$message }
    } -ResultSummary {
        param($value)
        if ($value.ubuntuWsl2) { "$($value.ubuntuName) 可用；运行于 WSL2" }
        elseif ($value.ubuntu) { "$($value.ubuntuName) 已安装；尚未使用 WSL2" }
        elseif ($value.installed) { 'WSL 可用；尚未安装 Ubuntu' }
        else { '未检测到 WSL' }
    }

    if ($DeepWsl) {
        $wslTools = Invoke-DetectionStage -Index 5 -Name '检测 WSL 工具链（可能需要 5–10 秒）' -Issues $issues -Operation {
            Get-WslToolchainInfo -WslInfo $wsl
        } -Fallback {
            param($message)
            [pscustomobject]@{
                available=$false; distro=$wsl.ubuntuName; tools=[pscustomobject]@{}; packages=[pscustomobject]@{}
                aptPackagesMissing=@(); codeRootExists=$null; managedBlockPresent=$null; managedBlockSharesCodexHome=$null; sudoAvailable=$null
                error=$message; skipped=$false; reason='WSL 工具链检测失败。'
            }
        } -ResultSummary {
            param($value)
            if (-not $value.available) { return $value.reason }
            $requiredToolNames = @('git', 'node', 'npm', 'python3', 'uv', 'fnm', 'jq', 'rg', 'fd')
            $missingToolNames = @($requiredToolNames | Where-Object {
                $property = $value.tools.PSObject.Properties[$_]
                $null -eq $property -or [string]$property.Value -in @('missing', 'windows-path', 'unavailable', '')
            })
            $availableToolCount = $requiredToolNames.Count - $missingToolNames.Count
            $toolText = if ($missingToolNames.Count -eq 0) {
                "$($requiredToolNames.Count) 项主要 Linux 工具均可用"
            }
            else {
                "主要 Linux 工具 $availableToolCount/$($requiredToolNames.Count) 可用；未检测到 $($missingToolNames -join '、')"
            }
            $missingPackageCount = @($value.aptPackagesMissing).Count
            $packageText = if ($missingPackageCount -eq 0) { '基础软件齐全' } else { "还需准备 $missingPackageCount 个基础软件包" }
            "$($value.distro) 可访问；$toolText；$packageText"
        }
    }
    else {
        Write-Host '[5/6] 跳过 WSL 工具链（可从菜单运行完整检测）' -ForegroundColor DarkGray
        Write-Host '      未启动 WSL/Linux；不影响本次快速检查。' -ForegroundColor DarkGray
        Write-SetupLog -Level Debug -Message '快速检测跳过 WSL 工具链'
        $wslTools = Get-WslToolchainInfo -WslInfo $wsl -Skip
    }

    $project = Invoke-DetectionStage -Index 6 -Name '生成项目建议与健康摘要' -Issues $issues -Operation {
        Get-ProjectRecommendation -ProjectPath $ProjectPath
    } -Fallback {
        param($message)
        [pscustomobject]@{ path=$ProjectPath; exists=$false; agent='WSL'; terminal='WSL'; confidence='low'; reasons=@("项目建议检测失败：$message") }
    } -ResultSummary {
        param($value)
        $agentText = if ($value.agent -eq 'WindowsNative') { 'Windows' } else { 'WSL/Linux' }
        $terminalText = if ($value.terminal -eq 'PowerShell7') { 'PowerShell' } else { 'WSL/Linux 终端' }
        "建议使用 $agentText；终端选择 $terminalText"
    }

    foreach ($entry in @($tools.powershell7, $tools.winget, $tools.git, $tools.githubCli, $tools.node, $tools.npm, $tools.python, $tools.uv)) {
        if ($entry.probeError) {
            $issues.Add([pscustomobject]@{ stage=3; name='命令版本探测'; error=$entry.probeError; severity='Warning' })
        }
    }
    if ($apps.terminal.error) { $issues.Add([pscustomobject]@{ stage=2; name='Windows Terminal package'; error=$apps.terminal.error; severity='Warning' }) }
    if ($apps.codex.error) { $issues.Add([pscustomobject]@{ stage=2; name='Codex Desktop package'; error=$apps.codex.error; severity='Warning' }) }
    if ($wsl.error) { $issues.Add([pscustomobject]@{ stage=4; name='WSL'; error=$wsl.error; severity='Warning' }) }
    if (-not $wslTools.skipped -and $wslTools.error) { $issues.Add([pscustomobject]@{ stage=5; name='WSL 工具链'; error=$wslTools.error; severity='Warning' }) }

    $result = [ordered]@{
        detectedAt=(Get-Date).ToString('o')
        detectionMode=$(if ($DeepWsl) { '完整' } else { '快速' })
        windows=$windows
        codexDesktop=$apps.codex
        windowsTerminal=[pscustomobject]@{ command=$apps.terminalCommand; app=$apps.terminal }
        powershell7=$tools.powershell7
        winget=$tools.winget
        git=$tools.git
        githubCli=$tools.githubCli
        node=$tools.node
        npm=$tools.npm
        fnm=$tools.fnm
        python=$tools.python
        pythonLauncher=$tools.pythonLauncher
        uv=$tools.uv
        codexCli=$tools.codexCli
        wsl=$wsl
        wslTools=$wslTools
        windowsSandboxFeature=$tools.windowsSandboxFeature
        path=$tools.path
        project=$project
        issues=@($issues)
        partial=$issues.Count -gt 0
    }
    $score = 100
    if (-not $windows.isWindows11) { $score -= 25 }
    foreach ($required in @($result.powershell7, $result.winget, $result.git)) { if (-not $required.installed) { $score -= 10 } }
    if (-not $result.codexDesktop.installed) { $score -= 15 }
    if (-not $result.githubCli.installed) { $score -= 5 }
    if (-not $wsl.ubuntuWsl2) { $score -= 10 }
    if ($result.path.conflicts.Count -gt 0) { $score -= [math]::Min(15, $result.path.conflicts.Count * 3) }
    $result.healthScore = [math]::Max(0, $score)
    $result.healthLabel = Get-HealthLabel -Score $result.healthScore
    $object = [pscustomobject]$result
    Write-SetupLog -Message '环境检测完成' -Data $object
    return $object
}

Export-ModuleMember -Function @(
    'Get-CodexSetupDetection', 'Get-ProjectRecommendation', 'Invoke-CapturedCommand',
    'Get-CommandInfoSafe', 'Test-IsAppExecutionAlias', 'Get-PathDiagnostics',
    'Get-HealthLabel', 'Get-ToolInstallationRoot', 'Get-WslToolchainInfo', 'Invoke-DetectionStage'
)
