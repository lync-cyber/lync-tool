Set-StrictMode -Version Latest

function Convert-WindowsPathToWsl {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedDistro)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return "/mnt/$($matches[1].ToLowerInvariant())/$($matches[2].Replace('\','/'))"
    }
    if ($full -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.*)$') {
        $pathDistro = $matches[1]
        $linuxPath = $matches[2]
        if ($ExpectedDistro -and $pathDistro -ine $ExpectedDistro) {
            throw "WSL helper 位于 $pathDistro，但计划目标发行版是 $ExpectedDistro；为避免在错误发行版执行，本次已停止。"
        }
        return '/' + $linuxPath.Replace('\', '/')
    }
    throw "无法将路径转换为 WSL 路径：$Path"
}

function Invoke-ExternalSetupCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Quiet
    )
    Write-SetupLog -Message '执行外部命令' -Data @{ command=$Command; arguments=$Arguments }
    if ($Quiet) {
        # Successful setup tools often print English messages such as "already
        # installed". Keep those details in the diagnostic log and only show a
        # short tail if the command actually fails.
        $commandOutput = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        if ($commandOutput.Count -gt 0) {
            Write-SetupLog -Level Debug -Message '外部命令输出已收起' -Data @{
                command=$Command
                output=(ConvertTo-RedactedText (($commandOutput | ForEach-Object { [string]$_ }) -join "`n"))
            }
        }
    }
    else {
        & $Command @Arguments
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = if ($Quiet -and $commandOutput.Count -gt 0) {
            $tail = @($commandOutput | Select-Object -Last 5 | ForEach-Object { [string]$_ }) -join '；'
            "。详情：$(ConvertTo-RedactedText $tail)"
        }
        else { '' }
        throw "命令失败（exit=$exitCode）：$Command $($Arguments -join ' ')$detail"
    }
    return $exitCode
}

function Invoke-InteractiveExternalSetupCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    Write-SetupLog -Message '以前台交互方式执行外部命令' -Data @{ command=$Command; arguments=$Arguments }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Command
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }

    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { throw '进程未能启动。' }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
    }
    catch {
        throw "无法启动交互命令 $Command：$($_.Exception.Message)"
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "命令失败（exit=$exitCode）：$Command $($Arguments -join ' ')"
    }
    return $exitCode
}

function Invoke-WingetReadOnlyQuery {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Purpose
    )
    Write-SetupLog -Message $Purpose -Data @{ command='winget.exe'; arguments=$Arguments; packageId=$PackageId }
    $commandOutput = @(& winget.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = (($commandOutput | ForEach-Object { [string]$_ }) -join "`n")
    Write-SetupLog -Level Debug -Message 'WinGet 查询输出已收起' -Data @{
        packageId=$PackageId; purpose=$Purpose; exitCode=$exitCode; output=(ConvertTo-RedactedText $outputText)
    }
    return [pscustomobject]@{ exitCode=$exitCode; lines=$commandOutput; text=$outputText }
}

function Get-WingetInstalledPackage {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source
    )
    $arguments = @('list', '--id', $PackageId, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    $query = Invoke-WingetReadOnlyQuery -Arguments $arguments -PackageId $PackageId -Purpose '查询软件是否已经安装'
    $packageLines = @($query.lines | ForEach-Object { [string]$_ } | Where-Object {
        $_ -match [regex]::Escape($PackageId)
    })
    $installed = $query.exitCode -eq 0 -and $packageLines.Count -gt 0
    $version = if ($installed) { Get-WingetPackageVersionFromLines -Lines $packageLines -PackageId $PackageId } else { $null }
    return [pscustomobject]@{ installed=$installed; version=$version }
}

function Get-WingetPackageVersionFromLines {
    param(
        [Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][string]$PackageId,
        [ValidateSet('Installed', 'Available')][string]$VersionKind = 'Installed'
    )
    foreach ($lineObject in $Lines) {
        $line = [string]$lineObject
        $idMatch = [regex]::Match($line, '(?<!\S)' + [regex]::Escape($PackageId) + '(?!\S)')
        if (-not $idMatch.Success) { continue }
        $tail = $line.Substring($idMatch.Index + $idMatch.Length).Trim()
        $columns = @($tail -split '\s+' | Where-Object { $_ })
        if ($VersionKind -eq 'Available' -and $columns.Count -lt 3) { return $null }
        $versionIndex = if ($VersionKind -eq 'Available') { 1 } else { 0 }
        if ($columns.Count -gt $versionIndex) { return [string]$columns[$versionIndex] }
    }
    return $null
}

function Install-WingetPackage {
    param([Parameter(Mandatory)]$Action)
    $id = [string]$Action.parameters.packageId
    $source = [string]$Action.parameters.source
    $existingPackage = Get-WingetInstalledPackage -PackageId $id -Source $source
    if ($existingPackage.installed) {
        $versionText = if ($existingPackage.version) { "版本 $($existingPackage.version)；" } else { '' }
        return [pscustomobject]@{ summary="已存在，${versionText}未重复安装"; installedVersion=$existingPackage.version }
    }

    $arguments = @('install', '--id', $id)
    if ($source -eq 'msstore') { $arguments += @('--source', 'msstore') }
    else { $arguments += @('--exact', '--source', 'winget') }
    $arguments += @('--accept-source-agreements', '--accept-package-agreements')
    Invoke-ExternalSetupCommand -Command 'winget.exe' -Arguments $arguments | Out-Null
    $installedPackage = Get-WingetInstalledPackage -PackageId $id -Source $source
    if ($installedPackage.installed) {
        Register-InstalledPackage -Id $id -Source $source
    }
    else {
        Add-RollbackNote "WinGet 已返回安装成功，但无法确认软件包 $id 的登记状态；为避免误卸载，未将其加入自动卸载清单。"
    }
    $installedVersion = $installedPackage.version
    $summary = if ($installedVersion) { "版本 $installedVersion" } else { '安装完成，暂时无法读取版本' }
    return [pscustomobject]@{ summary=$summary; installedVersion=$installedVersion }
}

function Test-WingetPackageUpgrade {
    param([Parameter(Mandatory)]$Action)
    $packageId = [string]$Action.parameters.packageId
    $source = [string]$Action.parameters.source
    $fallbackVersion = if ($Action.parameters.PSObject.Properties.Name -contains 'detectedVersion') {
        [string]$Action.parameters.detectedVersion
    }
    else { $null }
    if ($fallbackVersion -match '(?i)\bv?\d+(?:\.\d+){1,3}\b') { $fallbackVersion = $matches[0] }
    # A normal read-only list includes both the installed and available version
    # when an update exists. One query is enough for the full result.
    $arguments = @('list', '--id', $packageId, '--exact')
    if ($Action.parameters.source -eq 'winget') { $arguments += @('--source', 'winget') }
    else { $arguments += @('--source', 'msstore') }
    $arguments += @('--accept-source-agreements', '--disable-interactivity')
    $query = Invoke-WingetReadOnlyQuery -Arguments $arguments -PackageId $packageId -Purpose '只读查询软件更新'
    $commandOutput = @($query.lines)
    $exitCode = $query.exitCode
    $currentVersion = Get-WingetPackageVersionFromLines -Lines $commandOutput -PackageId $packageId
    if (-not $currentVersion) { $currentVersion = $fallbackVersion }

    if ($exitCode -ne 0) {
        $installedText = if ($currentVersion) { "已安装 $currentVersion；" } else { '' }
        return [pscustomobject]@{
            updateStatus='Unknown'; summary="${installedText}暂时无法确认更新（WinGet 返回 $exitCode）；未执行升级"
            currentVersion=$currentVersion; availableVersion=$null
        }
    }

    $packageLine = @($commandOutput | ForEach-Object { [string]$_ } | Where-Object {
        $_ -match [regex]::Escape($packageId)
    } | Select-Object -First 1)
    if ($packageLine.Count -eq 0 -or -not $currentVersion) {
        return [pscustomobject]@{
            updateStatus='Unknown'; summary='暂时无法读取已安装版本；未执行升级'
            currentVersion=$currentVersion; availableVersion=$null
        }
    }

    $availableVersion = Get-WingetPackageVersionFromLines -Lines $packageLine -PackageId $packageId -VersionKind Available
    if (-not $availableVersion) {
        return [pscustomobject]@{
            updateStatus='Current'; summary="已安装 $currentVersion；未发现可用更新"
            currentVersion=$currentVersion; availableVersion=$null
        }
    }
    $versionText = if ($currentVersion -and $availableVersion) {
        "已安装 $currentVersion；检测到待更新版本 $availableVersion"
    }
    elseif ($availableVersion) { "检测到待更新版本 $availableVersion" }
    else { '已检测到新版本' }
    return [pscustomobject]@{
        updateStatus='Available'; summary="$versionText；本次未安装"
        currentVersion=$currentVersion; availableVersion=$availableVersion
    }
}

