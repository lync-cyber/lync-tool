#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('Wizard', 'Detect', 'Plan', 'Apply', 'ProjectInit', 'Export', 'Rollback')]
    [string]$Mode = 'Wizard',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\defaults.json'),
    [string]$ProjectPath,
    [string]$ExportPath,
    [string]$RollbackManifest,
    [switch]$ApplyChanges,
    [switch]$NonInteractive,
    [switch]$DeepDetection,
    [switch]$ForceRefresh,
    [switch]$OpenDesktopSettings,
    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptVersion = '1.0.0'
$script:detectionCache = @{}
$script:detectionCacheLifetime = [TimeSpan]::FromMinutes(5)

if ($Version) {
    Write-Output "CodexDevSetup $scriptVersion"
    exit 0
}

$moduleRoot = Join-Path $PSScriptRoot 'modules'
foreach ($module in @('CodexSetup.Common.psm1', 'CodexSetup.Detection.psm1', 'CodexSetup.Planning.psm1', 'CodexSetup.Actions.psm1', 'CodexSetup.Reporting.psm1')) {
    Import-Module (Join-Path $moduleRoot $module) -Force -ErrorAction Stop
}

function Resolve-SetupConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $config = Read-SetupConfig -Path $resolved
    $config.paths.windowsProjects = [Environment]::ExpandEnvironmentVariables($config.paths.windowsProjects)
    return $config
}

