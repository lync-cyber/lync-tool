#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failed = $false

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1', '*.psm1') {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "FAIL $($file.FullName)" -ForegroundColor Red
        foreach ($errorItem in $errors) { Write-Host "  line $($errorItem.Extent.StartLineNumber): $($errorItem.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "PASS $($file.Name)" -ForegroundColor Green
    }
    $ambiguousQuotes = @($tokens | Where-Object {
        $_.Kind -eq [Management.Automation.Language.TokenKind]::StringExpandable -and $_.Text -match '[“”]'
    })
    if ($ambiguousQuotes.Count -gt 0) {
        $failed = $true
        foreach ($token in $ambiguousQuotes) {
            Write-Host "FAIL $($file.FullName):$($token.Extent.StartLineNumber) uses curly quotes as expandable-string delimiters" -ForegroundColor Red
        }
    }
}

try {
    Get-Content -LiteralPath (Join-Path $root 'config\defaults.json') -Raw -Encoding utf8 | ConvertFrom-Json | Out-Null
    Write-Host 'PASS defaults.json' -ForegroundColor Green
}
catch {
    $failed = $true
    Write-Host "FAIL defaults.json: $($_.Exception.Message)" -ForegroundColor Red
}

$bootstrapPath = Join-Path $root 'Bootstrap-CodexSetup.ps1'
$bootstrapBytes = [System.IO.File]::ReadAllBytes($bootstrapPath)
if ($bootstrapBytes.Length -ge 3 -and $bootstrapBytes[0] -eq 0xEF -and $bootstrapBytes[1] -eq 0xBB -and $bootstrapBytes[2] -eq 0xBF) {
    Write-Host 'PASS Bootstrap-CodexSetup.ps1 keeps its Windows PowerShell UTF-8 BOM' -ForegroundColor Green
}
else {
    $failed = $true
    Write-Host 'FAIL Bootstrap-CodexSetup.ps1 must keep a UTF-8 BOM for Windows PowerShell 5.1' -ForegroundColor Red
}

if ($failed) { exit 1 }
