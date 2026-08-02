Set-StrictMode -Version Latest

function Get-PlanningProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function New-SetupAction {
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Type,
        [string]$Target,
        [string]$Reason,
        [bool]$Critical = $false,
        [string[]]$DependsOn = @(),
        [hashtable]$Parameters = @{}
    )
    return [pscustomobject]@{
        module = $Module; id = $Id; title = $Title; type = $Type; target = $Target
        reason = $Reason; critical = $Critical; dependsOn = @($DependsOn); parameters = [pscustomobject]$Parameters
    }
}

function Get-AgentDisplayName {
    param([AllowNull()][string]$Agent)
    switch ($Agent) {
        'WindowsNative' { return 'Windows' }
        'PowerShell7' { return 'PowerShell' }
        'WSL' { return 'WSL/Linux' }
        default { return $Agent }
    }
}

function Get-CodexSetupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Detection,
        [Parameter(Mandatory)]$Config,
        [AllowNull()][string]$ProjectPath
    )

    $actions = @()
    $warnings = @()
    $information = @()
    $skipped = @()

    if (-not $Detection.windows.isWindows11) {
        $warnings += '当前系统不是受支持基线 Windows 11；脚本不会在旧系统上自动应用高风险配置。'
    }
    if (-not $Detection.windows.isAdministrator) {
        $information += '当前为标准权限会话（推荐）。WSL、Windows 功能和 elevated sandbox 首次设置时可能触发 UAC。'
    }
    $pathConflicts = @(Get-PlanningProperty $Detection.path 'conflicts' (Get-PlanningProperty $Detection.path 'shadowedTools' @()))
    $duplicateEntrypoints = @(Get-PlanningProperty $Detection.path 'duplicateEntrypoints' @())
    $appAliases = @(Get-PlanningProperty $Detection.path 'appAliases' @())
    $pathDuplicates = @(Get-PlanningProperty $Detection.path 'duplicates' @())
    $pathMissing = @(Get-PlanningProperty $Detection.path 'missing' @())
    if ($pathConflicts.Count -gt 0) {
        foreach ($item in $pathConflicts) {
            $warnings += "命令 $($item.tool) 有多个安装来源：$($item.paths -join '；')"
        }
    }
    if ($duplicateEntrypoints.Count -gt 0) {
        $information += "发现 $($duplicateEntrypoints.Count) 组同一软件的重复入口；不影响使用，仅记录。"
    }
    if ($appAliases.Count -gt 0) {
        $information += "发现 $($appAliases.Count) 组 Windows 应用快捷入口；不影响使用，仅记录。"
    }
    if ($pathDuplicates.Count -gt 0) {
        $information += "发现 $($pathDuplicates.Count) 组重复的命令目录；不会自动删除。"
    }
    if ($pathMissing.Count -gt 0) {
        $warnings += "发现 $($pathMissing.Count) 个已不存在的命令目录；仅提醒，不会自动删除。"
    }
    foreach ($issue in @(Get-PlanningProperty $Detection 'issues' @())) {
        $warnings += "部分检查未完成（$($issue.name)）：$($issue.error)"
    }

    $packageMap = @(
        @{ Module='Core'; Id='PowerShell7'; Title='安装 PowerShell 7'; Package='Microsoft.PowerShell'; Source='winget'; Installed=$Detection.powershell7.installed; Critical=$true; DetectionError=(Get-PlanningProperty $Detection.powershell7 'probeError') },
        @{ Module='Core'; Id='WindowsTerminal'; Title='安装 Windows Terminal'; Package='Microsoft.WindowsTerminal'; Source='winget'; Installed=($Detection.windowsTerminal.command.installed -or $Detection.windowsTerminal.app.installed); Critical=$false; DetectionError=$(if (-not ($Detection.windowsTerminal.command.installed -or $Detection.windowsTerminal.app.installed)) { Get-PlanningProperty $Detection.windowsTerminal.app 'error' }) },
        @{ Module='Core'; Id='Ripgrep'; Title='安装 ripgrep'; Package='BurntSushi.ripgrep.MSVC'; Source='winget'; Installed=[bool](Get-Command rg.exe -ErrorAction SilentlyContinue); Critical=$false; DetectionError=$null },
        @{ Module='Core'; Id='Fd'; Title='安装 fd（可选：快速查找文件）'; Package='sharkdp.fd'; Source='winget'; Installed=[bool](Get-Command fd.exe -ErrorAction SilentlyContinue); Critical=$false; DetectionError=$null; Reason='可选效率工具，用于按名称快速查找文件和文件夹；不安装也不影响基础开发。' },
        @{ Module='Core'; Id='Jq'; Title='安装 jq（可选：查看和处理 JSON）'; Package='jqlang.jq'; Source='winget'; Installed=[bool](Get-Command jq.exe -ErrorAction SilentlyContinue); Critical=$false; DetectionError=$null; Reason='可选效率工具，用于在终端中查看、筛选和转换 JSON；不安装也不影响基础开发。' },
        @{ Module='Git'; Id='Git'; Title='安装 Windows 原生 Git'; Package='Git.Git'; Source='winget'; Installed=$Detection.git.installed; Critical=$true; DetectionError=(Get-PlanningProperty $Detection.git 'probeError') },
        @{ Module='Git'; Id='GitHubCli'; Title='安装 GitHub CLI'; Package='GitHub.cli'; Source='winget'; Installed=$Detection.githubCli.installed; Critical=$false; DetectionError=(Get-PlanningProperty $Detection.githubCli 'probeError') },
        @{ Module='CodexDesktop'; Id='CodexDesktop'; Title='安装 ChatGPT/Codex Desktop'; Package='9PLM9XGG6VKS'; Source='msstore'; Installed=$Detection.codexDesktop.installed; Critical=$false; DetectionError=(Get-PlanningProperty $Detection.codexDesktop 'error') },
        @{ Module='Node'; Id='Fnm'; Title='安装 Node.js 管理工具（fnm）'; Package='Schniz.fnm'; Source='winget'; Installed=$Detection.fnm.installed; Critical=$false; DetectionError=(Get-PlanningProperty $Detection.fnm 'probeError'); Reason='用于安装和切换不同版本的 Node.js。' },
        @{ Module='Python'; Id='Uv'; Title='安装 Python 管理工具（uv）'; Package='astral-sh.uv'; Source='winget'; Installed=$Detection.uv.installed; Critical=$false; DetectionError=(Get-PlanningProperty $Detection.uv 'probeError'); Reason='用于安装 Python，并为每个项目管理独立环境。' }
    )

    foreach ($package in $packageMap) {
        if ($package.DetectionError) {
            $warnings += "无法确认 $($package.Title -replace '^安装 ','') 状态，已从自动安装计划跳过：$($package.DetectionError)"
            $skipped += "$($package.Title -replace '^安装 ','') 状态未知；未生成安装动作"
        }
        elseif (-not $package.Installed) {
            $reason = if ($package.ContainsKey('Reason') -and $package.Reason) {
                "$($package.Reason.TrimEnd())尚未检测到；设置前会先征求你的确认。"
            }
            else { '尚未检测到；开始设置时会先征求你的确认。' }
            $actions += New-SetupAction -Module $package.Module -Id $package.Id -Title $package.Title -Type 'WingetInstall' `
                -Target $package.Package -Reason $reason -Critical $package.Critical `
                -Parameters @{ packageId=$package.Package; source=$package.Source }
        }
        elseif ($Config.preferences.updatePolicy -eq 'CheckAndPrompt') {
            $actions += New-SetupAction -Module 'Updates' -Id "Check$($package.Id)" -Title "检查 $($package.Title -replace '^安装 ','') 更新" `
                -Type 'WingetUpgradeCheck' -Target $package.Package -Reason '只查询是否有更新；不会下载或安装。' `
                -Parameters @{ packageId=$package.Package; source=$package.Source }
        }
        else {
            $skipped += "$($package.Title -replace '^安装 ','') 已安装"
        }
    }

    if ($Config.toolchains.node.enabled -and $Config.toolchains.node.manager -eq 'fnm' -and -not (Get-PlanningProperty $Detection.fnm 'probeError')) {
        $actions += New-SetupAction -Module 'Node' -Id 'ConfigureNodeLts' -Title '安装推荐版本的 Node.js' -Type 'NodeConfigure' `
            -Target 'fnm:lts-latest' -Reason '使用长期支持版，适合大多数项目；项目可再用 .node-version 固定版本。' -DependsOn @('Fnm')
    }
    if ($Config.toolchains.python.enabled -and $Config.toolchains.python.manager -eq 'uv' -and -not (Get-PlanningProperty $Detection.uv 'probeError')) {
        $actions += New-SetupAction -Module 'Python' -Id 'ConfigurePythonUv' -Title '准备 Python 开发环境' -Type 'PythonConfigure' `
            -Target 'uv python install' -Reason '安装当前受支持的 Python；项目可再用 .python-version 或 pyproject.toml 固定版本。' -DependsOn @('Uv')
    }

    if (Get-PlanningProperty $Detection.wsl 'error') {
        $warnings += "无法确认 WSL 状态，已跳过 WSL 安装与配置动作：$($Detection.wsl.error)"
        $skipped += 'WSL 状态未知；未生成 WSL 变更动作'
    }
    elseif (-not $Detection.wsl.installed) {
        $actions += New-SetupAction -Module 'WSL' -Id 'InstallWslUbuntu' -Title '安装 WSL2 与 Ubuntu' -Type 'WslInstall' `
            -Target 'Ubuntu' -Reason '跨平台 Web/Python 项目和自动 Agent 建议需要 WSL2。' -Critical $true
    }
    elseif (-not $Detection.wsl.ubuntu) {
        $actions += New-SetupAction -Module 'WSL' -Id 'InstallUbuntu' -Title '安装 Ubuntu 发行版' -Type 'WslInstallDistro' `
            -Target 'Ubuntu' -Reason '已检测到 WSL，但未检测到 Ubuntu。' -Critical $true
    }
    elseif (-not $Detection.wsl.ubuntuWsl2) {
        $actions += New-SetupAction -Module 'WSL' -Id 'ConvertUbuntuWsl2' -Title '将 Ubuntu 转换为 WSL2' -Type 'WslConvert2' `
            -Target $Detection.wsl.ubuntuName -Reason 'Codex 0.115 起不再支持 WSL1。' -Critical $true `
            -Parameters @{ distro=$Detection.wsl.ubuntuName }
    }
    else {
        $wslTools = Get-PlanningProperty $Detection 'wslTools'
        $wslDetailsKnown = $null -ne $wslTools -and
            [bool](Get-PlanningProperty $wslTools 'available' $false) -and
            -not [bool](Get-PlanningProperty $wslTools 'skipped' $false) -and
            -not (Get-PlanningProperty $wslTools 'error')
        $installNodeInWsl = [bool]($Config.toolchains.node.enabled -and $Config.toolchains.node.manager -eq 'fnm')
        $installPythonInWsl = [bool]($Config.toolchains.python.enabled -and $Config.toolchains.python.manager -eq 'uv')
        $wslNeedLabels = @()
        $wslBlockedByMissingSudo = $false
        if ($wslDetailsKnown) {
            $wslToolStates = Get-PlanningProperty $wslTools 'tools' ([pscustomobject]@{})
            $missingAptPackages = @(Get-PlanningProperty $wslTools 'aptPackagesMissing' @())
            $unavailableWslToolStates = @('missing', 'windows-path', 'unavailable')
            $installNodeInWsl = $installNodeInWsl -and (
                (Get-PlanningProperty $wslToolStates 'fnm' 'missing') -in $unavailableWslToolStates -or
                (Get-PlanningProperty $wslToolStates 'node' 'missing') -in $unavailableWslToolStates
            )
            $installPythonInWsl = $installPythonInWsl -and (
                (Get-PlanningProperty $wslToolStates 'uv' 'missing') -in $unavailableWslToolStates -or
                (Get-PlanningProperty $wslToolStates 'python3' 'missing') -in $unavailableWslToolStates
            )
            $codeRootKnown = $Config.paths.wslProjects -eq '~/code'
            $needsCodeRoot = -not $codeRootKnown -or -not [bool](Get-PlanningProperty $wslTools 'codeRootExists' $false)
            $managedBlockPresent = [bool](Get-PlanningProperty $wslTools 'managedBlockPresent' $false)
            $managedBlockSharesCodexHome = Get-PlanningProperty $wslTools 'managedBlockSharesCodexHome'
            $desiredCodexHomeSharing = [bool]$Config.codex.shareWindowsHomeToWsl
            $needsShellBlock = -not $managedBlockPresent -or $null -eq $managedBlockSharesCodexHome -or [bool]$managedBlockSharesCodexHome -ne $desiredCodexHomeSharing
            $needsFdCommand = (Get-PlanningProperty $wslToolStates 'fd' 'missing') -in $unavailableWslToolStates

            if ($missingAptPackages.Count -gt 0) { $wslNeedLabels += "$($missingAptPackages.Count) 个 Linux 基础工具" }
            if ($needsFdCommand) { $wslNeedLabels += 'fd 文件查找命令' }
            if ($needsCodeRoot) { $wslNeedLabels += '代码文件夹' }
            if ($needsShellBlock) { $wslNeedLabels += '终端启动设置' }
            if ($installNodeInWsl) { $wslNeedLabels += 'Node.js' }
            if ($installPythonInWsl) { $wslNeedLabels += 'Python' }
            if ($missingAptPackages.Count -gt 0 -and -not [bool](Get-PlanningProperty $wslTools 'sudoAvailable' $false)) {
                $wslBlockedByMissingSudo = $true
                $warnings += 'Ubuntu 中缺少 sudo，无法安全完成所需的 Linux 系统工具安装；本次不会运行 WSL 设置，避免留下只完成一部分的环境。请先在该发行版中恢复 sudo 后重新检查。'
            }
        }

        if ($wslBlockedByMissingSudo) {
            $skipped += 'WSL/Linux 设置暂未执行：Ubuntu 缺少 sudo，且仍有系统工具需要安装。'
        }
        elseif ($wslDetailsKnown -and $wslNeedLabels.Count -eq 0) {
            $skipped += 'WSL/Linux 开发工具已准备好，无需重复设置。'
        }
        else {
            $wslReason = if ($wslNeedLabels.Count -gt 0) {
                "只处理仍缺少的项目：$($wslNeedLabels -join '、')。已具备的工具不会重复安装。"
            }
            else { '完整设置前会再次确认实际缺少的工具；已具备的工具不会重复安装。' }
            $actions += New-SetupAction -Module 'WSL' -Id 'ConfigureWsl' -Title '准备 WSL/Linux 开发工具' -Type 'WslConfigure' `
                -Target $Detection.wsl.ubuntuName -Reason $wslReason `
                -Parameters @{
                    distro=$Detection.wsl.ubuntuName
                    shareCodexHome=[bool]$Config.codex.shareWindowsHomeToWsl
                    installNode=$installNodeInWsl
                    installPython=$installPythonInWsl
                }
        }
    }

    $wslNetworking = Get-PlanningProperty $Config 'wslNetworking'
    if ($null -ne $wslNetworking -and [bool](Get-PlanningProperty $wslNetworking 'configure' $false)) {
        if (-not $Detection.windows.isWindows11 -or [int](Get-PlanningProperty $Detection.windows 'build' 0) -lt 22621) {
            $warnings += '当前 Windows 版本不支持 WSL mirrored networking；已跳过网络配置。'
            $skipped += 'WSL 网络设置未执行：需要 Windows 11 22H2 或更高版本。'
        }
        elseif (-not $Detection.wsl.ubuntuWsl2) {
            $warnings += '需要先准备可用的 WSL2 Ubuntu，之后才能配置 mirrored 网络与 WSL 代理环境。'
            $skipped += 'WSL 网络设置将在 WSL2 Ubuntu 可用后执行。'
        }
        else {
            $wslVersionText = [string](Get-PlanningProperty $Detection.wsl 'version' '')
            if ($wslVersionText -match '(\d+\.\d+(?:\.\d+){0,2})') {
                if ([version]$matches[1] -lt [version]'2.0.0') {
                    $warnings += '当前 WSL 包版本较旧；应用 mirrored 配置前请先在 PowerShell 运行 wsl --update。'
                }
            }
            else {
                $warnings += '未能确认 WSL 包版本；应用 mirrored 配置前建议先在 PowerShell 运行 wsl --update。'
            }
            $proxyMode = [string](Get-PlanningProperty $wslNetworking 'proxyMode' 'none')
            $httpPort = [int](Get-PlanningProperty $wslNetworking 'httpPort' 10808)
            $socksPort = [int](Get-PlanningProperty $wslNetworking 'socksPort' $httpPort)
            $proxyText = if ($proxyMode -eq 'persistent') {
                "同时持久加载 HTTP $httpPort / SOCKS $socksPort 代理；Codex 新启动的 WSL 进程也可继承。"
            }
            else { '配置 WSL mirrored 网络，并移除本工具管理的持久代理。' }
            $actions += New-SetupAction -Module 'Network' -Id 'ConfigureWslNetwork' -Title '配置 WSL mirrored 网络与本机代理' -Type 'WslNetworkConfigure' `
                -Target '%USERPROFILE%\.wslconfig；WSL ~/.config/codex/proxy.sh' `
                -Reason "WSL 通过 127.0.0.1 访问 Windows 服务；本工具不会开启 v2rayN LAN 监听。$proxyText" `
                -Parameters @{
                    distro=$Detection.wsl.ubuntuName
                    proxyMode=$proxyMode
                    httpPort=$httpPort
                    socksPort=$socksPort
                }
            if ($proxyMode -eq 'persistent') {
                $warnings += '已选择持久代理：请先启动 v2rayN 再启动 Codex；v2rayN 未运行或端口变化时，依赖代理变量的联网命令会失败。'
            }
            $detectedNetwork = Get-PlanningProperty $Detection 'wslNetwork'
            $wildcardListeners = @(Get-PlanningProperty $detectedNetwork 'wildcardListeners' @())
            if ($wildcardListeners.Count -gt 0) {
                $warnings += '检测到候选代理端口监听在 0.0.0.0 或 ::；请在 v2rayN 中关闭“允许来自局域网的连接”。'
            }
        }
    }

    $actions += New-SetupAction -Module 'Git' -Id 'ConfigureGit' -Title '设置 Git 常用安全选项' -Type 'GitConfig' `
        -Target '~/.gitconfig' -Reason '设置默认分支、拉取和换行规则；不读取或保存账号信息。'
    $actions += New-SetupAction -Module 'Git' -Id 'AuthGuidance' -Title 'GitHub 登录方法（可稍后完成）' -Type 'AuthGuidance' `
        -Target '报告' -Reason '提供浏览器登录和登录状态检查步骤；不会自动登录，也不会读取令牌或 SSH 私钥。'

    $actions += New-SetupAction -Module 'Terminal' -Id 'TerminalProfiles' -Title '添加 Codex 终端启动项' -Type 'TerminalFragment' `
        -Target '%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\CodexDevSetup\codex.json' `
        -Reason '在 Windows Terminal 中添加 Windows 和 WSL/Linux 入口，不会覆盖你现有的终端设置。' `
        -Parameters @{
            distro=$(if ($Detection.wsl.ubuntuName) { $Detection.wsl.ubuntuName } else { 'Ubuntu' })
            windowsProjects=$Config.paths.windowsProjects
        }
    $actions += New-SetupAction -Module 'Terminal' -Id 'PowerShellProfile' -Title '添加 PowerShell 开发快捷命令' -Type 'PowerShellProfile' `
        -Target '$HOME\Documents\PowerShell\profile.ps1' -Reason '添加常用 Git 和项目快捷命令，并自动切换项目需要的 Node.js 版本。' `
        -Parameters @{ windowsProjects=$Config.paths.windowsProjects }

    $sandboxText = switch ($Config.codex.sandboxMode) {
        'workspace-write' { '只允许修改当前工作区' }
        'read-only' { '只读，不修改文件' }
        'danger-full-access' { '允许访问工作区之外的位置' }
        default { "文件权限为 $($Config.codex.sandboxMode)" }
    }
    $approvalText = switch ($Config.codex.approvalPolicy) {
        'on-request' { '需要时会先询问' }
        'never' { '执行时不再询问' }
        'untrusted' { '不受信任的操作会先询问' }
        default { "确认方式为 $($Config.codex.approvalPolicy)" }
    }
    $windowsPermissionText = if ($Config.codex.windowsSandbox -eq 'unelevated') { 'Windows 使用标准权限' } else { 'Windows 使用增强隔离权限' }
    $webSearchText = if ($Config.codex.webSearch -eq 'live') { '可实时联网搜索' } else { "联网搜索为 $($Config.codex.webSearch)" }
    $actions += New-SetupAction -Module 'CodexConfig' -Id 'GlobalCodexConfig' -Title '设置 Codex 默认工作方式' -Type 'CodexGlobalConfig' `
        -Target '%USERPROFILE%\.codex\config.toml' `
        -Reason "$sandboxText；$approvalText；$windowsPermissionText；$webSearchText。" `
        -Critical ($Config.codex.sandboxMode -eq 'danger-full-access')

    if ($Config.codex.sandboxMode -eq 'danger-full-access') {
        $warnings += '已选择 danger-full-access：Codex 不受项目目录边界限制，命令网络访问也不受 workspace sandbox 限制。仅对可信个人项目使用。'
    }
    if ($Config.codex.shareWindowsHomeToWsl) {
        $warnings += '共享 CODEX_HOME 会让 WSL CLI 使用 Windows 侧配置、缓存认证与会话历史；脚本不会读取这些内容。'
    }
    if ($Config.codex.windowsSandbox -eq 'elevated') {
        $warnings += 'Codex elevated sandbox 与 Windows Sandbox 可选功能不是同一机制；前者首次设置可能需要管理员批准。'
    }

    $projectDetectionFailed = @((Get-PlanningProperty $Detection 'issues' @()) | Where-Object stage -eq 6).Count -gt 0
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and -not $projectDetectionFailed) {
        $actions += New-SetupAction -Module 'Project' -Id 'ProjectTemplates' -Title '为项目添加基础配置文件' -Type 'ProjectTemplates' `
            -Target $ProjectPath -Reason '可添加 AGENTS.md、Codex 设置、编辑器和 Git 配置；已有文件会逐个询问，不会直接覆盖。' `
            -Parameters @{ projectPath=$ProjectPath; agent=$Detection.project.agent }
    }
    elseif ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $skipped += '尚未选择项目文件夹，本次不会写入项目配置文件。可稍后从首页选择“为项目准备基础配置文件”。'
    }
    else {
        $warnings += '项目类型检测失败，已跳过项目模板动作，避免写入不匹配的 Agent 配置。'
    }

    return [pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        healthScore = $Detection.healthScore
        healthLabel = Get-PlanningProperty $Detection 'healthLabel' '未评级'
        detectionMode = Get-PlanningProperty $Detection 'detectionMode' '完整'
        recommendation = $Detection.project
        actions = $actions
        warnings = $warnings
        information = $information
        skipped = $skipped
        requiresRestart = @(@(
            '切换 Codex Desktop Agent 后必须重启应用。',
            '安装或转换 WSL 后 Windows 可能要求重启。',
            '安装新工具后重新打开终端以刷新 PATH。',
            $(if ($null -ne $wslNetworking -and [bool](Get-PlanningProperty $wslNetworking 'configure' $false)) { '修改 .wslconfig 或 WSL 代理后，请先保存 WSL 中的工作，再运行 wsl --shutdown 并重新打开 Codex。' })
        ) | Where-Object { $_ })
    }
}

function Show-CodexSetupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    Write-Host ''
    Write-Host '检查结果与建议' -ForegroundColor White
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host "核心环境可用性：$(Get-PlanningProperty $Plan 'healthLabel' '未评级')（$($Plan.healthScore)/100）"
    Write-SetupWrappedText -Text '分数只反映核心组件是否可用，不代表所有可选设置都已完成。' -FirstIndent '  说明：' -ContinuationIndent '        ' -ForegroundColor DarkGray
    $setupActionCount = @($Plan.actions | Where-Object { (Get-PlanningProperty $_ 'type' '') -notin @('WingetUpgradeCheck', 'AuthGuidance') }).Count
    $checkActionCount = @($Plan.actions | Where-Object { (Get-PlanningProperty $_ 'type' '') -in @('WingetUpgradeCheck', 'AuthGuidance') }).Count
    Write-Host "本次建议：设置 $setupActionCount 项；检查或指引 $checkActionCount 项"
    Write-Host "检查范围：$(Get-PlanningProperty $Plan 'detectionMode' '完整')"
    Write-Host "推荐工作方式：$(Get-AgentDisplayName $Plan.recommendation.agent)"
    Write-Host "推荐终端：$(Get-AgentDisplayName $Plan.recommendation.terminal)"
    foreach ($reason in $Plan.recommendation.reasons) {
        Write-SetupWrappedText -Text $reason -FirstIndent '  · ' -ContinuationIndent '    ' -ForegroundColor DarkCyan
    }
    $modules = @(Get-SetupOrderedModules -Actions $Plan.actions)
    for ($moduleIndex = 0; $moduleIndex -lt $modules.Count; $moduleIndex++) {
        $module = $modules[$moduleIndex]
        $groupActions = @($Plan.actions | Where-Object module -eq $module)
        Write-SetupSectionHeader -Title ("工作步骤 {0}/{1} · {2}" -f ($moduleIndex + 1), $modules.Count, (Get-SetupModuleDisplayName $module)) -ForegroundColor Magenta
        for ($actionIndex = 0; $actionIndex -lt $groupActions.Count; $actionIndex++) {
            $action = $groupActions[$actionIndex]
            $risk = if ($action.critical) { '（需要特别留意）' } else { '' }
            $actionNumber = '{0}.{1}' -f ($moduleIndex + 1), ($actionIndex + 1)
            Write-Host "  [$actionNumber] $($action.title)$risk" -ForegroundColor $(if ($action.critical) { 'Yellow' } else { 'Gray' })
            if ($action.reason) {
                Write-SetupWrappedText -Text $action.reason -FirstIndent '        ' -ContinuationIndent '        ' -ForegroundColor DarkGray
            }
        }
    }
    if ($Plan.warnings.Count -gt 0) {
        Write-SetupSectionHeader -Title '需要留意（不会自动处理）' -ForegroundColor Yellow
        foreach ($warning in $Plan.warnings) {
            Write-SetupWrappedText -Text $warning -FirstIndent '  ! ' -ContinuationIndent '    ' -ForegroundColor Yellow
        }
    }
    $planInformation = @(Get-PlanningProperty $Plan 'information' @())
    if ($planInformation.Count -gt 0) {
        Write-SetupSectionHeader -Title '补充说明' -ForegroundColor DarkCyan
        foreach ($item in $planInformation) {
            Write-SetupWrappedText -Text $item -FirstIndent '  · ' -ContinuationIndent '    ' -ForegroundColor DarkCyan
        }
    }
    if ($Plan.skipped.Count -gt 0) {
        Write-SetupSectionHeader -Title '暂不需要处理' -ForegroundColor DarkGray
        foreach ($item in $Plan.skipped) {
            Write-SetupWrappedText -Text $item -FirstIndent '  - ' -ContinuationIndent '    ' -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

Export-ModuleMember -Function @('Get-CodexSetupPlan', 'Show-CodexSetupPlan')
