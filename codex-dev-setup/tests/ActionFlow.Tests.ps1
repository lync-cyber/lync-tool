#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\CodexSetup.Common.psm1') -Force
Import-Module (Join-Path $root 'modules\CodexSetup.Actions.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}

$actionsModule = Get-Module CodexSetup.Actions
$installedVersion = & $actionsModule {
    Get-WingetPackageVersionFromLines -Lines @('PowerShell Microsoft.PowerShell 7.6.4.0 winget') -PackageId 'Microsoft.PowerShell'
}
$availableVersion = & $actionsModule {
    Get-WingetPackageVersionFromLines -Lines @('PowerShell Microsoft.PowerShell 7.6.3.0 7.6.4.0 winget') -PackageId 'Microsoft.PowerShell' -VersionKind Available
}
$noAvailableVersion = & $actionsModule {
    Get-WingetPackageVersionFromLines -Lines @('PowerShell Microsoft.PowerShell 7.6.4.0 winget') -PackageId 'Microsoft.PowerShell' -VersionKind Available
}
Assert-True ($installedVersion -eq '7.6.4.0') 'WinGet 结果应解析已安装版本。'
Assert-True ($availableVersion -eq '7.6.4.0' -and $null -eq $noAvailableVersion) 'WinGet 结果应仅在确有更新时解析待更新版本。'

$config = [pscustomobject]@{}
$plan = [pscustomobject]@{
    actions = @(
        [pscustomobject]@{
            module='Node'; id='Fnm'; title='模拟前置步骤失败'; type='ExpectedTestFailure'
            target='test'; critical=$false; dependsOn=@(); parameters=[pscustomobject]@{}
        },
        [pscustomobject]@{
            module='Node'; id='ConfigureNodeLts'; title='不应继续的后续步骤'; type='ExpectedBlockedAction'
            target='test'; critical=$false; dependsOn=@('Fnm'); parameters=[pscustomobject]@{}
        }
    )
}

$results = @(Invoke-CodexSetupPlan -Plan $plan -Config $config -NonInteractive -Confirm:$false)
Assert-True ($results.Count -eq 2) '每个动作都应产生明确结果。'
Assert-True ($results[0].status -eq 'Failed') '前置步骤失败应记录为未完成。'
Assert-True ($results[1].status -eq 'Skipped' -and $results[1].error -match '前置步骤未完成') '依赖项失败后不得继续执行后续步骤。'
Assert-True ($results[0].PSObject.Properties.Name -contains 'durationMs') '执行结果应包含耗时。'

$actionsText = Get-Content -LiteralPath (Join-Path $root 'modules\CodexSetup.Actions.psm1') -Raw -Encoding utf8
Assert-True ($actionsText -match "'进行中'") '实际执行必须与预览状态区分。'
Assert-True ($actionsText -match 'exit=77') 'WSL 密码失败应转换为可恢复的用户提示。'
Assert-True ($actionsText -match 'exit=79' -and $actionsText -match '不完整或重复的 Codex 管理区块') '损坏的 WSL 终端配置应转换为保护性提示。'
Assert-True ($actionsText -match 'Invoke-InteractiveExternalSetupCommand') 'WSL 安装必须继承当前终端的输入与输出。'
Assert-True ($actionsText -match '已添加两个 Windows Terminal 启动项') '终端设置完成后应说明新增了哪些入口。'
Assert-True ($actionsText -match '已添加 PowerShell 7 快捷功能') 'PowerShell 设置完成后应说明新增了哪些快捷功能。'
Assert-True ($actionsText -match 'Select-CodexConfigurationPreset') 'Codex 设置应提供面向用途的自定义分支。'
Assert-True ($actionsText -match '使用推荐设置.*选择工作方式') 'Codex 模块提示应明确区分推荐设置和自定义选择。'
Assert-True ($actionsText -match '工作步骤.*moduleIndex') '实际设置过程应按工作步骤显示模块编号。'
Assert-True ($actionsText -match '登录说明') 'GitHub 登录帮助不应显示为正在执行系统设置。'
Assert-True ($actionsText -match "@\('list', '--id'.*'--exact'\)") '软件更新必须使用只读的 WinGet list 查询。'
Assert-True ($actionsText -notmatch "@\('upgrade', '--id'") '软件更新检查不得调用会执行升级的 WinGet upgrade。'
Assert-True ($actionsText -match '更新检查摘要') '软件更新检查后应显示有更新、无更新和无法确认的汇总。'
Assert-True ($actionsText -match '已安装.*检测到待更新版本' -and $actionsText -match 'installedVersion') '安装与更新结果应记录具体版本。'
Assert-True ($actionsText -match 'fallbackVersion -match' -and $actionsText -match 'fallbackVersion = \$matches\[0\]') '命令探测到的备用版本应去掉构建哈希等冗余文本。'
Assert-True ($actionsText -match "preflightArguments -Quiet") 'WSL 网络预检应静默执行，避免重复显示预览和完成摘要。'
Assert-True ($actionsText -match 'Resolve-SetupCommandPath' -and $actionsText -match 'Schniz\.fnm') '新安装的便携工具应复用公共定位逻辑立即找到。'
Assert-True ($actionsText -match 'Get-WingetInstalledPackage' -and $actionsText -match '为避免误卸载') '只有确认由本次新增的软件包才应登记为可回滚安装。'

Write-Host '动作流程检查通过：23 项' -ForegroundColor Green
