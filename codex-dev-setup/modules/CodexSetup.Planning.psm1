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
    $catalogState = [string](Get-PlanningProperty $Catalog 'state' 'Unknown')
    $packageStates = Get-PlanningProperty $Catalog 'packageStates'
    $key = "$Source|$PackageId"
    $state = Get-PlanningProperty $packageStates $key
    if ($catalogState -ne 'Known' -or $null -eq $state) {
        $catalogError = [string](Get-PlanningProperty $Catalog 'error' '')
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
        [Parameter(Mandatory)][ref]$Warnings,
        [Parameter(Mandatory)][ref]$BlockingReasons,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source,
        [AllowNull()]$Detection,
        [AllowNull()]$Capability,
        [bool]$Critical = $false
    )
    $state = [string](Get-PlanningProperty $Detection 'state' 'Unknown')
    if ($state -notin @('KnownInstalled', 'KnownMissing')) { $state = 'Unknown' }
    $installed = $state -eq 'KnownInstalled' -and [bool](Get-PlanningProperty $Detection 'installed' $false)
    $detectedVersion = [string](Get-PlanningProperty $Detection 'version' '')
    $detectionError = [string](Get-PlanningProperty $Detection 'error' '')
    if (-not $detectionError) { $detectionError = [string](Get-PlanningProperty $Detection 'probeError' '') }
    if ($state -eq 'Unknown' -or (-not $installed -and $detectionError -and $detectionError -ne 'not-required-in-wsl-first')) {
        if (-not $detectionError) { $detectionError = 'Windows 软件包清单状态未知。' }
        $catalogWarning = "无法读取可信的 Windows 软件包清单；状态未知的软件不会自动安装。详情：$detectionError"
        if ($catalogWarning -notin $Warnings.Value) { $Warnings.Value += $catalogWarning }
        $BlockingReasons.Value += "$Title：无法确认精确的软件包状态。"
        return
    }
    if (-not $installed) {
        $Actions.Value += New-SetupAction -Module $Module -Id $Id -Title $Title -Type 'WingetInstall' `
            -Target $PackageId -Reason '当前模式需要此 Windows 组件。' -Critical $Critical `
            -Parameters @{ packageId=$PackageId; source=$Source }
        return
    }
    if ($Config.preferences.updatePolicy -eq 'CheckOnly') {
        $Actions.Value += New-SetupAction -Module 'Updates' -Id "Check$Id" -Title "检查 $($Title -replace '^安装 ', '') 更新" `
            -Type 'WingetUpgradeCheck' -Target $PackageId -Reason '只查询版本，不安装更新。' `
            -Parameters @{ packageId=$PackageId; source=$Source; detectedVersion=$detectedVersion }
    }
    else {
        $Skipped.Value += "$($Title -replace '^安装 ', '') 已安装"
    }
    if ($null -ne $Capability -and -not [bool](Get-PlanningProperty $Capability 'installed' $false)) {
        $Warnings.Value += "$($Title -replace '^安装 ', '') 已登记，但当前会话找不到对应命令。请重新打开终端后复核 PATH；不会因此重复安装。"
        $BlockingReasons.Value += "$($Title -replace '^安装 ', '') 已登记，但所需命令在当前会话不可执行。"
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
    if (-not [bool](Get-PlanningProperty $Detection.windows 'isWindows11' $false)) {
        $warnings += '当前系统不是 Windows 11，自动设置结果不受支持。'
        $blockingReasons += '当前系统不是受支持的 Windows 11。'
    }
    if (-not [bool](Get-PlanningProperty $Detection.windows 'isAdministrator' $false)) {
        $information += '当前是标准权限会话；WSL 和 elevated sandbox 首次设置可能触发 UAC。'
    }
    foreach ($issue in @(Get-PlanningProperty $Detection 'issues' @())) {
        $warnings += "检查未完成（$($issue.name)）：$($issue.error)"
    }

    $windows = $Config.windows
    $windowsPackageCatalog = Get-PlanningProperty $Detection 'windowsPackageCatalog'
    $windowsGitPackageDetection = $null
    if ([bool]$windows.installTerminal) {
        $terminalDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog `
            -PackageId 'Microsoft.WindowsTerminal' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'Core' -Id 'WindowsTerminal' -Title '安装 Windows Terminal' -PackageId 'Microsoft.WindowsTerminal' `
            -Source winget -Detection $terminalDetection -Capability $Detection.windowsTerminal.command
    }
    if ([bool]$windows.installUiGit) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Git.Git' -Source winget
        $windowsGitPackageDetection = $packageDetection
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'Git' -Id 'WindowsGit' -Title '安装 Git for Windows（仅供桌面 UI）' -PackageId 'Git.Git' `
            -Source winget -Detection $packageDetection -Capability $Detection.git
    }
    if ([bool]$windows.installGitHubCli) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'GitHub.cli' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'Git' -Id 'WindowsGitHubCli' -Title '安装 Windows GitHub CLI' -PackageId 'GitHub.cli' `
            -Source winget -Detection $packageDetection -Capability $Detection.githubCli
    }
    if ([bool]$windows.installDesktop) {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId '9PLM9XGG6VKS' -Source msstore
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'CodexDesktop' -Id 'CodexDesktop' -Title '安装 Codex Desktop' -PackageId '9PLM9XGG6VKS' `
            -Source msstore -Detection $packageDetection
    }
    if ([bool]$Config.toolchains.docker.enabled -and [string]$Config.toolchains.docker.provider -eq 'DockerDesktop') {
        $dockerDesktop = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Docker.DockerDesktop' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'Docker' -Id 'DockerDesktop' -Title '安装 Docker Desktop' -PackageId 'Docker.DockerDesktop' `
            -Source winget -Detection $dockerDesktop -Capability $Detection.dockerDesktop
    }

    if ($mode -eq 'WindowsNative') {
        $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'Microsoft.PowerShell' -Source winget
        Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
            -Module 'Core' -Id 'PowerShell7' -Title '安装 PowerShell 7' -PackageId 'Microsoft.PowerShell' -Source winget `
            -Detection $packageDetection -Capability $Detection.powershell7 -Critical $true
        foreach ($package in @(
            @{ Id='Ripgrep'; DetectionName='ripgrep'; Title='安装 Windows ripgrep'; Package='BurntSushi.ripgrep.MSVC' },
            @{ Id='Fd'; DetectionName='fd'; Title='安装 Windows fd'; Package='sharkdp.fd' },
            @{ Id='Jq'; DetectionName='jq'; Title='安装 Windows jq'; Package='jqlang.jq' }
        )) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId $package.Package -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
                -Module 'Core' -Id $package.Id -Title $package.Title -PackageId $package.Package -Source winget `
                -Detection $packageDetection -Capability (Get-PlanningProperty $Detection $package.DetectionName)
        }
        if ([bool]$Config.toolchains.node.enabled) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'OpenJS.NodeJS.LTS' -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
                -Module 'Node' -Id 'NodeLts' -Title '安装 Windows Node.js LTS' -PackageId 'OpenJS.NodeJS.LTS' -Source winget `
                -Detection $packageDetection -Capability (Get-PlanningProperty $Detection 'node')
            $npmDetection = Get-PlanningProperty $Detection 'npm'
            if ($packageDetection.state -eq 'KnownInstalled' -and -not [bool](Get-PlanningProperty $npmDetection 'installed' $false)) {
                $blockingReasons += 'Windows Node.js 包已登记，但 npm 在当前会话不可执行。'
            }
        }
        if ([bool]$Config.toolchains.python.enabled) {
            $packageDetection = Get-PlannedWindowsPackageDetection -Catalog $windowsPackageCatalog -PackageId 'astral-sh.uv' -Source winget
            Add-WindowsPackageAction -Actions ([ref]$actions) -Skipped ([ref]$skipped) -Warnings ([ref]$warnings) -BlockingReasons ([ref]$blockingReasons) -Config $Config `
                -Module 'Python' -Id 'Uv' -Title '安装 Windows uv' -PackageId 'astral-sh.uv' -Source winget `
                -Detection $packageDetection -Capability $Detection.uv
            $pythonDetection = Get-PlanningProperty $Detection 'python'
            if ($packageDetection.state -ne 'Unknown' -and -not [bool](Get-PlanningProperty $pythonDetection 'installed' $false)) {
                $pythonDependencies = $(if (@($actions.id) -contains 'Uv') { @('Uv') } else { @() })
                $actions += New-SetupAction -Module 'Python' -Id 'ConfigurePythonUv' -Title '安装 Windows Python' -Type 'PythonConfigure' `
                    -Target 'uv python install 3.12 --default' -Reason 'Windows 原生开发需要一套由 uv 管理的 Python 3.12。' -DependsOn $pythonDependencies
            }
        }
        if ($null -eq $windowsGitPackageDetection -or $windowsGitPackageDetection.state -eq 'Unknown') {
            $blockingReasons += 'WindowsNative 需要精确确认 Git for Windows 后才能设置 Git 基线。'
        }
        else {
            $gitDependencies = $(if (@($actions.id) -contains 'WindowsGit') { @('WindowsGit') } else { @() })
            $actions += New-SetupAction -Module 'Git' -Id 'ConfigureWindowsGit' -Title '设置 Windows Git 基线' -Type 'WindowsGitConfig' `
                -Target '%USERPROFILE%\.gitconfig' -Reason 'WindowsNative 模式只使用 Windows Git。' -DependsOn $gitDependencies
        }
    }
    else {
        $distro = [string]$Config.wsl.distribution
        $wslLifecycleState = [string](Get-PlanningProperty $Detection.wsl 'state' 'Unknown')
        $wslError = [string](Get-PlanningProperty $Detection.wsl 'error' '')
        if ($wslLifecycleState -eq 'Unknown') {
            $detail = if ($wslError) { $wslError } else { '检测未返回可信结果。' }
            $warnings += "无法确认 WSL 状态：$detail"
            $blockingReasons += "无法确认 WSL 生命周期状态：$detail"
        }
        elseif ($wslLifecycleState -eq 'UnsupportedWsl1') {
            $warnings += "$distro 正在使用 WSL1，当前版本只支持 WSL2。请在仓库工作流之外手动重建 WSL2 发行版后重试。"
            $blockingReasons += "$distro 正在使用不受支持的 WSL1。"
        }
        elseif ($wslLifecycleState -eq 'FeatureDisabled') {
            $actions += New-SetupAction -Module 'WSL' -Id 'InstallWslDistribution' -Title "启用 WSL2 并安装 $distro" -Type 'WslInstallDistribution' `
                -Target $distro -Reason '当前 Windows WSL 可选功能尚未启用。' -Critical $true `
                -Parameters @{ distro=$distro }
            $information += '启用 WSL 后可能需要重启 Windows；重启前不会继续配置 Linux 工具链。'
        }
        elseif ($wslLifecycleState -in @('NoDistribution', 'TargetMissing', 'Ready')) {
            $wslAllowsHostConfig = $true
            $prepareDependency = @()
            if ([bool]$Config.wsl.ensureLatest) {
                $actions += New-SetupAction -Module 'WSL' -Id 'UpdateWsl' -Title '更新 WSL' -Type 'WslUpdate' `
                    -Target 'WSL' -Reason '使用当前 WSL2 运行时与 Linux sandbox 支持。' -DependsOn $prepareDependency
                $prepareDependency = @('UpdateWsl')
            }
            if ([int](Get-PlanningProperty $Detection.wsl 'defaultVersion' 0) -ne 2) {
                $actions += New-SetupAction -Module 'WSL' -Id 'SetWsl2Default' -Title '将 WSL2 设为默认版本' -Type 'WslSetDefaultVersion2' `
                    -Target 'WSL' -Reason '新发行版必须使用 WSL2。' -DependsOn $prepareDependency
                $prepareDependency = @('SetWsl2Default')
            }
            if ($wslLifecycleState -in @('NoDistribution', 'TargetMissing')) {
                $actions += New-SetupAction -Module 'WSL' -Id 'InstallWslDistribution' -Title "安装 $distro" -Type 'WslInstallDistribution' `
                    -Target $distro -Reason 'WslFirst 模式固定使用此发行版。' -Critical $true -DependsOn $prepareDependency `
                    -Parameters @{ distro=$distro }
                $prepareDependency = @('InstallWslDistribution')
            }
            if ([string](Get-PlanningProperty $Detection.wsl 'defaultDistribution' '') -ne $distro) {
                $actions += New-SetupAction -Module 'WSL' -Id 'SetDefaultWslDistribution' -Title "将 $distro 设为默认发行版" -Type 'WslSetDefaultDistribution' `
                    -Target $distro -Reason '确保 Desktop integrated terminal 的 WSL 入口进入唯一开发发行版。' `
                    -DependsOn $prepareDependency -Parameters @{ distro=$distro }
                $prepareDependency = @('SetDefaultWslDistribution')
            }

            if ($wslLifecycleState -eq 'Ready') {
                $wslTools = Get-PlanningProperty $Detection 'wslTools'
                $wslReadiness = [string](Get-PlanningProperty $wslTools 'readiness' 'Unknown')
                if ($wslReadiness -eq 'NotReady') {
                    $actions += New-SetupAction -Module 'WSL' -Id 'ConfigureWsl' -Title "配置 $distro 唯一开发工具链" -Type 'WslConfigure' `
                        -Target $distro -Reason '安装 Linux Git、Codex CLI、pnpm、Node、Python、全局规则与环境验证命令。' `
                        -DependsOn $prepareDependency -Parameters @{ distro=$distro }
                }
                elseif ($wslReadiness -eq 'Ready') {
                    $skipped += "$distro 开发工具链已符合当前配置"
                }
                else {
                    $information += '本次尚未深入检查 Linux 工具链；开始设置前会先执行完整检查，不会根据未知状态重装工具。'
                    if ([string](Get-PlanningProperty $Detection 'detectionMode' '') -eq '完整') {
                        $blockingReasons += '完整检测无法确认 Linux 工具链状态。'
                    }
                }
            }
        }
        else {
            $warnings += "WSL 返回了不受支持的生命周期状态：$wslLifecycleState。"
            $blockingReasons += "WSL 生命周期状态不受支持：$wslLifecycleState。"
        }
    }

    $network = Get-PlanningProperty $Config.wsl 'networking'
    if ($mode -eq 'WslFirst' -and $wslAllowsHostConfig -and $null -ne $network -and [bool](Get-PlanningProperty $network 'enabled' $false) -and
        [bool](Get-PlanningProperty $network 'manageWslConfig' $false)) {
        if ([string]$network.networkingMode -eq 'mirrored' -and [int](Get-PlanningProperty $Detection.windows 'build' 0) -lt 22621) {
            $warnings += 'mirrored networking 需要 Windows 11 22H2 或更高版本。'
            $blockingReasons += '当前 Windows 11 build 不支持所需的 mirrored networking。'
        }
        else {
            $actions += New-SetupAction -Module 'Network' -Id 'ConfigureWslNetwork' -Title "配置 WSL $($network.networkingMode) networking" `
                -Type 'WslNetworkConfigure' -Target '%USERPROFILE%\.wslconfig' `
                -Reason '只管理 Windows WSL 网络设置，不向 Linux shell 注入代理变量。'
        }
    }
    $actions += New-SetupAction -Module 'CodexConfig' -Id 'GlobalCodexConfig' -Title '设置 Windows Codex 用户配置' `
        -Type 'CodexGlobalConfig' -Target '%USERPROFILE%\.codex\config.toml' `
        -Reason '为 Desktop 写入明确的 sandbox、approval 与联网策略。' -Critical ($Config.codex.sandboxMode -eq 'danger-full-access')
    $actions += New-SetupAction -Module 'CodexConfig' -Id 'GlobalAgents' -Title '设置 Windows Codex 全局环境规则' `
        -Type 'GlobalAgents' -Target '%USERPROFILE%\.codex\AGENTS.md' `
        -Reason "使 Desktop 始终遵守 $mode 的 shell、路径和工具链边界。" -Parameters @{ mode=$mode }

    if ($mode -eq 'WindowsNative' -and $Config.codex.windowsSandbox -ne 'elevated') {
        $warnings += 'Windows 原生开发建议使用 elevated sandbox；unelevated 只适合作为受限备用模式。'
    }
    if ($Config.codex.sandboxMode -eq 'danger-full-access') {
        $warnings += '当前选择的全局高风险权限不受工作区边界限制，只应在完全可信的环境中使用。'
    }

    $projectFailed = @((Get-PlanningProperty $Detection 'issues' @()) | Where-Object stage -eq 6).Count -gt 0
    $projectInfo = Get-PlanningProperty $Detection 'project'
    $projectLocationCompatible = [bool](Get-PlanningProperty $projectInfo 'locationCompatible' $false)
    if ([bool]$Config.projectTemplates.enabled -and -not [string]::IsNullOrWhiteSpace($ProjectPath) -and -not $projectFailed -and $projectLocationCompatible) {
        $actions += New-SetupAction -Module 'Project' -Id 'ProjectTemplates' -Title '写入项目级 Agent 入口' -Type 'ProjectTemplates' `
            -Target $ProjectPath -Reason '仅根据仓库已声明的脚本、锁文件和工具配置生成命令，不写项目级个人安全策略。' `
            -Parameters @{ projectPath=$ProjectPath }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and -not $projectLocationCompatible) {
        $expectedLocation = if ($mode -eq 'WslFirst') { '\\wsl$\{0}\home\<user>\code\...' -f $Config.wsl.distribution } else { 'Windows 本地磁盘路径' }
        $warnings += "项目位置与当前开发环境不一致，已禁止写入项目文件。请选择 $expectedLocation。"
        $blockingReasons += '所选项目不在当前环境允许的项目根中。'
    }
    elseif ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $skipped += '未选择项目，不写入项目模板。'
    }

    $recommendation = Get-PlanningProperty $Detection 'project' ([pscustomobject]@{ reasons=@() })
    $recommendedMode = [string](Get-PlanningProperty $recommendation 'recommendedEnvironmentMode' '')
    if ($recommendedMode -and $recommendedMode -ne $mode) {
        $warnings += "项目技术栈更适合另一种开发环境；当前设置不会自动切换，也不会跨环境写入项目。"
    }

    [pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        healthScore = Get-PlanningProperty $Detection 'healthScore' 0
        healthLabel = Get-PlanningProperty $Detection 'healthLabel' '未评级'
        detectionMode = Get-PlanningProperty $Detection 'detectionMode' '完整'
        environmentMode = $mode
        environmentLabel = $(if ($mode -eq 'WslFirst') { "WSL2 $($Config.wsl.distribution)" } else { 'Windows 原生开发环境' })
        recommendation = $recommendation
        actions = $actions
        warnings = $warnings
        information = $information
        skipped = $skipped
        blockingReasons = @($blockingReasons | Select-Object -Unique)
        requiresRestart = @(
            (Get-CodexDesktopChecklist -Config $Config).items
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
    if ($Plan.healthLabel -eq '尚未完整检查') { Write-Host '核心环境：尚未完整检查' }
    else { Write-Host "核心环境：$($Plan.healthLabel)（$($Plan.healthScore)/100）" }
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
    if (@($Plan.requiresRestart).Count -gt 0) {
        Write-SetupSectionHeader -Title '完成设置后' -ForegroundColor Cyan
        foreach ($item in $Plan.requiresRestart) {
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
