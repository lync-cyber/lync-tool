Set-StrictMode -Version Latest

function ConvertTo-WindowsPackageUserMessage {
    param([AllowNull()][string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return '' }
    if ($ErrorText -eq 'winget-command-not-found') {
        return '未找到 WinGet。请先更新或修复 Microsoft App Installer。'
    }
    if ($ErrorText -like 'winget-*-timeout:*' -or $ErrorText -like 'winget-source-query-skipped-after-timeout:*') {
        return 'WinGet 响应超时。请重新检查；若仍然超时，请检查 WinGet 软件源。'
    }
    if ($ErrorText -like 'winget-export-*') {
        return 'WinGet 未能读取已安装应用。请在 Windows Terminal 运行 winget --info 检查状态。'
    }
    if ($ErrorText -like 'winget-list-*') {
        return 'WinGet 未能确认该应用的安装状态。请重新检查。'
    }
    return $ErrorText
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
    [pscustomobject]@{
        module = $Module
        id = $Id
        title = $Title
        type = $Type
        target = $Target
        reason = $Reason
        critical = $Critical
        dependsOn = @($DependsOn)
        parameters = [pscustomobject]$Parameters
    }
}

function Get-PlannedWindowsPackageDetection {
    param(
        [AllowNull()]$Catalog,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source
    )
    $packageStates = Get-SetupProperty $Catalog 'packageStates'
    $key = "$Source|$PackageId"
    $state = Get-SetupProperty $packageStates $key
    if ($null -eq $state) {
        $catalogError = [string](Get-SetupProperty $Catalog 'error' '')
        return [pscustomobject]@{
            state='Unknown'; installed=$false; version=$null
            error=$(if ($catalogError) { $catalogError } else { "缺少 $key 的精确软件包查询结果。" })
        }
    }
    return $state
}

function Add-WindowsPackageAction {
    param(
        [Parameter(Mandatory)][ref]$Actions,
        [Parameter(Mandatory)][ref]$Skipped,
        [Parameter(Mandatory)][ref]$BlockingReasons,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source,
        [AllowNull()]$Detection,
        [AllowNull()]$Capability,
        [bool]$Critical = $false
    )
    $state = [string](Get-SetupProperty $Detection 'state' 'Unknown')
    if ($state -notin @('KnownInstalled', 'KnownMissing')) { $state = 'Unknown' }
    $installed = $state -eq 'KnownInstalled' -and [bool](Get-SetupProperty $Detection 'installed' $false)
    $detectionError = [string](Get-SetupProperty $Detection 'error' '')
    if (-not $detectionError) { $detectionError = [string](Get-SetupProperty $Detection 'probeError' '') }
    $detectionError = ConvertTo-WindowsPackageUserMessage -ErrorText $detectionError
    if ($state -eq 'Unknown' -or (-not $installed -and $detectionError -and $detectionError -ne 'not-required-in-wsl-first')) {
        if (-not $detectionError) { $detectionError = 'Windows 软件包清单状态未知。' }
        $BlockingReasons.Value += "无法确认 Windows 应用状态：$detectionError"
        return
    }
    if (-not $installed) {
        $Actions.Value += New-SetupAction -Module $Module -Id $Id -Title $Title -Type 'WingetInstall' `
            -Target $PackageId -Reason '当前模式需要此 Windows 组件。' -Critical $Critical `
            -Parameters @{ packageId=$PackageId; source=$Source }
        return
    }
    $Skipped.Value += "$($Title -replace '^安装 ', '') 已安装"
    if ($null -ne $Capability -and -not [bool](Get-SetupProperty $Capability 'installed' $false)) {
        $BlockingReasons.Value += "$($Title -replace '^安装 ', '') 已安装，但当前终端无法使用其命令。请重新打开终端并检查 PATH。"
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
    $blockingReasons = @()
    $mode = [string]$Config.environmentMode
    $wslLifecycleState = 'NotApplicable'
    $wslAllowsHostConfig = $false

    if ($mode -notin @('WslFirst', 'WindowsNative')) {
        throw '配置中的开发环境类型无效。'
    }
    if (-not [bool](Get-SetupProperty $Detection.windows 'isWindows11' $false)) {
        $blockingReasons += '当前系统不是受支持的 Windows 11。'
    }
    if (-not [bool](Get-SetupProperty $Detection.windows 'isAdministrator' $false)) {
        $information += '当前为标准权限；设置 WSL 或 Windows 沙盒时可能显示 UAC 提示。'
    }

    $windows = $Config.windows
    $windowsPackageCatalog = Get-SetupProperty $Detection 'windowsPackageCatalog'
    $windowsGitPackageDetection = $null
    if ([bool]$windows.installTerminal) {
        $terminalDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog `
            -PackageId 'Microsoft.WindowsTerminal' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'Core' -Id 'WindowsTerminal' -Title '安装 Windows Terminal' -PackageId 'Microsoft.WindowsTerminal' `
            -Source winget -Detection $terminalDetection -Capability $Detection.windowsTerminal.command
    }
    if ([bool]$windows.installUiGit) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Git.Git' -Source winget
        $windowsGitPackageDetection = $packageDetection
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'Git' -Id 'WindowsGit' -Title '安装 Git for Windows（仅供桌面 UI）' -PackageId 'Git.Git' `
            -Source winget -Detection $packageDetection -Capability $Detection.git
    }
    if ([bool]$windows.installGitHubCli) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'GitHub.cli' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'Git' -Id 'WindowsGitHubCli' -Title '安装 GitHub CLI（Windows）' -PackageId 'GitHub.cli' `
            -Source winget -Detection $packageDetection -Capability $Detection.githubCli
    }
    if ([bool]$windows.installDesktop) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId '9PLM9XGG6VKS' -Source msstore
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'CodexDesktop' -Id 'CodexDesktop' -Title '安装 Codex Desktop' -PackageId '9PLM9XGG6VKS' `
            -Source msstore -Detection $packageDetection
    }
    if ([bool]$Config.toolchains.docker.enabled -and [string]$Config.toolchains.docker.provider -eq 'DockerDesktop') {
        $dockerDesktop = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Docker.DockerDesktop' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'Docker' -Id 'DockerDesktop' -Title '安装 Docker Desktop' -PackageId 'Docker.DockerDesktop' `
            -Source winget -Detection $dockerDesktop -Capability $Detection.dockerDesktop
    }

    if ($mode -eq 'WindowsNative') {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Microsoft.PowerShell' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
            -Module 'Core' -Id 'PowerShell7' -Title '安装 PowerShell 7' -PackageId 'Microsoft.PowerShell' -Source winget `
            -Detection $packageDetection -Capability $Detection.powershell7 -Critical $true
        foreach ($package in @(
            @{ Id='Ripgrep'; DetectionName='ripgrep'; Title='安装 Windows ripgrep'; Package='BurntSushi.ripgrep.MSVC' },
            @{ Id='Fd'; DetectionName='fd'; Title='安装 Windows fd'; Package='sharkdp.fd' },
            @{ Id='Jq'; DetectionName='jq'; Title='安装 Windows jq'; Package='jqlang.jq' }
        )) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId $package.Package -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
                -Module 'Core' -Id $package.Id -Title $package.Title -PackageId $package.Package -Source winget `
                -Detection $packageDetection -Capability (Get-SetupProperty $Detection $package.DetectionName)
        }
        if ([bool]$Config.toolchains.node.enabled) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'OpenJS.NodeJS.LTS' -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
                -Module 'Node' -Id 'NodeLts' -Title '安装 Windows Node.js LTS' -PackageId 'OpenJS.NodeJS.LTS' -Source winget `
                -Detection $packageDetection -Capability (Get-SetupProperty $Detection 'node')
            $npmDetection = Get-SetupProperty $Detection 'npm'
            if ($packageDetection.state -eq 'KnownInstalled' -and -not [bool](Get-SetupProperty $npmDetection 'installed' $false)) {
                $blockingReasons += 'Windows Node.js 包已登记，但 npm 在当前会话不可执行。'
            }
        }
        if ([bool]$Config.toolchains.python.enabled) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'astral-sh.uv' -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -BlockingReasons ([ref]$blockingReasons) `
                -Module 'Python' -Id 'Uv' -Title '安装 Windows uv' -PackageId 'astral-sh.uv' -Source winget `
                -Detection $packageDetection -Capability $Detection.uv
            $pythonDetection = Get-SetupProperty $Detection 'python'
            if ($packageDetection.state -ne 'Unknown' -and -not [bool](Get-SetupProperty $pythonDetection 'installed' $false)) {
                $pythonDependencies = $(if (@($actions.id) -contains 'Uv') { @('Uv') } else { @() })
                $actions += New-SetupAction -Module 'Python' -Id 'ConfigurePythonUv' -Title '安装 Windows Python' -Type 'PythonConfigure' `
                    -Target 'uv python install 3.12 --default' -Reason 'Windows 原生开发需要一套由 uv 管理的 Python 3.12。' -DependsOn $pythonDependencies
            }
        }
        if ($null -eq $windowsGitPackageDetection -or $windowsGitPackageDetection.state -eq 'Unknown') {
            $blockingReasons += 'Windows 原生开发环境需要先确认 Git for Windows。'
        }
        elseif ($windowsGitPackageDetection.state -eq 'KnownMissing') {
            $actions += New-SetupAction -Module 'Git' -Id 'ConfigureWindowsGit' -Title '设置 Windows Git 基线' -Type 'WindowsGitConfig' `
                -Target '%USERPROFILE%\.gitconfig' -Reason 'Windows 原生开发环境使用 Windows Git。' -DependsOn @('WindowsGit')
        }
        elseif ([bool](Get-SetupProperty $Detection.git 'installed' $false)) {
            $gitConfigState = Get-SetupProperty $Detection 'windowsGitConfig'
            $gitConfigError = [string](Get-SetupProperty $gitConfigState 'error' '')
            if ($gitConfigError) {
                $blockingReasons += $gitConfigError
            }
            elseif (-not [bool](Get-SetupProperty $gitConfigState 'ready' $false)) {
                $actions += New-SetupAction -Module 'Git' -Id 'ConfigureWindowsGit' -Title '设置 Windows Git 基线' -Type 'WindowsGitConfig' `
                    -Target '%USERPROFILE%\.gitconfig' -Reason 'Windows 原生开发环境使用 Windows Git。'
            }
            else { $skipped += 'Windows Git 基线已符合当前配置' }
        }
    }
    else {
        $distro = [string]$Config.wsl.distribution
        $wslLifecycleState = [string](Get-SetupProperty $Detection.wsl 'state' 'Unknown')
        $wslError = [string](Get-SetupProperty $Detection.wsl 'error' '')
        if ($wslLifecycleState -eq 'Unknown') {
            $detail = if ($wslError) { $wslError } else { '检测未返回可信结果。' }
            $blockingReasons += "无法确认 WSL 生命周期状态：$detail"
        }
        elseif ($wslLifecycleState -eq 'UnsupportedWsl1') {
            $blockingReasons += "$distro 正在使用 WSL1。请迁移或重新安装为 WSL2 后重试。"
        }
        elseif ($wslLifecycleState -eq 'FeatureDisabled') {
            $actions += New-SetupAction -Module 'WSL' -Id 'InstallWslDistribution' -Title "启用 WSL2 并安装 $distro" -Type 'WslInstallDistribution' `
                -Target $distro -Reason '当前 Windows WSL 可选功能尚未启用。' -Critical $true `
                -Parameters @{ distro=$distro }
            $information += '启用 WSL 后按 Windows 提示重启，再继续配置 Linux 工具链。'
        }
        elseif ($wslLifecycleState -in @('NoDistribution', 'TargetMissing', 'Ready')) {
            $wslAllowsHostConfig = $true
            $prepareDependency = @()
            if ([int](Get-SetupProperty $Detection.wsl 'defaultVersion' 0) -ne 2) {
                $actions += New-SetupAction -Module 'WSL' -Id 'SetWsl2Default' -Title '将 WSL2 设为默认版本' -Type 'WslSetDefaultVersion2' `
                    -Target 'WSL' -Reason '新发行版必须使用 WSL2。' -DependsOn $prepareDependency
                $prepareDependency = @('SetWsl2Default')
            }
            if ($wslLifecycleState -in @('NoDistribution', 'TargetMissing')) {
                $actions += New-SetupAction -Module 'WSL' -Id 'InstallWslDistribution' -Title "安装 $distro" -Type 'WslInstallDistribution' `
                    -Target $distro -Reason '当前配置使用此发行版。' -Critical $true -DependsOn $prepareDependency `
                    -Parameters @{ distro=$distro }
                $prepareDependency = @('InstallWslDistribution')
            }
            if ([string](Get-SetupProperty $Detection.wsl 'defaultDistribution' '') -ne $distro) {
                $actions += New-SetupAction -Module 'WSL' -Id 'SetDefaultWslDistribution' -Title "将 $distro 设为默认发行版" -Type 'WslSetDefaultDistribution' `
                    -Target $distro -Reason "让 Codex Desktop 的集成终端默认进入 $distro。" `
                    -DependsOn $prepareDependency -Parameters @{ distro=$distro }
                $prepareDependency = @('SetDefaultWslDistribution')
            }

            if ($wslLifecycleState -eq 'Ready') {
                $wslTools = Get-SetupProperty $Detection 'wslTools'
                $wslReadiness = [string](Get-SetupProperty $wslTools 'readiness' 'Unknown')
                if ($wslReadiness -eq 'NotReady') {
                    $actions += New-SetupAction -Module 'WSL' -Id 'ConfigureWsl' -Title "配置 $distro 开发工具链" -Type 'WslConfigure' `
                        -Target $distro -Reason '安装并配置 Git、Codex CLI、Node.js、pnpm 和 Python。' `
                        -DependsOn $prepareDependency -Parameters @{ distro=$distro }
                }
                elseif ($wslReadiness -eq 'Ready') {
                    $skipped += "$distro 开发工具链已符合当前配置"
                }
                else {
                    $information += '尚未检查 Linux 工具链。'
                    if ([string](Get-SetupProperty $Detection 'detectionMode' '') -eq '完整') {
                        $blockingReasons += '无法确认 Linux 工具链状态。'
                    }
                }
            }
        }
        else {
            $blockingReasons += "WSL 生命周期状态不受支持：$wslLifecycleState。"
        }
    }

    $network = Get-SetupProperty $Config.wsl 'networking'
    $detectedNetwork = Get-SetupProperty $Detection 'wslNetwork' ([pscustomobject]@{})
    if ($mode -eq 'WslFirst' -and $wslAllowsHostConfig -and $null -ne $network -and [bool](Get-SetupProperty $network 'enabled' $false) -and
        [bool](Get-SetupProperty $network 'manageWslConfig' $false)) {
        if ([string]$network.networkingMode -eq 'mirrored' -and [int](Get-SetupProperty $Detection.windows 'build' 0) -lt 22621) {
            $blockingReasons += '当前 Windows 版本不支持 WSL 镜像网络，需要 Windows 11 22H2 或更高版本。'
        }
        elseif ([string](Get-SetupProperty $detectedNetwork 'networkingMode' '') -ne [string]$network.networkingMode -or
            [bool](Get-SetupProperty $detectedNetwork 'dnsTunneling' $false) -ne [bool]$network.dnsTunneling -or
            [bool](Get-SetupProperty $detectedNetwork 'autoProxy' $false) -ne [bool]$network.autoProxy -or
            [bool](Get-SetupProperty $detectedNetwork 'firewall' $false) -ne [bool]$network.firewall) {
            $networkTitle = if ($network.networkingMode -eq 'mirrored') { '配置 WSL 镜像网络' } else { '配置 WSL NAT 网络' }
            $actions += New-SetupAction -Module 'Network' -Id 'ConfigureWslNetwork' -Title $networkTitle `
                -Type 'WslNetworkConfigure' -Target '%USERPROFILE%\.wslconfig' `
                -Reason '同步 Windows WSL 网络设置。'
        }
        else { $skipped += 'WSL 网络设置已符合当前配置' }
    }
    if (-not [bool](Get-SetupProperty (Get-SetupProperty $Detection 'codexConfig') 'ready' $false)) {
        $actions += New-SetupAction -Module 'CodexConfig' -Id 'GlobalCodexConfig' -Title '设置 Windows Codex 用户配置' `
            -Type 'CodexGlobalConfig' -Target '%USERPROFILE%\.codex\config.toml' `
            -Reason '设置 Codex 的文件访问、操作确认和联网策略。' -Critical ($Config.codex.sandboxMode -eq 'danger-full-access')
    }
    else { $skipped += 'Windows Codex 用户配置已符合当前配置' }
    if (-not [bool](Get-SetupProperty (Get-SetupProperty $Detection 'globalAgents') 'ready' $false)) {
        $actions += New-SetupAction -Module 'CodexConfig' -Id 'GlobalAgents' -Title '设置 Windows Codex 全局环境规则' `
            -Type 'GlobalAgents' -Target '%USERPROFILE%\.codex\AGENTS.md' `
            -Reason '统一 Codex Desktop 使用的终端、路径和工具链规则。' -Parameters @{ mode=$mode }
    }
    else { $skipped += 'Windows Codex 全局环境规则已符合当前配置' }

    if ($mode -eq 'WindowsNative' -and $Config.codex.windowsSandbox -ne 'elevated') {
        $warnings += 'Windows 原生开发环境建议将 Windows sandbox 设为 elevated。'
    }
    if ($Config.codex.sandboxMode -eq 'danger-full-access') {
        $warnings += '当前选择的全局高风险权限不受工作区边界限制，只应在完全可信的环境中使用。'
    }

    $projectFailed = @((Get-SetupProperty $Detection 'issues' @()) | Where-Object stage -eq 6).Count -gt 0
    $projectInfo = Get-SetupProperty $Detection 'project'
    $projectLocationCompatible = [bool](Get-SetupProperty $projectInfo 'locationCompatible' $false)
    if ([bool]$Config.projectTemplates.enabled -and -not [string]::IsNullOrWhiteSpace($ProjectPath) -and -not $projectFailed -and $projectLocationCompatible) {
        $actions += New-SetupAction -Module 'Project' -Id 'ProjectTemplates' -Title '写入项目级 Agent 入口' -Type 'ProjectTemplates' `
            -Target $ProjectPath -Reason '根据仓库脚本、锁文件和工具配置生成命令。' `
            -Parameters @{ projectPath=$ProjectPath }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and -not $projectLocationCompatible) {
        $expectedLocation = if ($mode -eq 'WslFirst') { '\\wsl$\{0}\home\<user>\code\...' -f $Config.wsl.distribution } else { 'Windows 本地磁盘路径' }
        $blockingReasons += "项目不在当前环境的项目目录中。请选择 $expectedLocation。"
    }
    elseif ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $skipped += '未选择项目。'
    }

    $recommendation = Get-SetupProperty $Detection 'project' ([pscustomobject]@{ reasons=@() })
    $recommendedMode = [string](Get-SetupProperty $recommendation 'recommendedEnvironmentMode' '')
    if ($recommendedMode -and $recommendedMode -ne $mode) {
        $warnings += '项目技术栈更适合另一种开发环境；请调整环境配置或选择匹配的项目。'
    }

    [pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        healthScore = Get-SetupProperty $Detection 'healthScore' 0
        healthLabel = Get-SetupProperty $Detection 'healthLabel' '未评级'
        detectionMode = Get-SetupProperty $Detection 'detectionMode' '完整'
        environmentMode = $mode
        environmentLabel = $(if ($mode -eq 'WslFirst') { "WSL2 $($Config.wsl.distribution)" } else { 'Windows 原生开发环境' })
        recommendation = $recommendation
        actions = $actions
        warnings = $warnings
        information = $information
        skipped = $skipped
        blockingReasons = @($blockingReasons | Select-Object -Unique)
        afterSetup = @(
            if (@($actions | Where-Object { $_.id -in @('CodexDesktop', 'GlobalCodexConfig', 'GlobalAgents') }).Count -gt 0) {
                (Get-CodexDesktopChecklist -Config $Config).items
            }
            if (@($actions | Where-Object type -eq 'WslInstallDistribution').Count -gt 0) { '安装 WSL 或 Linux 发行版后按 Windows 提示重启。' }
            if (@($actions | Where-Object type -eq 'WslNetworkConfigure').Count -gt 0) { '保存 WSL 工作后运行 wsl --shutdown，再重启 Codex Desktop。' }
        )
    }
}

function Show-CodexSetupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    Write-Host ''
    Write-Host '检查结果与执行计划' -ForegroundColor White
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host "目标环境：$($Plan.environmentLabel)"
    if ($Plan.healthLabel -eq '尚未完整检查') { Write-Host '环境状态：尚未完整检查' }
    else { Write-Host "环境状态：$($Plan.healthLabel)（$($Plan.healthScore)/100）" }
    Write-Host "待执行：$(@($Plan.actions).Count) 项"
    if (@($Plan.blockingReasons).Count -gt 0) {
        Write-SetupSectionHeader -Title '必须先解决' -ForegroundColor Red
        foreach ($reason in $Plan.blockingReasons) {
            Write-SetupWrappedText -Text $reason -FirstIndent '  ! ' -ContinuationIndent '    ' -ForegroundColor Red
        }
    }
    $modules = @(Get-SetupOrderedModules -Actions $Plan.actions)
    for ($moduleIndex = 0; $moduleIndex -lt $modules.Count; $moduleIndex++) {
        $module = $modules[$moduleIndex]
        $groupActions = @($Plan.actions | Where-Object module -eq $module)
        Write-SetupSectionHeader -Title ("工作步骤 {0}/{1} · {2}" -f ($moduleIndex + 1), $modules.Count, (Get-SetupModuleDisplayName $module)) -ForegroundColor Magenta
        foreach ($action in $groupActions) {
            Write-Host "  - $($action.title)" -ForegroundColor $(if ($action.critical) { 'Yellow' } else { 'Gray' })
            if ($action.reason) {
                Write-SetupWrappedText -Text $action.reason -FirstIndent '    ' -ContinuationIndent '    ' -ForegroundColor DarkGray
            }
        }
    }
    if (@($Plan.warnings).Count -gt 0) {
        Write-SetupSectionHeader -Title '需要留意' -ForegroundColor Yellow
        foreach ($warning in $Plan.warnings) {
            Write-SetupWrappedText -Text $warning -FirstIndent '  ! ' -ContinuationIndent '    ' -ForegroundColor Yellow
        }
    }
    if (@($Plan.information).Count -gt 0) {
        Write-SetupSectionHeader -Title '说明' -ForegroundColor Cyan
        foreach ($item in $Plan.information) {
            Write-SetupWrappedText -Text $item -FirstIndent '  - ' -ContinuationIndent '    ' -ForegroundColor Gray
        }
    }
    if (@($Plan.afterSetup).Count -gt 0) {
        Write-SetupSectionHeader -Title '完成设置后' -ForegroundColor Cyan
        foreach ($item in $Plan.afterSetup) {
            Write-SetupWrappedText -Text $item -FirstIndent '  - ' -ContinuationIndent '    ' -ForegroundColor Gray
        }
    }
    if (@($Plan.skipped).Count -gt 0) {
        Write-SetupSectionHeader -Title '无需处理' -ForegroundColor DarkGray
        foreach ($item in $Plan.skipped) { Write-Host "  - $item" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

Export-ModuleMember -Function @('Get-CodexSetupPlan', 'Show-CodexSetupPlan')
