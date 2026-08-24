Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

$sourceFiles = @(
    Get-ChildItem -LiteralPath $root -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $root 'modules') -File -Filter '*.psm1'
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1' -Recurse
)

foreach ($file in $sourceFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($parseError in $errors) {
        $failures.Add("$($file.FullName): $($parseError.Message)")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "PASS: parsed $($sourceFiles.Count) PowerShell files"
& (Join-Path $PSScriptRoot 'V2Contract.Tests.ps1')
& (Join-Path $PSScriptRoot 'windows-integration\AcceptanceContract.Tests.ps1')
Write-Host 'All PowerShell static contract tests passed.'
