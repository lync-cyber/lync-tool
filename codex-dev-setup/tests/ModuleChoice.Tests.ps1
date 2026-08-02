#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'modules\CodexSetup.Common.psm1') -Force

function Assert-Choice {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Choice,
        [bool]$ApplyRemainingOrdinary = $false,
        [bool]$RequiresSeparateConfirmation = $false
    )
    if ($Actual.choice -ne $Choice -or
        $Actual.applyRemainingOrdinary -ne $ApplyRemainingOrdinary -or
        $Actual.requiresSeparateConfirmation -ne $RequiresSeparateConfirmation) {
        throw "Unexpected choice result: $($Actual | ConvertTo-Json -Compress)"
    }
}

Assert-Choice (Resolve-SetupModuleChoice -Answer 'Y') -Choice 'ApplyModule'
Assert-Choice (Resolve-SetupModuleChoice -Answer 'A') -Choice 'ApplyModule' -ApplyRemainingOrdinary $true
Assert-Choice (Resolve-SetupModuleChoice -Answer 'A' -HasCriticalAction $true) -Choice 'ApplyModule' -ApplyRemainingOrdinary $true -RequiresSeparateConfirmation $true
Assert-Choice (Resolve-SetupModuleChoice -Answer '') -Choice 'SkipModule'
Assert-Choice (Resolve-SetupModuleChoice -Answer 'S') -Choice 'SkipModule'
Assert-Choice (Resolve-SetupModuleChoice -Answer 'Q') -Choice 'Quit'

Write-Host 'PASS module confirmation choices preserve safe defaults and critical-module confirmation' -ForegroundColor Green