function Set-NodeLts {
    $fnm = Resolve-SetupCommandPath -Name 'fnm.exe' -PackageId 'Schniz.fnm'
    if (-not $fnm) { throw 'fnm 安装后尚未出现在 PATH；请重新打开终端后重运行 Node 模块。' }
    Invoke-ExternalSetupCommand -Command $fnm -Arguments @('install', '--lts') -Quiet | Out-Null
    Invoke-ExternalSetupCommand -Command $fnm -Arguments @('default', 'lts-latest') -Quiet | Out-Null
    Add-RollbackNote 'fnm 下载的 Node.js 版本不会由自动回滚删除；可用 fnm list / fnm uninstall 人工管理。'
    $listOutput = @(& $fnm list 2>&1)
    $version = @($listOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -match '(?i)\bv?\d+\.\d+\.\d+\b' } | ForEach-Object { $matches[0] } | Select-Object -First 1)
    $installedVersion = if ($version.Count -gt 0) { [string]$version[0] } else { $null }
    $summary = if ($installedVersion) { "Node.js $installedVersion" } else { 'Node.js 已安装，暂时无法读取版本' }
    return [pscustomobject]@{ summary=$summary; installedVersion=$installedVersion }
}

function Set-PythonWithUv {
    $uv = Resolve-SetupCommandPath -Name 'uv.exe' -PackageId 'astral-sh.uv'
    if (-not $uv) { throw 'uv 安装后尚未出现在 PATH；请重新打开终端后重运行 Python 模块。' }
    Invoke-ExternalSetupCommand -Command $uv -Arguments @('python', 'install') -Quiet | Out-Null
    Add-RollbackNote 'uv 管理的 Python 解释器不会由自动回滚删除；可用 uv python list / uninstall 人工管理。'
    $pythonPathOutput = @(& $uv python find 2>&1)
    $pythonPath = if ($LASTEXITCODE -eq 0) { @($pythonPathOutput | ForEach-Object { [string]$_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1) } else { @() }
    $installedVersion = $null
    if ($pythonPath.Count -gt 0) {
        $pythonExecutable = [string]$pythonPath[0]
        $versionOutput = @(& $pythonExecutable --version 2>&1)
        if ($LASTEXITCODE -eq 0 -and ($versionOutput -join ' ') -match '(?i)Python\s+([0-9]+(?:\.[0-9]+){1,3})') {
            $installedVersion = $matches[1]
        }
    }
    $summary = if ($installedVersion) { "Python $installedVersion" } else { 'Python 已安装，暂时无法读取版本' }
    return [pscustomobject]@{ summary=$summary; installedVersion=$installedVersion }
}

function Set-TomlValue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][System.Collections.Generic.List[string]]$Lines,
        [AllowEmptyString()][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $sectionStart = 0
    $sectionEnd = $Lines.Count
    if ($Section) {
        $headerPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*(?:#.*)?$'
        $sectionStart = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match $headerPattern) { $sectionStart = $i; break }
        }
        if ($sectionStart -lt 0) {
            if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') { [void]$Lines.Add('') }
            [void]$Lines.Add("[$Section]")
            $sectionStart = $Lines.Count - 1
            $sectionEnd = $Lines.Count
        }
        else {
            $sectionEnd = $Lines.Count
            for ($i = $sectionStart + 1; $i -lt $Lines.Count; $i++) {
                if ($Lines[$i] -match '^\s*\[') { $sectionEnd = $i; break }
            }
        }
    }
    else {
        $sectionStart = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\s*\[') { $sectionEnd = $i; break }
        }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($Lines[$i] -match $keyPattern) {
            $Lines[$i] = "$Key = $Value # managed by CodexDevSetup"
            return
        }
    }
    $Lines.Insert($sectionEnd, "$Key = $Value # managed by CodexDevSetup")
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $sectionStart = -1
    $sectionEnd = $Lines.Count
    $headerPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*(?:[;#].*)?$'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $headerPattern) { $sectionStart = $i; break }
    }
    if ($sectionStart -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') { [void]$Lines.Add('') }
        [void]$Lines.Add("[$Section]")
        $sectionStart = $Lines.Count - 1
        $sectionEnd = $Lines.Count
    }
    else {
        for ($i = $sectionStart + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\s*\[') { $sectionEnd = $i; break }
        }
    }
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($Lines[$i] -match $keyPattern) {
            $Lines[$i] = "$Key=$Value"
            return
        }
    }
    $Lines.Insert($sectionEnd, "$Key=$Value")
}

