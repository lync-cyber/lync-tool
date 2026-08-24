Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Invoke-Windows11Acceptance.ps1'
$text = Get-Content -LiteralPath $scriptPath -Raw

function Assert-Contract {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-Contract ($text.Contains('[switch]$ConfirmManualDesktopSettings')) 'Desktop evidence lacks explicit manual settings attestation.'
Assert-Contract ($text.Contains('channelOriginMachineVerified=$false')) 'Desktop channel origin must not be reported as machine verified.'
Assert-Contract ($text.Contains('repoWorkingTreeSha256')) 'Preflight does not bind the repository working tree.'
Assert-Contract ($text.Contains('artifactChain')) 'Acceptance stages are not bound by an artifact chain.'
Assert-Contract ($text.Contains("baselineRestored='desktop-BaselineRestored-final.json'")) 'Report does not require the BaselineRestored artifact.'
Assert-Contract ($text.Contains('distinctFromPriorScenarios=$screenshotDistinct')) 'Desktop screenshots are not required to differ by scenario.'
Assert-Contract ($text.Contains('$now.AddMinutes(-10)')) 'Desktop screenshots lack a maximum age.'
Assert-Contract ($text.Contains('initialApplyStartedAt')) 'Initial mutating Apply lacks a non-overwrite reservation.'
Assert-Contract ($text.Contains("'final-reapply-baseline.json'")) 'Final reapply lacks an independent baseline artifact.'
Assert-Contract ($text.Contains('managedFilesMatchFinalApply=$managedFilesReady')) 'Report does not revalidate managed files.'
Assert-Contract ($text.Contains('baselinePackagesPreserved=$baselinePackagesPreserved')) 'Report does not revalidate package safety.'
Assert-Contract (-not $text.Contains('contentMachineVerified=$true')) 'GUI screenshot content must not be reported as machine verified.'

Write-Host 'PASS: Windows acceptance integrity, attestation, freshness, and final-state contracts'
