Set-StrictMode -Version Latest

function Get-CodexSetupResultSummary {
    param([AllowNull()]$Results)

    $summary = [ordered]@{ total=0; changed=0; noChange=0; needsAttention=0; restartRequired=0; failed=0; skipped=0; preview=0; unknown=0 }
    foreach ($result in @($Results)) {
        $summary.total++
        switch ([string](Get-SetupProperty $result 'status' '')) {
            'Changed' { $summary.changed++; break }
            'NoChange' { $summary.noChange++; break }
            'NeedsAttention' { $summary.needsAttention++; break }
            'RestartRequired' { $summary.restartRequired++; break }
            'Failed' { $summary.failed++; break }
            'Skipped' { $summary.skipped++; break }
            { $_ -in @('Preview', 'WhatIf') } { $summary.preview++; break }
            default { $summary.unknown++; break }
        }
    }
    return [pscustomobject]$summary
}

function Get-CodexSetupResultSummaryText {
    param([Parameter(Mandatory)]$Summary)
    $parts = @(
        if ($Summary.changed -gt 0) { "更新 $($Summary.changed) 项" }
        if ($Summary.noChange -gt 0) { "无需修改 $($Summary.noChange) 项" }
        if ($Summary.needsAttention -gt 0) { "待处理 $($Summary.needsAttention) 项" }
        if ($Summary.restartRequired -gt 0) { "需要重启 $($Summary.restartRequired) 项" }
        if ($Summary.failed -gt 0) { "失败 $($Summary.failed) 项" }
        if ($Summary.skipped -gt 0) { "已跳过 $($Summary.skipped) 项" }
        if ($Summary.preview -gt 0) { "预览 $($Summary.preview) 项" }
    )
    return $parts -join '；'
}

function Get-ReportCommandState {
    param($CommandInfo)
    if ($null -eq $CommandInfo) { return '未检测' }
    if (Get-SetupProperty $CommandInfo 'installed' $false) { return '可用' }
    if (Get-SetupProperty $CommandInfo 'probeError') { return '检查失败' }
    return '未安装'
}

function Get-ReportResultLabel {
    param([string]$Status)
    switch ($Status) {
        'Changed' { '已更新'; break }
        'NoChange' { '无需修改'; break }
        'NeedsAttention' { '需要处理'; break }
        'RestartRequired' { '需要重启'; break }
        'Failed' { '失败'; break }
        'Skipped' { '跳过'; break }
        { $_ -in @('Preview', 'WhatIf') } { '预览'; break }
        default { if ($Status) { $Status } else { '未知' } }
    }
}

function Add-ReportTableRow {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()]$Detail
    )
    $safeDetail = ([string]$Detail).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
    $Lines.Add("| $Name | $Status | $safeDetail |")
}