function Quote-TomlString {
    param([Parameter(Mandatory)][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t').Replace("`n", '\n').Replace("`f", '\f').Replace("`r", '\r')
    return '"' + $escaped + '"'
}

function Assert-CodexConfigValues {
    param([Parameter(Mandatory)]$Config)
    $allowed = [ordered]@{
        approvalPolicy=@('untrusted', 'on-request', 'never')
        sandboxMode=@('read-only', 'workspace-write', 'danger-full-access')
        windowsSandbox=@('unelevated', 'elevated')
        webSearch=@('disabled', 'cached', 'indexed', 'live')
        personality=@('', 'none', 'friendly', 'pragmatic')
        reasoningEffort=@('', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
    }
    foreach ($entry in $allowed.GetEnumerator()) {
        $value = [string]$Config.codex.($entry.Key)
        if ($value -notin $entry.Value) {
            throw "Codex 配置值无效：$($entry.Key)=$value"
        }
    }
    foreach ($booleanName in @('checkForUpdateOnStartup', 'networkAccess')) {
        if ($Config.codex.$booleanName -isnot [bool]) { throw "Codex 配置值必须是布尔值：$booleanName" }
    }
}

function Assert-SupportedCodexTomlShape {
    param([AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return }
    if ($Content -match "'''" -or $Content -match '"""') {
        throw '现有 config.toml 含多行字符串；为避免误改，本工具不会自动合并，请先改为普通字符串或手动配置。'
    }
    foreach ($section in @('windows', 'sandbox_workspace_write')) {
        if ($Content -match ('(?m)^\s*' + [regex]::Escape($section) + '\s*=') -or
            $Content -match ('(?m)^\s*' + [regex]::Escape($section) + '\s*\.')) {
            throw "现有 config.toml 使用 $section 的 inline table 或 dotted key；为避免生成重复定义，本工具不会自动合并。"
        }
        $headerMatches = [regex]::Matches($Content, ('(?m)^\s*\[\[?\s*["'']?' + [regex]::Escape($section) + '["'']?\s*\]\]?\s*(?:#.*)?$'))
        if ($headerMatches.Count -gt 1 -or ($headerMatches.Count -eq 1 -and $headerMatches[0].Value -match '^\s*\[\[')) {
            throw "现有 config.toml 中 $section 表重复或使用数组表；本工具不会自动合并。"
        }
    }
}

function Assert-TomlParsesWhenPythonAvailable {
    param([Parameter(Mandatory)][string]$Content)
    $python = Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object {
        $_.Source -and $_.Source -notmatch '(?i)\\WindowsApps\\' -and (Test-Path -LiteralPath $_.Source -PathType Leaf)
    } | Select-Object -First 1
    if ($null -eq $python) { return }
    $temporaryPath = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $temporaryPath -Value $Content -Encoding utf8NoBOM
        $parseOutput = @(& $python.Source -c 'import sys,tomllib; tomllib.load(open(sys.argv[1], "rb"))' $temporaryPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "生成后的 config.toml 未通过 TOML 解析：$(@($parseOutput | Select-Object -Last 1) -join '')"
        }
    }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

function Set-CodexGlobalConfig {
    param([Parameter(Mandatory)]$Config)
    Assert-CodexConfigValues -Config $Config
    $path = Join-Path $env:USERPROFILE '.codex\config.toml'
    $existing = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding utf8 } else { '' }
    Assert-SupportedCodexTomlShape -Content $existing
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($existing -split "`r?`n")) { $lines.Add($line) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    if ($lines.Count -eq 0) { $lines.Add('# Codex user configuration') }

    Set-TomlValue -Lines $lines -Section '' -Key 'approval_policy' -Value (Quote-TomlString $Config.codex.approvalPolicy)
    Set-TomlValue -Lines $lines -Section '' -Key 'sandbox_mode' -Value (Quote-TomlString $Config.codex.sandboxMode)
    Set-TomlValue -Lines $lines -Section '' -Key 'web_search' -Value (Quote-TomlString $Config.codex.webSearch)
    Set-TomlValue -Lines $lines -Section '' -Key 'check_for_update_on_startup' -Value $(if ($Config.codex.checkForUpdateOnStartup) { 'true' } else { 'false' })
    if ($Config.codex.personality) { Set-TomlValue -Lines $lines -Section '' -Key 'personality' -Value (Quote-TomlString $Config.codex.personality) }
    if ($Config.codex.reasoningEffort) { Set-TomlValue -Lines $lines -Section '' -Key 'model_reasoning_effort' -Value (Quote-TomlString $Config.codex.reasoningEffort) }
    if ($Config.codex.model) { Set-TomlValue -Lines $lines -Section '' -Key 'model' -Value (Quote-TomlString $Config.codex.model) }
    Set-TomlValue -Lines $lines -Section 'windows' -Key 'sandbox' -Value (Quote-TomlString $Config.codex.windowsSandbox)
    Set-TomlValue -Lines $lines -Section 'windows' -Key 'sandbox_private_desktop' -Value 'true'
    if ($Config.codex.sandboxMode -eq 'workspace-write') {
        Set-TomlValue -Lines $lines -Section 'sandbox_workspace_write' -Key 'network_access' -Value $(if ($Config.codex.networkAccess) { 'true' } else { 'false' })
    }
    $content = $lines -join [Environment]::NewLine
    Assert-TomlParsesWhenPythonAvailable -Content $content
    Set-SetupFileContent -Path $path -Content $content -Description '更新 Codex 用户级 config.toml' | Out-Null

    $fileAccessText = switch ($Config.codex.sandboxMode) {
        'read-only' { '只读检查，不修改文件' }
        'workspace-write' { '可以修改当前项目，不能越过项目边界' }
        'danger-full-access' { '可以访问当前项目之外的位置（仅适合完全可信的项目）' }
        default { "文件访问方式：$($Config.codex.sandboxMode)" }
    }
    $approvalText = switch ($Config.codex.approvalPolicy) {
        'on-request' { '需要额外权限时先询问' }
        'untrusted' { '不受信任的操作先询问' }
        'never' { '执行时不再询问' }
        default { "操作确认方式：$($Config.codex.approvalPolicy)" }
    }
    $windowsText = if ($Config.codex.windowsSandbox -eq 'unelevated') { 'Windows 使用标准权限' } else { 'Windows 使用增强隔离权限' }
    $webText = if ($Config.codex.webSearch -eq 'live') { '允许实时联网搜索' } else { "联网搜索：$($Config.codex.webSearch)" }
    Write-Host '    已应用 Codex 工作方式：' -ForegroundColor DarkCyan
    Write-Host "      · $fileAccessText"
    Write-Host "      · $approvalText；$windowsText；$webText"
    Write-Host "      · 配置文件：$path" -ForegroundColor DarkGray
    Write-Host '      · 修改前的文件已备份，可从首页选择撤销。' -ForegroundColor DarkGray
}

function Read-ProxyPort {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][int]$DefaultPort)
    while ($true) {
        $raw = (Read-Host "$Label（直接按 Enter 使用 $DefaultPort）").Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultPort }
        $port = 0
        if ([int]::TryParse($raw, [ref]$port) -and $port -ge 1 -and $port -le 65535) { return $port }
        Write-SetupStatus -Kind Warning -Message '端口必须是 1–65535 之间的整数。'
    }
}

function Select-WslNetworkConfiguration {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Detection)
    $network = $Config.wslNetworking
    $detected = $Detection.wslNetwork
    $defaultHttpPort = if ($null -ne $detected) { [int]$detected.recommendedHttpPort } else { 10808 }
    $defaultSocksPort = if ($null -ne $detected) { [int]$detected.recommendedSocksPort } else { $defaultHttpPort }
    Write-Host ''
    Write-Host '  可选：配置 WSL 网络与 v2rayN 代理' -ForegroundColor Cyan
    $currentNetworkMode = if ($null -ne $detected) { [string]$detected.networkingMode } else { '未检测' }
    Write-Host "    当前网络模式：$currentNetworkMode"
    $listenerPorts = @()
    if ($null -ne $detected) {
        $listenerPorts = @($detected.loopbackListeners | ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
    }
    if ($listenerPorts.Count -gt 0) {
        Write-Host "    检测到 Windows localhost 候选端口：$($listenerPorts -join '、')" -ForegroundColor DarkGray
        Write-Host '    端口监听不代表协议；请以 v2rayN 界面中的 HTTP/Mixed 与 SOCKS 端口为准。' -ForegroundColor DarkGray
    }
    $wildcardListeners = @()
    if ($null -ne $detected -and $null -ne $detected.PSObject.Properties['wildcardListeners']) {
        $wildcardListeners = @($detected.wildcardListeners)
    }
    if ($wildcardListeners.Count -gt 0) {
        Write-SetupStatus -Kind Warning -Message '检测到候选代理端口监听在 0.0.0.0 或 ::；请在 v2rayN 中关闭“允许来自局域网的连接”。'
    }
    Write-Host '    [1] 推荐：mirrored + 持久代理'
    Write-Host '        Codex 独立启动的 WSL 进程也会加载代理；本工具不会开启 v2rayN LAN。' -ForegroundColor DarkGray
    Write-Host '    [2] mirrored + 关闭本工具持久代理'
    Write-Host '        同时移除本工具管理的持久代理；不影响 v2rayN 自身设置。' -ForegroundColor DarkGray
    Write-Host '    [3/Enter] 保持现状'
    while ($true) {
        $choice = (Read-Host '  请选择').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' {
                $network.configure = $true
                $network.networkingMode = 'mirrored'
                $network.proxyMode = 'persistent'
                $network.proxyHost = '127.0.0.1'
                $network.httpPort = Read-ProxyPort -Label '  HTTP 或 Mixed 端口' -DefaultPort $defaultHttpPort
                $network.socksPort = Read-ProxyPort -Label '  SOCKS 或 Mixed 端口' -DefaultPort $defaultSocksPort
                Write-SetupStatus -Kind Warning -Message '持久代理启用后，请先启动 v2rayN 再启动 Codex。'
                return
            }
            '2' {
                $network.configure = $true
                $network.networkingMode = 'mirrored'
                $network.proxyMode = 'none'
                return
            }
            { $_ -in @('', '3') } {
                $network.configure = $false
                return
            }
            default { Write-SetupStatus -Kind Warning -Message "无效选项：$choice" }
        }
    }
}

