Set-StrictMode -Version Latest

function Get-ReportProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function New-DetectionSummaryRow {
    param([string]$Name, [string]$Status, [AllowNull()]$Detail)
    return [pscustomobject]@{ name=$Name; status=$Status; detail=$Detail }
}

function Get-CommandSummaryStatus {
    param($CommandInfo)
    if ($null -eq $CommandInfo) { return '未检测' }
    if ((Get-ReportProperty $CommandInfo 'probeError') -and -not (Get-ReportProperty $CommandInfo 'installed' $false)) { return '检测失败' }
    if (Get-ReportProperty $CommandInfo 'installed' $false) { return '可用' }
    return '未安装'
}

function Get-ReportResultStatus {
    param([AllowNull()][string]$Status)
    switch ($Status) {
        'Preview' { return '预览' }
        'WhatIf' { return '预览' }
        'Completed' { return '已完成' }
        'Applied' { return '已完成' }
        'Changed' { return '已完成' }
        'Success' { return '已完成' }
        'Skipped' { return '未执行' }
        'Failed' { return '未完成' }
        default { return $Status }
    }
}

function Get-CodexSetupResultSummary {
    <#
    .SYNOPSIS
    将本次执行结果归类，避免把“已开始”误写成“全部完成”。
    #>
    param([AllowNull()]$Results)

    $summary = [ordered]@{
        total = 0
        completed = 0
        failed = 0
        skipped = 0
        preview = 0
        unknown = 0
    }
    foreach ($result in @($Results)) {
        $summary.total++
        switch ([string](Get-ReportProperty $result 'status' '')) {
            { $_ -in @('Completed', 'Applied', 'Changed', 'Success') } { $summary.completed++; break }
            'Failed' { $summary.failed++; break }
            'Skipped' { $summary.skipped++; break }
            { $_ -in @('Preview', 'WhatIf') } { $summary.preview++; break }
            default { $summary.unknown++; break }
        }
    }
    return [pscustomobject]$summary
}

function Get-CodexSetupPendingActionCount {
    param([AllowNull()]$Plan)
    return @((Get-ReportProperty $Plan 'actions' @())).Count
}

