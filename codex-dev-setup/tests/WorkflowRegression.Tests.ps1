# These tests exercise the interactive boundary with fake actions. No host setup runs.
& {
    $workflowConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../config/defaults.json') -Raw | ConvertFrom-Json
    $workflowConfig.wsl.distribution = 'Ubuntu-24.04'
    $workflowConfig | Add-Member -NotePropertyName preferences -NotePropertyValue ([pscustomobject]@{
        moduleConfirmation='Prompt'; firstRunWhatIf=$false
    }) -Force
    $common = Get-Module CodexSetup.Common
    $promptState = @{ answers=[System.Collections.Generic.Queue[string]]::new(); reads=0 }
    $savedReadHost = & $common { Get-Item Function:script:Read-Host -ErrorAction SilentlyContinue }
    & $common {
        param($State)
        $script:workflowPromptFixture = $State
        Set-Item Function:script:Read-Host -Value {
            param($Prompt)
            $script:workflowPromptFixture.reads++
            if ($script:workflowPromptFixture.answers.Count -eq 0) { throw 'Unexpected interactive prompt in workflow test.' }
            return $script:workflowPromptFixture.answers.Dequeue()
        }
    } $promptState

    try {
        & {
            $NonInteractive = $false
            $OpenDesktopSettings = $false
            $WhatIfPreference = $false
            $state = @{ applied=0; previews=0; detections=0; received=@(); resolveAfterApply=$true; resolutions=0; detectedDistribution='' }
            function Resolve-WslDistribution {
                param($Distribution)
                $state.resolutions++
                return 'Ubuntu-26.04'
            }
            $hostAction = [pscustomobject]@{
                id='HostFixture'; module='Codex'; type='Fixture'; title='Host fixture'; target='fixture';
                reason='Fixture only'; dependsOn=@(); parameters=@{}
            }
            $projectAction = [pscustomobject]@{
                id='ProjectTemplates'; module='Project'; type='ProjectTemplates'; title='Project fixture'; target='fixture-project';
                reason='Fixture only'; dependsOn=@(); parameters=@{}
            }
            $fixturePlan = [pscustomobject]@{
                actions=@($hostAction); blockingReasons=@(); warnings=@(); information=@(); skipped=@(); afterSetup=@()
            }
            function Initialize-SetupRuntime { [pscustomobject]@{ RunId='fixture'; ManifestPath='fixture'; LogPath='fixture' } }
            function Complete-SetupRuntime { param([switch]$Succeeded) }
            function Get-CachedSetupDetection {
                param($TargetProject, $DeepDetection, $ForceRefresh, $Config)
                $state.detections++
                $state.detectedDistribution = $Config.wsl.distribution
                [pscustomobject]@{ healthScore=100; healthLabel='fixture'; issues=@() }
            }
            function Get-CodexSetupPlan {
                param($Detection, $Config, $ProjectPath)
                $copy = $fixturePlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                if ($state.resolveAfterApply -and $state.applied -gt 0) { $copy.actions = @() }
                return $copy
            }
            function Show-CodexSetupPlan { param($Plan) }
            function New-CodexSetupReport { param($Detection, $Plan, $Results, $Config, $WhatIfRun, $RemainingPlan) 'fixture-report.md' }
            function Invoke-CodexSetupPlan {
                [CmdletBinding(SupportsShouldProcess)]
                param($Plan, $Config, [switch]$NonInteractive)
                $state.received = @($Plan.actions)
                if ($WhatIfPreference) { $state.previews++ } else { $state.applied++ }
                foreach ($action in $Plan.actions) {
                    [pscustomobject]@{
                        id=$action.id; module=$action.module; status=$(if ($WhatIfPreference) { 'Preview' } else { 'Changed' });
                        error=$null; detail=$null; durationMs=0
                    }
                }
            }

            $workflowConfig.wsl.distribution = 'latest-stable'
            $workflowConfig.environmentMode = 'WindowsNative'
            $nativeResult = Invoke-Workflow -Config $workflowConfig -WorkflowMode Detect -RealApply:$false 6>$null
            Assert-True ($state.resolutions -eq 0 -and $nativeResult.config.wsl.distribution -eq 'latest-stable') `
                'WindowsNative workflows must not resolve an unused WSL version.'
            $workflowConfig.environmentMode = 'WslFirst'
            $resolved = Invoke-Workflow -Config $workflowConfig -WorkflowMode Detect -RealApply:$false 6>$null
            $rechecked = Invoke-Workflow -Config $resolved.config -WorkflowMode Detect -RealApply:$false -ForceRefresh:$true 6>$null
            Assert-True ($state.resolutions -eq 1 -and $state.detectedDistribution -eq 'Ubuntu-26.04' -and
                $rechecked.config.wsl.distribution -eq 'Ubuntu-26.04' -and $workflowConfig.wsl.distribution -eq 'Ubuntu-26.04') `
                'Resolve the version once before detection and keep the exact target for recheck and session export.'
            $workflowConfig.wsl.distribution = 'Ubuntu-24.04'

            foreach ($confirmationPolicy in @('Prompt', 'Never')) {
                $workflowConfig.preferences.moduleConfirmation = $confirmationPolicy
                $promptState.reads = 0
                $promptState.answers.Clear()
                $promptState.answers.Enqueue('x')
                $promptState.answers.Enqueue('s')
                $state.applied = 0
                $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode Apply -RealApply:$true 6>$null
                Assert-True ($promptState.reads -eq 2 -and $promptState.answers.Count -eq 0) `
                    "The $confirmationPolicy configuration must reject x and then accept s at the plan confirmation."
                Assert-True ($state.applied -eq 0 -and @($result.results | Where-Object status -eq 'Skipped').Count -eq 1) `
                    'An invalid choice followed by Skip must not invoke any setup action.'
            }
            $promptState.answers.Enqueue('')
            $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode Apply -RealApply:$true 6>$null
            Assert-True ($state.applied -eq 0 -and $result.results[0].status -eq 'Skipped') `
                'The plan confirmation must default to Skip, including the legacy Never preference.'

            $promptState.reads = 0
            $WhatIfPreference = $true
            $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode Apply -RealApply:$true 6>$null
            Assert-True ($promptState.reads -eq 0 -and $state.applied -eq 0 -and $state.previews -eq 1) `
                'WhatIf must preview without interactive input or real actions.'
            Assert-True ($result.whatIfRun -and $result.results[0].status -eq 'Preview') 'WhatIf lost its preview result.'

            $WhatIfPreference = $false
            $NonInteractive = $true
            $state.detections = 0
            $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode Apply -RealApply:$true 6>$null
            Assert-True ($promptState.reads -eq 0 -and $state.applied -eq 1) `
                'An explicitly non-interactive apply must not ask for input.'
            Assert-True ($state.detections -eq 2 -and $result.remainingPlan.actions.Count -eq 0) `
                'A changed action must trigger fresh verification and remove resolved actions from the remaining plan.'

            $restart = [pscustomobject]@{ id='ConfigureWslNetwork'; module='Network'; status='RestartRequired'; error=$null; detail=$null; durationMs=0 }
            $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode Detect -RealApply:$false -PendingRestarts @($restart) 6>$null
            Assert-True (@($result.results | Where-Object { $_.id -eq 'ConfigureWslNetwork' -and $_.status -eq 'RestartRequired' }).Count -eq 1) `
                'A fresh read-only check cannot prove that a requested WSL restart occurred.'

            $NonInteractive = $false
            $state.applied = 0
            $fixturePlan.actions = @($hostAction, $projectAction)
            $fixturePlan.blockingReasons = @('无法确认 WSL 生命周期状态', '项目需要用户处理')
            $promptState.answers.Enqueue('s')
            $result = Invoke-Workflow -Config $workflowConfig -WorkflowMode ProjectInit -TargetProject 'fixture-project' -RealApply:$true 6>$null
            Assert-True ($result.plan.actions.Count -eq 1 -and $result.plan.actions[0].module -eq 'Project') `
                'Project initialization must exclude host actions before showing the plan.'
            Assert-True ($result.plan.blockingReasons.Count -eq 1 -and $result.plan.blockingReasons[0] -eq '项目需要用户处理') `
                'Project initialization must exclude unrelated host blockers before confirmation, even when skipped.'
        }

        & {
            $sessionState = @{ choices=[System.Collections.Generic.Queue[string]]::new(); calls=[System.Collections.Generic.List[object]]::new() }
            $sessionState.choices.Enqueue('Detect')
            $sessionState.choices.Enqueue('Apply')
            $sessionState.choices.Enqueue('')
            function Show-WorkflowCompletion { param($WorkflowResult) $sessionState.choices.Dequeue() }
            function Invoke-Workflow {
                param($Config, $WorkflowMode, $TargetProject, $RealApply, $DeepDetection, $ForceRefresh, $PendingRestarts)
                $sessionState.calls.Add([pscustomobject]@{ mode=$WorkflowMode; apply=$RealApply; project=$TargetProject })
                [pscustomobject]@{ workflowMode=$WorkflowMode; config=$Config; results=@($PendingRestarts) }
            }
            Show-WorkflowSession -WorkflowResult ([pscustomobject]@{ workflowMode='ProjectInit'; config=$workflowConfig; results=@() }) -TargetProject 'fixture-project'
            Assert-True ($sessionState.calls.Count -eq 2 -and -not $sessionState.calls[0].apply -and $sessionState.calls[1].apply) `
                'Recheck must remain read-only, and Continue must apply within the same session.'
            Assert-True ($sessionState.calls[1].mode -eq 'ProjectInit' -and $sessionState.calls[1].project -eq 'fixture-project') `
                'Project initialization followed by Recheck and Continue must never expand to host Apply.'
        }

        & {
            $restartState = @{ choices=[System.Collections.Generic.Queue[string]]::new(); calls=[System.Collections.Generic.List[object]]::new(); shutdownCalls=0; failShutdown=$false }
            function Show-WorkflowCompletion { param($WorkflowResult) $restartState.choices.Dequeue() }
            function Invoke-Workflow {
                param($Config, $WorkflowMode, $TargetProject, $RealApply, $DeepDetection, $ForceRefresh, $PendingRestarts)
                $restartState.calls.Add([pscustomobject]@{ pending=@($PendingRestarts); apply=$RealApply })
                [pscustomobject]@{ workflowMode=$WorkflowMode; config=$Config; results=@($PendingRestarts) }
            }
            function Invoke-InteractiveExternalSetupCommand {
                param($Command, $Arguments)
                $restartState.shutdownCalls++
                Assert-True ($Command -eq 'wsl.exe' -and $Arguments.Count -eq 1 -and $Arguments[0] -eq '--shutdown') `
                    'The WSL restart shortcut must invoke only the reviewed shutdown command.'
                if ($restartState.failShutdown) { throw 'fixture-shutdown-failed' }
                return 0
            }
            $restartResult = [pscustomobject]@{ workflowMode='Apply'; config=$workflowConfig; results=@(
                [pscustomobject]@{ id='ConfigureWslNetwork'; status='RestartRequired' }
                [pscustomobject]@{ id='InstallWslDistribution'; status='RestartRequired' }
            ) }
            foreach ($choice in @('Detect', 'RestartWsl', '')) { $restartState.choices.Enqueue($choice) }
            Show-WorkflowSession -WorkflowResult $restartResult
            Assert-True ($restartState.calls.Count -eq 2 -and $restartState.calls[0].pending.Count -eq 2) `
                'Recheck must retain every unfulfilled restart requirement.'
            Assert-True ($restartState.shutdownCalls -eq 1 -and $restartState.calls[1].pending.Count -eq 1 -and
                $restartState.calls[1].pending[0].id -eq 'InstallWslDistribution') `
                'Successful WSL shutdown clears only its network restart requirement, not a Windows reboot requirement.'
            $restartState.calls.Clear()
            $restartState.shutdownCalls = 0
            $restartState.failShutdown = $true
            foreach ($choice in @('RestartWsl', 'Detect', '')) { $restartState.choices.Enqueue($choice) }
            # Shutdown failure is handled by the session, not propagated. Capture
            # its expected diagnostic and supply enough input to exit normally;
            # an unrelated exception (including an exhausted queue) must fail.
            $failureOutput = @(Show-WorkflowSession -WorkflowResult $restartResult 6>&1)
            $failureMessages = @($failureOutput | ForEach-Object { [string]$_ })
            Assert-True ($failureMessages.Count -eq 1 -and $failureMessages[0] -eq '[错误] fixture-shutdown-failed') `
                'Failed shutdown must report exactly its expected diagnostic, without other errors.'
            Assert-True ($restartState.shutdownCalls -eq 1 -and $restartState.choices.Count -eq 0) `
                'Failed shutdown must return to the menu and allow a normal exit, without an implicit retry.'
            Assert-True ($restartState.calls.Count -eq 1 -and -not $restartState.calls[0].apply -and
                (@($restartState.calls[0].pending | ForEach-Object id) -join ',') -eq 'ConfigureWslNetwork,InstallWslDistribution') `
                'After failed shutdown, explicit recheck must stay read-only and retain both restart requirements.'
            Write-Host 'PASS: simulated shutdown failure is reported; recheck preserves pending restarts and exits normally'
        }
    }
    finally {
        & $common {
            param($SavedReadHost)
            if ($null -ne $SavedReadHost) { Set-Item Function:script:Read-Host -Value $SavedReadHost.ScriptBlock }
            else { Remove-Item Function:script:Read-Host -ErrorAction SilentlyContinue }
            Remove-Variable workflowPromptFixture -Scope Script -ErrorAction SilentlyContinue
        } $savedReadHost
    }
}
Write-Host 'PASS: plan consent, preview, non-interactive execution, verification, and project session scope'

& {
    $reportConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../config/defaults.json') -Raw | ConvertFrom-Json
    $reportCommon = Get-Module CodexSetup.Common
    $savedRuntime = & $reportCommon { $script:Runtime }
    $missing = [pscustomobject]@{ installed=$false; version=''; path=''; error=$null }
    $reportDetection = [pscustomobject]@{
        windows=[pscustomobject]@{ isWindows11=$true; build=26100; caption='fixture' }
        codexDesktop=$missing; windowsTerminal=[pscustomobject]@{ command=$missing; app=$missing }
        powershell7=$missing; git=$missing; githubCli=$missing; dockerDesktop=$missing
        wsl=[pscustomobject]@{ state='Unknown'; distribution='Ubuntu-24.04' }
        wslTools=[pscustomobject]@{ readiness='Unknown'; missingRequiredCommands=@(); nonNativeCommands=@(); reason='fixture-query-failed' }
        healthScore=$null; healthLabel='检查未完成'; detectionMode='完整'; issues=@(); project=$null
    }
    $reportPlan = [pscustomobject]@{
        environmentMode='WslFirst'; environmentLabel='WSL2 Ubuntu-24.04'; actions=@(); warnings=@(); blockingReasons=@()
    }
    $reportRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-report-' + [guid]::NewGuid().ToString('N'))
    $oldLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $reportRoot
        Initialize-SetupRuntime | Out-Null
        $path = New-CodexSetupReport -Detection $reportDetection -Plan $reportPlan -Results @() -Config $reportConfig -WhatIfRun:$true
        $text = Get-Content -LiteralPath $path -Raw
        Assert-True ($text.Contains('| Windows 11 |') -and $text.Contains('检查未完成') -and -not $text.Contains('/100') -and $text.Contains('fixture-query-failed')) `
            'A real report must accept blank lines and empty results, retain unknown state, and include WSL diagnostics.'
    }
    finally {
        Complete-SetupRuntime
        & $reportCommon { param($SavedRuntime) $script:Runtime = $SavedRuntime } $savedRuntime
        $env:LOCALAPPDATA = $oldLocalAppData
        $resolvedRoot = [System.IO.Path]::GetFullPath($reportRoot)
        $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Report fixture cleanup escaped the temporary directory.' }
        if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
    }
}
Write-Host 'PASS: real report handles blank lines, empty results, and unknown WSL status'

