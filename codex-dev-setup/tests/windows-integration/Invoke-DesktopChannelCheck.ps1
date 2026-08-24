#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Agent', 'Terminal')]
    [string]$Channel,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')]
    [string]$RunId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$Nonce,
    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$resolved = [System.IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $resolved
if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
$command = Get-Command codex-env-check -ErrorAction SilentlyContinue | Select-Object -First 1
$exitCode = 127
$output = @()
if ($command) {
    $output = @(& $command.Source --json 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
}
$jsonLine = @($output | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
if ($jsonLine.Count -eq 1) {
    try { $verifier = $jsonLine[0] | ConvertFrom-Json -ErrorAction Stop }
    catch { $verifier = $null }
}
else { $verifier = $null }
$evidence = [ordered]@{
    schemaVersion=2
    captureType='CodexDesktopChannelEvidence'
    runId=$RunId
    nonce=$Nonce
    channel=$Channel
    capturedAt=(Get-Date).ToUniversalTime().ToString('o')
    hostProcessId=$PID
    command='codex-env-check --json'
    commandPath=$(if ($command) { [string]$command.Source } else { $null })
    exitCode=$(if ($command) { $exitCode } else { 127 })
    os=$(if ($IsLinux) { 'Linux' } elseif ($IsWindows) { 'Windows_NT' } else { 'Unknown' })
    shell=$(if ($IsLinux) { [string]$env:SHELL } else { 'PowerShell' })
    workingDirectory=(Get-Location).Path
    verifier=$verifier
    error=$(if ($null -ne $verifier) { $null } elseif ($command) { 'command-returned-no-json' } else { 'command-not-found' })
}
$json = ($evidence | ConvertTo-Json -Depth 30).TrimEnd("`r", "`n") + [Environment]::NewLine
[System.IO.File]::WriteAllText($resolved, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Desktop $Channel channel evidence: $resolved"
exit $evidence.exitCode