function Convert-DetectionToSummaryRows {
    param([Parameter(Mandatory)]$Detection)
    $terminalVersion = if ($Detection.windowsTerminal.command.version) {
        $Detection.windowsTerminal.command.version
    }
    elseif ($Detection.windowsTerminal.app.packages.Count -gt 0) {
        'App package ' + (($Detection.windowsTerminal.app.packages.Version | Select-Object -Unique) -join ', ')
    }
    else { '' }
    $codexDetail = if ($Detection.codexDesktop.installed) {
        @($Detection.codexDesktop.packages | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
    }
    else { '未检测到' }
    $windowsStatus = if (Get-ReportProperty $Detection.windows 'error') { '检测失败' } elseif ($Detection.windows.isWindows11) { '正常' } else { '未配置' }
    $adminStatus = if (Get-ReportProperty $Detection.windows 'error') { '未检测' } else { '正常' }
    $codexStatus = if (Get-ReportProperty $Detection.codexDesktop 'error') { '检测失败' } elseif ($Detection.codexDesktop.installed) { '可用' } else { '未安装' }
    $terminalError = (Get-ReportProperty $Detection.windowsTerminal.app 'error')
    $terminalInstalled = $Detection.windowsTerminal.command.installed -or $Detection.windowsTerminal.app.installed
    $terminalStatus = if ($terminalError -and -not $terminalInstalled) { '检测失败' } elseif ($terminalInstalled) { '可用' } else { '未安装' }
    $wslStatus = if (Get-ReportProperty $Detection.wsl 'error') { '检测失败' } elseif (-not $Detection.wsl.installed) { '未安装' } elseif (-not $Detection.wsl.ubuntuWsl2) { '未配置' } else { '可用' }
    $wslNetwork = Get-ReportProperty $Detection 'wslNetwork'
    $wslNetworkStatus = if ($null -eq $wslNetwork) { '未检测' } elseif (Get-ReportProperty $wslNetwork 'error') { '检测失败' } elseif (Get-ReportProperty $wslNetwork 'mirroredConfigured' $false) { '可用' } else { '可优化' }
    $wslNetworkDetail = if ($null -eq $wslNetwork) { '' } else {
        $ports = @((Get-ReportProperty $wslNetwork 'loopbackListeners' @()) | ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
        "模式：$(Get-ReportProperty $wslNetwork 'networkingMode' 'unknown')$(if ($ports.Count -gt 0) { '；localhost 端口：' + ($ports -join '、') })"
    }
    $sandboxStatus = switch ($Detection.windowsSandboxFeature.state) {
        'Enabled' { '可用' }
        'Disabled' { '未配置' }
        default { if (Get-ReportProperty $Detection.windowsSandboxFeature 'error') { '需要管理员权限确认' } else { '未检测' } }
    }
    $pythonInstalled = $Detection.python.installed -or $Detection.pythonLauncher.installed
    $pythonStatus = if (-not $pythonInstalled -and ((Get-ReportProperty $Detection.python 'probeError') -or (Get-ReportProperty $Detection.pythonLauncher 'probeError'))) {
        '检测失败'
    } elseif ($pythonInstalled) { '可用' } else { '未安装' }
    return @(
        (New-DetectionSummaryRow 'Windows 11' $windowsStatus "$($Detection.windows.caption) build $($Detection.windows.build)"),
        (New-DetectionSummaryRow '当前权限' $adminStatus $(if ($Detection.windows.isAdministrator) { '管理员会话' } else { '标准权限会话；需要时会触发 UAC' })),
        (New-DetectionSummaryRow 'Codex Desktop' $codexStatus $codexDetail),
        (New-DetectionSummaryRow 'Windows Terminal' $terminalStatus $terminalVersion),
        (New-DetectionSummaryRow 'PowerShell 7' (Get-CommandSummaryStatus $Detection.powershell7) $Detection.powershell7.version),
        (New-DetectionSummaryRow 'Git (Windows)' (Get-CommandSummaryStatus $Detection.git) $Detection.git.version),
        (New-DetectionSummaryRow 'GitHub CLI' (Get-CommandSummaryStatus $Detection.githubCli) $Detection.githubCli.version),
        (New-DetectionSummaryRow 'WSL2 Ubuntu' $wslStatus $(if ($Detection.wsl.ubuntuName) { $Detection.wsl.ubuntuName } else { '未检测到' })),
        (New-DetectionSummaryRow 'WSL 网络' $wslNetworkStatus $wslNetworkDetail),
        (New-DetectionSummaryRow 'Windows Sandbox 可选功能' $sandboxStatus $Detection.windowsSandboxFeature.state),
        (New-DetectionSummaryRow 'Node.js' (Get-CommandSummaryStatus $Detection.node) $Detection.node.version),
        (New-DetectionSummaryRow 'fnm' (Get-CommandSummaryStatus $Detection.fnm) $Detection.fnm.version),
        (New-DetectionSummaryRow 'Python' $pythonStatus $(if ($Detection.python.version) { $Detection.python.version } else { $Detection.pythonLauncher.version })),
        (New-DetectionSummaryRow 'uv' (Get-CommandSummaryStatus $Detection.uv) $Detection.uv.version)
    )
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
    $rows = Convert-DetectionToSummaryRows -Detection $Detection
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Codex 开发环境检查结果')
    $lines.Add('')
    $lines.Add("- 本次编号：$($runtime.RunId)")
    $lines.Add("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $resultSummary = Get-CodexSetupResultSummary -Results $Results
    $lines.Add("- 本次操作：$(if ($WhatIfRun) { '预览（未修改任何设置）' } elseif ($resultSummary.total -eq 0) { '没有可执行的设置' } elseif ($resultSummary.failed -gt 0) { '设置未完全完成；请查看未完成项目' } elseif ($resultSummary.skipped -gt 0) { '设置已结束；有项目未执行' } else { '设置已完成' })")
    $detectionMode = Get-ReportProperty $Detection 'detectionMode' '完整'
    $healthLabel = Get-ReportProperty $Detection 'healthLabel' '未评级'
    $lines.Add("- 检测范围：**$detectionMode**")
    $lines.Add("- 核心环境可用性：**$healthLabel（$($Detection.healthScore)/100）**")
    $lines.Add('- 说明：该分数只衡量 Windows、终端、Git、Codex 与 WSL 等核心组件；不代表所有可选工具和个性化设置都已完成。')
    $setupActionCount = @($Plan.actions | Where-Object { (Get-ReportProperty $_ 'type' '') -notin @('WingetUpgradeCheck', 'AuthGuidance') }).Count
    $checkActionCount = @($Plan.actions | Where-Object { (Get-ReportProperty $_ 'type' '') -in @('WingetUpgradeCheck', 'AuthGuidance') }).Count
    $lines.Add("- 本次开始前：建议设置 **$setupActionCount 项**；检查或指引 **$checkActionCount 项**")
    if ($null -ne $Results -and $resultSummary.total -gt 0) {
        $lines.Add("- 本次结果：已完成 $($resultSummary.completed) 项；未完成 $($resultSummary.failed) 项；未执行 $($resultSummary.skipped) 项；预览 $($resultSummary.preview) 项")
    }
    $lines.Add('')
    $lines.Add('## 检查结果')
    $lines.Add('')
    $lines.Add('| 项目 | 状态 | 详情 |')
    $lines.Add('|---|---:|---|')
    foreach ($row in $rows) {
        $detail = ([string]$row.detail).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
        $lines.Add("| $($row.name) | $($row.status) | $detail |")
    }
    $lines.Add('')
    $lines.Add('### WSL/Linux 工具检查')
    $lines.Add('')
    $wslTools = Get-ReportProperty $Detection 'wslTools'
    if ($null -eq $wslTools) {
        $lines.Add('- 未检测：当前检测结果不包含 WSL 工具链信息。')
    }
    elseif (Get-ReportProperty $wslTools 'skipped' $false) {
        $lines.Add("- 已跳过：$(Get-ReportProperty $wslTools 'reason' '快速检测未启动 WSL 发行版。')")
    }
    elseif (Get-ReportProperty $wslTools 'error') {
        $lines.Add("- 检测失败：$(Get-ReportProperty $wslTools 'error')")
    }
    elseif (-not (Get-ReportProperty $wslTools 'available' $false)) {
        $lines.Add("- 未检测：$(Get-ReportProperty $wslTools 'reason' '没有可用的 WSL2 Ubuntu。')")
    }
    else {
        $toolDetails = Get-ReportProperty $wslTools 'tools'
        $lines.Add("- 发行版：$(Get-ReportProperty $wslTools 'distro' '未知')")
        foreach ($property in @($toolDetails.PSObject.Properties)) {
            $value = switch ([string]$property.Value) {
                'missing' { '未安装' }
                'windows-path' { '仅发现 Windows 入口；WSL/Linux 中建议单独安装' }
                'unavailable' { '入口存在但无法运行' }
                default { [string]$property.Value }
            }
            $lines.Add("- $($property.Name)：$value")
        }
    }
    $lines.Add('')
    $lines.Add('## 推荐的工作方式')
    $lines.Add('')
    $agentLabel = if ($Plan.recommendation.agent -eq 'WindowsNative') { 'Windows' } else { 'WSL/Linux' }
    $terminalLabel = switch ($Plan.recommendation.terminal) { 'PowerShell7' { 'PowerShell' } 'WSL' { 'WSL/Linux 终端' } default { $Plan.recommendation.terminal } }
    $lines.Add("- 建议工作方式：**$agentLabel**")
    $lines.Add("- 建议终端：**$terminalLabel**")
    foreach ($reason in $Plan.recommendation.reasons) { $lines.Add("- $reason") }
    $lines.Add('')
    $lines.Add('## 建议进行的设置')
    $lines.Add('')
    if ($null -eq $Results -or @($Results).Count -eq 0) {
        foreach ($action in $Plan.actions) { $lines.Add("- [建议] $($action.title)") }
    }
    else {
        foreach ($result in @($Results)) {
            $action = @($Plan.actions | Where-Object id -eq $result.id | Select-Object -First 1)
            $actionTitle = if ($action.Count -gt 0) { $action[0].title } else { $result.id }
            $resultDetail = Get-ReportProperty $result 'detail'
            $detailSummary = if ($null -ne $resultDetail) { Get-ReportProperty $resultDetail 'summary' } else { $null }
            $suffix = if ($result.error) { " — $($result.error)" } elseif ($detailSummary) { " — $detailSummary" } else { '' }
            $lines.Add("- [$(Get-ReportResultStatus $result.status)] $actionTitle$suffix")
        }
    }
    if ($null -ne $RemainingPlan) {
        $remainingActions = @((Get-ReportProperty $RemainingPlan 'actions' @()))
        $lines.Add('')
        $lines.Add('## 仍可继续设置')
        $lines.Add('')
        if ($remainingActions.Count -eq 0) {
            $lines.Add('- 本次快速复核后，没有新的待设置项目。')
        }
        else {
            foreach ($action in $remainingActions) { $lines.Add("- [待设置] $($action.title)") }
        }
    }
    if ($null -ne $VerificationDetection) {
        $lines.Add('')
        $lines.Add('## 本次快速复核')
        $lines.Add('')
        $lines.Add("- 已于 $(Get-ReportProperty $VerificationDetection 'detectedAt' (Get-Date -Format 'o')) 重新检查 Windows 侧核心工具。")
        $verificationHealthLabel = Get-ReportProperty $VerificationDetection 'healthLabel' '未评级'
        $lines.Add("- 设置后的核心环境可用性：**$verificationHealthLabel（$($VerificationDetection.healthScore)/100）**")
        $lines.Add('- 已完成的项目不会因为终端尚未刷新 PATH 而再次列为待设置；重新打开终端后即可使用新安装的命令。')
        if ((Get-ReportProperty $VerificationDetection 'detectionMode' '') -ne '完整') {
            $lines.Add('- WSL/Linux 工具链未在本次快速复核中再次启动；其执行结果已单独保留在上方。')
        }
    }
    $lines.Add('')
    $lines.Add('## 验证并开始使用')
    $lines.Add('')
    if ($WhatIfRun) {
        $lines.Add('1. 本次只是预览，没有修改电脑。')
        $lines.Add('2. 返回工具首页选择“开始设置开发环境”，再按提示确认需要的项目。')
    }
    elseif ($resultSummary.failed -gt 0) {
        $lines.Add('1. 先查看上方标记为“未完成”的项目。')
        $lines.Add('2. 处理提示的问题后重新运行设置；工具会重新检查当前状态。')
    }
    elseif ($resultSummary.skipped -gt 0) {
        $lines.Add('1. 本次有项目未执行；当前环境可能尚未完整准备。')
        $lines.Add('2. 查看上方结果，确认是否需要返回首页继续设置。')
    }
    elseif ($resultSummary.total -eq 0) {
        $lines.Add('本次没有可执行项目；请查看上方提示后再决定是否重试。')
    }
    else {
        $lines.Add('1. 关闭并重新打开 Windows Terminal 和 Codex Desktop，让新设置生效。')
        if ($Plan.recommendation.agent -eq 'WindowsNative') {
            $lines.Add('2. 在 Codex Desktop Settings 中选择 **Windows** 工作方式和 **PowerShell** 终端。')
            $lines.Add('3. 打开 Windows Terminal 的 **Codex Windows (PowerShell 7)**，运行 `git --version`、`node --version`、`python --version`。')
            $lines.Add("4. 在 Windows 项目文件夹 $($Config.paths.windowsProjects) 中新建或打开项目，然后交给 Codex。")
        }
        else {
            $lines.Add('2. 在 Codex Desktop Settings 中选择 **WSL/Linux** 工作方式和 **WSL/Linux 终端**。')
            $lines.Add('3. 打开 Windows Terminal 的 **Codex WSL (Ubuntu)**，运行 `git --version`、`node --version`、`python3 --version`。')
            $lines.Add("4. 在 Linux 的 $($Config.paths.wslProjects) 文件夹中新建或打开项目，然后交给 Codex。")
        }
        $lines.Add('5. 三条命令都显示版本号，即表示主要开发环境可用。')
        $lines.Add('6. 如需使用 GitHub，运行 `gh auth status`；尚未登录时运行 `gh auth login`。')
    }
    if ($Plan.warnings.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## 需要留意')
        $lines.Add('')
        foreach ($warning in $Plan.warnings) { $lines.Add("- $warning") }
    }
    $pathConflicts = @(Get-ReportProperty $Detection.path 'conflicts' (Get-ReportProperty $Detection.path 'shadowedTools' @()))
    $duplicateEntrypoints = @(Get-ReportProperty $Detection.path 'duplicateEntrypoints' @())
    $appAliases = @(Get-ReportProperty $Detection.path 'appAliases' @())
    $pathDuplicates = @(Get-ReportProperty $Detection.path 'duplicates' @())
    $pathMissing = @(Get-ReportProperty $Detection.path 'missing' @())
    if ($pathConflicts.Count -gt 0 -or $duplicateEntrypoints.Count -gt 0 -or $appAliases.Count -gt 0 -or $pathDuplicates.Count -gt 0 -or $pathMissing.Count -gt 0) {
        $lines.Add('')
        $lines.Add('### 命令来源检查')
        $lines.Add('')
        foreach ($item in $pathConflicts) { $lines.Add("- **需要处理 · 同一命令来自不同安装位置**：$($item.tool)：$($item.paths -join '；')") }
        foreach ($item in $pathMissing) { $lines.Add("- **需要留意 · 已不存在的命令目录**：$($item.raw)（$($item.scope)）") }
        foreach ($item in $duplicateEntrypoints) { $lines.Add("- 补充说明 · 同一软件有多个入口：$($item.tool)：$($item.paths -join '；')") }
        foreach ($item in $appAliases) { $lines.Add("- 补充说明 · Windows 应用快捷入口：$($item.tool)：$($item.paths -join '；')") }
        foreach ($item in $pathDuplicates) { $lines.Add("- 补充说明 · 重复的命令目录：$($item.normalized)（$($item.locations -join ', ')）") }
    }
    $detectionIssues = @(Get-ReportProperty $Detection 'issues' @())
    if ($detectionIssues.Count -gt 0) {
        $lines.Add('')
        $lines.Add('### 未完成的检查')
        $lines.Add('')
        foreach ($issue in $detectionIssues) { $lines.Add("- $($issue.name)：$($issue.error)") }
    }
    $lines.Add('')
    $lines.Add('## 在 Codex Desktop 中确认设置')
    $lines.Add('')
    $lines.Add('1. 打开 Codex Desktop 的 Settings。')
    $lines.Add("2. 工作方式选择 **$agentLabel**；更改后重启 Codex。")
    $lines.Add("3. 终端选择 **$terminalLabel**；新建终端或重启 Codex 后生效。")
    $lines.Add('4. 默认只允许 Codex 修改当前项目；只有完全信任的个人项目，才考虑开启更高权限。')
    $lines.Add('5. GitHub 功能需要 Windows 原生 Git；完成 `gh auth login` 后重新打开应用。')
    $lines.Add('')
    $lines.Add('## 项目放在哪里更合适')
    $lines.Add('')
    $lines.Add("- Windows 专属项目：$($Config.paths.windowsProjects)，使用 Windows + PowerShell。")
    $lines.Add("- Web、Python 或跨平台项目：WSL 的 $($Config.paths.wslProjects)，使用 WSL/Linux。")
    $lines.Add('- 不要在 Windows 和 WSL/Linux 之间共用同一项目副本、`node_modules` 或 `.venv`。')
    $lines.Add('- Codex Desktop worktrees 由应用管理；Git 仓库、锁文件和环境初始化脚本必须可在 worktree 中重建环境。')
    $lines.Add('')
    $lines.Add('## 可能还需要重启或重新登录')
    $lines.Add('')
    foreach ($item in $Plan.requiresRestart) { $lines.Add("- $item") }
    $lines.Add('')
    $lines.Add('## 安全说明')
    $lines.Add('')
    $lines.Add('- 本脚本不读取或记录 API Key、访问令牌、SSH 私钥、浏览器凭据或 `.env` 内容。')
    $lines.Add('- MCP、插件和技能不在第一版管理范围。')
    $lines.Add('- 现有仓库不会自动迁移；只给出位置和 Agent 建议。')
    $lines.Add(('- 当前选择 sandbox_mode = "{0}"。完全访问会扩大数据损失风险，只用于可信项目。' -f $Config.codex.sandboxMode))
    $lines.Add('')
    $lines.Add('## 结果文件与撤销')
    $lines.Add('')
    $lines.Add("- 详细记录：$($runtime.LogPath)")
    $lines.Add("- 撤销清单：$($runtime.ManifestPath)")
    $lines.Add('- 撤销会恢复本次备份的文件，并可选择卸载本次安装的软件。WSL/Linux 软件、版本转换和登录状态需要你自行确认。')
    $content = $lines -join [Environment]::NewLine
    Set-Content -LiteralPath $runtime.SummaryPath -Value $content -Encoding utf8
    $Detection | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'detection.json') -Encoding utf8
    $Plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'plan.json') -Encoding utf8
    if ($null -ne $Results) { $Results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runtime.RunRoot 'results.json') -Encoding utf8 }
    Write-SetupLog -Message '最终报告已生成' -Data @{ path=$runtime.SummaryPath }
    return $runtime.SummaryPath
}

Export-ModuleMember -Function @('New-CodexSetupReport', 'Get-CodexSetupResultSummary', 'Get-CodexSetupPendingActionCount')
