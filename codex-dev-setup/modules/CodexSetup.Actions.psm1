Set-StrictMode -Version Latest

function Get-ActionProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function New-ActionOutcome {
    param(
        [Parameter(Mandatory)][ValidateSet('Changed', 'NoChange', 'NeedsAttention', 'RestartRequired')][string]$Status,
        [Parameter(Mandatory)][string]$Summary,
        [AllowNull()]$Data
    )
    [pscustomobject]@{ status=$Status; summary=$Summary; data=$Data }
}

function Convert-WindowsPathToWsl {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedDistro)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return "/mnt/$($matches[1].ToLowerInvariant())/$($matches[2].Replace('\\','/'))"
    }
    if ($full -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.*)$') {
        $pathDistro = $matches[1]
        if ($ExpectedDistro -and $pathDistro -ine $ExpectedDistro) {
            throw "文件位于 $pathDistro，但目标发行版是 $ExpectedDistro。"
        }
        return '/' + $matches[2].Replace('\\', '/')
    }
    throw "无法转换为 WSL 路径：$Path"
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
        $commandOutput = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        if ($commandOutput.Count -gt 0) {
            Write-SetupLog -Level Debug -Message '外部命令输出' -Data @{
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
            '。详情：' + (ConvertTo-RedactedText ((@($commandOutput | Select-Object -Last 5) -join '；')))
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
    Write-SetupLog -Message '执行交互命令' -Data @{ command=$Command; arguments=$Arguments }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Command
    $startInfo.UseShellExecute = $false
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw "无法启动命令：$Command" }
    try {
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally { $process.Dispose() }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "命令失败（exit=$exitCode）：$Command $($Arguments -join ' ')"
    }
    return $exitCode
}

function Install-WingetPackage {
    param([Parameter(Mandatory)]$Action)
    $packageId = [string]$Action.parameters.packageId
    $source = [string]$Action.parameters.source
    $existing = Get-WindowsPackageState -PackageId $packageId -Source $source
    if ($existing.state -eq 'Unknown') { throw "无法确认 $packageId 是否已安装；已停止自动安装。$($existing.error)" }
    if ($existing.installed) {
        return New-ActionOutcome -Status NoChange -Summary '已安装，无需处理' -Data @{ installedVersion=$existing.version }
    }
    $arguments = @('install', '--id', $packageId, '--source', $source)
    $arguments += '--exact'
    $arguments += @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity', '--silent')
    Invoke-ExternalSetupCommand -Command 'winget.exe' -Arguments $arguments | Out-Null
    $installed = Get-WindowsPackageState -PackageId $packageId -Source $source
    if ($installed.installed) {
        Register-InstalledPackage -Id $packageId -Source $source -Version ([string]$installed.version)
        return New-ActionOutcome -Status Changed -Summary '安装完成并已复核' -Data @{ installedVersion=$installed.version }
    }
    Add-RollbackNote "无法确认 $packageId 的安装登记状态，因此未加入自动卸载清单。"
    return New-ActionOutcome -Status NeedsAttention -Summary '安装命令已结束，但无法确认软件已可用' -Data @{ packageId=$packageId }
}

function Test-WingetPackageUpgrade {
    param([Parameter(Mandatory)]$Action)
    $packageId = [string]$Action.parameters.packageId
    $source = [string]$Action.parameters.source
    $installed = Get-WindowsPackageState -PackageId $packageId -Source $source
    if ($installed.state -eq 'Unknown') {
        return New-ActionOutcome -Status NeedsAttention -Summary '无法读取结构化软件包清单；未执行升级' -Data @{ currentVersion=$null; availableVersion=$null }
    }
    if (-not $installed.installed) {
        return New-ActionOutcome -Status NeedsAttention -Summary '软件包未安装，无法检查更新' -Data @{ currentVersion=$null; availableVersion=$null }
    }
    New-ActionOutcome -Status NoChange -Summary "已确认安装版本 $($installed.version)；当前策略不自动升级" -Data @{ currentVersion=$installed.version; availableVersion=$null }
}

function Get-WslRuntimeSnapshot {
    $output = @(& wsl.exe --version 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "无法读取 WSL 运行时版本（exit=$exitCode）。" }
    $text = ($output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'WSL 运行时版本输出为空。' }
    [pscustomobject]@{ sha256=Get-SetupTextSha256 -Text $text; text=ConvertTo-RedactedText $text }
}

function Update-WslRuntime {
    $before = Get-WslRuntimeSnapshot
    Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments @('--update') | Out-Null
    $after = Get-WslRuntimeSnapshot
    if ($before.sha256 -eq $after.sha256) {
        return New-ActionOutcome -Status NoChange -Summary 'WSL 运行时已经是当前版本' -Data @{ before=$before.text; after=$after.text }
    }
    New-ActionOutcome -Status RestartRequired -Summary 'WSL 运行时已更新；保存 Linux 工作后关闭 WSL 再继续' -Data @{ before=$before.text; after=$after.text }
}

function Set-WslDefaultVersion2 {
    $registryPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $before = try {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains 'DefaultVersion') { [int]$item.DefaultVersion } else { 2 }
    }
    catch [System.Management.Automation.ItemNotFoundException] { 2 }
    catch { $null }
    Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments @('--set-default-version', '2') | Out-Null
    $itemAfter = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $after = if ($itemAfter.PSObject.Properties.Name -contains 'DefaultVersion') { [int]$itemAfter.DefaultVersion } else { 2 }
    if ($after -ne 2) { throw '设置命令结束后，WSL 默认版本仍不是 2。' }
    $status = if ($null -ne $before -and $before -eq 2) { 'NoChange' } else { 'Changed' }
    New-ActionOutcome -Status $status -Summary $(if ($status -eq 'Changed') { '新发行版默认版本已改为 WSL2' } else { '新发行版已经默认使用 WSL2' }) -Data @{ before=$before; after=$after }
}

