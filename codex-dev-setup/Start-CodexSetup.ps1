#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('Wizard', 'Detect', 'Plan', 'Apply', 'ProjectInit', 'Export', 'Rollback')]
    [string]$Mode = 'Wizard',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\defaults.json'),
    [string]$Distribution,
    [string]$ProjectPath,
    [string]$ExportPath,
    [string]$ResultJsonPath,
    [string]$RollbackManifest,
    [switch]$AllowIncompleteRollback,
    [switch]$ApplyChanges,
    [switch]$NonInteractive,
    [switch]$DeepDetection,
    [switch]$ForceRefresh,
    [switch]$OpenDesktopSettings,
    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$isDotSourced = $MyInvocation.InvocationName -eq '.'
$modeWasExplicit = $PSBoundParameters.ContainsKey('Mode')
$scriptVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw -Encoding utf8).Trim()
if ([string]::IsNullOrWhiteSpace($scriptVersion)) { throw 'VERSION 文件不能为空。' }
$script:detectionCache = @{}
$script:detectionCacheLifetime = [TimeSpan]::FromMinutes(5)

function Write-SetupResultJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temporary = Join-Path $parent ('.{0}.{1}.tmp' -f (Split-Path -Leaf $resolved), [guid]::NewGuid().ToString('N'))
    try {
        $json = $Value | ConvertTo-Json -Depth 30
        $safeJson = ConvertTo-RedactedText $json
        [System.IO.File]::WriteAllText($temporary, $safeJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $resolved -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $resolved
}

if ($Version) {
    Write-Output "CodexDevSetup $scriptVersion"
    if (-not $isDotSourced) { exit 0 }
    return
}

$moduleRoot = Join-Path $PSScriptRoot 'modules'
foreach ($module in @('CodexSetup.Common.psm1', 'CodexSetup.Detection.psm1', 'CodexSetup.Planning.psm1', 'CodexSetup.Actions.psm1', 'CodexSetup.Reporting.psm1')) {
    Import-Module (Join-Path $moduleRoot $module) -Force -ErrorAction Stop
}

function Resolve-SetupConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $config = Read-SetupConfig -Path $resolved
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $config.wsl.distribution = $Distribution
        [void](Assert-SetupConfiguration -Config $config)
    }
    $config.paths.windowsProjects = [Environment]::ExpandEnvironmentVariables($config.paths.windowsProjects)
    return $config
}

function Show-Banner {
    param([Parameter(Mandatory)]$Config)
    try { Clear-Host -ErrorAction Stop } catch { }
    Write-Host 'Codex 开发环境助手' -ForegroundColor Cyan
    $distributionText = switch ($Config.wsl.distribution) {
        'latest-stable' { 'Ubuntu 最新稳定版（按 WSL 安装目录选择）' }
        'latest-lts' { 'Ubuntu 最新 LTS（按 WSL 安装目录选择）' }
        default { $Config.wsl.distribution }
    }
    $modeText = if ($Config.environmentMode -eq 'WslFirst') { "WSL2 $distributionText" } else { 'Windows 原生开发环境' }
    Write-Host "目标环境：$modeText  ·  v$scriptVersion" -ForegroundColor White
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host ''
}

function Show-MainMenu {
    param([Parameter(Mandatory)]$Config)
    Write-Host '请选择操作'
    Write-Host '  [1/Enter] 开始或修复（推荐）' -ForegroundColor Green
    Write-Host '      检查 → 确认变更 → 设置 → 验证；已完成的步骤自动跳过'
    Write-Host '  [2] 仅检查'
    Write-Host '      完整检查并给出建议，不应用设置'
    Write-Host '  [3] 初始化项目配置'
    Write-Host '      为指定项目生成基础配置'
    Write-Host '  [M] 更多：导出设置、撤销更改、Desktop 指南'
    Write-Host '  [0] 退出'
}

function Open-CodexSettingsGuide {
    param([Parameter(Mandatory)]$Config)
    Write-Host ''
    Write-Host 'Codex Desktop 设置清单' -ForegroundColor Cyan
    $checklist = Get-CodexDesktopChecklist -Config $Config
    $index = 1
    foreach ($item in $checklist.items) { Write-Host "  $index. $item"; $index++ }
    try { Start-Process 'codex://settings' -ErrorAction Stop }
    catch { Write-SetupStatus -Kind Warning -Message '无法自动打开 Codex 设置。请在 Codex Desktop 左下角打开“设置”。' }
}