function Set-WslNetworkingConfig {
    param([Parameter(Mandatory)]$Config)
    $network = $Config.wslNetworking
    if ([string]$network.networkingMode -ne 'mirrored') { throw '当前版本只自动配置安全的 WSL mirrored networking。' }
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $existing = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding utf8 } else { '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($existing -split "`r?`n")) { [void]$lines.Add($line) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'networkingMode' -Value 'mirrored'
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'dnsTunneling' -Value $network.dnsTunneling.ToString().ToLowerInvariant()
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'autoProxy' -Value $network.autoProxy.ToString().ToLowerInvariant()
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'firewall' -Value $network.firewall.ToString().ToLowerInvariant()
    $timeout = [int]$network.initialAutoProxyTimeoutMs
    if ($timeout -lt 0 -or $timeout -gt 60000) { throw 'initialAutoProxyTimeoutMs 必须在 0–60000 之间。' }
    Set-IniValue -Lines $lines -Section 'experimental' -Key 'initialAutoProxyTimeout' -Value ([string]$timeout)
    $changed = Set-SetupFileContent -Path $path -Content ($lines -join [Environment]::NewLine) -Description '更新 WSL 全局网络配置'
    Write-Host "    $(if ($changed) { '已更新' } else { '已符合目标配置' })：$path" -ForegroundColor DarkGray
}

function Invoke-WslNetworkSetup {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Config)
    $proxyMode = [string]$Config.wslNetworking.proxyMode
    if ($proxyMode -notin @('persistent', 'none')) { throw "不支持的 WSL 代理模式：$proxyMode" }
    if ([string]$Config.wslNetworking.proxyHost -ne '127.0.0.1') { throw 'mirrored 模式只允许自动配置 127.0.0.1 代理。' }
    foreach ($portName in @('httpPort', 'socksPort')) {
        $port = [int]$Config.wslNetworking.$portName
        if ($port -lt 1 -or $port -gt 65535) { throw "$portName 必须在 1–65535 之间。" }
    }
    $distro = [string]$Action.parameters.distro
    $helper = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wsl\setup.sh'))
    $helperWsl = Convert-WindowsPathToWsl -Path $helper -ExpectedDistro $distro
    $commonArguments = @(
        '-d', $distro, '--', 'bash', $helperWsl, '--network-only',
        '--proxy-mode', $proxyMode, '--proxy-host', [string]$Config.wslNetworking.proxyHost,
        '--proxy-http-port', [string]$Config.wslNetworking.httpPort,
        '--proxy-socks-port', [string]$Config.wslNetworking.socksPort
    )
    if ($Config.codex.shareWindowsHomeToWsl) {
        $codexHomeWsl = Convert-WindowsPathToWsl (Join-Path $env:USERPROFILE '.codex')
        $commonArguments += @('--share-codex-home', $codexHomeWsl)
    }
    # The helper's preview validates its arguments, distro/path, and every managed
    # marker without changing WSL files. Only then update the Windows-side config.
    $preflightArguments = @($commonArguments[0..4]) + @('--what-if') + @($commonArguments[5..($commonArguments.Count - 1)])
    Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments $preflightArguments -Quiet | Out-Null
    Set-WslNetworkingConfig -Config $Config
    $arguments = @($commonArguments[0..4]) + @('--apply') + @($commonArguments[5..($commonArguments.Count - 1)])
    Invoke-InteractiveExternalSetupCommand -Command 'wsl.exe' -Arguments $arguments | Out-Null
    if ($proxyMode -eq 'persistent') {
        Write-Host '    已确认 ~/.config/codex/proxy.sh 由 ~/.profile 与 ~/.bashrc 持久加载。' -ForegroundColor DarkCyan
    }
    else {
        Write-Host '    已保留 mirrored 网络，并关闭本工具管理的 WSL 持久代理。' -ForegroundColor DarkCyan
    }
    Write-Host '    请保存 WSL 中的工作，随后运行 wsl --shutdown，再重新打开 Codex。' -ForegroundColor Yellow
    Add-RollbackNote '.wslconfig 已纳入本次 Windows 回滚清单；WSL 代理变更可用 wsl/setup.sh --rollback --network-only 删除。'
}

function Set-GitBaseline {
    $gitConfig = Join-Path $env:USERPROFILE '.gitconfig'
    Backup-SetupFile -Path $gitConfig | Out-Null
    $settings = [ordered]@{
        'init.defaultBranch' = 'main'
        'fetch.prune'        = 'true'
        'pull.ff'            = 'only'
        'core.autocrlf'      = 'false'
        'core.safecrlf'      = 'warn'
        'credential.helper'  = 'manager'
    }
    foreach ($entry in $settings.GetEnumerator()) {
        Invoke-ExternalSetupCommand -Command 'git.exe' -Arguments @('config', '--global', $entry.Key, $entry.Value) | Out-Null
    }
}

function Get-ManagedBlockContent {
    param(
        [AllowEmptyString()][string]$Existing,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Body,
        [string]$CommentPrefix = '#'
    )
    $start = "$CommentPrefix >>> CodexDevSetup:$Name >>>"
    $end = "$CommentPrefix <<< CodexDevSetup:$Name <<<"
    $pattern = '(?ms)^' + [regex]::Escape($start) + '.*?^' + [regex]::Escape($end) + '\s*'
    $clean = [regex]::Replace($Existing, $pattern, '').TrimEnd()
    $block = "$start`n$($Body.Trim())`n$end"
    if ($clean) { return "$clean`n`n$block`n" }
    return "$block`n"
}

function Set-PowerShellDeveloperProfile {
    param([Parameter(Mandatory)][string]$WindowsProjects)
    $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
    $existing = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw -Encoding utf8 } else { '' }
    $windowsProjectsLiteral = "'" + $WindowsProjects.Replace("'", "''") + "'"
    $body = @'
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
}
function gst { git status --short --branch @args }
function gdf { git diff @args }
function cproj { Set-Location -LiteralPath __WINDOWS_PROJECTS__ }
function wproj { wsl.exe --cd '~' }
'@
    $body = $body.Replace('__WINDOWS_PROJECTS__', $windowsProjectsLiteral)
    $content = Get-ManagedBlockContent -Existing $existing -Name 'PowerShellProfile' -Body $body
    Set-SetupFileContent -Path $profilePath -Content $content -Description '更新 PowerShell 7 开发快捷命令' | Out-Null
    Write-Host '    已添加 PowerShell 7 快捷功能：' -ForegroundColor DarkCyan
    Write-Host '      · 进入项目文件夹时，自动切换项目需要的 Node.js 版本。'
    Write-Host '      · gst：查看 Git 状态；gdf：查看代码差异。'
    Write-Host '      · cproj：进入 Windows 项目目录；wproj：打开 WSL/Linux。'
    Write-Host "      · 配置文件：$profilePath" -ForegroundColor DarkGray
    Write-Host '      · 只更新本工具标记的区块，不覆盖原有快捷命令。' -ForegroundColor DarkGray
}

function Set-TerminalFragment {
    param(
        [string]$Distro = 'Ubuntu',
        [Parameter(Mandatory)][string]$WindowsProjects
    )
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\CodexDevSetup\codex.json'
    $fragment = [ordered]@{
        profiles = @(
            [ordered]@{
                name = 'Codex Windows (PowerShell 7)'
                guid = '{2c4b1c53-58df-4b35-b2ab-3cbf5e9c7d01}'
                commandline = 'pwsh.exe -NoLogo'
                startingDirectory = $WindowsProjects
            },
            [ordered]@{
                name = 'Codex WSL (Ubuntu)'
                guid = '{49e8ae7a-3d8c-4a1e-a08f-9490e1d7e102}'
                commandline = "wsl.exe -d $Distro --cd ~"
                startingDirectory = '~'
            }
        )
    }
    $content = $fragment | ConvertTo-Json -Depth 10
    Set-SetupFileContent -Path $path -Content $content -Description '创建 Windows Terminal Codex profiles fragment' | Out-Null
    Write-Host '    已添加两个 Windows Terminal 启动项：' -ForegroundColor DarkCyan
    Write-Host '      · Codex Windows：使用 PowerShell 7，从 Windows 项目目录启动。'
    Write-Host "      · Codex WSL：使用 $Distro，从 Linux 主目录启动。"
    Write-Host "      · 配置文件：$path" -ForegroundColor DarkGray
    Write-Host '      · 使用 Terminal 官方扩展文件，不覆盖现有终端设置。' -ForegroundColor DarkGray
}