function Show-Banner {
    try { Clear-Host -ErrorAction Stop } catch { }
    Write-Host 'Codex 开发环境助手' -ForegroundColor Cyan
    Write-Host '检查并准备 Windows 开发环境' -ForegroundColor White
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host '先检查，再决定是否设置；不会读取你的密码或密钥，也不会自动移动项目。' -ForegroundColor Yellow
    Write-Host "版本 $scriptVersion" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-MainMenu {
    Write-Host '你想做什么？'
    Write-Host '  [1] 先检查我的电脑（推荐）' -ForegroundColor Green
    Write-Host '      不会改动任何设置，也不会启动 WSL/Linux'
    Write-Host '  [2] 开始设置开发环境'
    Write-Host '      先完整检查，再由你逐项确认要做的改动'
    Write-Host '  [3] 为项目准备基础配置文件'
    Write-Host '      选择一个项目文件夹；已有文件不会被直接覆盖'
    Write-Host '  [4] 导出当前设置到文件'
    Write-Host '      方便在另一台电脑上复用相同选择'
    Write-Host '  [5] 撤销上一次由本工具做出的设置'
    Write-Host '      只恢复本工具创建的备份，不影响你的其他文件'
    Write-Host '  [6] 查看 Codex Desktop 的使用建议'
    Write-Host '      帮你选择 Windows 或 WSL/Linux 工作方式'
    Write-Host '  [7] 深入检查 WSL/Linux 开发环境'
    Write-Host '      不会改动任何设置'
    Write-Host '  [R] 重新检查（忽略刚才的结果）'
    Write-Host '  [0] 退出'
    Write-Host ''
    Write-Host '小提示：不确定时直接按 Enter，先进行安全检查。' -ForegroundColor DarkGray
}

function Open-CodexSettingsGuide {
    Write-Host ''
    Write-Host 'Codex Desktop 使用建议' -ForegroundColor Cyan
    Write-Host '  1. 打开 Settings 后，按项目建议选择 Windows 或 WSL 工作方式；切换后重启 Codex。'
    Write-Host '  2. 终端也选择相同的工作方式：Windows 用 PowerShell，WSL 用 Linux 终端。'
    Write-Host '  3. 默认只允许 Codex 修改当前项目；这是较稳妥的选择。'
    Write-Host '  4. 只有完全信任的个人项目，才考虑开启更高权限。'
    try { Start-Process 'codex://settings' -ErrorAction Stop }
    catch { Write-SetupStatus -Kind Warning -Message '无法自动打开 codex://settings，请在 Codex Desktop 左下角手动打开 Settings。' }
}

function Get-RecentRollbackManifest {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    $runs = Join-Path $base 'CodexDevSetup\runs'
    return Get-ChildItem -LiteralPath $runs -Filter 'rollback-manifest.json' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Get-DetectionCacheKey {
    param(
        [AllowNull()][string]$TargetProject,
        [bool]$DeepDetection
    )
    $normalizedProject = if ([string]::IsNullOrWhiteSpace($TargetProject)) {
        '<none>'
    }
    else {
        try { [System.IO.Path]::GetFullPath($TargetProject).TrimEnd('\').ToLowerInvariant() }
        catch { $TargetProject.Trim().ToLowerInvariant() }
    }
    return "$(if ($DeepDetection) { 'full' } else { 'quick' })|$normalizedProject"
}

function Get-CachedSetupDetection {
    param(
        [AllowNull()][string]$TargetProject,
        [bool]$DeepDetection,
        [bool]$ForceRefresh
    )
    $cacheKey = Get-DetectionCacheKey -TargetProject $TargetProject -DeepDetection:$DeepDetection
    $now = Get-Date
    if (-not $ForceRefresh -and $script:detectionCache.ContainsKey($cacheKey)) {
        $cached = $script:detectionCache[$cacheKey]
        $age = $now - $cached.createdAt
        if ($age -lt $script:detectionCacheLifetime) {
            $ageText = if ($age.TotalMinutes -ge 1) {
                '{0:N1}分钟' -f $age.TotalMinutes
            }
            else {
                '{0:N0}秒' -f [math]::Max(0, $age.TotalSeconds)
            }
            Write-SetupStatus -Kind Info -Message "使用 $ageText 前的检查结果；如需重新检查，可在首页按 R。"
            return $cached.detection
        }
        [void]$script:detectionCache.Remove($cacheKey)
    }

    if ($ForceRefresh) {
        Write-SetupStatus -Kind Info -Message '正在重新检查环境…'
    }
    $detection = Get-CodexSetupDetection -ProjectPath $TargetProject -DeepWsl:$DeepDetection
    $cacheEntry = [pscustomobject]@{
        createdAt = Get-Date
        detection = $detection
    }
    $script:detectionCache[$cacheKey] = $cacheEntry
    # 完整检测已包含快速检测的全部信息，可直接满足同项目的后续快速请求。
    if ($DeepDetection) {
        $quickCacheKey = Get-DetectionCacheKey -TargetProject $TargetProject -DeepDetection:$false
        $script:detectionCache[$quickCacheKey] = $cacheEntry
    }
    return $detection
}

function Get-DisplayProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )
    if ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $DefaultValue
}

function Get-IssueDisplayText {
    param([AllowNull()]$Issue)
    if ($null -eq $Issue) { return $null }
    if ($Issue -is [string]) { return $Issue }
    $errorText = Get-DisplayProperty -InputObject $Issue -Name 'error'
    $issueName = Get-DisplayProperty -InputObject $Issue -Name 'name'
    if (-not [string]::IsNullOrWhiteSpace([string]$errorText)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$issueName)) { return "$issueName：$errorText" }
        return [string]$errorText
    }
    foreach ($name in @('message', 'title', 'name', 'tool', 'code')) {
        $value = Get-DisplayProperty -InputObject $Issue -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return [string]$Issue
}

function Invoke-ReportShortcut {
    param(
        [Parameter(Mandatory)][ValidateSet('Open', 'Folder', 'Copy')][string]$Action,
        [Parameter(Mandatory)][string]$ReportPath
    )
    try {
        switch ($Action) {
            'Open' { Start-Process -FilePath $ReportPath -ErrorAction Stop }
            'Folder' { Start-Process -FilePath (Split-Path -Parent $ReportPath) -ErrorAction Stop }
            'Copy' {
                Set-Clipboard -Value $ReportPath -ErrorAction Stop
                Write-SetupStatus -Kind Success -Message '报告路径已复制到剪贴板。'
            }
        }
    }
    catch {
        Write-SetupStatus -Kind Warning -Message "无法完成报告操作：$($_.Exception.Message)"
    }
}

function Show-WorkflowCompletion {
    param([Parameter(Mandatory)]$WorkflowResult)

    $verificationDetection = Get-DisplayProperty -InputObject $WorkflowResult -Name 'verificationDetection'
    $detection = if ($null -ne $verificationDetection) { $verificationDetection } else { $WorkflowResult.detection }
    $score = [int](Get-DisplayProperty -InputObject $detection -Name 'healthScore' -DefaultValue 0)
    $healthLabel = [string](Get-DisplayProperty -InputObject $detection -Name 'healthLabel')
    if ([string]::IsNullOrWhiteSpace($healthLabel)) {
        $healthLabel = if ($score -ge 90) { '状态良好' } elseif ($score -ge 70) { '基本可用' } elseif ($score -ge 50) { '建议优化' } else { '关键组件缺失' }
    }
    $mode = [string](Get-DisplayProperty -InputObject $detection -Name 'detectionMode' -DefaultValue $(if ($WorkflowResult.deepDetection) { '完整' } else { '快速' }))
    $issues = @(Get-DisplayProperty -InputObject $detection -Name 'issues' -DefaultValue @())
    $pathInfo = Get-DisplayProperty -InputObject $detection -Name 'path'
    $conflicts = @(Get-DisplayProperty -InputObject $pathInfo -Name 'conflicts' -DefaultValue @())
    $actions = @(Get-DisplayProperty -InputObject $WorkflowResult.plan -Name 'actions' -DefaultValue @())
    $remainingPlan = Get-DisplayProperty -InputObject $WorkflowResult -Name 'remainingPlan'
    # Keep the collection shape stable. PowerShell normally unwraps a one-item
    # result from an if-expression, which made the completion page fail when
    # exactly one action remained and the code later read .Count.
    $remainingActions = @(
        if ($null -ne $remainingPlan) {
            Get-DisplayProperty -InputObject $remainingPlan -Name 'actions' -DefaultValue @()
        }
        else {
            $actions
        }
    )
    $resultSummary = Get-CodexSetupResultSummary -Results $WorkflowResult.results
    $missingTools = @($actions | Where-Object {
        (Get-DisplayProperty -InputObject $_ -Name 'type' -DefaultValue '') -eq 'WingetInstall'
    } | ForEach-Object {
        ([string](Get-DisplayProperty -InputObject $_ -Name 'title' -DefaultValue '')) -replace '^安装\s*', ''
    } | Where-Object { $_ } | Select-Object -Unique)

    Write-Host ''
    $completionTitle = if ($WorkflowResult.whatIfRun) { '预览完成' } elseif ($resultSummary.total -eq 0) { '没有可执行的设置' } elseif ($resultSummary.failed -gt 0) { '设置未完全完成' } elseif ($resultSummary.skipped -gt 0) { '设置已结束（部分未执行）' } else { '设置完成' }
    $completionColor = if ($WorkflowResult.whatIfRun) { 'Yellow' } elseif ($resultSummary.failed -gt 0) { 'Red' } elseif ($resultSummary.skipped -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host $completionTitle -ForegroundColor $completionColor
    Write-Host ('─' * 48) -ForegroundColor DarkGray
    Write-Host "核心环境可用性：$healthLabel（$score/100）"
    Write-Host '说明：该分数只反映核心组件是否可用，不代表所有可选设置都已完成。' -ForegroundColor DarkGray
    Write-Host "检查范围：$mode"
    $remainingSetupCount = @($remainingActions | Where-Object {
        (Get-DisplayProperty -InputObject $_ -Name 'type' -DefaultValue '') -notin @('WingetUpgradeCheck', 'AuthGuidance')
    }).Count
    $remainingCheckCount = $remainingActions.Count - $remainingSetupCount
    if ($remainingActions.Count -eq 0) {
        Write-Host '仍可继续处理：无'
    }
    else {
        $visibleActions = @($remainingActions | ForEach-Object { Get-DisplayProperty -InputObject $_ -Name 'title' -DefaultValue $_.id } | Select-Object -First 3)
        Write-Host "仍可继续处理：设置 $remainingSetupCount 项；检查或指引 $remainingCheckCount 项"
        Write-Host "  · $($visibleActions -join '；')" -ForegroundColor DarkGray
        if ($remainingActions.Count -gt 3) { Write-Host "                另有 $($remainingActions.Count - 3) 项，请查看报告" -ForegroundColor DarkGray }
    }
    if ($issues.Count -gt 0) {
        $issueText = @($issues | ForEach-Object { Get-IssueDisplayText $_ } | Where-Object { $_ } | Select-Object -First 3)
        Write-Host "部分检查未完成：$($issueText -join '；')" -ForegroundColor Yellow
    }
    Write-Host "命令来源冲突：$($conflicts.Count) 项"
    if ($WorkflowResult.whatIfRun) {
        Write-Host '系统变更：无（本次只是预览）' -ForegroundColor Yellow
    }
    else {
        Write-Host "本次结果：已完成 $($resultSummary.completed) 项；未完成 $($resultSummary.failed) 项；未执行 $($resultSummary.skipped) 项" -ForegroundColor $completionColor
        if ($null -ne $verificationDetection) {
            Write-Host '已完成快速复核；已完成项目不会重复列为待设置。' -ForegroundColor DarkCyan
        }
    }
    Write-Host "报告：$($WorkflowResult.reportPath)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '接下来' -ForegroundColor Cyan
    if ($WorkflowResult.whatIfRun) {
        Write-Host '  1. 本次只是预览，没有修改电脑。'
        Write-Host '  2. 返回首页选择“开始设置开发环境”，再按提示确认需要的项目。'
    }
    elseif ($resultSummary.failed -gt 0) {
        Write-Host '  1. 先查看详细结果中的“未完成”项目。' -ForegroundColor Yellow
        Write-Host '  2. 处理提示的问题后，再次选择“开始设置开发环境”；工具会重新检查当前状态。'
    }
    elseif ($resultSummary.skipped -gt 0) {
        Write-Host '  1. 本次有项目未执行；当前环境可能尚未完整准备。' -ForegroundColor Yellow
        Write-Host '  2. 查看详细结果，确认是否需要返回首页继续设置。'
    }
    elseif ($resultSummary.total -eq 0) {
        Write-Host '  本次没有可执行项目；请查看上方提示或详细结果。' -ForegroundColor Yellow
    }
    else {
        $recommendedAgent = [string](Get-DisplayProperty -InputObject $WorkflowResult.plan.recommendation -Name 'agent' -DefaultValue 'WSL')
        Write-Host '  1. 关闭并重新打开 Windows Terminal 和 Codex Desktop，让新设置生效。'
        if ($recommendedAgent -eq 'WindowsNative') {
            Write-Host '  2. 在 Codex Desktop Settings 中选择 Windows 工作方式和 PowerShell 终端。'
            Write-Host '  3. 打开 Windows Terminal 的“Codex Windows (PowerShell 7)”，逐行运行：'
            Write-Host '       git --version    node --version    python --version' -ForegroundColor DarkCyan
            Write-Host '  4. 在 Windows 的 source 文件夹中新建或打开项目，然后交给 Codex。'
        }
        else {
            Write-Host '  2. 在 Codex Desktop Settings 中选择 WSL/Linux 工作方式和 WSL/Linux 终端。'
            Write-Host '  3. 打开 Windows Terminal 的“Codex WSL (Ubuntu)”，逐行运行：'
            Write-Host '       git --version    node --version    python3 --version' -ForegroundColor DarkCyan
            Write-Host '  4. 在 Linux 的 ~/code 文件夹中新建或打开项目，然后交给 Codex。'
        }
        Write-Host '     三条命令都显示版本号，即表示主要开发环境可用。' -ForegroundColor DarkGray
        Write-Host '     如需使用 GitHub：运行 gh auth status；尚未登录时运行 gh auth login。' -ForegroundColor DarkGray
    }

    while ($true) {
        Write-Host ''
        Write-Host '[R] 查看详细结果  [L] 打开结果所在目录  [C] 复制结果路径  [Enter] 返回首页'
        $choice = (Read-Host '请选择').Trim().ToUpperInvariant()
        switch ($choice) {
            '' { return }
            'R' { Invoke-ReportShortcut -Action Open -ReportPath $WorkflowResult.reportPath }
            'L' { Invoke-ReportShortcut -Action Folder -ReportPath $WorkflowResult.reportPath }
            'C' { Invoke-ReportShortcut -Action Copy -ReportPath $WorkflowResult.reportPath }
            default { Write-SetupStatus -Kind Warning -Message "无效选项：$choice" }
        }
    }
}

function Invoke-Workflow {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('Detect', 'Plan', 'Apply', 'ProjectInit')][string]$WorkflowMode,
        [AllowNull()][string]$TargetProject,
        [bool]$RealApply,
        [bool]$DeepDetection = $false,
        [bool]$ForceRefresh = $false
    )
    $runtime = Initialize-SetupRuntime
    $succeeded = $false
    try {
        $detection = Get-CachedSetupDetection -TargetProject $TargetProject -DeepDetection:$DeepDetection -ForceRefresh:$ForceRefresh
        $plan = Get-CodexSetupPlan -Detection $detection -Config $Config -ProjectPath $TargetProject
        if ($WorkflowMode -eq 'ProjectInit') {
            $plan.actions = @($plan.actions | Where-Object module -eq 'Project')
        }
        Show-CodexSetupPlan -Plan $plan
        $results = @()
        $verificationDetection = $null
        $remainingPlan = $null
        $effectiveWhatIf = -not $RealApply -or [bool]$WhatIfPreference
        if ($WorkflowMode -in @('Plan', 'Apply', 'ProjectInit')) {
            if ($effectiveWhatIf) {
                Write-SetupStatus -Kind Info -Message '当前是预览：不会安装软件，也不会修改系统或项目文件。'
                $results = @(Invoke-CodexSetupPlan -Plan $plan -Config $Config -NonInteractive:$NonInteractive -WhatIf -InformationAction SilentlyContinue)
            }
            else {
                if ($Config.codex.sandboxMode -eq 'danger-full-access') {
                    Write-SetupStatus -Kind Warning -Message '将写入 danger-full-access 配置。只应对可信个人项目启用。'
                }
                $results = @(Invoke-CodexSetupPlan -Plan $plan -Config $Config -NonInteractive:$NonInteractive -ConfirmModules:([bool]$Config.preferences.moduleConfirmation) -Confirm:$false)
            }
        }
        if (-not $effectiveWhatIf -and @($results | Where-Object {
            (Get-DisplayProperty -InputObject $_ -Name 'status' -DefaultValue '') -in @('Completed', 'Applied', 'Changed', 'Success')
        }).Count -gt 0) {
            Write-SetupStatus -Kind Info -Message '正在快速复核本次已完成的设置…'
            # 复核 Windows 侧核心工具即可；不重复启动 WSL，已完成的操作会从待设置列表排除。
            $verificationDetection = Get-CachedSetupDetection -TargetProject $TargetProject -DeepDetection:$false -ForceRefresh:$true
            $remainingPlan = Get-CodexSetupPlan -Detection $verificationDetection -Config $Config -ProjectPath $TargetProject
            $originalActionIds = @($plan.actions | ForEach-Object { Get-DisplayProperty -InputObject $_ -Name 'id' } | Where-Object { $_ } | Select-Object -Unique)
            $completedIds = @($results | Where-Object {
                (Get-DisplayProperty -InputObject $_ -Name 'status' -DefaultValue '') -in @('Completed', 'Applied', 'Changed', 'Success')
            } | ForEach-Object { Get-DisplayProperty -InputObject $_ -Name 'id' } | Where-Object { $_ } | Select-Object -Unique)
            # A quick verification does not inspect the WSL toolchain. Restrict
            # remaining work to the original plan so missing detail cannot
            # invent a new WSL action after a successful full detection.
            $remainingPlan.actions = @($remainingPlan.actions | Where-Object {
                $_.id -in $originalActionIds -and $_.id -notin $completedIds
            })
        }
        $reportPath = New-CodexSetupReport -Detection $detection -Plan $plan -Results $results -Config $Config -WhatIfRun:$effectiveWhatIf `
            -RemainingPlan $remainingPlan -VerificationDetection $verificationDetection
        Write-SetupStatus -Kind Success -Message "报告已生成：$reportPath"
        if (-not $effectiveWhatIf) {
            # 写入后的环境可能已变化，旧检测结果不应继续供下一次操作复用。
            $script:detectionCache.Clear()
        }
        $succeeded = $true
        if ($OpenDesktopSettings -and -not $NonInteractive) { Open-CodexSettingsGuide }
        return [pscustomobject]@{
            runtime=$runtime
            detection=$detection
            plan=$plan
            results=$results
            reportPath=$reportPath
            whatIfRun=$effectiveWhatIf
            deepDetection=$DeepDetection
            remainingPlan=$remainingPlan
            verificationDetection=$verificationDetection
        }
    }
    finally {
        Complete-SetupRuntime -Succeeded:$succeeded
    }
}

try {
    $config = Resolve-SetupConfiguration -Path $ConfigPath
    if ([string]::IsNullOrWhiteSpace($ProjectPath) -and -not [string]::IsNullOrWhiteSpace($config.paths.projectPath)) {
        $ProjectPath = [Environment]::ExpandEnvironmentVariables($config.paths.projectPath)
    }

    if ($Mode -eq 'Wizard') {
        if ($NonInteractive) { throw 'Wizard 模式需要交互；无人值守时请使用 -Mode Plan/Apply/Detect。' }
        while ($true) {
            Show-Banner
            Show-MainMenu
            $selection = Read-Host '输入编号（直接按 Enter 先检查）'
            if ([string]::IsNullOrWhiteSpace($selection)) { $selection = '1' }
            $selection = $selection.Trim().ToUpperInvariant()
            $completionShown = $false
            switch ($selection) {
                '0' { return }
                '1' {
                    $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Plan -TargetProject $ProjectPath -RealApply:$false -DeepDetection:$false
                    Show-WorkflowCompletion -WorkflowResult $workflowResult
                    $completionShown = $true
                }
                '2' {
                    $confirmed = Confirm-SetupChoice -Prompt '开始设置吗？接下来会按功能逐项请你确认' -DefaultYes:$false
                    if ($confirmed) {
                        $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Apply -TargetProject $ProjectPath -RealApply:$true -DeepDetection:$true
                        Show-WorkflowCompletion -WorkflowResult $workflowResult
                        $completionShown = $true
                    }
                    else { Write-SetupStatus -Kind Info -Message '已取消，未修改系统。' }
                }
                '3' {
                    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $ProjectPath = Read-Host '请输入项目文件夹的完整路径' }
                    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { throw '项目路径不能为空。' }
                    $confirmed = Confirm-SetupChoice -Prompt '现在写入基础配置文件吗？已有文件会逐个请你确认' -DefaultYes:$false
                    if (-not $confirmed) {
                        Write-SetupStatus -Kind Info -Message '已取消；没有检查或写入项目文件。'
                        continue
                    }
                    $workflowResult = Invoke-Workflow -Config $config -WorkflowMode ProjectInit -TargetProject $ProjectPath -RealApply:$confirmed -DeepDetection:$confirmed
                    Show-WorkflowCompletion -WorkflowResult $workflowResult
                    $completionShown = $true
                }
                '4' {
                    if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = Join-Path (Get-Location) 'codex-setup.export.json' }
                    Export-SetupConfig -Config $config -Path $ExportPath -Confirm:$false
                    Write-SetupStatus -Kind Success -Message "配置已导出：$ExportPath"
                }
                '5' {
                    if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { $RollbackManifest = Get-RecentRollbackManifest }
                    if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { throw '没有找到可回滚的运行清单。' }
                    Invoke-CodexSetupRollback -ManifestPath $RollbackManifest
                }
                '6' { Open-CodexSettingsGuide }
                '7' {
                    $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Plan -TargetProject $ProjectPath -RealApply:$false -DeepDetection:$true
                    Show-WorkflowCompletion -WorkflowResult $workflowResult
                    $completionShown = $true
                }
                'R' {
                    $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Detect -TargetProject $ProjectPath -RealApply:$false -DeepDetection:$false -ForceRefresh:$true
                    Show-WorkflowCompletion -WorkflowResult $workflowResult
                    $completionShown = $true
                }
                default {
                    Write-SetupStatus -Kind Warning -Message "无效选项：$selection"
                }
            }
            if (-not $completionShown) {
                Write-Host ''
                [void](Read-Host '操作结束。按 Enter 返回主菜单')
            }
        }
    }

    switch ($Mode) {
        'Detect' {
            Invoke-Workflow -Config $config -WorkflowMode Detect -TargetProject $ProjectPath -RealApply:$false `
                -DeepDetection:([bool]$DeepDetection) -ForceRefresh:([bool]$ForceRefresh) | Out-Null
        }
        'Plan' {
            Invoke-Workflow -Config $config -WorkflowMode Plan -TargetProject $ProjectPath -RealApply:$false `
                -DeepDetection:([bool]$DeepDetection) -ForceRefresh:([bool]$ForceRefresh) | Out-Null
        }
        'Apply' {
            if (-not $ApplyChanges) { Write-SetupStatus -Kind Info -Message '未提供 -ApplyChanges，本次只预览将要进行的设置。' }
            Invoke-Workflow -Config $config -WorkflowMode Apply -TargetProject $ProjectPath -RealApply:([bool]$ApplyChanges) `
                -DeepDetection:$true -ForceRefresh:([bool]$ForceRefresh) | Out-Null
        }
        'ProjectInit' {
            if ([string]::IsNullOrWhiteSpace($ProjectPath)) { throw 'ProjectInit 需要 -ProjectPath。' }
            Invoke-Workflow -Config $config -WorkflowMode ProjectInit -TargetProject $ProjectPath -RealApply:([bool]$ApplyChanges) `
                -DeepDetection:([bool]($DeepDetection -or $ApplyChanges)) -ForceRefresh:([bool]$ForceRefresh) | Out-Null
        }
        'Export' {
            if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = Join-Path (Get-Location) 'codex-setup.export.json' }
            Export-SetupConfig -Config $config -Path $ExportPath -WhatIf:$WhatIfPreference -Confirm:$false
            Write-SetupStatus -Kind Success -Message "配置导出目标：$ExportPath"
        }
        'Rollback' {
            if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { $RollbackManifest = Get-RecentRollbackManifest }
            if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { throw '没有找到可回滚的运行清单。' }
            Invoke-CodexSetupRollback -ManifestPath $RollbackManifest -NonInteractive:$NonInteractive -WhatIf:(-not $ApplyChanges -or [bool]$WhatIfPreference)
        }
    }
}
catch {
    $message = ConvertTo-RedactedText $_.Exception.Message
    Write-Host "[错误] $message" -ForegroundColor Red
    Write-SetupLog -Level Error -Message $message -Data @{ stack=$_.ScriptStackTrace }
    exit 1
}