function Get-RecentRollbackManifest {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
    $runs = Join-Path $base 'CodexDevSetup\runs'
    $candidates = @(Get-ChildItem -LiteralPath $runs -Filter 'rollback-manifest.json' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        try {
            $manifest = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop
            Assert-RollbackManifestAuthentication -Path $candidate.FullName -Manifest $manifest
        }
        catch { continue }
        if ($manifest.schemaVersion -eq 3 -and $manifest.completed -eq $true -and $manifest.hasChanges -eq $true -and
            [int]$manifest.changeCount -gt 0 -and [string]::IsNullOrWhiteSpace([string]$manifest.rolledBackAt)) {
            return $candidate.FullName
        }
        if ($manifest.schemaVersion -eq 3 -and $manifest.hasChanges -eq $true -and -not $manifest.completed -and
            [string]::IsNullOrWhiteSpace([string]$manifest.rolledBackAt)) {
            throw "最近一次更改尚未完整结束，不能自动跳过它撤销更早的运行。请先检查清单：$($candidate.FullName)；确认范围后使用 -Mode Rollback -RollbackManifest <清单路径> -AllowIncompleteRollback。"
        }
    }
    return $null
}

function Get-DetectionCacheKey {
    param(
        [AllowNull()][string]$TargetProject,
        [bool]$DeepDetection,
        [Parameter(Mandatory)]$Config
    )
    $normalizedProject = if ([string]::IsNullOrWhiteSpace($TargetProject)) {
        '<none>'
    }
    else {
        try { [System.IO.Path]::GetFullPath($TargetProject).TrimEnd('\').ToLowerInvariant() }
        catch { $TargetProject.Trim().ToLowerInvariant() }
    }
    $configJson = $Config | ConvertTo-Json -Depth 20 -Compress
    $configHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($configJson))
    ).Substring(0, 16)
    return "$(if ($DeepDetection) { 'full' } else { 'quick' })|$normalizedProject|$configHash"
}

function Get-CachedSetupDetection {
    param(
        [AllowNull()][string]$TargetProject,
        [bool]$DeepDetection,
        [bool]$ForceRefresh,
        [Parameter(Mandatory)]$Config
    )
    $cacheKey = Get-DetectionCacheKey -TargetProject $TargetProject -DeepDetection:$DeepDetection -Config $Config
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
            Write-SetupStatus -Kind Info -Message "使用 $ageText 前的检查结果；如需重新检查，可在结果页按 R。"
            return $cached.detection
        }
        [void]$script:detectionCache.Remove($cacheKey)
    }

    $detection = Get-CodexSetupDetection -ProjectPath $TargetProject -DeepWsl:$DeepDetection -Config $Config
    $cacheEntry = [pscustomobject]@{
        createdAt = Get-Date
        detection = $detection
    }
    $script:detectionCache[$cacheKey] = $cacheEntry
    if ($DeepDetection) {
        $quickCacheKey = Get-DetectionCacheKey -TargetProject $TargetProject -DeepDetection:$false -Config $Config
        $script:detectionCache[$quickCacheKey] = $cacheEntry
    }
    return $detection
}

function Get-IssueDisplayText {
    param([AllowNull()]$Issue)
    if ($null -eq $Issue) { return $null }
    if ($Issue -is [string]) { return $Issue }
    $errorText = Get-SetupProperty -InputObject $Issue -Name 'error'
    $issueName = Get-SetupProperty -InputObject $Issue -Name 'name'
    if (-not [string]::IsNullOrWhiteSpace([string]$errorText)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$issueName)) { return "$issueName：$errorText" }
        return [string]$errorText
    }
    foreach ($name in @('message', 'title', 'name', 'tool', 'code')) {
        $value = Get-SetupProperty -InputObject $Issue -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return [string]$Issue
}

function Get-RemainingSetupPlan {
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowNull()]$Results
    )
    $completedIds = @($Results | Where-Object {
        (Get-SetupProperty -InputObject $_ -Name 'status' -Default '') -in @('Changed', 'NoChange')
    } | ForEach-Object {
        Get-SetupProperty -InputObject $_ -Name 'id' -Default ''
    } | Where-Object { $_ } | Select-Object -Unique)
    $remaining = $Plan.PSObject.Copy()
    $remaining.actions = @($Plan.actions | Where-Object { $_.id -notin $completedIds })
    return $remaining
}