function Select-CodexConfigurationPreset {
    param([Parameter(Mandatory)]$Config)

    while ($true) {
        Write-Host ''
        Write-Host '  选择 Codex 工作方式' -ForegroundColor Cyan
        Write-Host '    [1/Enter] 日常开发（推荐）'
        Write-Host '              可以修改当前项目；需要额外权限时先询问。' -ForegroundColor DarkGray
        Write-Host '    [2]       只读检查'
        Write-Host '              可以阅读和分析，但不修改文件。' -ForegroundColor DarkGray
        Write-Host '    [3]       可信项目完全访问'
        Write-Host '              可以访问项目之外的位置；仅用于完全可信的个人项目。' -ForegroundColor Yellow
        Write-Host '    [B]       返回，不设置 Codex'
        $choice = (Read-Host '  请选择').Trim().ToUpperInvariant()
        switch ($choice) {
            { $_ -in @('', '1') } {
                $Config.codex.sandboxMode = 'workspace-write'
                $Config.codex.approvalPolicy = 'on-request'
                $Config.codex.windowsSandbox = 'unelevated'
                $Config.codex.webSearch = 'live'
                $Config.codex.networkAccess = $true
                return $true
            }
            '2' {
                $Config.codex.sandboxMode = 'read-only'
                $Config.codex.approvalPolicy = 'on-request'
                $Config.codex.windowsSandbox = 'unelevated'
                $Config.codex.webSearch = 'live'
                return $true
            }
            '3' {
                Write-SetupStatus -Kind Warning -Message '完全访问不受当前项目边界限制，可能修改其他文件。'
                if (Confirm-SetupChoice -Prompt '确认只在完全可信的个人项目中使用完全访问吗？' -DefaultYes:$false) {
                    $Config.codex.sandboxMode = 'danger-full-access'
                    $Config.codex.approvalPolicy = 'on-request'
                    $Config.codex.windowsSandbox = 'unelevated'
                    $Config.codex.webSearch = 'live'
                    return $true
                }
            }
            'B' { return $false }
            default { Write-SetupStatus -Kind Warning -Message "无效选项：$choice" }
        }
    }
}

function Invoke-WslSetup {
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Config
    )
    $helper = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wsl\setup.sh'))
    $helperWsl = Convert-WindowsPathToWsl $helper
    $codexHomeWsl = Convert-WindowsPathToWsl (Join-Path $env:USERPROFILE '.codex')
    $distro = [string]$Action.parameters.distro
    $codeRoot = Resolve-WslUserPath -Distro $distro -Path ([string]$Config.paths.wslProjects)
    $arguments = @('-d', $distro, '--', 'bash', $helperWsl, '--apply', '--code-root', $codeRoot)
    $wslPackageConfiguration = Get-WslPackageConfiguration -Config $Config
    foreach ($packageName in @($wslPackageConfiguration.packageNames)) {
        $arguments += @('--apt-package', [string]$packageName)
    }
    foreach ($alias in @($wslPackageConfiguration.aliases)) {
        $arguments += @('--command-alias', "$($alias.name)=$($alias.target)")
    }
    if ($Action.parameters.shareCodexHome) { $arguments += @('--share-codex-home', $codexHomeWsl) }
    $installNode = if ($Action.parameters.PSObject.Properties.Name -contains 'installNode') {
        [bool]$Action.parameters.installNode
    }
    else { $Config.toolchains.node.manager -eq 'fnm' }
    $installPython = if ($Action.parameters.PSObject.Properties.Name -contains 'installPython') {
        [bool]$Action.parameters.installPython
    }
    else { $Config.toolchains.python.manager -eq 'uv' }
    if ($installNode) { $arguments += '--install-node' }
    if ($installPython) { $arguments += '--install-python' }
    Write-Host ''
    Write-Host '  WSL/Linux 设置将在当前窗口中继续。' -ForegroundColor Cyan
    Write-Host '  如果要求输入密码，请输入 Ubuntu 用户密码后按 Enter。' -ForegroundColor DarkGray
    Write-Host '  输入密码时屏幕不会显示字符；验证通过后会继续显示安装进度。' -ForegroundColor DarkGray
    Write-Host ''
    # Start the child with inherited console handles. Piping wsl.exe through
    # PowerShell (especially into Out-Null) hides stdout after sudo succeeds and
    # makes a healthy apt run look frozen to the user.
    Invoke-InteractiveExternalSetupCommand -Command 'wsl.exe' -Arguments $arguments | Out-Null
    Add-RollbackNote 'WSL 内已配置的 APT 软件包及 fnm/uv 安装不会由 Windows 回滚自动卸载；.bashrc 变更可用 wsl/setup.sh --rollback 删除。'
    $ghProbeScript = 'gh_path="$(command -v gh 2>/dev/null || true)"; case "$gh_path" in ""|/mnt/[a-zA-Z]/*) exit 0;; esac; version="$(gh --version 2>/dev/null | head -n 1)"; printf "ghVersion=%s\n" "$version"; if gh auth status >/dev/null 2>&1; then printf "ghAuth=authenticated\n"; else printf "ghAuth=unauthenticated\n"; fi'
    $ghProbeOutput = @(& wsl.exe -d $distro -- bash -lc $ghProbeScript 2>&1 | ForEach-Object { [string]$_ })
    $ghVersion = @($ghProbeOutput | Where-Object { $_ -match '^ghVersion=(.*)$' } | ForEach-Object { $_ -replace '^ghVersion=', '' } | Select-Object -First 1)
    $ghAuth = @($ghProbeOutput | Where-Object { $_ -match '^ghAuth=(.*)$' } | ForEach-Object { $_ -replace '^ghAuth=', '' } | Select-Object -First 1)
    if ($ghVersion.Count -gt 0) {
        $authText = if ($ghAuth.Count -gt 0 -and $ghAuth[0] -eq 'authenticated') { '已登录' } else { '未登录；需要时运行 gh auth login' }
        return [pscustomobject]@{ summary="Linux $($ghVersion[0])；GitHub $authText"; githubVersion=$ghVersion[0]; githubAuthStatus=$(if ($ghAuth.Count -gt 0) { $ghAuth[0] } else { 'unknown' }) }
    }
}

function New-ProjectTemplateMap {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)]$Config,
        [string]$RecommendedAgent = 'WSL'
    )
    $agentLabel = if ($RecommendedAgent -eq 'WindowsNative') { 'Windows native / PowerShell 7' } else { 'WSL2 / Bash' }
    $templateRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates\project'))
    $agents = Get-Content -LiteralPath (Join-Path $templateRoot 'AGENTS.md.template') -Raw -Encoding utf8
    $agents = $agents.Replace('{{AGENT_LABEL}}', $agentLabel)
    $networkBlock = if ($Config.codex.sandboxMode -eq 'workspace-write') {
        "`n[sandbox_workspace_write]`nnetwork_access = $($Config.codex.networkAccess.ToString().ToLowerInvariant())"
    } else { '' }
    $projectToml = Get-Content -LiteralPath (Join-Path $templateRoot 'config.toml.template') -Raw -Encoding utf8
    $projectToml = $projectToml.Replace('{{APPROVAL_POLICY}}', $Config.codex.approvalPolicy)
    $projectToml = $projectToml.Replace('{{SANDBOX_MODE}}', $Config.codex.sandboxMode)
    $projectToml = $projectToml.Replace('{{WEB_SEARCH}}', $Config.codex.webSearch)
    $projectToml = $projectToml.Replace('{{WORKSPACE_NETWORK_BLOCK}}', $networkBlock)
    $editorConfig = Get-Content -LiteralPath (Join-Path $templateRoot 'editorconfig.template') -Raw -Encoding utf8
    $gitattributes = Get-Content -LiteralPath (Join-Path $templateRoot 'gitattributes.template') -Raw -Encoding utf8
    $gitignore = Get-Content -LiteralPath (Join-Path $templateRoot 'gitignore.template') -Raw -Encoding utf8
    return [ordered]@{
        (Join-Path $ProjectPath 'AGENTS.md') = $agents
        (Join-Path $ProjectPath '.codex\config.toml') = $projectToml
        (Join-Path $ProjectPath '.editorconfig') = $editorConfig
        (Join-Path $ProjectPath '.gitattributes') = $gitattributes
        (Join-Path $ProjectPath '.gitignore') = $gitignore
    }
}

