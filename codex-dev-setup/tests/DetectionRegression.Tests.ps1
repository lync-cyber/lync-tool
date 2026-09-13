Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Called by SetupBehavior.Tests.ps1, which supplies Assert-True.
& {
    $testRoot = Split-Path -Parent $PSScriptRoot
    $commonPath = Join-Path $testRoot 'modules/CodexSetup.Common.psm1'
    $detectionPath = Join-Path $testRoot 'modules/CodexSetup.Detection.psm1'
    Import-Module $commonPath -Force
    Import-Module $detectionPath -Force
    $testConfig = Read-SetupConfig -Path (Join-Path $testRoot 'config/defaults.json')
    $testConfig.wsl.distribution = 'Ubuntu-24.04'
    try {
        $detection = Get-Module 'CodexSetup.Detection'
        $listCases = @(
            @{ label='legacy Chinese empty list'; code=-1; output='适用于 Linux 的 Windows 子系统没有已安装的分发。'; expected='NoDistribution'; enabled=$null }
            @{ label='legacy English empty list'; code=-1; output='Windows Subsystem for Linux has no installed distributions.'; expected='NoDistribution'; enabled=$null }
            @{ label='symbolic empty list'; code=-1; output='错误代码: Wsl/WSL_E_DEFAULT_DISTRO_NOT_FOUND'; expected='NoDistribution'; enabled=$null }
            @{ label='empty success'; code=0; output=''; expected='Unknown'; enabled=$true }
            @{ label='header only'; code=0; output='  NAME            STATE           VERSION'; expected='Unknown'; enabled=$true }
            @{ label='arbitrary failure'; code=-1; output='WSL service failed'; expected='Unknown'; enabled=$true }
            @{ label='disabled legacy component does not hide errors'; code=-1; output='Access denied'; expected='Unknown'; enabled=$false }
            @{ label='explicit missing optional component'; code=-1; output='Error code: Wsl/WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED'; expected='FeatureDisabled'; enabled=$null }
            @{ label='explicit missing virtual machine platform'; code=-1; output='Error code: Wsl/Service/CreateVm/WSL_E_VIRTUAL_MACHINE_PLATFORM_REQUIRED'; expected='FeatureDisabled'; enabled=$null }
            @{ label='Store WSL2 without WSL1 component'; code=0; output="  NAME            STATE           VERSION`n* Ubuntu-24.04    Stopped         2"; expected='Ready'; enabled=$false }
            @{ label='target missing'; code=0; output="  NAME            STATE           VERSION`n* Debian          Stopped         2"; expected='TargetMissing'; enabled=$true }
        )
        foreach ($case in $listCases) {
            $actual = & $detection {
                param($Case)
                $script:listCase = $Case
                function Get-WslFeatureInfo { [pscustomobject]@{ state='Mocked'; enabled=$script:listCase.enabled; error=$null } }
                function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Source='mock-wsl.exe' } }
                function Get-WslDefaultVersion { 2 }
                function Invoke-SetupProcessCapture {
                    [pscustomobject]@{ exitCode=$script:listCase.code; output=$script:listCase.output; timedOut=$false; error=$null }
                }
                Get-WslInfo -Distribution 'Ubuntu-24.04'
            } $case
            Assert-True ($actual.state -eq $case.expected) "WSL list regression: $($case.label) returned $($actual.state)."
            if ($case.expected -eq 'Unknown') { Assert-True (-not [string]::IsNullOrWhiteSpace($actual.error)) 'Unknown WSL must retain a diagnostic.' }
        }
        Write-Host 'PASS: WSL list distinguishes missing, malformed and failed queries; Store WSL2 does not depend on WSL1'

        Import-Module $detectionPath -Force
        $detection = Get-Module 'CodexSetup.Detection'
        $packageConfig = Get-WslPackageConfiguration -Config $testConfig
        $toolNames = @($packageConfig.commandNames + @('git', 'pwsh', 'rg', 'node', 'npm', 'fnm', 'pnpm', 'python3', 'uv', 'codex') | Sort-Object -Unique)
        $completeLines = @(
            'state:codeRoot=present'; 'state:managedShellBlock=ready'; 'state:globalAgents=ready'
            'state:codexConfig=ready'; 'state:environmentCheck=ready'; 'state:gitBaseline=ready'
            'state:uvManagedPython=ready'; 'state:sudo=interactive'; 'state:ghAuth=unauthenticated'
            foreach ($name in $toolNames) { "tool:${name}=1.0" }
            foreach ($name in $packageConfig.packageNames) { "package:${name}=installed|1.0" }
        )
        $probeCases = @(
            @{ label='VM failed to start'; code=1; output='WSL VM failed'; timedOut=$false; error=$null; expected='Unknown' }
            @{ label='timeout'; code=$null; output=''; timedOut=$true; error='timeout:30s'; expected='Unknown' }
            @{ label='process failed to start'; code=$null; output=''; timedOut=$false; error='start failed'; expected='Unknown' }
            @{ label='empty protocol'; code=0; output=''; timedOut=$false; error=$null; expected='Unknown' }
            @{ label='truncated protocol'; code=0; output=(($completeLines | Where-Object { $_ -ne 'state:gitBaseline=ready' }) -join "`n"); timedOut=$false; error=$null; expected='Unknown' }
            @{ label='missing tool record'; code=0; output=(($completeLines | Where-Object { $_ -notlike 'tool:git=*' }) -join "`n"); timedOut=$false; error=$null; expected='Unknown' }
            @{ label='missing package record'; code=0; output=(($completeLines | Where-Object { $_ -notlike 'package:curl=*' }) -join "`n"); timedOut=$false; error=$null; expected='Unknown' }
            @{ label='invalid state'; code=0; output=(($completeLines -replace 'state:gitBaseline=ready', 'state:gitBaseline=???') -join "`n"); timedOut=$false; error=$null; expected='Unknown' }
            @{ label='known missing tool'; code=0; output=(($completeLines -replace 'tool:git=1.0', 'tool:git=missing') -join "`n"); timedOut=$false; error=$null; expected='NotReady' }
            @{ label='known missing package'; code=0; output=(($completeLines -replace 'package:curl=installed\|1.0', 'package:curl=missing') -join "`n"); timedOut=$false; error=$null; expected='NotReady' }
            @{ label='complete ready protocol'; code=0; output=($completeLines -join "`n"); timedOut=$false; error=$null; expected='Ready' }
        )
        foreach ($case in $probeCases) {
            $actual = & $detection {
                param($Case, $Config)
                $script:probeCase = $Case
                function Invoke-SetupProcessCapture {
                    [pscustomobject]@{ exitCode=$script:probeCase.code; output=$script:probeCase.output; timedOut=$script:probeCase.timedOut; error=$script:probeCase.error }
                }
                Get-WslToolchainInfo -WslInfo ([pscustomobject]@{ distribution='Ubuntu-24.04'; distributionWsl2=$true }) -Config $Config
            } $case $testConfig
            Assert-True ($actual.readiness -eq $case.expected) "WSL probe regression: $($case.label) returned $($actual.readiness)."
            if ($case.expected -eq 'Unknown') {
                Assert-True (-not $actual.available -and -not $actual.skipped -and $actual.missingRequiredCommands.Count -eq 0) 'Failed probes must not invent missing tools.'
                Assert-True (-not [string]::IsNullOrWhiteSpace($actual.error) -and -not [string]::IsNullOrWhiteSpace($actual.reason)) 'Failed probes must expose a diagnostic.'
            }
        }
        Write-Host 'PASS: deep WSL probe validates execution and complete records before reporting tool readiness'

        Import-Module $detectionPath -Force
        $detection = Get-Module 'CodexSetup.Detection'
        foreach ($scenario in @('installed', 'empty', 'one-failure')) {
            $actual = & $detection {
                param($Scenario, $Config)
                $script:appScenario = $Scenario
                $script:capturedApps = $null
                function Get-RequiredWindowsPackageTargets {
                    if ($script:appScenario -eq 'empty') { return @() }
                    @(
                        [pscustomobject]@{ source='winget'; id='Microsoft.WindowsTerminal'; label='Terminal' }
                        [pscustomobject]@{ source='winget'; id='GitHub.cli'; label='GitHub CLI' }
                        [pscustomobject]@{ source='msstore'; id='9PLM9XGG6VKS'; label='Codex' }
                    )
                }
                function Get-WindowsPackageState {
                    param($PackageId, $Source, $TimeoutSeconds)
                    if ($script:appScenario -eq 'one-failure' -and $PackageId -eq 'GitHub.cli') { throw 'fixture query failed' }
                    [pscustomobject]@{ state='KnownInstalled'; installed=$true; version=$null; error=$null }
                }
                function Get-CommandInfoSafe { [pscustomobject]@{ installed=$true; path='mock'; version='1.0' } }
                function Invoke-DetectionStage {
                    param($Index, $Name, $Issues, $Operation, $Fallback, $ResultSummary)
                    if ($Index -eq 1) { return [pscustomobject]@{} }
                    if ($Index -ne 2) { throw 'Unexpected real detection stage.' }
                    $script:capturedApps = & $Operation
                    [void](& $ResultSummary $script:capturedApps)
                    # Stop after the actual application aggregation; no host probes are run.
                    throw 'application-stage-captured'
                }
                try { Get-CodexSetupDetection -Config $Config | Out-Null }
                catch { if ($_.Exception.Message -ne 'application-stage-captured') { throw } }
                $script:capturedApps
            } $scenario $testConfig
            $states = @($actual.catalog.packageStates.PSObject.Properties | ForEach-Object Value)
            if ($scenario -eq 'one-failure') {
                Assert-True ($actual.catalog.state -eq 'Partial' -and @($states | Where-Object state -eq 'KnownInstalled').Count -eq 2) 'One failed package query must preserve other application results.'
                Assert-True ($actual.catalog.error -like '*fixture query failed*') 'Failed package query must retain its error.'
            }
            else {
                Assert-True ($actual.catalog.state -eq 'Known' -and $null -eq $actual.catalog.error) 'Zero failed package queries must aggregate without accessing an absent array property.'
                Assert-True ($states.Count -eq $(if ($scenario -eq 'empty') { 0 } else { 3 })) 'Application aggregation changed the number of package states.'
            }
        }
        Write-Host 'PASS: empty and successful application arrays aggregate; individual failures preserve successful results'
    }
    finally {
        # Restore real module functions so these mocks cannot leak into later checks.
        Import-Module $commonPath -Force
        Import-Module $detectionPath -Force
    }
}