function Set-PythonWithUv {
    $uv = Resolve-SetupCommandPath -Name 'uv.exe' -PackageId 'astral-sh.uv'
    if (-not $uv) { throw 'uv 尚未进入 Windows PATH，请重开终端后重试。' }
    $beforeExitCode = Invoke-ExternalSetupCommand -Command $uv -Arguments @('python', 'find', '3.12') -AllowFailure -Quiet
    Invoke-ExternalSetupCommand -Command $uv -Arguments @('python', 'install', '3.12', '--default') -Quiet | Out-Null
    $afterOutput = @(& $uv python find 3.12 2>&1 | ForEach-Object { [string]$_ })
    $afterExitCode = $LASTEXITCODE
    $afterPaths = @($afterOutput | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    if ($afterExitCode -ne 0 -or $afterPaths.Count -ne 1) {
        throw 'uv 安装结束后无法定位 Python 3.12 解释器。'
    }
    Add-RollbackNote 'uv 管理的 Python 解释器不由自动回滚删除。'
    $changed = $beforeExitCode -ne 0
    New-ActionOutcome -Status $(if ($changed) { 'Changed' } else { 'NoChange' }) `
        -Summary $(if ($changed) { 'Windows Python 3.12 已由 uv 准备' } else { 'uv 已管理 Windows Python 3.12' }) `
        -Data @{ interpreter=(ConvertTo-RedactedText $afterPaths[0]) }
}

function Quote-TomlString {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Assert-CodexConfigValues {
    param([Parameter(Mandatory)]$Config)
    $allowed = [ordered]@{
        approvalPolicy=@('untrusted', 'on-request', 'never')
        sandboxMode=@('read-only', 'workspace-write', 'danger-full-access')
        windowsSandbox=@('unelevated', 'elevated')
        webSearch=@('disabled', 'cached', 'indexed', 'live')
    }
    foreach ($entry in $allowed.GetEnumerator()) {
        if ([string]$Config.codex.($entry.Key) -notin $entry.Value) {
            throw "Codex 配置值无效：$($entry.Key)=$($Config.codex.($entry.Key))"
        }
    }
    foreach ($name in @('checkForUpdateOnStartup', 'networkAccess')) {
        if ($Config.codex.$name -isnot [bool]) { throw "Codex 配置必须是布尔值：$name" }
    }
}

function Assert-SupportedCodexTomlShape {
    param([AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return }
    if ($Content -match "'''" -or $Content -match '"""') {
        throw 'config.toml 含多行字符串，无法安全更新目标键。'
    }
    foreach ($key in @('approval_policy', 'sandbox_mode', 'web_search', 'check_for_update_on_startup', 'sandbox', 'sandbox_private_desktop', 'network_access')) {
        if ($Content -match ('(?m)^\s*["'']' + [regex]::Escape($key) + '["'']\s*=')) {
            throw "config.toml 使用带引号的受管键 $key，无法安全更新。"
        }
    }
    foreach ($section in @('windows', 'sandbox_workspace_write')) {
        if ($Content -match ('(?m)^\s*' + [regex]::Escape($section) + '\s*=') -or
            $Content -match ('(?m)^\s*' + [regex]::Escape($section) + '\s*\.')) {
            throw "config.toml 使用 $section inline table 或 dotted key，无法安全更新。"
        }
        $headers = [regex]::Matches($Content, ('(?m)^\s*\[\s*["'']?' + [regex]::Escape($section) + '["'']?\s*\]\s*(?:#.*)?$'))
        if ($headers.Count -gt 1) { throw "config.toml 重复定义 [$section]。" }
        if ($Content -match ('(?m)^\s*\[\[\s*["'']?' + [regex]::Escape($section) + '["'']?\s*\]\]')) {
            throw "config.toml 将 $section 定义为数组表，无法安全更新。"
        }
    }
}

function Set-TomlValue {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Lines,
        [AllowEmptyString()][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $start = -1
    $end = $Lines.Count
    if ($Section) {
        $headerPattern = '^\s*\[\s*["'']?' + [regex]::Escape($Section) + '["'']?\s*\]\s*(?:#.*)?$'
        for ($index = 0; $index -lt $Lines.Count; $index++) {
            if ($Lines[$index] -match $headerPattern) { $start = $index; break }
        }
        if ($start -lt 0) {
            if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1]) { [void]$Lines.Add('') }
            [void]$Lines.Add("[$Section]")
            $start = $Lines.Count - 1
            $end = $Lines.Count
        }
        else {
            for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
                if ($Lines[$index] -match '^\s*\[') { $end = $index; break }
            }
        }
    }
    else {
        for ($index = 0; $index -lt $Lines.Count; $index++) {
            if ($Lines[$index] -match '^\s*\[') { $end = $index; break }
        }
    }
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $keyIndexes = [System.Collections.Generic.List[int]]::new()
    for ($index = $start + 1; $index -lt $end; $index++) {
        if ($Lines[$index] -match $keyPattern) { $keyIndexes.Add($index) }
    }
    if ($keyIndexes.Count -gt 1) { throw "config.toml 重复定义 $Key。" }
    if ($keyIndexes.Count -eq 1) { $Lines[$keyIndexes[0]] = "$Key = $Value"; return }
    $Lines.Insert($end, "$Key = $Value")
}

function Set-CodexGlobalConfig {
    param([Parameter(Mandatory)]$Config)
    Assert-CodexConfigValues -Config $Config
    $path = Join-Path $env:USERPROFILE '.codex\config.toml'
    $existing = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw -Encoding utf8 } else { '' }
    Assert-SupportedCodexTomlShape -Content $existing
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($existing -split "`r?`n")) { [void]$lines.Add($line) }
    while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1]) { $lines.RemoveAt($lines.Count - 1) }
    Set-TomlValue -Lines $lines -Section '' -Key 'approval_policy' -Value (Quote-TomlString ([string]$Config.codex.approvalPolicy))
    Set-TomlValue -Lines $lines -Section '' -Key 'sandbox_mode' -Value (Quote-TomlString ([string]$Config.codex.sandboxMode))
    Set-TomlValue -Lines $lines -Section '' -Key 'web_search' -Value (Quote-TomlString ([string]$Config.codex.webSearch))
    Set-TomlValue -Lines $lines -Section '' -Key 'check_for_update_on_startup' -Value (($Config.codex.checkForUpdateOnStartup).ToString().ToLowerInvariant())
    Set-TomlValue -Lines $lines -Section 'windows' -Key 'sandbox' -Value (Quote-TomlString ([string]$Config.codex.windowsSandbox))
    Set-TomlValue -Lines $lines -Section 'windows' -Key 'sandbox_private_desktop' -Value 'true'
    Set-TomlValue -Lines $lines -Section 'sandbox_workspace_write' -Key 'network_access' -Value (($Config.codex.networkAccess).ToString().ToLowerInvariant())
    $changed = Set-SetupFileContent -Path $path -Content ($lines -join [Environment]::NewLine) -Description '设置 Windows Codex 用户配置' -ManagedKind CodexConfig
    New-ActionOutcome -Status $(if ($changed) { 'Changed' } else { 'NoChange' }) -Summary $(if ($changed) { 'Codex 用户配置已更新' } else { 'Codex 用户配置已是目标状态' }) -Data @{ path=$path }
}

function Set-GlobalAgents {
    param([Parameter(Mandatory)]$Action)
    $mode = [string]$Action.parameters.mode
    $templateName = switch ($mode) {
        'WslFirst' { 'AGENTS.wsl.md.template' }
        'WindowsNative' { 'AGENTS.windows.md.template' }
        default { throw "不支持的环境模式：$mode" }
    }
    $templatePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\templates\global\$templateName"))
    $content = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
    $path = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
    $changed = Set-SetupFileContent -Path $path -Content $content -Description '设置 Windows Codex 全局 AGENTS.md' -ManagedKind GlobalAgents
    New-ActionOutcome -Status $(if ($changed) { 'Changed' } else { 'NoChange' }) -Summary $(if ($changed) { '全局开发环境规则已更新' } else { '全局开发环境规则已是目标状态' }) -Data @{ path=$path }
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $header = '(?i)^\s*\[' + [regex]::Escape($Section) + '\]\s*(?:[;#].*)?$'
    $start = -1
    $end = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $header) { $start = $index; break }
    }
    if ($start -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1]) { [void]$Lines.Add('') }
        [void]$Lines.Add("[$Section]")
        $start = $Lines.Count - 1
        $end = $Lines.Count
    }
    else {
        for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
            if ($Lines[$index] -match '^\s*\[') { $end = $index; break }
        }
    }
    $keyPattern = '(?i)^\s*' + [regex]::Escape($Key) + '\s*='
    for ($index = $start + 1; $index -lt $end; $index++) {
        if ($Lines[$index] -match $keyPattern) {
            $Lines[$index] = "$Key=$Value"
            return
        }
    }
    $Lines.Insert($end, "$Key=$Value")
}

function Assert-SupportedWslConfigShape {
    param([AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return }
    $lines = @($Content -split "`r?`n")
    $sectionCount = @($lines | Where-Object { $_ -match '(?i)^\s*\[wsl2\]\s*(?:[;#].*)?$' }).Count
    if ($sectionCount -gt 1) { throw '.wslconfig 重复定义 [wsl2]，无法安全更新。' }
    $currentSection = ''
    $counts = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            $currentSection = $matches[1].Trim()
            continue
        }
        if ($currentSection -ieq 'wsl2' -and $line -match '^\s*([A-Za-z][A-Za-z0-9]*)\s*=') {
            $key = $matches[1].ToLowerInvariant()
            if ($key -in @('networkingmode', 'dnstunneling', 'autoproxy', 'firewall')) {
                $counts[$key] = 1 + [int]$counts[$key]
                if ($counts[$key] -gt 1) { throw ".wslconfig 在 [wsl2] 中重复定义 $key，无法安全更新。" }
            }
        }
    }
}

