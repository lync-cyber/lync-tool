#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$modules = Join-Path $root 'modules'
foreach ($name in @('CodexSetup.Common.psm1', 'CodexSetup.Reporting.psm1')) {
    Import-Module (Join-Path $modules $name) -Force
}

$script:Passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    $script:Passed++
    Write-Host "PASS $Message" -ForegroundColor Green
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-result-summary-" + [guid]::NewGuid().ToString('N'))
try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $results = @(
        [pscustomobject]@{ id='Fd'; status='Completed'; error=$null },
        [pscustomobject]@{ id='ConfigureWsl'; status='Failed'; error='sudo 验证失败' },
        [pscustomobject]@{ id='TerminalProfiles'; status='Skipped'; error=$null },
        [pscustomobject]@{ id='CheckGit'; status='Preview'; error=$null; detail=[pscustomobject]@{ summary='已安装 2.50.1；检测到待更新版本 2.51.0；本次未安装' } }
    )
    $summary = Get-CodexSetupResultSummary -Results $results
    Assert-True ($summary.total -eq 4 -and $summary.completed -eq 1 -and $summary.failed -eq 1 -and $summary.skipped -eq 1 -and $summary.preview -eq 1) 'result summary keeps completed, failed, skipped, and preview separate'

    $plan = [pscustomobject]@{
        recommendation=[pscustomobject]@{ agent='WSL'; terminal='WSL'; reasons=@('test') }
        actions=@(
            [pscustomobject]@{ id='Fd'; title='安装 fd（快速查找文件）' },
            [pscustomobject]@{ id='ConfigureWsl'; title='准备 WSL/Linux 开发工具' },
            [pscustomobject]@{ id='TerminalProfiles'; title='创建 Codex Terminal 配置' }
        )
        warnings=@()
        requiresRestart=@()
    }
    $remainingPlan = [pscustomobject]@{
        actions=@([pscustomobject]@{ id='TerminalProfiles'; title='创建 Codex Terminal 配置' })
    }
    Assert-True ((Get-CodexSetupPendingActionCount -Plan $plan) -eq 3) 'pending action count is distinct from core health score'

    $available = [pscustomobject]@{ installed=$true; version='test'; probeError=$null }
    $detection = [pscustomobject]@{
        healthScore=100; healthLabel='状态良好'; detectionMode='完整'; detectedAt='2026-08-02T12:00:00+08:00'
        windows=[pscustomobject]@{ isWindows11=$true; isAdministrator=$false; caption='Windows 11'; build='test'; error=$null }
        codexDesktop=[pscustomobject]@{ installed=$true; error=$null; packages=@([pscustomobject]@{ Name='Codex'; Version='test' }) }
        windowsTerminal=[pscustomobject]@{ command=$available; app=[pscustomobject]@{ installed=$true; error=$null; packages=@() } }
        powershell7=$available; git=$available; githubCli=$available; node=$available; fnm=$available; python=$available; pythonLauncher=$available; uv=$available
        wsl=[pscustomobject]@{ installed=$true; ubuntuWsl2=$true; ubuntuName='Ubuntu'; error=$null }
        wslTools=[pscustomobject]@{
            skipped=$false; available=$true; error=$null; reason=$null; distro='Ubuntu-Test'
            githubAuthStatus='authenticated'
            configuredPackageGroups=@([pscustomobject]@{ label='Linux 基础工具' })
            packages=[pscustomobject]@{ gh=[pscustomobject]@{ status='installed'; version='2.45.0-1ubuntu0.3' } }
            tools=[pscustomobject]@{ gh='gh version 2.45.0'; git='git version 2.43.0' }
        }
        windowsSandboxFeature=[pscustomobject]@{ state='Disabled'; error=$null }
        path=[pscustomobject]@{ conflicts=@(); shadowedTools=@(); duplicateEntrypoints=@(); appAliases=@(); duplicates=@(); missing=@() }
        issues=@()
    }
    $config = [pscustomobject]@{ codex=[pscustomobject]@{ sandboxMode='workspace-write' }; paths=[pscustomobject]@{ windowsProjects='C:\source'; wslProjects='~/code' } }
    Initialize-SetupRuntime -RunId 'result-summary-test' -StateRoot $testRoot | Out-Null
    $reportPath = New-CodexSetupReport -Detection $detection -Plan $plan -Results $results -Config $config -WhatIfRun:$false -RemainingPlan $remainingPlan -VerificationDetection $detection
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8
    Assert-True ($report -match '核心环境可用性：\*\*状态良好（100/100）\*\*') 'report labels 100 points as core availability'
    Assert-True ($report -match '本次结果：已完成 1 项；未完成 1 项；未执行 1 项；预览 1 项') 'report does not turn a partial run into all completed'
    Assert-True ($report -match '仍可继续设置' -and $report -match '创建 Codex Terminal 配置') 'report shows only remaining settings after verification'
    Assert-True ($report -match '本次快速复核') 'report records the post-apply verification'
    Assert-True ($report -match '已安装 2\.50\.1；检测到待更新版本 2\.51\.0；本次未安装') 'report preserves installed and available versions from update checks'
    Assert-True ($report -match 'GitHub 登录（WSL/Linux）：已登录' -and $report -match 'gh version 2\.45\.0' -and $report -match 'APT gh：2\.45\.0-1ubuntu0\.3') 'report shows Linux gh package, command version, and authentication status'
    Assert-True ($report -match '验证并开始使用' -and $report -match '先查看上方标记为“未完成”的项目') 'report gives recovery steps when setup is incomplete'

    $startScript = Get-Content -LiteralPath (Join-Path $root 'Start-CodexSetup.ps1') -Raw -Encoding utf8
    Assert-True ($startScript -match '(?s)\$remainingActions\s*=\s*@\(\s*if \(\$null -ne \$remainingPlan\)') 'completion page preserves an array when exactly one action remains'
    Assert-True ($startScript -match "接下来" -and $startScript -match '上述命令都显示版本号' -and $startScript -match 'gh --version' -and $startScript -match 'gh auth status') 'successful completion page explains how to verify and start using the environment'
    Assert-True ($startScript -match '\$Config' -and $startScript -match '\$windowsProjects' -and $startScript -match '\$wslProjects') 'completion page uses configured project paths'
    Assert-True ($startScript -match '本次有项目未执行；当前环境可能尚未完整准备') 'skipped actions do not receive an all-success getting-started message'
    Assert-True ($startScript -match '\$_\.id -in \$originalActionIds') 'quick verification cannot invent actions outside the original full-detection plan'
}
finally {
    Complete-SetupRuntime -Succeeded:$true
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "All $script:Passed result-summary assertions passed." -ForegroundColor Cyan