function New-WorkflowMachineResult {
    param(
        [Parameter(Mandatory)]$WorkflowResult,
        [Parameter(Mandatory)][string]$InvocationMode,
        [Parameter(Mandatory)][bool]$RequestedApply
    )
    $summary = Get-CodexSetupResultSummary -Results $WorkflowResult.results
    $remainingActions = @(
        if ($null -ne $WorkflowResult.remainingPlan) {
            Get-SetupProperty -InputObject $WorkflowResult.remainingPlan -Name 'actions' -Default @()
        }
    )
    $completionPlan = if ($null -ne $WorkflowResult.remainingPlan) { $WorkflowResult.remainingPlan } else { $WorkflowResult.plan }
    $blockingReasons = @(Get-SetupProperty -InputObject $completionPlan -Name 'blockingReasons' -Default @())
    $warnings = @(Get-SetupProperty -InputObject $completionPlan -Name 'warnings' -Default @())
    $issues = @(Get-SetupProperty -InputObject $WorkflowResult.detection -Name 'issues' -Default @())
    $exitCode = if ($summary.failed -gt 0 -or $summary.unknown -gt 0) {
        1
    }
    elseif ($blockingReasons.Count -gt 0) {
        20
    }
    elseif ($summary.restartRequired -gt 0) {
        10
    }
    elseif ($summary.needsAttention -gt 0 -or $summary.skipped -gt 0 -or $remainingActions.Count -gt 0 -or
        ($RequestedApply -and $issues.Count -gt 0)) {
        20
    }
    else { 0 }
    $status = switch ($exitCode) {
        0 { if ($WorkflowResult.whatIfRun) { 'Preview' } else { 'Succeeded' }; break }
        10 { 'RestartRequired'; break }
        20 { 'NeedsAttention'; break }
        default { 'Failed' }
    }
    [ordered]@{
        schemaVersion = 2
        generatedAt = (Get-Date).ToString('o')
        runId = [string]$WorkflowResult.runtime.RunId
        mode = $InvocationMode
        environmentMode = [string]$WorkflowResult.config.environmentMode
        requestedApply = $RequestedApply
        whatIf = [bool]$WorkflowResult.whatIfRun
        status = $status
        exitCode = $exitCode
        reportPath = [string]$WorkflowResult.reportPath
        logPath = [string]$WorkflowResult.runtime.LogPath
        manifestPath = [string]$WorkflowResult.runtime.ManifestPath
        summary = [ordered]@{
            total = $summary.total
            changed = $summary.changed
            noChange = $summary.noChange
            needsAttention = $summary.needsAttention
            restartRequired = $summary.restartRequired
            failed = $summary.failed
            skipped = $summary.skipped
            preview = $summary.preview
            unknown = $summary.unknown
        }
        detection = $WorkflowResult.detection
        plan = $WorkflowResult.plan
        results = @($WorkflowResult.results)
        remainingPlan = $WorkflowResult.remainingPlan
        blockingReasons = @($blockingReasons)
        remainingActions = @($remainingActions | ForEach-Object {
            [ordered]@{
                id = [string](Get-SetupProperty -InputObject $_ -Name 'id' -Default '')
                type = [string](Get-SetupProperty -InputObject $_ -Name 'type' -Default '')
                target = [string](Get-SetupProperty -InputObject $_ -Name 'target' -Default '')
            }
        })
        issues = @($issues | ForEach-Object {
            [ordered]@{
                name = [string](Get-SetupProperty -InputObject $_ -Name 'name' -Default '检测')
                error = [string](Get-SetupProperty -InputObject $_ -Name 'error' -Default '')
            }
        })
        desktopEvidenceRequired = $true
    }
}

function Test-SetupProcessExitRequired {
    param(
        [Parameter(Mandatory)][string]$InvocationMode,
        [Parameter(Mandatory)][bool]$WasModeExplicit,
        [Parameter(Mandatory)][bool]$WasDotSourced,
        [Parameter(Mandatory)][bool]$IsNonInteractive,
        [AllowNull()][string]$MachineResultPath
    )
    if ($WasDotSourced -or $InvocationMode -notin @('Detect', 'Plan', 'Apply', 'ProjectInit', 'Rollback')) {
        return $false
    }
    return $IsNonInteractive -or $WasModeExplicit -or -not [string]::IsNullOrWhiteSpace($MachineResultPath)
}

function Open-SetupReport {
    param([Parameter(Mandatory)][string]$ReportPath)
    try { Start-Process -FilePath $ReportPath -ErrorAction Stop }
    catch { Write-SetupStatus -Kind Warning -Message "无法打开报告：$($_.Exception.Message)" }
}

