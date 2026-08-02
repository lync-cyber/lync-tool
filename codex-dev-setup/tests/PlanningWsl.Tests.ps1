#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\CodexSetup.Common.psm1') -Force
Import-Module (Join-Path $root 'modules\CodexSetup.Planning.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}

function New-ReadyDetection {
    $available = [pscustomobject]@{ installed=$true; probeError=$null }
    return [pscustomobject]@{
        windows=[pscustomobject]@{ isWindows11=$true; isAdministrator=$false; build=22631 }
        path=[pscustomobject]@{ conflicts=@(); shadowedTools=@(); duplicateEntrypoints=@(); appAliases=@(); duplicates=@(); missing=@() }
        powershell7=$available; winget=$available; git=$available; githubCli=$available
        windowsTerminal=[pscustomobject]@{ command=$available; app=[pscustomobject]@{ installed=$true; error=$null } }
        codexDesktop=[pscustomobject]@{ installed=$true; error=$null }
        fnm=$available; uv=$available
        wsl=[pscustomobject]@{ installed=$true; ubuntu=$true; ubuntuWsl2=$true; ubuntuName='Ubuntu-Test'; error=$null }
        wslNetwork=[pscustomobject]@{ networkingMode='nat'; mirroredConfigured=$false; loopbackListeners=@(); recommendedHttpPort=10808; recommendedSocksPort=10808; error=$null }
        wslTools=[pscustomobject]@{
            available=$true; skipped=$false; error=$null; aptPackagesMissing=@()
            codeRootExists=$true; managedBlockPresent=$true; managedBlockSharesCodexHome=$false; sudoAvailable=$true
            tools=[pscustomobject]@{ fnm='fnm 1'; node='v24'; uv='uv 1'; python3='Python 3'; fd='fd 10' }
        }
        project=[pscustomobject]@{ agent='WSL'; terminal='WSL'; reasons=@('test') }
        healthScore=100; healthLabel='状态良好'; detectionMode='完整'; issues=@()
    }
}

$config = Read-SetupConfig -Path (Join-Path $root 'config\defaults.json')
$config.preferences.updatePolicy = 'Never'
$readyDetection = New-ReadyDetection
$readyPlan = Get-CodexSetupPlan -Detection $readyDetection -Config $config
Assert-True (@($readyPlan.actions | Where-Object id -eq 'ConfigureWsl').Count -eq 0) 'WSL 已齐全时不应重复生成整套配置动作。'
Assert-True (@($readyPlan.skipped | Where-Object { $_ -match 'WSL/Linux 开发工具已准备好' }).Count -eq 1) 'WSL 已齐全时应给出明确说明。'

$missingDetection = New-ReadyDetection
$missingDetection.wslTools.aptPackagesMissing = @('jq')
$missingDetection.wslTools.tools.fnm = 'missing'
$missingDetection.wslTools.tools.node = 'missing'
$missingPlan = Get-CodexSetupPlan -Detection $missingDetection -Config $config
$wslAction = @($missingPlan.actions | Where-Object id -eq 'ConfigureWsl' | Select-Object -First 1)
Assert-True ($wslAction.Count -eq 1) 'WSL 有缺失项时应生成配置动作。'
Assert-True ($wslAction[0].parameters.installNode -and -not $wslAction[0].parameters.installPython) 'WSL 参数应只启用缺少的语言工具链。'
Assert-True ($wslAction[0].reason -match '已具备的工具不会重复安装') 'WSL 计划应解释只处理缺失项。'

$noSudoDetection = New-ReadyDetection
$noSudoDetection.wslTools.aptPackagesMissing = @('jq')
$noSudoDetection.wslTools.sudoAvailable = $false
$noSudoPlan = Get-CodexSetupPlan -Detection $noSudoDetection -Config $config
Assert-True (@($noSudoPlan.actions | Where-Object id -eq 'ConfigureWsl').Count -eq 0) '缺少 sudo 且需要系统包时，不应进入注定失败的 WSL 设置。'
Assert-True (@($noSudoPlan.warnings | Where-Object { $_ -match '避免留下只完成一部分' }).Count -eq 1) '缺少 sudo 时应解释为何暂不执行。'

$networkDetection = New-ReadyDetection
$config.wslNetworking.configure = $true
$config.wslNetworking.proxyMode = 'persistent'
$networkPlan = Get-CodexSetupPlan -Detection $networkDetection -Config $config
$networkAction = @($networkPlan.actions | Where-Object id -eq 'ConfigureWslNetwork' | Select-Object -First 1)
Assert-True ($networkAction.Count -eq 1) '用户明确选择后应生成 WSL 网络配置动作。'
Assert-True ($networkAction[0].reason -match '127\.0\.0\.1' -and $networkAction[0].reason -match '不会开启 v2rayN LAN') '网络计划应解释 mirrored loopback 的安全边界。'
Assert-True (@($networkPlan.warnings | Where-Object { $_ -match '先启动 v2rayN' }).Count -eq 1) '持久代理计划应提醒 v2rayN 生命周期依赖。'

Write-Host 'WSL 计划检查通过：10 项' -ForegroundColor Green
