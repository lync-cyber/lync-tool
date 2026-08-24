Set-StrictMode -Version Latest

function Get-ReportProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function Get-CodexSetupResultSummary {
    param([AllowNull()]$Results)

    $summary = [ordered]@{ total=0; changed=0; noChange=0; needsAttention=0; restartRequired=0; failed=0; skipped=0; preview=0; unknown=0 }
    foreach ($result in @($Results)) {
        $summary.total++
        switch ([string](Get-ReportProperty $result 'status' '')) {
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

function Get-ReportCommandState {
    param($CommandInfo)
    if ($null -eq $CommandInfo) { return '未检测' }
    if (Get-ReportProperty $CommandInfo 'installed' $false) { return '可用' }
    if (Get-ReportProperty $CommandInfo 'probeError') { return '检测失败' }
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
        [AllowNull()]$RemainingPlan,
        [AllowNull()]$VerificationDetection
    )

    $runtime = Get-SetupRuntime
    $lines = [System.Collections.Generic.List[string]]::new()
    $resultSummary = Get-CodexSetupResultSummary -Results $Results
    $effectiveDetection = if ($null -ne $VerificationDetection) { $VerificationDetection } else { $Detection }
    $mode = [string](Get-ReportProperty $Plan 'environmentMode' $Config.environmentMode)
    $actions = @(Get-ReportProperty $Plan 'actions' @())
    $issues = @(Get-ReportProperty $effectiveDetection 'issues' @())
    $remaining = if ($null -ne $RemainingPlan) { @(Get-ReportProperty $RemainingPlan 'actions' @()) } else { @() }
    $remainingSetupCount = @($remaining | Where-Object { (Get-ReportProperty $_ 'type' '') -ne 'WingetUpgradeCheck' }).Count
    $completionPlan = if ($null -ne $RemainingPlan) { $RemainingPlan } else { $Plan }
    $blockingReasons = @(Get-ReportProperty $completionPlan 'blockingReasons' @())

    $lines.Add('# Codex 开发环境结果')
    $lines.Add('')
    $lines.Add("- 运行编号：$($runtime.RunId)")
    $lines.Add("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $lines.Add("- 目标环境：**$(Get-ReportProperty $Plan 'environmentLabel' $mode)**")
    $lines.Add("- 检测范围：$(Get-ReportProperty $effectiveDetection 'detectionMode' '未知')")
    $healthLabel = [string](Get-ReportProperty $effectiveDetection 'healthLabel' '未评级')
    if ($healthLabel -eq '尚未完整检查') { $lines.Add('- 核心状态：**尚未完整检查**') }
    else { $lines.Add("- 核心状态：**$healthLabel（$(Get-ReportProperty $effectiveDetection 'healthScore' 0)/100）**") }
    $runState = if ($WhatIfRun) { '预览，未执行持久修改' } elseif ($resultSummary.failed -gt 0) { '有失败项' } elseif ($blockingReasons.Count -gt 0) { '存在必须先解决的阻断' } elseif ($resultSummary.restartRequired -gt 0) { '需要重启后继续' } elseif ($resultSummary.needsAttention -gt 0 -or $remainingSetupCount -gt 0) { '仍有待处理项' } elseif ($resultSummary.skipped -gt 0) { '有未执行项' } else { '目标状态已复核' }
    $lines.Add("- 本次状态：$runState")
    $lines.Add("- 动作结果：更新 $($resultSummary.changed)，无需修改 $($resultSummary.noChange)，待处理 $($resultSummary.needsAttention)，需重启 $($resultSummary.restartRequired)，失败 $($resultSummary.failed)，未执行 $($resultSummary.skipped)，预览 $($resultSummary.preview)")

    $lines.Add('')
    $lines.Add('## 可检测事实')
    $lines.Add('')
    $lines.Add('| 项目 | 状态 | 详情 |')
    $lines.Add('|---|---|---|')
    Add-ReportTableRow $lines 'Windows 11' $(if (Get-ReportProperty $effectiveDetection.windows 'isWindows11' $false) { '可用' } else { '不符合' }) "$(Get-ReportProperty $effectiveDetection.windows 'caption' '') build $(Get-ReportProperty $effectiveDetection.windows 'build' '')"
    Add-ReportTableRow $lines 'Codex Desktop' $(if (Get-ReportProperty $effectiveDetection.codexDesktop 'installed' $false) { '可用' } elseif (Get-ReportProperty $effectiveDetection.codexDesktop 'error' '') { '检测失败' } else { '未安装' }) ''
    $terminalInstalled = (Get-ReportProperty $effectiveDetection.windowsTerminal.command 'installed' $false) -or (Get-ReportProperty $effectiveDetection.windowsTerminal.app 'installed' $false)
    Add-ReportTableRow $lines 'Windows Terminal' $(if ($terminalInstalled) { '可用' } else { '未安装' }) ''
    Add-ReportTableRow $lines 'PowerShell 7' (Get-ReportCommandState $effectiveDetection.powershell7) (Get-ReportProperty $effectiveDetection.powershell7 'version' '')
    Add-ReportTableRow $lines 'Git for Windows' (Get-ReportCommandState $effectiveDetection.git) (Get-ReportProperty $effectiveDetection.git 'version' '')
    Add-ReportTableRow $lines 'GitHub CLI for Windows' (Get-ReportCommandState $effectiveDetection.githubCli) (Get-ReportProperty $effectiveDetection.githubCli 'version' '')
    if ([bool]$Config.toolchains.docker.enabled) {
        Add-ReportTableRow $lines 'Docker Desktop' (Get-ReportCommandState $effectiveDetection.dockerDesktop) (Get-ReportProperty $effectiveDetection.dockerDesktop 'version' '')
    }
    if ($mode -eq 'WslFirst') {
        $wslState = switch ([string](Get-ReportProperty $effectiveDetection.wsl 'state' 'Unknown')) {
            'Ready' { '可用' }
            'UnsupportedWsl1' { '不支持 WSL1' }
            'FeatureDisabled' { 'Windows 功能未启用' }
            'NoDistribution' { '没有发行版' }
            'TargetMissing' { '目标发行版未安装' }
            default { '检测失败' }
        }
        Add-ReportTableRow $lines 'WSL 发行版' $wslState (Get-ReportProperty $effectiveDetection.wsl 'distribution' $Config.wsl.distribution)
        $wslTools = Get-ReportProperty $effectiveDetection 'wslTools'
        $toolchainState = switch ([string](Get-ReportProperty $wslTools 'readiness' 'Unknown')) { 'Ready' { '符合当前配置' } 'NotReady' { '需要配置' } default { '尚未完整检查' } }
        $missing = @((Get-ReportProperty $wslTools 'missingRequiredCommands' @()) + (Get-ReportProperty $wslTools 'nonNativeCommands' @())) -join '、'
        Add-ReportTableRow $lines 'WSL 开发工具链' $toolchainState $(if ($missing) { "缺失或非 Linux 原生：$missing" } else { '' })
    }
    else {
        foreach ($entry in @(
            @{ name='Windows ripgrep'; value=$effectiveDetection.ripgrep }, @{ name='Windows fd'; value=$effectiveDetection.fd },
            @{ name='Windows jq'; value=$effectiveDetection.jq },
            @{ name='Windows Node.js'; value=$effectiveDetection.node }, @{ name='Windows uv'; value=$effectiveDetection.uv },
            @{ name='Windows Python'; value=$effectiveDetection.python }, @{ name='Windows Codex CLI'; value=$effectiveDetection.codexCli }
        )) { Add-ReportTableRow $lines $entry.name (Get-ReportCommandState $entry.value) (Get-ReportProperty $entry.value 'version' '') }
    }

    $lines.Add('')
    $lines.Add('## 计划与执行结果')
    $lines.Add('')
    if ($actions.Count -eq 0) {
        $lines.Add('- 当前检测没有生成动作。')
    }
    elseif ($null -eq $Results -or @($Results).Count -eq 0) {
        foreach ($action in $actions) { $lines.Add("- [计划] $($action.title)") }
    }
    else {
        foreach ($action in $actions) {
            $result = @($Results | Where-Object { (Get-ReportProperty $_ 'id' '') -eq $action.id } | Select-Object -First 1)
            if ($result.Count -eq 0) {
                $lines.Add("- [未执行] $($action.title)")
                continue
            }
            $status = Get-ReportResultLabel ([string](Get-ReportProperty $result[0] 'status' ''))
            $errorText = [string](Get-ReportProperty $result[0] 'error' '')
            $summaryText = [string](Get-ReportProperty (Get-ReportProperty $result[0] 'detail') 'summary' '')
            $suffix = if ($errorText) { ' — ' + (ConvertTo-RedactedText $errorText) } elseif ($summaryText) { ' — ' + (ConvertTo-RedactedText $summaryText) } else { '' }
            $lines.Add("- [$status] $($action.title)$suffix")
        }
    }

    if ($null -ne $RemainingPlan) {
        $lines.Add('')
        $lines.Add('### 复核后仍待处理')
        if ($remaining.Count -eq 0) { $lines.Add('- 无自动动作。') }
        else { foreach ($action in $remaining) { $lines.Add("- $($action.title)") } }
    }
    if ($null -ne $VerificationDetection) {
        $lines.Add('')
        $lines.Add('### 执行后复核')
        $lines.Add("- 复核时间：$(Get-ReportProperty $VerificationDetection 'detectedAt' '')")
        $lines.Add('- 该复核不读取 Codex Desktop 的 Agent environment 或 Integrated terminal shell。')
    }

    $lines.Add('')
    $lines.Add('## Desktop 人工待办')
    $lines.Add('')
    $checklist = Get-CodexDesktopChecklist -Config $Config
    $checklistIndex = 1
    foreach ($item in $checklist.items) { $lines.Add("$checklistIndex. $item"); $checklistIndex++ }
    $lines.Add('')
    $lines.Add('Desktop 这两个设置没有供本工具可靠读取的公开接口；显示清单或打开 Settings 不代表已经验证。')

    $project = Get-ReportProperty $effectiveDetection 'project'
    if ($null -ne $project -and -not (Get-ReportProperty $project 'matchesConfiguredMode' $true)) {
        $lines.Add('')
        $lines.Add('## 项目环境提示')
        $lines.Add('')
        $lines.Add('- 项目技术栈更适合另一类开发环境；工具没有自动切换或跨环境写入。')
        foreach ($reason in @(Get-ReportProperty $project 'reasons' @())) { $lines.Add("- $reason") }
    }

    $warnings = @(Get-ReportProperty $Plan 'warnings' @())
    if ($blockingReasons.Count -gt 0 -or $warnings.Count -gt 0 -or $issues.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## 未完成与风险')
        $lines.Add('')
        foreach ($reason in $blockingReasons) { $lines.Add("- [阻断] $reason") }
        foreach ($warning in $warnings) { $lines.Add("- $warning") }
        foreach ($issue in $issues) { $lines.Add("- $(Get-ReportProperty $issue 'name' '检测')：$(Get-ReportProperty $issue 'error' '未知错误')") }
    }

    $lines.Add('')
    $lines.Add('## 安全边界')
    $lines.Add('')
    $lines.Add(('- approval_policy = `{0}`' -f $Config.codex.approvalPolicy))
    $lines.Add(('- sandbox_mode = `{0}`' -f $Config.codex.sandboxMode))
    if ($mode -eq 'WindowsNative') { $lines.Add(('- windows sandbox = `{0}`' -f $Config.codex.windowsSandbox)) }
    $lines.Add('- Shell 或路径错误必须通过修正环境解决，不能通过扩大 sandbox 权限解决。')
    $lines.Add('- 本工具不读取或复制令牌、API key、SSH 私钥、浏览器凭据、`.env`、Codex 认证、历史或会话。')

    $lines.Add('')
    $lines.Add('## 结果文件')
    $lines.Add('')
    $lines.Add("- 详细日志：$($runtime.LogPath)")
    $lines.Add("- 回滚清单：$($runtime.ManifestPath)")
    $lines.Add('- 回滚只卸载本次运行新装的 WinGet 软件包并恢复受管文件；原有软件、WSL 发行版、Linux 工具链和登录状态保持不变。')

    Set-Content -LiteralPath $runtime.SummaryPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    $Detection | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'detection.json') -Encoding utf8
    $Plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'plan.json') -Encoding utf8
    if ($null -ne $Results) {
        $Results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'results.json') -Encoding utf8
    }
    Write-SetupLog -Message '最终报告已生成' -Data @{ path=$runtime.SummaryPath }
    return $runtime.SummaryPath
}

Export-ModuleMember -Function @('New-CodexSetupReport', 'Get-CodexSetupResultSummary')