function Set-ProjectTemplates {
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Config,
        [switch]$NonInteractive
    )
    $projectPath = [System.IO.Path]::GetFullPath($Action.parameters.projectPath)
    [System.IO.Directory]::CreateDirectory($projectPath) | Out-Null
    $templates = New-ProjectTemplateMap -ProjectPath $projectPath -Config $Config -RecommendedAgent $Action.parameters.agent
    foreach ($entry in $templates.GetEnumerator()) {
        $path = $entry.Key
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $current = Get-Content -LiteralPath $path -Raw -Encoding utf8
            $desired = $entry.Value.TrimEnd("`r", "`n") + [Environment]::NewLine
            if ($current -eq $desired) { continue }
            $replace = Confirm-SetupChoice -Prompt "文件已存在，是否备份并替换？$path" -DefaultYes:$false -NonInteractive:$NonInteractive
            if (-not $replace) {
                $candidate = "$path.codex-setup.candidate"
                Set-SetupFileContent -Path $candidate -Content $entry.Value -Description '写入项目模板候选文件' | Out-Null
                continue
            }
        }
        Set-SetupFileContent -Path $path -Content $entry.Value -Description '写入项目标准模板' | Out-Null
    }
}

function Show-AuthenticationGuidance {
    Write-Host ''
    Write-Host '    推荐方式：通过 GitHub CLI 在浏览器登录' -ForegroundColor Cyan
    Write-Host '      1. 在新终端运行：'
    Write-Host '         gh auth login' -ForegroundColor DarkCyan
    Write-Host '      2. 按终端提示打开浏览器并完成授权。'
    Write-Host '      3. 返回终端检查登录状态：'
    Write-Host '         gh auth status' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    如果项目明确要求使用 SSH（可选）' -ForegroundColor Cyan
    Write-Host '      · 查看已有公钥：Get-Content $HOME\.ssh\id_ed25519.pub'
    Write-Host '      · 没有公钥时新建：ssh-keygen -t ed25519 -C "你的公开邮箱或标签"'
    Write-Host '      · 将公钥添加到 GitHub 后测试：ssh -T git@github.com'
    Write-Host ''
    Write-Host '    登录可稍后完成；本工具不会读取令牌、密码或 SSH 私钥。' -ForegroundColor DarkGray
    Add-RollbackNote 'GitHub CLI/SSH 登录由用户在官方交互流程中完成；认证状态不纳入回滚。'
}

function Invoke-SetupAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Config,
        [switch]$NonInteractive
    )
    switch ($Action.type) {
        'WingetInstall'       { Install-WingetPackage -Action $Action }
        'WingetUpgradeCheck'  { Test-WingetPackageUpgrade -Action $Action }
        'NodeConfigure'       { Set-NodeLts }
        'PythonConfigure'     { Set-PythonWithUv }
        'WslInstall'          { Invoke-ExternalSetupCommand 'wsl.exe' @('--install', '--distribution', 'Ubuntu') | Out-Null; Add-RollbackNote 'WSL 安装可能需要重启；脚本不会自动注销发行版。' }
        'WslInstallDistro'    { Invoke-ExternalSetupCommand 'wsl.exe' @('--install', '--distribution', 'Ubuntu') | Out-Null; Add-RollbackNote 'Ubuntu 安装不会由自动回滚注销，以避免数据丢失。' }
        'WslConvert2'         { Invoke-ExternalSetupCommand 'wsl.exe' @('--set-version', $Action.parameters.distro, '2') | Out-Null; Add-RollbackNote 'WSL2 转换不会自动降级回 WSL1。' }
        'WslConfigure'        { Invoke-WslSetup -Action $Action -Config $Config }
        'WslNetworkConfigure' { Invoke-WslNetworkSetup -Action $Action -Config $Config }
        'GitConfig'           { Set-GitBaseline }
        'AuthGuidance'        { Show-AuthenticationGuidance }
        'TerminalFragment'    { Set-TerminalFragment -Distro $Action.parameters.distro -WindowsProjects $Action.parameters.windowsProjects }
        'PowerShellProfile'   { Set-PowerShellDeveloperProfile -WindowsProjects $Action.parameters.windowsProjects }
        'CodexGlobalConfig'   { Set-CodexGlobalConfig -Config $Config }
        'ProjectTemplates'    { Set-ProjectTemplates -Action $Action -Config $Config -NonInteractive:$NonInteractive }
        default               { throw "未知操作类型：$($Action.type)" }
    }
}

function Show-WslPasswordRecoveryGuidance {
    param([Parameter(Mandatory)]$Action)

    $distro = [string]$Action.parameters.distro
    if ([string]::IsNullOrWhiteSpace($distro)) { $distro = 'Ubuntu' }
    Write-Host ''
    Write-Host '如果忘记了 Ubuntu/WSL 用户密码，可以稍后这样恢复：' -ForegroundColor Cyan
    Write-Host "  1. 另开一个 PowerShell 窗口，运行：wsl.exe -d $distro -u root"
    Write-Host '  2. 在打开的 Linux 终端中运行：passwd <你的 Ubuntu 用户名>'
    Write-Host '  3. 设置新密码后运行 exit，再回到本工具重试。'
    Write-Host '提示：这只修改该 Ubuntu 发行版的 Linux 用户密码，不会修改 Windows 密码。' -ForegroundColor DarkGray
}

function Read-WslFailureChoice {
    while ($true) {
        Write-Host '[R] 重试  [S/Enter] 暂时跳过  [H] 查看密码恢复方法  [Q] 结束设置' -ForegroundColor Yellow
        $answer = (Read-Host '请选择').Trim().ToUpperInvariant()
        switch ($answer) {
            'R' { return 'Retry' }
            'H' { return 'Help' }
            'Q' { return 'Quit' }
            ''  { return 'Skip' }
            'S' { return 'Skip' }
            default { Write-SetupStatus -Kind Warning -Message "无效选项：$answer" }
        }
    }
}