function New-CodexSetupReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Detection,
        [Parameter(Mandatory)]$Plan,
        [AllowNull()]$Results,
        [Parameter(Mandatory)]$Config,
        [bool]$WhatIfRun,
        [AllowNull()]$RemainingPlan
    )

    $runtime = Get-SetupRuntime
    $lines = [System.Collections.Generic.List[string]]::new()
    $resultSummary = Get-CodexSetupResultSummary -Results $Results
    $effectiveDetection = $Detection
    $mode = [string](Get-SetupProperty $Plan 'environmentMode' $Config.environmentMode)
    $actions = @(Get-SetupProperty $Plan 'actions' @())
    $issues = @(Get-SetupProperty $effectiveDetection 'issues' @())
    $remaining = if ($null -ne $RemainingPlan) { @(Get-SetupProperty $RemainingPlan 'actions' @()) } else { @() }
    $remainingSetupCount = $remaining.Count
    $completionPlan = if ($null -ne $RemainingPlan) { $RemainingPlan } else { $Plan }
    $blockingReasons = @(Get-SetupProperty $completionPlan 'blockingReasons' @())

    $lines.Add('# Codex 开发环境报告')
    $lines.Add('')
    $lines.Add("- 运行编号：$($runtime.RunId)")
    $lines.Add("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $lines.Add("- 目标环境：**$(Get-SetupProperty $Plan 'environmentLabel' $mode)**")
    $lines.Add("- 检查范围：$(Get-SetupProperty $effectiveDetection 'detectionMode' '未知')")
    $healthLabel = [string](Get-SetupProperty $effectiveDetection 'healthLabel' '未评级')
    if ($healthLabel -eq '尚未完整检查') { $lines.Add('- 环境状态：**尚未完整检查**') }
    else { $lines.Add("- 环境状态：**$healthLabel（$(Get-SetupProperty $effectiveDetection 'healthScore' 0)/100）**") }
    $runState = if ($WhatIfRun) { '预览完成' } elseif ($resultSummary.failed -gt 0) { '有失败项' } elseif ($blockingReasons.Count -gt 0) { '存在必须先解决的阻断' } elseif ($resultSummary.restartRequired -gt 0) { '需要重启后继续' } elseif ($resultSummary.needsAttention -gt 0 -or $remainingSetupCount -gt 0) { '仍有待处理项' } elseif ($resultSummary.skipped -gt 0) { '有未执行项' } else { '执行完成' }
    $lines.Add("- 本次状态：$runState")
    $summaryText = Get-CodexSetupResultSummaryText -Summary $resultSummary
    if ($summaryText) { $lines.Add("- 执行结果：$summaryText") }

    $lines.Add('')
    $lines.Add('## 环境状态')
    $lines.Add('')
    $lines.Add('| 项目 | 状态 | 详情 |')
    $lines.Add('|---|---|---|')
    Add-ReportTableRow $lines 'Windows 11' $(if (Get-SetupProperty $effectiveDetection.windows 'isWindows11' $false) { '可用' } else { '不符合' }) "$(Get-SetupProperty $effectiveDetection.windows 'caption' '') build $(Get-SetupProperty $effectiveDetection.windows 'build' '')"
    Add-ReportTableRow $lines 'Codex Desktop' $(if (Get-SetupProperty $effectiveDetection.codexDesktop 'installed' $false) { '可用' } elseif (Get-SetupProperty $effectiveDetection.codexDesktop 'error' '') { '检查失败' } else { '未安装' }) ''
    $terminalInstalled = (Get-SetupProperty $effectiveDetection.windowsTerminal.command 'installed' $false) -or (Get-SetupProperty $effectiveDetection.windowsTerminal.app 'installed' $false)
    Add-ReportTableRow $lines 'Windows Terminal' $(if ($terminalInstalled) { '可用' } else { '未安装' }) ''
    Add-ReportTableRow $lines 'PowerShell 7' (Get-ReportCommandState $effectiveDetection.powershell7) (Get-SetupProperty $effectiveDetection.powershell7 'version' '')
    Add-ReportTableRow $lines 'Git for Windows' (Get-ReportCommandState $effectiveDetection.git) (Get-SetupProperty $effectiveDetection.git 'version' '')
    Add-ReportTableRow $lines 'GitHub CLI（Windows）' (Get-ReportCommandState $effectiveDetection.githubCli) (Get-SetupProperty $effectiveDetection.githubCli 'version' '')
    if ([bool]$Config.toolchains.docker.enabled) {
        Add-ReportTableRow $lines 'Docker Desktop' (Get-ReportCommandState $effectiveDetection.dockerDesktop) (Get-SetupProperty $effectiveDetection.dockerDesktop 'version' '')
    }
    if ($mode -eq 'WslFirst') {
        $wslState = switch ([string](Get-SetupProperty $effectiveDetection.wsl 'state' 'Unknown')) {
            'Ready' { '可用' }
            'UnsupportedWsl1' { '不支持 WSL1' }
            'FeatureDisabled' { 'Windows 功能未启用' }
            'NoDistribution' { '没有发行版' }
            'TargetMissing' { '目标发行版未安装' }
            default { '检查失败' }
        }
        Add-ReportTableRow $lines 'WSL 发行版' $wslState (Get-SetupProperty $effectiveDetection.wsl 'distribution' $Config.wsl.distribution)
        $wslTools = Get-SetupProperty $effectiveDetection 'wslTools'
        $toolchainState = switch ([string](Get-SetupProperty $wslTools 'readiness' 'Unknown')) { 'Ready' { '符合当前配置' } 'NotReady' { '需要配置' } default { '尚未完整检查' } }
        $missing = @((Get-SetupProperty $wslTools 'missingRequiredCommands' @()) + (Get-SetupProperty $wslTools 'nonNativeCommands' @())) -join '、'
        Add-ReportTableRow $lines 'WSL 开发工具链' $toolchainState $(if ($missing) { "缺失或非 Linux 原生：$missing" } else { '' })
    }
    else {
        foreach ($entry in @(
            @{ name='Windows ripgrep'; value=$effectiveDetection.ripgrep }, @{ name='Windows fd'; value=$effectiveDetection.fd },
            @{ name='Windows jq'; value=$effectiveDetection.jq },
            @{ name='Windows Node.js'; value=$effectiveDetection.node }, @{ name='Windows uv'; value=$effectiveDetection.uv },
            @{ name='Windows Python'; value=$effectiveDetection.python }, @{ name='Windows Codex CLI'; value=$effectiveDetection.codexCli }
        )) { Add-ReportTableRow $lines $entry.name (Get-ReportCommandState $entry.value) (Get-SetupProperty $entry.value 'version' '') }
    }

    $lines.Add('')
    $lines.Add('## 执行结果')
    $lines.Add('')
    if ($actions.Count -eq 0) {
        $lines.Add('- 没有需要执行的设置。')
    }
    elseif ($null -eq $Results -or @($Results).Count -eq 0) {
        foreach ($action in $actions) { $lines.Add("- [计划] $($action.title)") }
    }
    else {
        foreach ($action in $actions) {
            $result = @($Results | Where-Object { (Get-SetupProperty $_ 'id' '') -eq $action.id } | Select-Object -First 1)
            if ($result.Count -eq 0) {
                $lines.Add("- [已跳过] $($action.title)")
                continue
            }
            $status = Get-ReportResultLabel ([string](Get-SetupProperty $result[0] 'status' ''))
            $errorText = [string](Get-SetupProperty $result[0] 'error' '')
            $summaryText = [string](Get-SetupProperty (Get-SetupProperty $result[0] 'detail') 'summary' '')
            $suffix = if ($errorText) { ' — ' + (ConvertTo-RedactedText $errorText) } elseif ($summaryText) { ' — ' + (ConvertTo-RedactedText $summaryText) } else { '' }
            $lines.Add("- [$status] $($action.title)$suffix")
        }
    }

    if ($null -ne $RemainingPlan) {
        $lines.Add('')
        $lines.Add('### 仍待处理')
        if ($remaining.Count -eq 0) { $lines.Add('- 无自动动作。') }
        else { foreach ($action in $remaining) { $lines.Add("- $($action.title)") } }
    }
    if (@($actions | Where-Object { $_.id -in @('CodexDesktop', 'GlobalCodexConfig', 'GlobalAgents') }).Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Codex Desktop 待确认')
        $lines.Add('')
        $checklist = Get-CodexDesktopChecklist -Config $Config
        $checklistIndex = 1
        foreach ($item in $checklist.items) { $lines.Add("$checklistIndex. $item"); $checklistIndex++ }
        $lines.Add('')
        $lines.Add('完成清单后，请重启 Codex Desktop 并再次检查。')
    }

    $project = Get-SetupProperty $effectiveDetection 'project'
    if ($null -ne $project -and -not (Get-SetupProperty $project 'matchesConfiguredMode' $true)) {
        $lines.Add('')
        $lines.Add('## 项目环境提示')
        $lines.Add('')
        $lines.Add('- 项目环境与当前配置不匹配，请按下方建议调整。')
        foreach ($reason in @(Get-SetupProperty $project 'reasons' @())) { $lines.Add("- $reason") }
    }

    $warnings = @(Get-SetupProperty $Plan 'warnings' @())
    if ($blockingReasons.Count -gt 0 -or $warnings.Count -gt 0 -or $issues.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## 待处理问题')
        $lines.Add('')
        foreach ($reason in $blockingReasons) { $lines.Add("- [阻断] $reason") }
        foreach ($warning in $warnings) { $lines.Add("- $warning") }
        if ($blockingReasons.Count -eq 0 -and $warnings.Count -eq 0) {
            foreach ($issue in $issues) {
                $lines.Add("- $(Get-SetupProperty $issue 'name' '检查')：$(Get-SetupProperty $issue 'error' '未知错误')")
            }
        }
    }

    $lines.Add('')
    $lines.Add('## Codex 权限设置')
    $lines.Add('')
    $lines.Add(('- approval_policy = `{0}`' -f $Config.codex.approvalPolicy))
    $lines.Add(('- sandbox_mode = `{0}`' -f $Config.codex.sandboxMode))
    if ($mode -eq 'WindowsNative') { $lines.Add(('- windows sandbox = `{0}`' -f $Config.codex.windowsSandbox)) }

    $lines.Add('')
    $lines.Add('## 结果文件')
    $lines.Add('')
    $lines.Add("- 详细日志：$($runtime.LogPath)")
    $lines.Add("- 回滚清单：$($runtime.ManifestPath)")
    $lines.Add('- 回滚范围：本次新安装的 WinGet 软件包和本工具管理的文件。')

    Set-Content -LiteralPath $runtime.SummaryPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    $Detection | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'detection.json') -Encoding utf8
    $Plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'plan.json') -Encoding utf8
    if ($null -ne $Results) {
        $Results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'results.json') -Encoding utf8
    }
    Write-SetupLog -Message '最终报告已生成' -Data @{ path=$runtime.SummaryPath }
    return $runtime.SummaryPath
}

Export-ModuleMember -Function @('New-CodexSetupReport', 'Get-CodexSetupResultSummary', 'Get-CodexSetupResultSummaryText')