function Set-WslNetworkingConfig {
    param([Parameter(Mandatory)]$Config)
    $network = $Config.wsl.networking
    if ([string]$network.networkingMode -notin @('nat', 'mirrored')) { throw "不支持的 WSL networkingMode：$($network.networkingMode)" }
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $existing = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding utf8 } else { '' }
    Assert-SupportedWslConfigShape -Content $existing
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($existing -split "`r?`n")) { [void]$lines.Add($line) }
    while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1]) { $lines.RemoveAt($lines.Count - 1) }
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'networkingMode' -Value ([string]$network.networkingMode)
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'dnsTunneling' -Value $network.dnsTunneling.ToString().ToLowerInvariant()
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'autoProxy' -Value $network.autoProxy.ToString().ToLowerInvariant()
    Set-IniValue -Lines $lines -Section 'wsl2' -Key 'firewall' -Value $network.firewall.ToString().ToLowerInvariant()
    $changed = Set-SetupFileContent -Path $path -Content ($lines -join [Environment]::NewLine) -Description '设置 WSL networking' -ManagedKind WslConfig
    New-ActionOutcome -Status $(if ($changed) { 'RestartRequired' } else { 'NoChange' }) -Summary $(if ($changed) { 'WSL 网络设置已更新；保存 WSL 工作后执行 shutdown 并继续验收' } else { 'WSL 网络设置已是目标状态' }) -Data @{ networkingMode=$network.networkingMode }
}

function Set-WindowsGitBaseline {
    $path = Join-Path $env:USERPROFILE '.gitconfig'
    $git = Resolve-SetupCommandPath -Name 'git.exe' -PackageId 'Git.Git'
    if (-not $git) { throw 'Git for Windows 已登记，但无法解析 git.exe；请重新打开终端后重试。' }
    $desired = [ordered]@{
        'init.defaultBranch'='main'
        'fetch.prune'='true'
        'pull.ff'='only'
        'core.autocrlf'='input'
        'core.safecrlf'='warn'
        'credential.helper'='manager'
    }
    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-git-{0}.config" -f [guid]::NewGuid().ToString('N'))
    $previousGlobalConfig = $env:GIT_CONFIG_GLOBAL
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination $temporaryPath -Force }
        else { [System.IO.File]::WriteAllText($temporaryPath, '', [Text.UTF8Encoding]::new($false)) }
        $env:GIT_CONFIG_GLOBAL = $temporaryPath
        foreach ($entry in $desired.GetEnumerator()) {
            Invoke-ExternalSetupCommand -Command $git -Arguments @('config', '--global', $entry.Key, $entry.Value) -Quiet | Out-Null
        }
        $targetContent = Get-Content -LiteralPath $temporaryPath -Raw -Encoding utf8
    }
    finally {
        $env:GIT_CONFIG_GLOBAL = $previousGlobalConfig
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    $changed = Set-SetupFileContent -Path $path -Content $targetContent -Description '设置 Windows Git 基线' -ManagedKind GitConfig
    New-ActionOutcome -Status $(if ($changed) { 'Changed' } else { 'NoChange' }) -Summary $(if ($changed) { 'Windows Git 基线已更新' } else { 'Windows Git 基线已是目标状态' }) -Data $null
}

function Select-CodexConfigurationPreset {
    param([Parameter(Mandatory)]$Config)
    while ($true) {
        Write-Host ''
        Write-Host '  选择 Codex 工作方式' -ForegroundColor Cyan
        Write-Host '    [1/Enter] workspace-write + on-request'
        Write-Host '    [2]       read-only + on-request'
        Write-Host '    [3]       danger-full-access + on-request'
        Write-Host '    [B]       返回'
        switch ((Read-Host '  请选择').Trim().ToUpperInvariant()) {
            { $_ -in @('', '1') } {
                $Config.codex.sandboxMode = 'workspace-write'
                $Config.codex.approvalPolicy = 'on-request'
                $Config.codex.windowsSandbox = 'elevated'
                return $true
            }
            '2' {
                $Config.codex.sandboxMode = 'read-only'
                $Config.codex.approvalPolicy = 'on-request'
                $Config.codex.windowsSandbox = 'elevated'
                return $true
            }
            '3' {
                if (Confirm-SetupChoice -Prompt '确认仅用于完全可信项目？' -DefaultYes:$false) {
                    $Config.codex.sandboxMode = 'danger-full-access'
                    $Config.codex.approvalPolicy = 'on-request'
                    $Config.codex.windowsSandbox = 'elevated'
                    return $true
                }
            }
            'B' { return $false }
            default { Write-SetupStatus -Kind Warning -Message '无效选择。' }
        }
    }
}

function Invoke-WslSetup {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    $distro = [string]$Action.parameters.distro
    $helper = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wsl\setup.sh'))
    $agentsTemplate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates\global\AGENTS.wsl.md.template'))
    $verifyScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\wsl\verify.sh'))
    $helperWsl = Convert-WindowsPathToWsl -Path $helper -ExpectedDistro $distro
    $agentsTemplateWsl = Convert-WindowsPathToWsl -Path $agentsTemplate -ExpectedDistro $distro
    $verifyScriptWsl = Convert-WindowsPathToWsl -Path $verifyScript -ExpectedDistro $distro
    $codeRoot = Resolve-WslUserPath -Distro $distro -Path ([string]$Config.paths.wslProjects)
    $parameters = @(
        '--code-root', $codeRoot
        '--expected-distro', $distro
        '--global-agents-template', $agentsTemplateWsl
        '--verify-script', $verifyScriptWsl
        '--approval-policy', [string]$Config.codex.approvalPolicy
        '--sandbox-mode', [string]$Config.codex.sandboxMode
        '--network-access', $Config.codex.networkAccess.ToString().ToLowerInvariant()
        '--web-search', [string]$Config.codex.webSearch
        '--check-for-update', $Config.codex.checkForUpdateOnStartup.ToString().ToLowerInvariant()
    )
    $packageConfig = Get-WslPackageConfiguration -Config $Config
    foreach ($package in $packageConfig.packageNames) { $parameters += @('--apt-package', [string]$package) }
    foreach ($alias in $packageConfig.aliases) { $parameters += @('--command-alias', "$($alias.name)=$($alias.target)") }
    if ([bool]$Config.toolchains.node.enabled) { $parameters += '--install-node' }
    if ([bool]$Config.toolchains.python.enabled) { $parameters += '--install-python' }
    if ([bool]$Config.wsl.installPnpm) { $parameters += '--install-pnpm' }
    if ([bool]$Config.wsl.installCodexCli) { $parameters += '--install-codex' }
    if ([bool]$Config.wsl.configureGit) { $parameters += '--configure-git' }
    if ([bool]$Config.toolchains.docker.enabled) { $parameters += '--verify-docker' }

    $prefix = @('-d', $distro, '--', 'bash', $helperWsl)
    Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments ($prefix + '--what-if' + $parameters) -Quiet | Out-Null
    Write-Host ''
    Write-Host "  正在 $distro 内配置 Linux 工具链。" -ForegroundColor Cyan
    if ($NonInteractive) {
        Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments ($prefix + '--apply' + '--non-interactive' + $parameters) -Quiet | Out-Null
    }
    else {
        Write-Host '  仅在缺少系统包时，Ubuntu 会直接提示输入 sudo 密码；密码不会写入文件。' -ForegroundColor DarkGray
        Invoke-InteractiveExternalSetupCommand -Command 'wsl.exe' -Arguments ($prefix + '--apply' + $parameters) | Out-Null
    }
    Add-RollbackNote 'WSL 内的软件包和用户配置不由 Windows 回滚自动删除。'
    New-ActionOutcome -Status Changed -Summary "$distro 工具链已配置并通过环境检查" -Data $null
}

function Add-DeclaredProjectCommand {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Commands,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Command
    )
    if (-not $Commands.Contains($Label)) { $Commands.Add($Label, $Command) }
}