function Invoke-CodexSetupPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Config,
        [switch]$NonInteractive,
        [switch]$ConfirmModules
    )
    $results = @()
    $failedOrBlockedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $applyRemainingOrdinary = $false
    $stopRequested = $false
    $modules = @(Get-SetupOrderedModules -Actions $Plan.actions)
    for ($moduleIndex = 0; $moduleIndex -lt $modules.Count; $moduleIndex++) {
        $module = $modules[$moduleIndex]
        $groupActions = @($Plan.actions | Where-Object module -eq $module)
        if ($stopRequested) {
            foreach ($action in $groupActions) {
                [void]$failedOrBlockedIds.Add([string]$action.id)
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error='用户已结束后续设置。'; durationMs=0 }
            }
            continue
        }
        $moduleDisplayName = Get-SetupModuleDisplayName -Module $module
        if (-not $WhatIfPreference) {
            Write-SetupSectionHeader -Title ("工作步骤 {0}/{1} · {2}（{3} 项）" -f ($moduleIndex + 1), $modules.Count, $moduleDisplayName, $groupActions.Count)
        }
        $runModule = $true
        if ($ConfirmModules -and -not $WhatIfPreference) {
            # -ApplyChanges is the explicit mutation gate. In non-interactive replay,
            # module prompts cannot surface, so the exported policy is accepted as-is.
            if ($NonInteractive) {
                $runModule = $true
            }
            elseif ($applyRemainingOrdinary -and -not ($groupActions.critical -contains $true)) {
                Write-SetupStatus -Kind Info -Message "按你的选择继续设置：$(Get-SetupModuleDisplayName -Module $module)"
                $runModule = $true
            }
            else {
                $hasCriticalAction = $groupActions.critical -contains $true
                if ($hasCriticalAction) {
                    Write-SetupStatus -Kind Warning -Message "$moduleDisplayName 包含需要特别留意的设置，仍会单独确认。"
                }
                do {
                    $continueLabel = if ($module -eq 'Updates') { '检查' } else { '设置' }
                    if ($module -eq 'CodexConfig') {
                        Write-Host '[Y] 使用推荐设置   [C] 选择工作方式   [S/Enter] 暂不处理   [Q] 结束' -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host "[Y] $continueLabel   [S/Enter] 暂不处理   [A] 后续普通项目自动继续   [Q] 结束" -ForegroundColor DarkGray
                    }
                    $rawChoice = Read-Host '请选择'
                    $validPattern = if ($module -eq 'CodexConfig') {
                        '^(?i:y|yes|是|确认|c|custom|自定义|s|skip|跳过|q|quit|退出)$'
                    }
                    else {
                        '^(?i:y|yes|是|确认|s|skip|跳过|a|all|全部|q|quit|退出)$'
                    }
                    $validChoice = [string]::IsNullOrWhiteSpace($rawChoice) -or $rawChoice.Trim() -match $validPattern
                    if (-not $validChoice) { Write-SetupStatus -Kind Warning -Message "无效选项：$rawChoice" }
                } while (-not $validChoice)
                $isCodexCustomChoice = $module -eq 'CodexConfig' -and $rawChoice.Trim() -match '^(?i:c|custom|自定义)$'
                $moduleChoice = if ($isCodexCustomChoice) {
                    [pscustomobject]@{ choice='CustomCodex'; applyRemainingOrdinary=$false; requiresSeparateConfirmation=$false }
                }
                else {
                    Resolve-SetupModuleChoice -Answer $rawChoice -HasCriticalAction:$hasCriticalAction
                }
                if ($moduleChoice.applyRemainingOrdinary) { $applyRemainingOrdinary = $true }
                switch ($moduleChoice.choice) {
                    'Quit' {
                        $stopRequested = $true
                        $runModule = $false
                    }
                    'ApplyModule' {
                        $runModule = $true
                        if ($moduleChoice.requiresSeparateConfirmation) {
                            $criticalPrompt = '确认继续设置“{0}”中的高风险项目吗？' -f $moduleDisplayName
                            $runModule = Confirm-SetupChoice -Prompt $criticalPrompt -DefaultYes:$false
                        }
                    }
                    'CustomCodex' {
                        $runModule = Select-CodexConfigurationPreset -Config $Config
                    }
                    default { $runModule = $false }
                }
            }
        }
        if (-not $runModule) {
            $skipReason = if ($stopRequested) { '用户已结束后续设置。' } else { $null }
            foreach ($action in $groupActions) {
                [void]$failedOrBlockedIds.Add([string]$action.id)
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error=$skipReason; durationMs=0 }
            }
            continue
        }
        $updateOutcomes = @()
        for ($actionIndex = 0; $actionIndex -lt $groupActions.Count; $actionIndex++) {
            $action = $groupActions[$actionIndex]
            $actionProgress = '{0}/{1}' -f ($actionIndex + 1), $groupActions.Count
            $dependsOn = if ($action.PSObject.Properties.Name -contains 'dependsOn') { @($action.dependsOn) } else { @() }
            $blockingDependencies = @($dependsOn | Where-Object { $failedOrBlockedIds.Contains([string]$_) })
            if ($blockingDependencies.Count -gt 0) {
                $dependencyMessage = "前置步骤未完成：$($blockingDependencies -join '、')"
                Write-Host "  [$actionProgress 已跳过] $($action.title)：$dependencyMessage。" -ForegroundColor Yellow
                [void]$failedOrBlockedIds.Add([string]$action.id)
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error=$dependencyMessage; durationMs=0 }
                continue
            }
            # PowerShell's built-in WhatIf message exposes implementation jargon for every
            # action. The plan has already been shown in plain language, so record a clear
            # preview result here instead of emitting a noisy line for each operation.
            if ($WhatIfPreference) {
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Preview'; error=$null; durationMs=0 }
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($action.target, $action.title)) {
                [void]$failedOrBlockedIds.Add([string]$action.id)
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error=$null; durationMs=0 }
                continue
            }
            $actionTimer = [Diagnostics.Stopwatch]::StartNew()
            $actionStatus = 'Failed'
            $actionError = $null
            $actionOutcome = $null
            :actionAttempt while ($true) {
                try {
                    $progressLabel = switch ($action.type) {
                        'AuthGuidance' { '登录说明' }
                        'WingetUpgradeCheck' { '检查中' }
                        default { '进行中' }
                    }
                    Write-Host "  [$actionProgress $progressLabel] $($action.title)" -ForegroundColor Cyan
                    Write-SetupLog -Message '开始设置项目' -Data @{ id=$action.id; module=$module; title=$action.title }
                    $actionOutcome = Invoke-SetupAction -Action $action -Config $Config -NonInteractive:$NonInteractive
                    $actionStatus = 'Completed'
                    $actionError = $null
                    break actionAttempt
                }
                catch {
                    $message = ConvertTo-RedactedText $_.Exception.Message
                    $isWslPasswordFailure = $action.type -eq 'WslConfigure' -and $message -match '(?:exit=77|CODEX_SETUP_SUDO_AUTH_FAILED)'
                    $isWslSudoUnavailable = $action.type -eq 'WslConfigure' -and $message -match '(?:exit=78|CODEX_SETUP_SUDO_UNAVAILABLE)'
                    $isWslShellMarkerFailure = $action.type -eq 'WslConfigure' -and $message -match '(?:exit=79|CODEX_SETUP_SHELL_MARKERS_INVALID)'
                    if ($isWslPasswordFailure) {
                        $actionError = 'Ubuntu/WSL 用户密码验证失败；尚未安装缺少的 Linux 系统工具。'
                        Write-SetupStatus -Kind Error -Message $actionError
                        if (-not $NonInteractive) {
                            do {
                                $failureChoice = Read-WslFailureChoice
                                if ($failureChoice -eq 'Help') { Show-WslPasswordRecoveryGuidance -Action $action }
                            } while ($failureChoice -eq 'Help')
                            if ($failureChoice -eq 'Retry') { continue actionAttempt }
                            if ($failureChoice -eq 'Quit') { $stopRequested = $true }
                        }
                    }
                    elseif ($isWslSudoUnavailable) {
                        $actionError = 'Ubuntu 中没有可用的 sudo，无法自动安装缺少的 Linux 系统工具。'
                        Write-SetupStatus -Kind Error -Message $actionError
                    }
                    elseif ($isWslShellMarkerFailure) {
                        $actionError = 'Ubuntu 的 .bashrc 中存在不完整或重复的 Codex 管理区块；为保护原有终端设置，本次没有修改该文件或继续安装。'
                        Write-SetupStatus -Kind Error -Message $actionError
                        Write-Host '  请检查并修复成对的 CodexDevSetup:WSL 开始/结束标记，然后重新运行。' -ForegroundColor DarkGray
                    }
                    else {
                        $actionError = $message
                        Write-SetupStatus -Kind Error -Message "$($action.title) 失败：$message"
                    }
                    break actionAttempt
                }
            }
            $actionTimer.Stop()
            if ($actionStatus -eq 'Completed') {
                if ($action.type -eq 'WingetUpgradeCheck') {
                    $softwareName = ([string]$action.title -replace '^检查\s*', '') -replace '\s*更新$', ''
                    $summaryText = if ($null -ne $actionOutcome -and $actionOutcome.PSObject.Properties.Name -contains 'summary') {
                        [string]$actionOutcome.summary
                    }
                    else { '检查完成；未执行升级' }
                    $resultColor = if ($null -ne $actionOutcome -and $actionOutcome.updateStatus -eq 'Available') { 'Yellow' } elseif ($null -ne $actionOutcome -and $actionOutcome.updateStatus -eq 'Unknown') { 'DarkYellow' } else { 'Green' }
                    Write-Host (('  [{0} 结果] {1}：{2}（{3:N1}s）' -f $actionProgress, $softwareName, $summaryText, $actionTimer.Elapsed.TotalSeconds)) -ForegroundColor $resultColor
                    if ($null -ne $actionOutcome) { $updateOutcomes += $actionOutcome }
                }
                elseif ($action.type -ne 'AuthGuidance') {
                    $completionSummary = if ($null -ne $actionOutcome -and $actionOutcome.PSObject.Properties.Name -contains 'summary') {
                        [string]$actionOutcome.summary
                    }
                    else { $null }
                    $completionPrefix = if ($completionSummary) { "$completionSummary；" } else { '' }
                    Write-Host (('  [{0} 完成] {1}（{2}{3:N1}s）' -f $actionProgress, $action.title, $completionPrefix, $actionTimer.Elapsed.TotalSeconds)) -ForegroundColor Green
                }
                Write-SetupLog -Message '设置项目完成' -Data @{ id=$action.id; module=$module; title=$action.title; durationMs=[math]::Round($actionTimer.Elapsed.TotalMilliseconds); detail=$actionOutcome }
            }
            else {
                [void]$failedOrBlockedIds.Add([string]$action.id)
                if ($action.critical) { Write-SetupStatus -Kind Warning -Message '关键操作失败；继续执行不依赖此操作的模块。' }
            }
            $results += [pscustomobject]@{ id=$action.id; module=$module; status=$actionStatus; error=$actionError; detail=$actionOutcome; durationMs=[math]::Round($actionTimer.Elapsed.TotalMilliseconds) }
        }
        if ($module -eq 'Updates' -and -not $WhatIfPreference -and $updateOutcomes.Count -gt 0) {
            $availableUpdates = @($updateOutcomes | Where-Object updateStatus -eq 'Available').Count
            $currentPackages = @($updateOutcomes | Where-Object updateStatus -eq 'Current').Count
            $unknownPackages = @($updateOutcomes | Where-Object updateStatus -eq 'Unknown').Count
            Write-Host ''
            Write-Host '  更新检查摘要' -ForegroundColor Cyan
            Write-Host "    有可用更新：$availableUpdates 项；未发现更新：$currentPackages 项；无法确认：$unknownPackages 项。"
            Write-Host '    本步骤只进行了查询，没有下载或安装更新。' -ForegroundColor DarkGray
        }
    }
    return $results
}

