[CmdletBinding()]
param([switch]$InstallPowerShell7)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$entry = Join-Path $root 'Start-CodexSetup.ps1'
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwsh) { $pwsh.Source } else { $null }

if (-not $pwsh) {
    Write-Host '需要先安装 PowerShell 7，才能打开开发环境助手。' -ForegroundColor Yellow
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host '未找到 WinGet。请先更新或修复 Microsoft App Installer，然后再试。' -ForegroundColor Red
        Write-Host '帮助：https://learn.microsoft.com/windows/package-manager/winget/'
        exit 1
    }
    if (-not $InstallPowerShell7) {
        $answer = Read-Host '现在通过 WinGet 安装 PowerShell 7 吗？[y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host '未作任何更改。准备好后再次运行此文件即可。'
            exit 0
        }
    }
    & $winget.Source install --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 安装失败（退出代码：$LASTEXITCODE）。" }
    $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath)) {
        Write-Host 'PowerShell 7 已安装。请重新双击 Launch-CodexSetup.cmd 打开助手。' -ForegroundColor Green
        exit 0
    }
}

& $pwshPath -NoLogo -NoProfile -File $entry
exit $LASTEXITCODE