function Get-DeclaredProjectCommands {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][ValidateSet('WslFirst', 'WindowsNative')][string]$EnvironmentMode
    )
    $commands = [ordered]@{}
    $scriptExtension = if ($EnvironmentMode -eq 'WslFirst') { 'sh' } else { 'ps1' }
    foreach ($name in @('setup', 'dev', 'check', 'test', 'lint', 'format', 'typecheck', 'build')) {
        $scriptPath = Join-Path $ProjectPath "scripts\$name.$scriptExtension"
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            $scriptCommand = if ($EnvironmentMode -eq 'WslFirst') { "./scripts/$name.sh" } else { ".\scripts\$name.ps1" }
            Add-DeclaredProjectCommand -Commands $commands -Label ((Get-Culture).TextInfo.ToTitleCase($name)) -Command $scriptCommand
        }
    }

    $packageJsonPath = Join-Path $ProjectPath 'package.json'
    if (Test-Path -LiteralPath $packageJsonPath -PathType Leaf) {
        try { $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "package.json 无法解析：$($_.Exception.Message)" }
        $declaredPackageManager = [string](Get-ActionProperty $packageJson 'packageManager' '')
        $declaredManager = $null
        if ($declaredPackageManager) {
            if ($declaredPackageManager -notmatch '^(pnpm|npm)@[^\s]+$') {
                throw "package.json.packageManager 不受当前环境支持：$declaredPackageManager"
            }
            $declaredManager = $matches[1]
        }
        $lockManagers = @(@(
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'pnpm-lock.yaml') -PathType Leaf) { 'pnpm' }
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'package-lock.json') -PathType Leaf) { 'npm' }
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'npm-shrinkwrap.json') -PathType Leaf) { 'npm' }
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'yarn.lock') -PathType Leaf) { 'yarn' }
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'bun.lock') -PathType Leaf) { 'bun' }
            if (Test-Path -LiteralPath (Join-Path $ProjectPath 'bun.lockb') -PathType Leaf) { 'bun' }
        ) | Select-Object -Unique)
        if ($lockManagers.Count -gt 1) { throw "检测到冲突的 Node 锁文件：$($lockManagers -join '、')。" }
        $lockManager = @($lockManagers | Select-Object -First 1)
        if ($lockManager.Count -eq 1 -and $lockManager[0] -notin @('pnpm', 'npm')) {
            throw "当前环境不支持 $($lockManager[0]) 锁文件；请先统一项目包管理器。"
        }
        if ($declaredManager -and $lockManager.Count -eq 1 -and $declaredManager -ne $lockManager[0]) {
            throw "packageManager=$declaredManager 与 $($lockManager[0]) 锁文件冲突。"
        }
        $manager = if ($declaredManager) { $declaredManager } elseif ($lockManager.Count -eq 1) { $lockManager[0] } else { $null }
        if ($manager -eq 'pnpm') {
            $setup = if (Test-Path -LiteralPath (Join-Path $ProjectPath 'pnpm-lock.yaml') -PathType Leaf) { 'pnpm install --frozen-lockfile' } else { 'pnpm install' }
            Add-DeclaredProjectCommand -Commands $commands -Label 'Setup' -Command $setup
        }
        elseif ($manager -eq 'npm' -and (Test-Path -LiteralPath (Join-Path $ProjectPath 'package-lock.json') -PathType Leaf)) {
            Add-DeclaredProjectCommand -Commands $commands -Label 'Setup' -Command 'npm ci'
        }
        $scripts = Get-ActionProperty $packageJson 'scripts'
        if ($manager -and $null -ne $scripts) {
            foreach ($name in @('dev', 'test', 'lint', 'check', 'format', 'typecheck', 'build')) {
                if ($scripts.PSObject.Properties.Name -contains $name) {
                    Add-DeclaredProjectCommand -Commands $commands -Label ((Get-Culture).TextInfo.ToTitleCase($name)) -Command "$manager run $name"
                }
            }
        }
    }

    $pyprojectPath = Join-Path $ProjectPath 'pyproject.toml'
    if (Test-Path -LiteralPath $pyprojectPath -PathType Leaf) {
        $pyprojectLines = @(Get-Content -LiteralPath $pyprojectPath -Encoding utf8)
        $usesUv = (Test-Path -LiteralPath (Join-Path $ProjectPath 'uv.lock') -PathType Leaf) -or
            @($pyprojectLines | Where-Object { $_ -match '^\s*\[tool\.uv(?:\.|\])' }).Count -gt 0
        if ($usesUv) {
            $sync = if (Test-Path -LiteralPath (Join-Path $ProjectPath 'uv.lock') -PathType Leaf) { 'uv sync --frozen' } else { 'uv sync' }
            Add-DeclaredProjectCommand -Commands $commands -Label 'Setup' -Command $sync
            if ((Test-Path -LiteralPath (Join-Path $ProjectPath 'tests') -PathType Container) -and
                @($pyprojectLines | Where-Object { $_ -match '^\s*\[tool\.pytest(?:\.|\])' }).Count -gt 0) {
                Add-DeclaredProjectCommand -Commands $commands -Label 'Test' -Command 'uv run pytest'
            }
            if (@($pyprojectLines | Where-Object { $_ -match '^\s*\[tool\.ruff(?:\.|\])' }).Count -gt 0) {
                Add-DeclaredProjectCommand -Commands $commands -Label 'Lint' -Command 'uv run ruff check .'
                Add-DeclaredProjectCommand -Commands $commands -Label 'Format' -Command 'uv run ruff format .'
            }
        }
    }
    return $commands
}

function New-ProjectTemplateMap {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)]$Config
    )
    $fullProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
    $pathCompatible = if ($Config.environmentMode -eq 'WslFirst') {
        $escapedDistribution = [regex]::Escape([string]$Config.wsl.distribution)
        $fullProjectPath -match "(?i)^\\\\wsl(?:\$|\.localhost)\\$escapedDistribution\\home\\[^\\]+\\code(?:\\|$)"
    }
    else { $fullProjectPath -match '^[A-Za-z]:\\' -and $fullProjectPath -notmatch '^\\\\wsl(?:\$|\.localhost)\\' }
    if (-not $pathCompatible) {
        $expected = if ($Config.environmentMode -eq 'WslFirst') { '目标 Ubuntu 的 \\wsl$\...\home\<user>\code 路径' } else { 'Windows 本地磁盘路径' }
        throw "项目位置不符合当前开发环境；请选择$expected。当前路径：$fullProjectPath"
    }
    $templateRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates\project'))
    $environmentRules = if ($Config.environmentMode -eq 'WslFirst') {
        @(
            '- Use WSL2 Ubuntu and run commands directly in Bash.'
            '- Use Linux paths and tools. Keep the repository under `~/code`; never develop under `/mnt`.'
            '- Do not use PowerShell, Command Prompt, Git Bash, `wsl.exe`, or Windows executables for repository work.'
        ) -join "`n"
    }
    else {
        @(
            '- Use Windows native PowerShell 7 and Windows-native tools.'
            '- Use Windows paths. Do not access this repository through WSL or Git Bash.'
        ) -join "`n"
    }
    $commands = Get-DeclaredProjectCommands -ProjectPath $fullProjectPath -EnvironmentMode $Config.environmentMode
    $commandLines = if ($commands.Count -gt 0) {
        @($commands.GetEnumerator() | ForEach-Object { "- $($_.Key): ``$($_.Value)``" }) -join "`n"
    }
    else { '- No setup, run, test, lint, format, or build command is declared. Do not invent one.' }
    $agents = Get-Content -LiteralPath (Join-Path $templateRoot 'AGENTS.md.template') -Raw -Encoding utf8
    $agents = $agents.Replace('{{ENVIRONMENT_RULES}}', $environmentRules).Replace('{{PROJECT_COMMANDS}}', $commandLines)
    [ordered]@{
        (Join-Path $fullProjectPath 'AGENTS.md') = $agents
        (Join-Path $fullProjectPath '.editorconfig') = (Get-Content -LiteralPath (Join-Path $templateRoot 'editorconfig.template') -Raw -Encoding utf8)
        (Join-Path $fullProjectPath '.gitattributes') = (Get-Content -LiteralPath (Join-Path $templateRoot 'gitattributes.template') -Raw -Encoding utf8)
        (Join-Path $fullProjectPath '.gitignore') = (Get-Content -LiteralPath (Join-Path $templateRoot 'gitignore.template') -Raw -Encoding utf8)
    }
}