function Get-DefaultSetupStateRoot {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    return Join-Path $base 'CodexDevSetup'
}

function Test-SetupPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Read-ValidatedRollbackManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $fullManifestPath -PathType Leaf)) { throw "回滚清单不存在：$fullManifestPath" }
    $runsRoot = [System.IO.Path]::GetFullPath((Join-Path $StateRoot 'runs'))
    $runRoot = Split-Path -Parent $fullManifestPath
    if ((Split-Path -Parent $runRoot) -ne $runsRoot -or (Split-Path -Leaf $fullManifestPath) -ne 'rollback-manifest.json') {
        throw '回滚清单不在本工具的 runs 目录中，已拒绝执行。'
    }

    try { $manifest = Get-Content -LiteralPath $fullManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "回滚清单不是有效的 JSON：$($_.Exception.Message)" }
    if ($manifest.schemaVersion -ne 1) { throw '回滚清单版本不受支持。' }
    if ([string]$manifest.runId -ne (Split-Path -Leaf $runRoot)) { throw '回滚清单的运行编号与所在目录不一致。' }

    $files = @($manifest.files)
    if ($files.Count -gt 1000) { throw '回滚清单包含过多文件记录，已拒绝执行。' }
    $backupRoot = Join-Path $runRoot 'backups'
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace([string]$file.path) -or -not [System.IO.Path]::IsPathFullyQualified([string]$file.path)) {
            throw '回滚清单包含无效的目标文件路径。'
        }
        if ($file.existed -isnot [bool]) { throw "回滚清单的 existed 字段无效：$($file.path)" }
        if ($file.existed) {
            if ([string]::IsNullOrWhiteSpace([string]$file.backup) -or
                -not (Test-SetupPathWithinRoot -Path ([string]$file.backup) -Root $backupRoot) -or
                -not (Test-Path -LiteralPath ([string]$file.backup) -PathType Leaf)) {
                throw "回滚备份缺失或超出本次运行目录：$($file.path)"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$file.backup)) {
            throw "原本不存在的文件不应带有备份路径：$($file.path)"
        }
    }

    $packages = @($manifest.installedPackages)
    foreach ($package in $packages) {
        if ([string]$package.id -notmatch '^[A-Za-z0-9._-]+$' -or [string]$package.source -notin @('winget', 'msstore')) {
            throw '回滚清单包含无效的软件包记录。'
        }
    }
    return [pscustomobject]@{
        path=$fullManifestPath; files=$files; installedPackages=$packages; notes=@($manifest.notes)
    }
}

function Invoke-CodexSetupRollback {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$NonInteractive,
        [string]$StateRoot = (Get-DefaultSetupStateRoot)
    )
    # Validate the complete manifest before touching any target. A user-supplied
    # JSON file must never turn rollback into an arbitrary copy/delete primitive.
    $manifest = Read-ValidatedRollbackManifest -ManifestPath $ManifestPath -StateRoot $StateRoot
    foreach ($file in @($manifest.files | Select-Object -Last 999 | Sort-Object { [array]::IndexOf($manifest.files, $_) } -Descending)) {
        if ($file.existed -and $file.backup -and (Test-Path -LiteralPath $file.backup)) {
            if ($PSCmdlet.ShouldProcess($file.path, '恢复备份文件')) {
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $file.path)) | Out-Null
                Copy-Item -LiteralPath $file.backup -Destination $file.path -Force
            }
        }
        elseif (-not $file.existed -and (Test-Path -LiteralPath $file.path)) {
            if ($PSCmdlet.ShouldProcess($file.path, '删除本次运行创建的文件')) { Remove-Item -LiteralPath $file.path -Force }
        }
    }
    foreach ($package in @($manifest.installedPackages)) {
        $remove = Confirm-SetupChoice -Prompt "是否卸载本次安装的软件包 $($package.id)？" -DefaultYes:$false -NonInteractive:$NonInteractive
        if ($remove -and $PSCmdlet.ShouldProcess($package.id, '使用 winget 卸载本次安装的软件包')) {
            Invoke-ExternalSetupCommand -Command 'winget.exe' -Arguments @('uninstall', '--id', $package.id, '--exact', '--source', $package.source) -AllowFailure | Out-Null
        }
    }
    Write-SetupStatus -Kind Success -Message "回滚处理完成：$($manifest.path)"
    if ($manifest.notes.Count -gt 0) {
        Write-Host '以下项目需要人工复核：' -ForegroundColor Yellow
        foreach ($note in $manifest.notes) { Write-Host "  - $note" -ForegroundColor Yellow }
    }
}

Export-ModuleMember -Function @(
    'Invoke-CodexSetupPlan', 'Invoke-CodexSetupRollback', 'New-ProjectTemplateMap',
    'Select-WslNetworkConfiguration', 'Convert-WindowsPathToWsl', 'Set-WslNetworkingConfig'
)