function Show-WorkflowCompletion {
    param([Parameter(Mandatory)]$WorkflowResult)

    $workflowConfig = Get-SetupProperty -InputObject $WorkflowResult -Name 'config'
    $detection = $WorkflowResult.detection
    $healthLabel = [string](Get-SetupProperty -InputObject $detection -Name 'healthLabel' -Default '未评级')
    $mode = [string](Get-SetupProperty -InputObject $detection -Name 'detectionMode' -Default $(if ($WorkflowResult.deepDetection) { '完整' } else { '快速' }))
    $issues = @(Get-SetupProperty -InputObject $detection -Name 'issues' -Default @())
    $pathInfo = Get-SetupProperty -InputObject $detection -Name 'path'
    $wslToolInfo = Get-SetupProperty -InputObject $detection -Name 'wslTools'
    $conflicts = @(
        if ($workflowConfig.environmentMode -eq 'WslFirst') {
            Get-SetupProperty -InputObject $wslToolInfo -Name 'nonNativeCommands' -Default @()
        }
        else {
            Get-SetupProperty -InputObject $pathInfo -Name 'conflicts' -Default @()
        }
    )
    $actions = @(Get-SetupProperty -InputObject $WorkflowResult.plan -Name 'actions' -Default @())
    $remainingPlan = Get-SetupProperty -InputObject $WorkflowResult -Name 'remainingPlan'
    $completionPlan = if ($null -ne $remainingPlan) { $remainingPlan } else { $WorkflowResult.plan }
    $blockingReasons = @(Get-SetupProperty -InputObject $completionPlan -Name 'blockingReasons' -Default @())
    $warnings = @(Get-SetupProperty -InputObject $completionPlan -Name 'warnings' -Default @())
    $remainingActions = @(
        if ($null -ne $remainingPlan) {
            Get-SetupProperty -InputObject $remainingPlan -Name 'actions' -Default @()
        }
        else {
            $actions
        }
    )
    $resultSummary = Get-CodexSetupResultSummary -Results $WorkflowResult.results
    $remainingSetupCount = $remainingActions.Count

    Write-Host ''
    $isProjectWorkflow = (Get-SetupProperty -InputObject $WorkflowResult -Name 'workflowMode' -Default '') -eq 'ProjectInit'
    $completionTitle = if ($WorkflowResult.whatIfRun -and $blockingReasons.Count -eq 0) { '预览完成' } elseif ($resultSummary.failed -gt 0) { '操作未完全完成' } elseif ($blockingReasons.Count -gt 0) { '操作已结束，仍有待处理项' } elseif ($resultSummary.restartRequired -gt 0) { '需要重启后继续' } elseif ($resultSummary.needsAttention -gt 0 -or $resultSummary.skipped -gt 0 -or $remainingSetupCount -gt 0) { '操作已结束，仍有待处理项' } elseif ($resultSummary.total -eq 0) { '没有需要执行的操作' } else { '设置完成' }
    if ($WorkflowResult.whatIfRun -and $WorkflowResult.workflowMode -eq 'Detect') { $completionTitle = '检查完成，未应用设置' }
    if ($resultSummary.total -gt 0 -and $resultSummary.skipped -eq $resultSummary.total) { $completionTitle = '已跳过，未应用设置' }
    if ($resultSummary.restartRequired -gt 0) { $completionTitle = '需要重启后继续' }
    $completionColor = if ($resultSummary.failed -gt 0) { 'Red' } elseif ($WorkflowResult.whatIfRun -or $blockingReasons.Count -gt 0 -or $resultSummary.restartRequired -gt 0 -or $resultSummary.needsAttention -gt 0 -or $resultSummary.skipped -gt 0 -or $remainingSetupCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host $completionTitle -ForegroundColor $completionColor
    Write-Host ('─' * 48) -ForegroundColor DarkGray
    Write-Host "检查状态：$healthLabel"
    Write-Host "检查范围：$mode"
    if ($remainingActions.Count -gt 0) {
        $visibleActions = @($remainingActions | ForEach-Object { Get-SetupProperty -InputObject $_ -Name 'title' -Default $_.id } | Select-Object -First 3)
        Write-Host "待处理：$remainingSetupCount 项"
        Write-Host "  · $($visibleActions -join '；')" -ForegroundColor DarkGray
        if ($remainingActions.Count -gt 3) { Write-Host "                另有 $($remainingActions.Count - 3) 项，请查看报告" -ForegroundColor DarkGray }
    }
    if ($issues.Count -gt 0 -and $blockingReasons.Count -eq 0 -and $warnings.Count -eq 0) {
        $issueText = @($issues | ForEach-Object { Get-IssueDisplayText $_ } | Where-Object { $_ } | Select-Object -First 3)
        Write-Host "部分检查未完成：$($issueText -join '；')" -ForegroundColor Yellow
    }
    if ($blockingReasons.Count -gt 0) {
        Write-Host "需要先处理：$(@($blockingReasons | Select-Object -First 3) -join '；')" -ForegroundColor Yellow
    }
    if ($conflicts.Count -gt 0) { Write-Host "命令冲突：$($conflicts.Count) 项" }
    if ($WorkflowResult.whatIfRun) {
        Write-Host '预览状态：执行计划已生成' -ForegroundColor Yellow
    }
    else {
        $summaryText = Get-CodexSetupResultSummaryText -Summary $resultSummary
        if ($summaryText) { Write-Host "本次结果：$summaryText" -ForegroundColor $completionColor }
    }
    Write-Host "报告：$($WorkflowResult.reportPath)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '接下来' -ForegroundColor Cyan
    if ($isProjectWorkflow -and -not $WorkflowResult.whatIfRun -and $blockingReasons.Count -eq 0 -and
        $resultSummary.failed -eq 0 -and $resultSummary.needsAttention -eq 0) {
        $projectResult = @($WorkflowResult.results | Where-Object id -eq 'ProjectTemplates' | Select-Object -First 1)
        if ($projectResult.Count -eq 1) {
            $projectSummary = [string](Get-SetupProperty -InputObject (Get-SetupProperty -InputObject $projectResult[0] -Name 'detail') -Name 'summary' -Default '')
            if ($projectSummary) { Write-Host "  $projectSummary" }
        }
        Write-Host '  查看项目根目录的 AGENTS.md，并按其中命令继续。'
    }
    elseif ($WorkflowResult.whatIfRun -and $blockingReasons.Count -eq 0 -and $resultSummary.restartRequired -eq 0) {
        Write-Host '  1. 查看上方计划和详细报告。'
        Write-Host '  2. 在下方选择“继续设置”，无需退出工具。'
    }
    elseif ($resultSummary.restartRequired -gt 0 -and $blockingReasons.Count -eq 0) {
        $restartIds = @($WorkflowResult.results | Where-Object status -eq 'RestartRequired' | ForEach-Object id)
        if ('InstallWslDistribution' -in $restartIds) {
            Write-Host '  1. 保存工作并按 Windows 提示重启电脑。' -ForegroundColor Yellow
            Write-Host '  2. 重启电脑后打开工具，直接按 Enter；已完成的步骤自动跳过。'
        }
        else {
            Write-Host '  1. 保存所有 WSL 工作并完全关闭使用 WSL 的程序。' -ForegroundColor Yellow
            Write-Host '  2. 在 Windows PowerShell 运行 wsl --shutdown。'
            Write-Host '  3. 回到此页选择“重新检查”，确认下一步。'
        }
    }
    elseif ($blockingReasons.Count -gt 0 -or $resultSummary.failed -gt 0 -or $resultSummary.needsAttention -gt 0) {
        Write-Host '  1. 先查看详细结果中的“未完成”项目。' -ForegroundColor Yellow
        Write-Host '  2. 处理提示后，在下方选择“继续设置”或“重新检查”。'
    }
    elseif ($resultSummary.skipped -gt 0) {
        Write-Host '  1. 本次有项目未执行；当前环境可能尚未完整准备。' -ForegroundColor Yellow
        Write-Host '  2. 如需处理未执行项，在下方选择“继续设置”。'
    }
    elseif ($remainingSetupCount -gt 0) {
        Write-Host '  1. 仍有设置需要处理。' -ForegroundColor Yellow
        Write-Host '  2. 处理提示后，在下方选择“继续设置”。'
    }
    elseif ($resultSummary.total -eq 0) {
        Write-Host '  本次没有可执行项目；请查看上方提示或详细结果。' -ForegroundColor Yellow
    }
    else {
        $showDesktopChecklist = @($actions | Where-Object { $_.id -in @('CodexDesktop', 'GlobalCodexConfig', 'GlobalAgents') }).Count -gt 0
        if ($showDesktopChecklist) {
            $checklist = Get-CodexDesktopChecklist -Config $workflowConfig
            $step = 1
            foreach ($item in $checklist.items) { Write-Host "  $step. $item"; $step++ }
            Write-Host '     请在 Codex Desktop 中确认以上设置，再重启并验证环境。' -ForegroundColor DarkGray
        }
        else { Write-Host '  环境已符合当前配置。' }
    }

    while ($true) {
        Write-Host ''
        $choices = @('R', 'D', 'G')
        if (@($WorkflowResult.results | Where-Object { $_.id -eq 'ConfigureWslNetwork' -and $_.status -eq 'RestartRequired' }).Count -gt 0) {
            Write-Host '[W] 停止 WSL 并重新验证（会停止所有发行版，请先保存 WSL 中的工作）' -ForegroundColor Yellow
            $choices += 'W'
        }
        if ($remainingSetupCount -gt 0 -or $blockingReasons.Count -gt 0) {
            Write-Host '[1] 继续设置  [R] 重新检查  [D] 详细报告  [G] Desktop 指南  [Enter] 返回首页'
            $choices += '1'
        }
        else { Write-Host '[R] 重新检查  [D] 详细报告  [G] Desktop 指南  [Enter] 返回首页' }
        $choice = Read-SetupMenuChoice -Prompt '请选择 [默认返回]' -Choices $choices
        switch ($choice) {
            '' { return }
            '1' { return 'Apply' }
            'R' { return 'Detect' }
            'W' { return 'RestartWsl' }
            'D' { Open-SetupReport -ReportPath $WorkflowResult.reportPath }
            'G' { Open-CodexSettingsGuide -Config $workflowConfig }
        }
    }
}

function Show-WorkflowSession {
    param([Parameter(Mandatory)]$WorkflowResult, [AllowNull()][string]$TargetProject)
    $projectOnly = $WorkflowResult.workflowMode -eq 'ProjectInit'
    $pendingRestarts = @()
    while ($true) {
        $pendingRestarts = @((Get-SetupProperty $WorkflowResult 'results' @()) | Where-Object status -eq 'RestartRequired')
        $next = Show-WorkflowCompletion -WorkflowResult $WorkflowResult
        if (-not $next) { return }
        if ($next -eq 'RestartWsl') {
            try { Invoke-InteractiveExternalSetupCommand -Command 'wsl.exe' -Arguments @('--shutdown') | Out-Null }
            catch { Write-SetupStatus -Kind Error -Message $_.Exception.Message; continue }
            $pendingRestarts = @($pendingRestarts | Where-Object id -ne 'ConfigureWslNetwork')
            $next = 'Detect'
        }
        $nextMode = if ($projectOnly) { 'ProjectInit' } else { $next }
        $WorkflowResult = Invoke-Workflow -Config $WorkflowResult.config -WorkflowMode $nextMode -TargetProject $TargetProject `
            -RealApply:($next -eq 'Apply') -DeepDetection:($nextMode -ne 'ProjectInit') -ForceRefresh:$true -PendingRestarts $pendingRestarts
    }
}

function Show-SetupMoreMenu {
    param([Parameter(Mandatory)]$Config)
    while ($true) {
        Write-Host ''
        Write-Host '[1] 导出当前设置  [2] 撤销上次更改  [3] Desktop 指南  [Enter] 返回首页'
        switch (Read-SetupMenuChoice -Prompt '请选择 [默认返回]' -Choices @('1', '2', '3')) {
            '' { return }
            '1' {
                $path = if ($ExportPath) { $ExportPath } else { Join-Path (Get-Location) 'codex-setup.export.json' }
                Write-SetupStatus -Kind Info -Message "导出当前版本选择：$($Config.wsl.distribution)；已检查的会话使用固定版本，便于复现。"
                $exportResult = Export-SetupConfig -Config $Config -Path $path -Confirm:$false
                Write-SetupStatus -Kind Info -Message "导出结果：$($exportResult.status)；$path"
            }
            '2' {
                $manifest = if ($RollbackManifest) { $RollbackManifest } else { Get-RecentRollbackManifest }
                if (-not $manifest) { Write-SetupStatus -Kind Info -Message '没有可撤销的更改。'; continue }
                Invoke-CodexSetupRollback -ManifestPath $manifest -Confirm:$false | Out-Null
                $script:detectionCache.Clear()
            }
            '3' { Open-CodexSettingsGuide -Config $Config }
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
        [bool]$ForceRefresh = $false,
        [AllowEmptyCollection()][object[]]$PendingRestarts = @()
    )
    $runtime = Initialize-SetupRuntime
    $succeeded = $false
    try {
        if ($Config.environmentMode -eq 'WslFirst' -and $Config.wsl.distribution -like 'latest-*') {
            $requestedDistribution = $Config.wsl.distribution
            Write-SetupStatus -Kind Info -Message "正在查询 Ubuntu 正式版本与 WSL 安装目录（$requestedDistribution）。"
            # Pin this shared session config before detection, planning, and continuation.
            $Config.wsl.distribution = Resolve-WslDistribution -Distribution $requestedDistribution
            Write-SetupStatus -Kind Info -Message "本次目标：$($Config.wsl.distribution)；已有其他发行版不会被升级或删除。"
        }
        $detection = Get-CachedSetupDetection -TargetProject $TargetProject -DeepDetection:$DeepDetection -ForceRefresh:$ForceRefresh -Config $Config
        $effectiveWhatIf = -not $RealApply -or [bool]$WhatIfPreference
        $applyApproved = $true
        while ($true) {
            $plan = Get-CodexSetupPlan -Detection $detection -Config $Config -ProjectPath $TargetProject
            if ($WorkflowMode -eq 'ProjectInit') {
                $plan.actions = @($plan.actions | Where-Object module -eq 'Project')
                $plan.warnings = @($plan.warnings | Where-Object { [string]$_ -match '^项目' })
                $plan.blockingReasons = @($plan.blockingReasons | Where-Object { [string]$_ -match '^项目' })
                $plan.information = @()
                $plan.skipped = @()
                $plan.afterSetup = @()
            }
            Show-CodexSetupPlan -Plan $plan
            if ($effectiveWhatIf -or $NonInteractive -or $plan.actions.Count -eq 0) { break }
            $choices = @('Y', 'S')
            $customText = ''
            if ($WorkflowMode -ne 'ProjectInit') { $choices += 'C'; $customText = '  [C] 自定义 Codex 权限' }
            Write-Host "[Y] 执行以上 $($plan.actions.Count) 项变更$customText  [S/Enter] 跳过"
            $choice = Read-SetupMenuChoice -Prompt '请选择 [默认 S]' -Choices $choices -Default 'S'
            if ($choice -eq 'C') {
                if (Select-CodexConfigurationPreset -Config $Config) {
                    $detection = Get-CachedSetupDetection -TargetProject $TargetProject -DeepDetection:$DeepDetection -ForceRefresh:$false -Config $Config
                }
                continue
            }
            $applyApproved = $choice -eq 'Y'
            break
        }
        $results = @()
        $remainingPlan = $null
        if ($WorkflowMode -in @('Plan', 'Apply', 'ProjectInit')) {
            if ($effectiveWhatIf) {
                Write-SetupStatus -Kind Info -Message '当前为预览，下面展示执行计划。'
                $results = @(Invoke-CodexSetupPlan -Plan $plan -Config $Config -NonInteractive:$NonInteractive -WhatIf -InformationAction SilentlyContinue)
            }
            elseif (-not $applyApproved) {
                $results = @($plan.actions | ForEach-Object {
                    [pscustomobject]@{ id=$_.id; module=$_.module; status='Skipped'; error='用户跳过本次设置。'; detail=$null; durationMs=0 }
                })
                Write-SetupStatus -Kind Info -Message '已跳过，未应用设置。'
            }
            else {
                if ($Config.codex.sandboxMode -eq 'danger-full-access') {
                    Write-SetupStatus -Kind Warning -Message '将修改用户级全局权限默认值，影响之后打开的所有 Codex 项目与任务；执行前还会要求单独确认。'
                }
                $results = @(Invoke-CodexSetupPlan -Plan $plan -Config $Config -NonInteractive:$NonInteractive `
                    -Confirm:$false)
            }
        }
        if (-not $effectiveWhatIf) {
            $remainingPlan = Get-RemainingSetupPlan -Plan $plan -Results $results
            if (@($results | Where-Object status -eq 'Changed').Count -gt 0) {
                Write-SetupStatus -Kind Info -Message '正在验证设置结果。'
                $detection = Get-CachedSetupDetection -TargetProject $TargetProject -DeepDetection:$DeepDetection -ForceRefresh:$true -Config $Config
                $verifiedPlan = Get-CodexSetupPlan -Detection $detection -Config $Config -ProjectPath $TargetProject
                if ($WorkflowMode -eq 'ProjectInit') {
                    $verifiedPlan.actions = @($verifiedPlan.actions | Where-Object module -eq 'Project')
                    $verifiedPlan.blockingReasons = @($verifiedPlan.blockingReasons | Where-Object { [string]$_ -match '^项目' })
                }
                # Project templates are generated on demand; the writer already verified them.
                $completedProjects = @($results | Where-Object { $_.module -eq 'Project' -and $_.status -in @('Changed', 'NoChange') })
                $remainingPlan = Get-RemainingSetupPlan -Plan $verifiedPlan -Results $completedProjects
            }
        }
        # Reading the updated .wslconfig cannot prove that an existing VM restarted.
        $pendingIds = @($PendingRestarts | ForEach-Object id)
        $results = @($results | Where-Object { $_.id -notin $pendingIds }) + $PendingRestarts
        $reportPath = New-CodexSetupReport -Detection $detection -Plan $plan -Results $results -Config $Config -WhatIfRun:$effectiveWhatIf `
            -RemainingPlan $remainingPlan
        Write-SetupStatus -Kind Success -Message "报告已生成：$reportPath"
        if (-not $effectiveWhatIf) {
            $script:detectionCache.Clear()
        }
        $succeeded = $true
        if ($OpenDesktopSettings -and -not $NonInteractive) { Open-CodexSettingsGuide -Config $Config }
        return [pscustomobject]@{
            runtime=$runtime
            detection=$detection
            plan=$plan
            results=$results
            reportPath=$reportPath
            workflowMode=$WorkflowMode
            whatIfRun=$effectiveWhatIf
            deepDetection=$DeepDetection
            remainingPlan=$remainingPlan
            config=$Config
        }
    }
    finally {
        Complete-SetupRuntime -Succeeded:$succeeded
    }
}

if ($isDotSourced) { return }

try {
    $config = Resolve-SetupConfiguration -Path $ConfigPath
    $commandResult = $null
    $processExitCode = 0
    if ([string]::IsNullOrWhiteSpace($ProjectPath) -and -not [string]::IsNullOrWhiteSpace($config.paths.projectPath)) {
        $ProjectPath = [Environment]::ExpandEnvironmentVariables($config.paths.projectPath)
    }

    if ($Mode -eq 'Wizard') {
        if ($NonInteractive) { throw 'Wizard 模式需要交互；无人值守时请使用 -Mode Plan/Apply/Detect。' }
        while ($true) {
            Show-Banner -Config $config
            Show-MainMenu -Config $config
            $selection = Read-SetupMenuChoice -Prompt '请选择 [默认 1]' -Choices @('1', '2', '3', 'M', '0') -Default '1'
            try {
                switch ($selection) {
                    '0' { return }
                    '1' {
                        Write-SetupStatus -Kind Info -Message '正在检查环境并生成计划；确认前不会应用设置。'
                        $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Apply -TargetProject $ProjectPath -RealApply:$true -DeepDetection:$true
                        Show-WorkflowSession -WorkflowResult $workflowResult -TargetProject $ProjectPath
                    }
                    '2' {
                        $workflowResult = Invoke-Workflow -Config $config -WorkflowMode Detect -TargetProject $ProjectPath -RealApply:$false -DeepDetection:$true -ForceRefresh:$true
                        Show-WorkflowSession -WorkflowResult $workflowResult -TargetProject $ProjectPath
                    }
                    '3' {
                        $ProjectPath = Read-Host '项目文件夹完整路径 [Enter 返回]'
                        if ([string]::IsNullOrWhiteSpace($ProjectPath)) { continue }
                        $workflowResult = Invoke-Workflow -Config $config -WorkflowMode ProjectInit -TargetProject $ProjectPath -RealApply:$true -DeepDetection:$false
                        Show-WorkflowSession -WorkflowResult $workflowResult -TargetProject $ProjectPath
                    }
                    'M' { Show-SetupMoreMenu -Config $config }
                }
            }
            catch {
                Write-SetupStatus -Kind Error -Message (ConvertTo-RedactedText $_.Exception.Message)
                $script:detectionCache.Clear()
                [void](Read-Host '按 Enter 返回首页；可选择“开始或修复”重试')
            }
        }
    }

    switch ($Mode) {
        'Detect' {
            $commandResult = Invoke-Workflow -Config $config -WorkflowMode Detect -TargetProject $ProjectPath -RealApply:$false `
                -DeepDetection:([bool]$DeepDetection) -ForceRefresh:([bool]$ForceRefresh)
        }
        'Plan' {
            $commandResult = Invoke-Workflow -Config $config -WorkflowMode Plan -TargetProject $ProjectPath -RealApply:$false `
                -DeepDetection:([bool]$DeepDetection) -ForceRefresh:([bool]$ForceRefresh)
        }
        'Apply' {
            if (-not $ApplyChanges) { Write-SetupStatus -Kind Info -Message '未提供 -ApplyChanges，本次只预览将要进行的设置。' }
            $commandResult = Invoke-Workflow -Config $config -WorkflowMode Apply -TargetProject $ProjectPath -RealApply:([bool]$ApplyChanges) `
                -DeepDetection:$true -ForceRefresh:([bool]$ForceRefresh)
        }
        'ProjectInit' {
            if ([string]::IsNullOrWhiteSpace($ProjectPath)) { throw 'ProjectInit 需要 -ProjectPath。' }
            $commandResult = Invoke-Workflow -Config $config -WorkflowMode ProjectInit -TargetProject $ProjectPath -RealApply:([bool]$ApplyChanges) `
                -DeepDetection:([bool]($DeepDetection -or $ApplyChanges)) -ForceRefresh:([bool]$ForceRefresh)
        }
        'Export' {
            if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = Join-Path (Get-Location) 'codex-setup.export.json' }
            $exportResult = Export-SetupConfig -Config $config -Path $ExportPath -WhatIf:$WhatIfPreference -Confirm:$false
            switch ($exportResult.status) {
                'Changed' { Write-SetupStatus -Kind Success -Message "配置已导出：$ExportPath" }
                'NoChange' { Write-SetupStatus -Kind Info -Message "配置文件无需修改：$ExportPath" }
                'Preview' { Write-SetupStatus -Kind Info -Message "预览：将导出到 $ExportPath；当前未写入文件。" }
                default { Write-SetupStatus -Kind Info -Message '已取消导出。' }
            }
        }
        'Rollback' {
            if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { $RollbackManifest = Get-RecentRollbackManifest }
            if ([string]::IsNullOrWhiteSpace($RollbackManifest)) { throw '没有找到可回滚的运行清单。' }
            $commandResult = Invoke-CodexSetupRollback -ManifestPath $RollbackManifest -NonInteractive:$NonInteractive `
                -AllowIncompleteRun:$AllowIncompleteRollback -WhatIf:(-not $ApplyChanges -or [bool]$WhatIfPreference)
        }
    }
    if ($null -ne $commandResult -and $Mode -in @('Detect', 'Plan', 'Apply', 'ProjectInit')) {
        $machineResult = New-WorkflowMachineResult -WorkflowResult $commandResult -InvocationMode $Mode -RequestedApply:([bool]$ApplyChanges)
        $processExitCode = [int]$machineResult.exitCode
        if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
            [void](Write-SetupResultJson -Path $ResultJsonPath -Value $machineResult)
        }
    }
    elseif ($Mode -eq 'Rollback' -and $null -ne $commandResult) {
        $processExitCode = if ($commandResult.status -eq 'Completed') { 0 } elseif ($commandResult.status -eq 'Preview') { 0 } else { 1 }
        if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
            [void](Write-SetupResultJson -Path $ResultJsonPath -Value ([ordered]@{
                schemaVersion=2; generatedAt=(Get-Date).ToString('o'); mode='Rollback'; status=$commandResult.status
                exitCode=$processExitCode; manifestPath=$commandResult.manifestPath; result=$commandResult
            }))
        }
    }
    if (Test-SetupProcessExitRequired -InvocationMode $Mode -WasModeExplicit:$modeWasExplicit -WasDotSourced:$isDotSourced `
        -IsNonInteractive:([bool]$NonInteractive) -MachineResultPath $ResultJsonPath) {
        exit $processExitCode
    }
}
catch {
    $message = ConvertTo-RedactedText $_.Exception.Message
    Write-Host "[错误] $message" -ForegroundColor Red
    try { Write-SetupLog -Level Error -Message $message -Data @{ stack=$_.ScriptStackTrace } }
    catch { }
    if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
        try {
            [void](Write-SetupResultJson -Path $ResultJsonPath -Value ([ordered]@{
                schemaVersion=2; generatedAt=(Get-Date).ToString('o'); mode=$Mode; status='Failed'; exitCode=1; error=$message
            }))
        }
        catch { }
    }
    exit 1
}