function Set-ProjectTemplates {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    $projectPath = [System.IO.Path]::GetFullPath([string]$Action.parameters.projectPath)
    if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) { throw "项目目录不存在：$projectPath" }
    $templates = New-ProjectTemplateMap -ProjectPath $projectPath -Config $Config
    $skippedFiles = [System.Collections.Generic.List[string]]::new()
    $changedFiles = [System.Collections.Generic.List[string]]::new()
    $unchangedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $templates.GetEnumerator()) {
        $path = [string]$entry.Key
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $current = Get-Content -LiteralPath $path -Raw -Encoding utf8
            $desired = $entry.Value.TrimEnd("`r", "`n") + [Environment]::NewLine
            if ($current -eq $desired) { $unchangedFiles.Add($path); continue }
            if (-not (Confirm-SetupChoice -Prompt "文件已存在，是否备份并替换？$path" -DefaultYes:$false -NonInteractive:$NonInteractive)) {
                $skippedFiles.Add($path)
                continue
            }
        }
        if (Set-SetupFileContent -Path $path -Content $entry.Value -Description '写入项目模板' -ManagedKind ProjectTemplate -ManagedRoot $projectPath) { $changedFiles.Add($path) }
    }
    $status = if ($skippedFiles.Count -gt 0) { 'NeedsAttention' } elseif ($changedFiles.Count -gt 0) { 'Changed' } else { 'NoChange' }
    $summary = "项目文件：更新 $($changedFiles.Count) 个，无需修改 $($unchangedFiles.Count) 个，保留 $($skippedFiles.Count) 个"
    New-ActionOutcome -Status $status -Summary $summary -Data @{
        changedFiles=@($changedFiles); unchangedFiles=@($unchangedFiles); preservedFiles=@($skippedFiles)
    }
}

function Invoke-SetupAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    switch ($Action.type) {
        'WingetInstall'          { Install-WingetPackage -Action $Action }
        'WingetUpgradeCheck'     { Test-WingetPackageUpgrade -Action $Action }
        'PythonConfigure'        { Set-PythonWithUv }
        'WslUpdate'              { Update-WslRuntime }
        'WslSetDefaultVersion2'  { Set-WslDefaultVersion2 }
        'WslInstallDistribution' { Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments @('--install', '--distribution', [string]$Action.parameters.distro) | Out-Null; Add-RollbackNote '不会自动注销新发行版，以免删除 Linux 数据。'; New-ActionOutcome -Status RestartRequired -Summary '发行版安装已启动；请按 Windows 提示重启后再继续' -Data $null }
        'WslSetDefaultDistribution' { Invoke-ExternalSetupCommand -Command 'wsl.exe' -Arguments @('--set-default', [string]$Action.parameters.distro) | Out-Null; New-ActionOutcome -Status Changed -Summary '默认 WSL 发行版已设置' -Data $null }
        'WslConfigure'           { Invoke-WslSetup -Action $Action -Config $Config -NonInteractive:$NonInteractive }
        'WslNetworkConfigure'    { Set-WslNetworkingConfig -Config $Config }
        'WindowsGitConfig'       { Set-WindowsGitBaseline }
        'CodexGlobalConfig'      { Set-CodexGlobalConfig -Config $Config }
        'GlobalAgents'           { Set-GlobalAgents -Action $Action }
        'ProjectTemplates'       { Set-ProjectTemplates -Action $Action -Config $Config -NonInteractive:$NonInteractive }
        default                  { throw "未知操作类型：$($Action.type)" }
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
    $blocked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in @(Get-SetupOrderedModules -Actions $Plan.actions)) {
        $group = @($Plan.actions | Where-Object module -eq $module)
        $runModule = $true
        if ($ConfirmModules -and -not $NonInteractive -and -not $WhatIfPreference) {
            if ($module -eq 'CodexConfig') {
                Write-Host '[Y] 应用  [C] 自定义  [S/Enter] 跳过' -ForegroundColor DarkGray
                $choice = (Read-Host '请选择').Trim().ToUpperInvariant()
                if ($choice -eq 'C') { $runModule = Select-CodexConfigurationPreset -Config $Config }
                elseif ($choice -notin @('Y', 'YES', '是', '确认')) { $runModule = $false }
            }
            else {
                $runModule = Confirm-SetupChoice -Prompt "执行模块：$(Get-SetupModuleDisplayName -Module $module)？" -DefaultYes:$false
            }
        }
        foreach ($action in $group) {
            $dependencies = @($action.dependsOn | Where-Object { $blocked.Contains([string]$_) })
            if (-not $runModule -or $dependencies.Count -gt 0) {
                [void]$blocked.Add([string]$action.id)
                $dependencyTitles = @($Plan.actions | Where-Object { $_.id -in $dependencies } | ForEach-Object title)
                $reason = if ($dependencies.Count -gt 0) { "前一步尚未完成：$($dependencyTitles -join '、')" } else { '这组操作未获确认。' }
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error=$reason; detail=$null; durationMs=0 }
                continue
            }
            $isCritical = [bool]$action.critical -or
                ($action.type -eq 'CodexGlobalConfig' -and $Config.codex.sandboxMode -eq 'danger-full-access')
            if ($isCritical -and -not $NonInteractive -and -not $WhatIfPreference) {
                Write-Host ''
                Write-Host "高影响操作：$($action.title)" -ForegroundColor Yellow
                Write-SetupWrappedText -Text $action.reason -FirstIndent '  影响：' -ContinuationIndent '        ' -ForegroundColor Yellow
                Write-Host "  目标：$($action.target)" -ForegroundColor DarkGray
                $criticalApproved = if ($action.type -eq 'CodexGlobalConfig' -and $Config.codex.sandboxMode -eq 'danger-full-access') {
                    Write-Host '  这会修改用户级全局默认值，影响之后打开的所有 Codex 项目与任务。' -ForegroundColor Red
                    (Read-Host '如要继续，请输入：启用全局高风险权限').Trim() -ceq '启用全局高风险权限'
                }
                else {
                    Confirm-SetupChoice -Prompt '确认继续这项高影响操作？' -DefaultYes:$false
                }
                if (-not $criticalApproved) {
                    [void]$blocked.Add([string]$action.id)
                    $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error='用户未确认高影响操作。'; detail=$null; durationMs=0 }
                    continue
                }
            }
            if ($WhatIfPreference) {
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Preview'; error=$null; detail=$null; durationMs=0 }
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($action.target, $action.title)) {
                [void]$blocked.Add([string]$action.id)
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Skipped'; error=$null; detail=$null; durationMs=0 }
                continue
            }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                Write-Host "  [进行中] $($action.title)" -ForegroundColor Cyan
                $detail = Invoke-SetupAction -Action $action -Config $Config -NonInteractive:$NonInteractive
                $timer.Stop()
                $outcomeStatus = [string](Get-ActionProperty $detail 'status' 'Changed')
                if ($outcomeStatus -notin @('Changed', 'NoChange', 'NeedsAttention', 'RestartRequired')) {
                    throw "操作返回了无效状态：$outcomeStatus"
                }
                $outcomeSummary = [string](Get-ActionProperty $detail 'summary' $action.title)
                switch ($outcomeStatus) {
                    'Changed' { Write-Host "  [已更新] $outcomeSummary" -ForegroundColor Green }
                    'NoChange' { Write-Host "  [无需修改] $outcomeSummary" -ForegroundColor DarkGreen }
                    'NeedsAttention' { Write-Host "  [需要处理] $outcomeSummary" -ForegroundColor Yellow; [void]$blocked.Add([string]$action.id) }
                    'RestartRequired' { Write-Host "  [需要重启] $outcomeSummary" -ForegroundColor Yellow; [void]$blocked.Add([string]$action.id) }
                }
                $results += [pscustomobject]@{ id=$action.id; module=$module; status=$outcomeStatus; error=$null; detail=$detail; durationMs=[math]::Round($timer.Elapsed.TotalMilliseconds) }
            }
            catch {
                $timer.Stop()
                [void]$blocked.Add([string]$action.id)
                $message = ConvertTo-RedactedText $_.Exception.Message
                Write-SetupStatus -Kind Error -Message "$($action.title) 失败：$message"
                $results += [pscustomobject]@{ id=$action.id; module=$module; status='Failed'; error=$message; detail=$null; durationMs=[math]::Round($timer.Elapsed.TotalMilliseconds) }
            }
        }
    }
    return $results
}