& {
    $actionsModule = Get-Module CodexSetup.Actions
    $actionConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../config/defaults.json') -Raw | ConvertFrom-Json
    $actionState = @{ processCalls=0; probes=0; exitCode=0; distroState='Ready'; invoked=[System.Collections.Generic.List[string]]::new() }
    $templateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-templates-' + [guid]::NewGuid().ToString('N'))
    $savedFunctions = & $actionsModule {
        $saved = @{}
        foreach ($name in @('Invoke-InteractiveExternalSetupCommand', 'Get-WslInfo', 'Add-RollbackNote', 'Invoke-SetupAction',
            'New-ProjectTemplateMap', 'Confirm-SetupChoice', 'Set-SetupFileContent')) {
            $saved[$name] = Get-Item "Function:script:$name" -ErrorAction SilentlyContinue
        }
        return $saved
    }
    try {
        & $actionsModule {
            param($State)
            $script:workflowActionFixture = $State
            Set-Item Function:script:Invoke-InteractiveExternalSetupCommand -Value {
                param($Command, $Arguments, [switch]$AllowFailure)
                $script:workflowActionFixture.processCalls++
                return $script:workflowActionFixture.exitCode
            }
            Set-Item Function:script:Get-WslInfo -Value {
                param($Distribution)
                $script:workflowActionFixture.probes++
                [pscustomobject]@{ state=$script:workflowActionFixture.distroState; distribution=$Distribution }
            }
            Set-Item Function:script:Add-RollbackNote -Value { param($Note) }
        } $actionState

        foreach ($case in @(
            @{ exitCode=0; distroState='Ready'; expected='Changed'; expectedProbes=1 }
            @{ exitCode=3010; distroState='Ready'; expected='RestartRequired'; expectedProbes=0 }
            @{ exitCode=0; distroState='TargetMissing'; expected='NeedsAttention'; expectedProbes=1 }
        )) {
            $actionState.processCalls = 0
            $actionState.probes = 0
            $actionState.exitCode = $case.exitCode
            $actionState.distroState = $case.distroState
            $outcome = & $actionsModule { Install-WslDistribution -Distribution 'Ubuntu-24.04' } 6>$null
            Assert-True ($outcome.status -eq $case.expected -and $actionState.processCalls -eq 1 -and $actionState.probes -eq $case.expectedProbes) `
                "WSL installation exit=$($case.exitCode), state=$($case.distroState) must produce $($case.expected)."
        }

        $actionState.processCalls = 0
        $actionState.probes = 0
        $outcome = & $actionsModule {
            param($Config)
            Invoke-SetupAction -Action ([pscustomobject]@{
                type='WslInstallDistribution'; parameters=@{ distro='Ubuntu-24.04' }
            }) -Config $Config -NonInteractive
        } $actionConfig 6>$null
        Assert-True ($outcome.status -eq 'NeedsAttention' -and $actionState.processCalls -eq 0 -and $actionState.probes -eq 0) `
            'Non-interactive first installation must propagate the flag and return guidance without launching an interactive process.'

        & $actionsModule {
            Set-Item Function:script:Invoke-SetupAction -Value {
                param($Action, $Config, [switch]$NonInteractive)
                $script:workflowActionFixture.invoked.Add([string]$Action.id)
                if ($Action.id -eq 'InstallWslDistribution') { throw 'fixture-install-failure' }
                New-ActionOutcome -Status Changed -Summary 'fixture completed' -Data $null
            }
        }
        $dependencyPlan = [pscustomobject]@{ actions=@(
            [pscustomobject]@{ id='InstallWslDistribution'; module='WSL'; type='WslInstallDistribution'; target='fixture'; title='Install fixture'; dependsOn=@() }
            [pscustomobject]@{ id='ConfigureWsl'; module='WSL'; type='WslConfigure'; target='fixture'; title='Configure fixture'; dependsOn=@('InstallWslDistribution') }
            [pscustomobject]@{ id='GlobalCodexConfig'; module='CodexConfig'; type='CodexGlobalConfig'; target='fixture'; title='Codex fixture'; dependsOn=@() }
        ) }
        $results = @(Invoke-CodexSetupPlan -Plan $dependencyPlan -Config $actionConfig -NonInteractive -Confirm:$false 6>$null)
        Assert-True (@($results | Where-Object { $_.id -eq 'InstallWslDistribution' -and $_.status -eq 'Failed' }).Count -eq 1) `
            'The failed WSL prerequisite must retain its failure result.'
        Assert-True (@($results | Where-Object { $_.id -eq 'ConfigureWsl' -and $_.status -eq 'Skipped' }).Count -eq 1 -and
            'ConfigureWsl' -notin $actionState.invoked) 'A dependent action must not run after its prerequisite fails.'
        Assert-True (@($results | Where-Object { $_.id -eq 'GlobalCodexConfig' -and $_.status -eq 'Changed' }).Count -eq 1 -and
            'GlobalCodexConfig' -in $actionState.invoked) 'A WSL failure must not prevent independent Codex configuration.'

        [void][System.IO.Directory]::CreateDirectory($templateRoot)
        $actionState.templates = [ordered]@{}
        foreach ($name in @('AGENTS.md', '.editorconfig', '.gitattributes', '.gitignore')) {
            $path = Join-Path $templateRoot $name
            [System.IO.File]::WriteAllText($path, 'existing fixture content')
            $actionState.templates[$path] = 'replacement fixture content'
        }
        $actionState.confirmCalls = 0
        $actionState.writeCalls = 0
        $actionState.replace = $true
        & $actionsModule {
            Set-Item Function:script:New-ProjectTemplateMap -Value {
                param($ProjectPath, $Config)
                return $script:workflowActionFixture.templates
            }
            Set-Item Function:script:Confirm-SetupChoice -Value {
                param($Prompt, $DefaultYes, [switch]$NonInteractive)
                $script:workflowActionFixture.confirmCalls++
                return $script:workflowActionFixture.replace
            }
            Set-Item Function:script:Set-SetupFileContent -Value {
                param($Path, $Content, $Description, $ManagedKind, $ManagedRoot)
                $script:workflowActionFixture.writeCalls++
                return $true
            }
        }
        $templateAction = [pscustomobject]@{ parameters=@{ projectPath=$templateRoot } }
        $outcome = & $actionsModule { param($Action, $Config) Set-ProjectTemplates -Action $Action -Config $Config } $templateAction $actionConfig 6>$null
        Assert-True ($actionState.confirmCalls -eq 1 -and $actionState.writeCalls -eq 4 -and $outcome.status -eq 'Changed') `
            'Four existing project files must use one explicit replacement confirmation.'
        $actionState.confirmCalls = 0
        $actionState.writeCalls = 0
        $actionState.replace = $false
        $outcome = & $actionsModule { param($Action, $Config) Set-ProjectTemplates -Action $Action -Config $Config } $templateAction $actionConfig 6>$null
        Assert-True ($actionState.confirmCalls -eq 1 -and $actionState.writeCalls -eq 0 -and $outcome.status -eq 'NeedsAttention') `
            'Declining the combined replacement must preserve all existing files.'
        $actionState.confirmCalls = 0
        $outcome = & $actionsModule { param($Action, $Config) Set-ProjectTemplates -Action $Action -Config $Config -NonInteractive } $templateAction $actionConfig 6>$null
        Assert-True ($actionState.confirmCalls -eq 0 -and $actionState.writeCalls -eq 0 -and $outcome.status -eq 'NeedsAttention') `
            'Non-interactive project initialization must preserve existing files without prompting.'
    }
    finally {
        & $actionsModule {
            param($SavedFunctions)
            foreach ($name in $SavedFunctions.Keys) {
                if ($null -ne $SavedFunctions[$name]) { Set-Item "Function:script:$name" -Value $SavedFunctions[$name].ScriptBlock }
                else { Remove-Item "Function:script:$name" -ErrorAction SilentlyContinue }
            }
            Remove-Variable workflowActionFixture -Scope Script -ErrorAction SilentlyContinue
        } $savedFunctions
        $resolvedRoot = [System.IO.Path]::GetFullPath($templateRoot)
        $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Template fixture cleanup escaped the temporary directory.' }
        if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
    }
}
Write-Host 'PASS: WSL installation outcomes, prerequisite isolation, and one project replacement confirmation'