function Get-DefaultSetupStateRoot {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    return Join-Path $base 'CodexDevSetup'
}

function Test-SetupPathWithinRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ManagedRollbackTarget {
    param([Parameter(Mandatory)]$File)
    Assert-SetupManagedFileTarget -Path ([string]$File.path) -ManagedKind ([string]$File.managedKind) -ManagedRoot ([string]$File.managedRoot)
}

function Assert-SetupSha256Value {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Field, [switch]$AllowNull)
    if ($AllowNull -and [string]::IsNullOrWhiteSpace($Value)) { return }
    if ([string]$Value -notmatch '^(?i:[a-f0-9]{64})$') { throw "回滚清单 $Field 不是有效 SHA-256。" }
}

function Read-ValidatedRollbackManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [switch]$AllowIncompleteRun
    )
    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $fullManifestPath -PathType Leaf)) { throw "回滚清单不存在：$fullManifestPath" }
    $runsRoot = [System.IO.Path]::GetFullPath((Join-Path $StateRoot 'runs'))
    $runRoot = Split-Path -Parent $fullManifestPath
    if ((Split-Path -Parent $runRoot) -ne $runsRoot -or (Split-Path -Leaf $fullManifestPath) -ne 'rollback-manifest.json') {
        throw '回滚清单不在本工具的 runs 目录中。'
    }
    try { $manifest = Get-Content -LiteralPath $fullManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop }
    catch { throw "回滚清单不是有效 JSON：$($_.Exception.Message)" }
    Assert-RollbackManifestAuthentication -Path $fullManifestPath -Manifest $manifest
    $manifestFields = @(
        'schemaVersion', 'runId', 'createdAt', 'hostBinding', 'userBinding', 'manifestHmac',
        'runStatus', 'completed', 'completedAt', 'changeCount', 'hasChanges', 'rolledBackAt',
        'files', 'installedPackages', 'notes'
    )
    foreach ($field in $manifestFields) {
        if ($manifest.PSObject.Properties.Name -notcontains $field) { throw "回滚清单缺少 v3 字段：$field。" }
    }
    $unknownManifestFields = @($manifest.PSObject.Properties.Name | Where-Object { $_ -notin $manifestFields })
    if ($unknownManifestFields.Count -gt 0) { throw "回滚清单包含不支持的字段：$($unknownManifestFields -join '、')。" }
    if (($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or
        $manifest.schemaVersion -ne 3 -or [string]$manifest.runId -ne (Split-Path -Leaf $runRoot)) {
        throw '回滚清单标识无效；仅接受 v3 清单。'
    }
    $createdAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$manifest.createdAt, [ref]$createdAt)) { throw '回滚清单创建时间无效。' }
    if ([string]$manifest.runStatus -notin @('InProgress', 'Completed', 'Interrupted', 'RolledBack')) { throw '回滚清单运行状态无效。' }
    if ($manifest.completed -isnot [bool] -or $manifest.hasChanges -isnot [bool] -or
        ($manifest.changeCount -isnot [int] -and $manifest.changeCount -isnot [long])) {
        throw '回滚清单运行状态字段类型无效。'
    }
    $hasCompletedAt = -not [string]::IsNullOrWhiteSpace([string]$manifest.completedAt)
    $hasRolledBackAt = -not [string]::IsNullOrWhiteSpace([string]$manifest.rolledBackAt)
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if ($hasCompletedAt -and -not [DateTimeOffset]::TryParse([string]$manifest.completedAt, [ref]$parsedTimestamp)) {
        throw '回滚清单完成时间无效。'
    }
    if ($hasRolledBackAt -and -not [DateTimeOffset]::TryParse([string]$manifest.rolledBackAt, [ref]$parsedTimestamp)) {
        throw '回滚清单回滚时间无效。'
    }
    $statusConsistent = switch ([string]$manifest.runStatus) {
        'InProgress' { -not $manifest.completed -and -not $hasCompletedAt -and -not $hasRolledBackAt }
        'Interrupted' { -not $manifest.completed -and $hasCompletedAt -and -not $hasRolledBackAt }
        'Completed' { $manifest.completed -and $hasCompletedAt -and -not $hasRolledBackAt }
        'RolledBack' { $manifest.completed -and $hasCompletedAt -and $hasRolledBackAt }
    }
    if (-not $statusConsistent) { throw '回滚清单运行状态字段相互矛盾。' }
    if ([string]$manifest.runStatus -in @('InProgress', 'Interrupted') -and -not $AllowIncompleteRun) {
        throw '该清单来自未完整结束的运行；如已核对目标，请显式指定 -AllowIncompleteRun。'
    }
    if ($manifest.hasChanges -ne $true -or [int]$manifest.changeCount -le 0) {
        throw '该运行没有可恢复的更改。'
    }
    if ($hasRolledBackAt) { throw '该运行已经执行过回滚。' }
    $files = @($manifest.files)
    $installedPackages = @($manifest.installedPackages)
    if (($files.Count + $installedPackages.Count) -gt 1000) { throw '回滚清单记录超过 1000 条。' }
    if ([int]$manifest.changeCount -ne ($files.Count + $installedPackages.Count)) { throw '回滚清单 changeCount 与记录数不一致。' }
    $backupRoot = Join-Path $runRoot 'backups'
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $fileFields = @(
            'path', 'existed', 'backup', 'beforeSha256', 'appliedSha256', 'backupSha256',
            'beforeSddl', 'appliedSddl', 'managedKind', 'managedRoot', 'rollbackStatus', 'rollbackError'
        )
        if ([string]::IsNullOrWhiteSpace([string]$file.path) -or -not [System.IO.Path]::IsPathFullyQualified([string]$file.path)) {
            throw '回滚清单包含无效目标路径。'
        }
        if (-not $seenPaths.Add([System.IO.Path]::GetFullPath([string]$file.path))) { throw "回滚清单包含重复目标：$($file.path)" }
        foreach ($field in $fileFields) {
            if ($file.PSObject.Properties.Name -notcontains $field) { throw "文件回滚记录缺少字段 $field：$($file.path)" }
        }
        if (@($file.PSObject.Properties.Name | Where-Object { $_ -notin $fileFields }).Count -gt 0) {
            throw "文件回滚记录包含不支持的字段：$($file.path)"
        }
        if ($file.existed -isnot [bool]) { throw "回滚清单 existed 字段无效：$($file.path)" }
        if ([string]$file.rollbackStatus -notin @('Pending', 'Failed', 'Restored', 'Removed', 'NoChange')) {
            throw "文件回滚状态无效：$($file.path)"
        }
        Assert-ManagedRollbackTarget -File $file
        Assert-SetupSha256Value -Value ([string]$file.appliedSha256) -Field 'appliedSha256'
        $currentExists = Test-Path -LiteralPath ([string]$file.path) -PathType Leaf
        $currentSha = if ($currentExists) { Get-SetupSha256 -Path ([string]$file.path) } else { $null }
        $currentSddl = if ($IsWindows -and $currentExists) { (Get-Acl -LiteralPath ([string]$file.path)).Sddl } else { $null }
        if ($file.existed) {
            Assert-SetupSha256Value -Value ([string]$file.beforeSha256) -Field 'beforeSha256'
            Assert-SetupSha256Value -Value ([string]$file.backupSha256) -Field 'backupSha256'
            if (-not (Test-SetupPathWithinRoot -Path ([string]$file.backup) -Root $backupRoot) -or
                -not (Test-Path -LiteralPath ([string]$file.backup) -PathType Leaf)) {
                throw "回滚备份缺失或越界：$($file.path)"
            }
            $backupSha = Get-SetupSha256 -Path ([string]$file.backup)
            if ($backupSha -ne [string]$file.backupSha256 -or $backupSha -ne [string]$file.beforeSha256) {
                throw "回滚备份哈希不匹配：$($file.path)"
            }
            if (-not $currentExists) { throw "受管文件在回滚前意外丢失：$($file.path)" }
            if ($IsWindows -and ([string]::IsNullOrWhiteSpace([string]$file.beforeSddl) -or
                [string]::IsNullOrWhiteSpace([string]$file.appliedSddl))) {
                throw "回滚清单缺少 Windows ACL 证据：$($file.path)"
            }
            $allowedCurrentHashes = if ([string]$file.rollbackStatus -in @('Restored', 'NoChange')) {
                @([string]$file.beforeSha256)
            }
            else { @([string]$file.appliedSha256, [string]$file.beforeSha256) }
            if ($currentSha -notin $allowedCurrentHashes) { throw "受管文件在应用后已被修改，拒绝回滚：$($file.path)" }
            if ($IsWindows) {
                $expectedSddl = if ($currentSha -eq [string]$file.beforeSha256) { [string]$file.beforeSddl } else { [string]$file.appliedSddl }
                if (-not [string]::Equals($currentSddl, $expectedSddl, [StringComparison]::Ordinal)) {
                    throw "受管文件 ACL 在应用后已被修改，拒绝回滚：$($file.path)"
                }
            }
        }
        else {
            foreach ($field in @('backup', 'beforeSha256', 'backupSha256', 'beforeSddl')) {
                if (-not [string]::IsNullOrWhiteSpace([string]$file.$field)) { throw "新增文件不能包含 $field：$($file.path)" }
            }
            if ($IsWindows -and $currentExists -and [string]::IsNullOrWhiteSpace([string]$file.appliedSddl)) {
                throw "回滚清单缺少新增文件的 Windows ACL 证据：$($file.path)"
            }
            if ([string]$file.rollbackStatus -in @('Removed', 'NoChange')) {
                if ($currentExists) { throw "已回滚的新文件再次出现：$($file.path)" }
            }
            elseif ($currentExists -and $currentSha -ne [string]$file.appliedSha256) {
                throw "新增文件在应用后已被修改，拒绝删除：$($file.path)"
            }
            elseif ($IsWindows -and $currentExists -and
                -not [string]::Equals($currentSddl, [string]$file.appliedSddl, [StringComparison]::Ordinal)) {
                throw "新增文件 ACL 在应用后已被修改，拒绝删除：$($file.path)"
            }
        }
    }
    $seenPackages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $installedPackages) {
        $packageFields = @('id', 'source', 'installedVersion', 'rollbackStatus', 'rollbackError')
        foreach ($field in $packageFields) {
            if ($package.PSObject.Properties.Name -notcontains $field) { throw "软件包回滚记录缺少字段 $field。" }
        }
        if (@($package.PSObject.Properties.Name | Where-Object { $_ -notin $packageFields }).Count -gt 0) {
            throw '软件包回滚记录包含不支持的字段。'
        }
        if (-not (Test-ManagedWindowsPackage -Id ([string]$package.id) -Source ([string]$package.source)) -or
            [string]::IsNullOrWhiteSpace([string]$package.installedVersion) -or
            [string]$package.rollbackStatus -notin @('Pending', 'Failed', 'Uninstalled', 'NoChange')) {
            throw '回滚清单包含无效软件包。'
        }
        if (-not $seenPackages.Add(([string]$package.source + '|' + [string]$package.id))) { throw "回滚清单包含重复软件包：$($package.id)" }
    }
    $packageStates = @{}
    if ($installedPackages.Count -gt 0) {
        $packageCatalog = Get-WindowsPackageCatalog
        foreach ($package in $installedPackages) {
            $current = Get-WindowsPackageState -PackageId ([string]$package.id) -Source ([string]$package.source) -Catalog $packageCatalog
            if ($current.state -eq 'Unknown') {
                throw "无法精确确认软件包状态；回滚尚未修改任何内容：$($package.id)：$($current.error)"
            }
            if ([string]$package.rollbackStatus -in @('Uninstalled', 'NoChange') -and $current.installed) {
                throw "已完成回滚的软件包再次出现：$($package.id)"
            }
            if ($current.installed -and -not [string]::Equals(
                [string]$current.version,
                [string]$package.installedVersion,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "软件包版本已变化，拒绝卸载：$($package.id)（本次安装 $($package.installedVersion)，当前 $($current.version)）"
            }
            $packageStates[(([string]$package.source).ToLowerInvariant() + '|' + ([string]$package.id).ToLowerInvariant())] = $current
        }
    }
    [pscustomobject]@{
        path=$fullManifestPath
        raw=$manifest
        files=$files
        installedPackages=$installedPackages
        packageStates=$packageStates
        notes=@($manifest.notes)
    }
}

function Invoke-CodexSetupRollback {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$NonInteractive,
        [switch]$AllowIncompleteRun,
        [string]$StateRoot = (Get-DefaultSetupStateRoot)
    )
    $manifest = Read-ValidatedRollbackManifest -ManifestPath $ManifestPath -StateRoot $StateRoot -AllowIncompleteRun:$AllowIncompleteRun
    $fileCount = @($manifest.files).Count
    $packageCount = @($manifest.installedPackages).Count
    Write-Host ''
    Write-Host '准备撤销一次由本工具完成的更改' -ForegroundColor Yellow
    Write-Host "  运行时间：$($manifest.raw.completedAt)"
    Write-Host "  文件：$fileCount 个（恢复原文件或删除本次新建文件）"
    Write-Host "  软件包：$packageCount 个（逐个尝试卸载）"
    foreach ($note in @($manifest.notes | Select-Object -First 3)) { Write-Host "  不自动撤销：$note" -ForegroundColor DarkGray }
    if ($WhatIfPreference) {
        Write-SetupStatus -Kind Info -Message '当前是预览；没有恢复文件或卸载软件包。'
        return [pscustomobject]@{ status='Preview'; restored=0; removed=0; uninstalled=0; failed=0; skipped=0; manifestPath=$manifest.path }
    }
    if (-not $NonInteractive -and -not (Confirm-SetupChoice -Prompt '确认撤销以上更改？' -DefaultYes:$false)) {
        Write-SetupStatus -Kind Info -Message '已取消回滚；没有修改电脑。'
        return [pscustomobject]@{ status='Cancelled'; restored=0; removed=0; uninstalled=0; failed=0; skipped=($fileCount + $packageCount); manifestPath=$manifest.path }
    }
    $restored = 0
    $removed = 0
    $uninstalled = 0
    $failed = 0
    $skipped = 0
    $fileChangesSinceCheckpoint = 0
    for ($index = $manifest.files.Count - 1; $index -ge 0; $index--) {
        $file = $manifest.files[$index]
        if ([string]$file.rollbackStatus -in @('Restored', 'Removed', 'NoChange')) { $skipped++; continue }
        try {
            if ($file.existed) {
                $currentSha = Get-SetupSha256 -Path ([string]$file.path)
                if ($currentSha -eq [string]$file.beforeSha256) {
                    if ($IsWindows -and -not [string]::Equals(
                        (Get-Acl -LiteralPath ([string]$file.path)).Sddl,
                        [string]$file.beforeSddl,
                        [StringComparison]::Ordinal
                    )) { throw '目标 ACL 在预检后发生变化。' }
                    $file.rollbackStatus = 'NoChange'
                    $file.rollbackError = $null
                    $skipped++
                    $fileChangesSinceCheckpoint++
                    if ($fileChangesSinceCheckpoint -ge 25) {
                        Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
                        $fileChangesSinceCheckpoint = 0
                    }
                    continue
                }
                if ($currentSha -ne [string]$file.appliedSha256) { throw '目标哈希在预检后发生变化。' }
                if ($IsWindows -and -not [string]::Equals(
                    (Get-Acl -LiteralPath ([string]$file.path)).Sddl,
                    [string]$file.appliedSddl,
                    [StringComparison]::Ordinal
                )) { throw '目标 ACL 在预检后发生变化。' }
                $parent = Split-Path -Parent ([string]$file.path)
                [System.IO.Directory]::CreateDirectory($parent) | Out-Null
                $temporaryPath = Join-Path $parent ('.{0}.{1}.rollback' -f (Split-Path -Leaf ([string]$file.path)), [guid]::NewGuid().ToString('N'))
                try {
                    Copy-Item -LiteralPath $file.backup -Destination $temporaryPath -Force
                    if ($IsWindows) {
                        $acl = Get-Acl -LiteralPath $temporaryPath
                        $acl.SetSecurityDescriptorSddlForm([string]$file.beforeSddl)
                        Set-Acl -LiteralPath $temporaryPath -AclObject $acl
                    }
                    if ((Get-SetupSha256 -Path $temporaryPath) -ne [string]$file.beforeSha256) { throw '临时恢复文件哈希复核失败。' }
                    if ($IsWindows -and -not [string]::Equals(
                        (Get-Acl -LiteralPath $temporaryPath).Sddl,
                        [string]$file.beforeSddl,
                        [StringComparison]::Ordinal
                    )) { throw '临时恢复文件 ACL 复核失败。' }
                    if ((Get-SetupSha256 -Path ([string]$file.path)) -ne [string]$file.appliedSha256) { throw '目标哈希在原子替换前发生变化。' }
                    if ($IsWindows -and -not [string]::Equals(
                        (Get-Acl -LiteralPath ([string]$file.path)).Sddl,
                        [string]$file.appliedSddl,
                        [StringComparison]::Ordinal
                    )) { throw '目标 ACL 在原子替换前发生变化。' }
                    [System.IO.File]::Move($temporaryPath, [string]$file.path, $true)
                }
                finally {
                    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    }
                }
                if ((Get-SetupSha256 -Path ([string]$file.path)) -ne [string]$file.beforeSha256) { throw '恢复后哈希复核失败。' }
                if ($IsWindows -and -not [string]::Equals(
                    (Get-Acl -LiteralPath ([string]$file.path)).Sddl,
                    [string]$file.beforeSddl,
                    [StringComparison]::Ordinal
                )) {
                    throw '恢复后 ACL 复核失败。'
                }
                $file.rollbackStatus = 'Restored'
                $file.rollbackError = $null
                $restored++
            }
            elseif (Test-Path -LiteralPath $file.path -PathType Leaf) {
                if ((Get-SetupSha256 -Path ([string]$file.path)) -ne [string]$file.appliedSha256) { throw '目标哈希在预检后发生变化。' }
                if ($IsWindows -and -not [string]::Equals(
                    (Get-Acl -LiteralPath ([string]$file.path)).Sddl,
                    [string]$file.appliedSddl,
                    [StringComparison]::Ordinal
                )) { throw '目标 ACL 在预检后发生变化。' }
                Remove-Item -LiteralPath $file.path -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $file.path) { throw '删除后文件仍然存在。' }
                $file.rollbackStatus = 'Removed'
                $file.rollbackError = $null
                $removed++
            }
            else {
                $file.rollbackStatus = 'NoChange'
                $file.rollbackError = $null
                $skipped++
            }
            $fileChangesSinceCheckpoint++
            if ($fileChangesSinceCheckpoint -ge 25) {
                Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
                $fileChangesSinceCheckpoint = 0
            }
        }
        catch {
            $file.rollbackStatus = 'Failed'
            $file.rollbackError = ConvertTo-RedactedText $_.Exception.Message
            Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
            $fileChangesSinceCheckpoint = 0
            $failed++
            Write-SetupStatus -Kind Error -Message "无法恢复 $($file.path)：$($file.rollbackError)"
        }
    }
    if ($fileChangesSinceCheckpoint -gt 0) {
        Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
    }
    foreach ($package in $manifest.installedPackages) {
        if ([string]$package.rollbackStatus -in @('Uninstalled', 'NoChange')) { $skipped++; continue }
        try {
            $packageStateKey = ([string]$package.source).ToLowerInvariant() + '|' + ([string]$package.id).ToLowerInvariant()
            $beforePackage = $manifest.packageStates[$packageStateKey]
            if (-not [bool]$beforePackage.installed) {
                $package.rollbackStatus = 'NoChange'
                $package.rollbackError = $null
                $skipped++
                Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
                continue
            }
            $currentPackage = Get-WindowsPackageState -PackageId ([string]$package.id) -Source ([string]$package.source)
            if ($currentPackage.state -eq 'Unknown') { throw "卸载前无法再次确认软件包状态：$($currentPackage.error)" }
            if (-not $currentPackage.installed) {
                $package.rollbackStatus = 'NoChange'
                $package.rollbackError = $null
                $skipped++
                Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
                continue
            }
            if (-not [string]::Equals(
                [string]$currentPackage.version,
                [string]$package.installedVersion,
                [StringComparison]::OrdinalIgnoreCase
            )) { throw "卸载前软件包版本已变化：$($package.id)" }
            $exitCode = Invoke-ExternalSetupCommand -Command 'winget.exe' -Arguments @(
                'uninstall', '--id', [string]$package.id, '--exact', '--source', [string]$package.source,
                '--accept-source-agreements', '--disable-interactivity', '--silent'
            ) -AllowFailure -Quiet
            if ($exitCode -ne 0) { throw "WinGet 卸载命令失败（exit=$exitCode）。" }
            $after = Get-WindowsPackageState -PackageId ([string]$package.id) -Source ([string]$package.source)
            if ($after.state -eq 'Unknown') { throw "卸载后无法复核软件包状态（exit=$exitCode）。" }
            if ($after.installed) { throw "卸载后软件包仍存在（exit=$exitCode）。" }
            $package.rollbackStatus = 'Uninstalled'
            $package.rollbackError = $null
            $uninstalled++
            Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
        }
        catch {
            $package.rollbackStatus = 'Failed'
            $package.rollbackError = ConvertTo-RedactedText $_.Exception.Message
            Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
            $failed++
            Write-SetupStatus -Kind Error -Message "无法卸载 $($package.id)：$($package.rollbackError)"
        }
    }
    $status = if ($failed -gt 0) { 'Partial' } else { 'Completed' }
    if ($failed -eq 0) {
        $manifest.raw.rolledBackAt = (Get-Date).ToString('o')
        $manifest.raw.runStatus = 'RolledBack'
        Write-RollbackManifestAtomic -Path $manifest.path -Manifest $manifest.raw
        Write-SetupStatus -Kind Success -Message "已撤销：恢复 $restored 个文件，删除 $removed 个新文件，卸载 $uninstalled 个软件包。"
    }
    else {
        Write-SetupStatus -Kind Warning -Message "回滚未完全完成：成功处理 $($restored + $removed + $uninstalled) 项，失败 $failed 项，未处理 $skipped 项。"
    }
    return [pscustomobject]@{ status=$status; restored=$restored; removed=$removed; uninstalled=$uninstalled; failed=$failed; skipped=$skipped; manifestPath=$manifest.path }
}

Export-ModuleMember -Function @(
    'Invoke-CodexSetupPlan', 'Invoke-CodexSetupRollback', 'New-ProjectTemplateMap',
    'Convert-WindowsPathToWsl', 'Set-WslNetworkingConfig'
)
