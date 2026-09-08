Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Script,

        [Parameter(Mandatory)]
        [string]$Message
    )

    try {
        & $Script
    }
    catch {
        return
    }
    throw $Message
}

$configPath = Join-Path $root 'config/defaults.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

Assert-True ($config.schemaVersion -eq 2) 'schemaVersion must be 2.'
Assert-True ($config.environmentMode -eq 'WslFirst') 'WslFirst must be the default mode.'
Assert-True ($config.wsl.distribution -eq 'Ubuntu-24.04') 'The WSL distribution must be exact.'
Assert-True ($config.wsl.packages.Count -gt 0) 'The WSL package list must not be empty.'
Assert-True ($config.wsl.installCodexCli -eq $true) 'Codex CLI must be installed in WSL.'
Assert-True ($config.wsl.installPnpm -eq $true) 'pnpm must be installed in WSL.'
Assert-True ($config.wsl.configureGit -eq $true) 'Git baseline must be configured in WSL.'
Assert-True ((@($config.toolchains.node.PSObject.Properties.Name) -join ',') -eq 'enabled') 'Node manager is fixed by v2 and must not be duplicated in config.'
Assert-True ((@($config.toolchains.python.PSObject.Properties.Name) -join ',') -eq 'enabled') 'Python manager is fixed to uv and must not be duplicated in config.'
Assert-True ($config.codex.windowsSandbox -eq 'elevated') 'Windows native sandbox must default to elevated.'

Assert-True (Test-Path -LiteralPath (Join-Path $root 'templates/global/AGENTS.wsl.md.template')) 'WSL global AGENTS template is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'templates/global/AGENTS.windows.md.template')) 'Windows global AGENTS template is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'wsl/verify.sh')) 'WSL verifier is missing.'

$projectTemplate = Get-Content -LiteralPath (Join-Path $root 'templates/project/AGENTS.md.template') -Raw
Assert-True ($projectTemplate.Contains('{{ENVIRONMENT_RULES}}')) 'Project template lacks environment placeholder.'
Assert-True ($projectTemplate.Contains('{{PROJECT_COMMANDS}}')) 'Project template lacks command placeholder.'

Import-Module (Join-Path $root 'modules/CodexSetup.Common.psm1') -Force
$commonModule = Get-Module 'CodexSetup.Common'
$validatedConfig = Read-SetupConfig -Path $configPath
Assert-True ($validatedConfig.schemaVersion -eq 2) 'The strict config reader rejected the default contract.'

$pwshPath = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$captureResult = & $commonModule {
    param($Executable)
    Invoke-SetupProcessCapture -FilePath $Executable -Arguments @('-NoProfile', '-Command', "[Console]::Out.Write('ready')") -TimeoutSeconds 5
} $pwshPath
Assert-True (-not $captureResult.timedOut -and $captureResult.exitCode -eq 0 -and $captureResult.output -eq 'ready') `
    'Bounded process capture did not return successful output.'
$timeoutResult = & $commonModule {
    param($Executable)
    Invoke-SetupProcessCapture -FilePath $Executable -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -TimeoutSeconds 1
} $pwshPath
Assert-True ($timeoutResult.timedOut -and $null -eq $timeoutResult.exitCode -and $timeoutResult.error -eq 'timeout:1s') `
    'Bounded process capture did not terminate a stalled child process.'
$stdinResult = & $commonModule {
    param($Executable)
    Invoke-SetupProcessCapture -FilePath $Executable -Arguments @(
        '-NoProfile', '-Command', '[Console]::Out.Write([Console]::In.ReadToEnd())'
    ) -StandardInput 'input-ready' -TimeoutSeconds 5 -OutputEncoding ([Text.Encoding]::UTF8)
} $pwshPath
Assert-True ($stdinResult.exitCode -eq 0 -and $stdinResult.output -eq 'input-ready') `
    'Shared process capture did not handle standard input and explicit output encoding.'
Write-Host 'PASS: external read-only queries have a process timeout'

$unknownConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$unknownConfig | Add-Member -NotePropertyName legacyCompatibility -NotePropertyValue $true
Assert-Throws { Assert-SetupConfiguration -Config $unknownConfig } 'Unknown root fields must be rejected.'
$wrongDistroConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$wrongDistroConfig.wsl.distribution = 'Ubuntu'
Assert-Throws { Assert-SetupConfiguration -Config $wrongDistroConfig } 'A generic Ubuntu name must be rejected.'
$missingPackageConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$missingPackageConfig.wsl.packages = @($missingPackageConfig.wsl.packages | Where-Object { $_ -ne 'curl' })
Assert-Throws { Assert-SetupConfiguration -Config $missingPackageConfig } 'Required WSL packages must not be optional.'
Write-Host 'PASS: strict v2 configuration validation'

Import-Module (Join-Path $root 'modules/CodexSetup.Detection.psm1') -Force
$detectionModule = Get-Module 'CodexSetup.Detection'
$wslPackageTargets = & $detectionModule {
    param($Config)
    @(Get-RequiredWindowsPackageTargets -Config $Config)
} $validatedConfig
Assert-True ($wslPackageTargets.Count -eq 4) 'WslFirst detection queries packages that are not required by its configuration.'
Assert-True ('Microsoft.PowerShell' -notin @($wslPackageTargets.id)) 'WslFirst detection queries WindowsNative toolchain packages.'
Write-Host 'PASS: package detection is limited to configured Windows applications'
$wslRows = & $detectionModule {
    @(ConvertFrom-WslListVerbose -Output "  NAME            STATE           VERSION`n* Ubuntu-24.04    Running         2`n  Debian          Stopped         2")
}
Assert-True ($wslRows.Count -eq 2 -and $wslRows[0].name -eq 'Ubuntu-24.04' -and $wslRows[0].isDefault -and $wslRows[1].name -eq 'Debian') `
    'The single WSL verbose listing was not parsed correctly.'
$acceptedWslPath = & $detectionModule {
    Get-ProjectRecommendation -ProjectPath '\\wsl$\Ubuntu-24.04\home\alice\code\repo' `
        -ConfiguredEnvironmentMode WslFirst -WslProjects '~/code' -WslDistribution 'Ubuntu-24.04'
}
$rejectedWslPath = & $detectionModule {
    Get-ProjectRecommendation -ProjectPath '\\wsl$\Ubuntu-24.04\home\alice\.ssh' `
        -ConfiguredEnvironmentMode WslFirst -WslProjects '~/code' -WslDistribution 'Ubuntu-24.04'
}
Assert-True ($acceptedWslPath.locationCompatible -eq $true) 'A repository under the exact WSL ~/code root was rejected.'
Assert-True ($rejectedWslPath.locationCompatible -eq $false) 'A WSL path outside ~/code was accepted.'
Write-Host 'PASS: WslFirst project boundary is limited to ~/code'
$deepProbe = & $detectionModule {
    param($Config)
    $script:probeCalls = 0
    Set-Item -Path Function:script:Invoke-SetupProcessCapture -Value {
        param($FilePath, $Arguments, $TimeoutSeconds, $OutputEncoding, $StandardInput)
        $script:probeCalls++
        $script:probeInput = $StandardInput
        $script:probeArguments = $Arguments
        [pscustomobject]@{ exitCode=0; output=''; timedOut=$false; error=$null; elapsedMs=1 }
    }
    $result = Get-WslToolchainInfo -WslInfo ([pscustomobject]@{
        distribution='Ubuntu-24.04'; distributionWsl2=$true
    }) -Config $Config
    [pscustomobject]@{
        calls=$script:probeCalls
        input=$script:probeInput
        arguments=$script:probeArguments
        available=$result.available
    }
} $validatedConfig
Assert-True ($deepProbe.calls -eq 1 -and $deepProbe.available) 'Deep WSL inspection launched more than one probe process.'
Assert-True ($deepProbe.input.Contains('state:codeRoot') -and $deepProbe.input.Contains('report_tool')) `
    'Deep WSL inspection did not combine configuration and tool checks.'
Assert-True ('~/code' -in @($deepProbe.arguments)) 'Deep WSL inspection did not let Linux resolve its configured home path.'
Write-Host 'PASS: deep WSL inspection uses one combined process'

Import-Module (Join-Path $root 'modules/CodexSetup.Planning.psm1') -Force
$planningModule = Get-Module 'CodexSetup.Planning'
$missingTool = [pscustomobject]@{ installed=$false; version=''; path='' }
$knownMissingPackage = [pscustomobject]@{ state='KnownMissing'; installed=$false; version=$null; error=$null }
$packageStates = [pscustomobject][ordered]@{
    'winget|Microsoft.WindowsTerminal'=$knownMissingPackage
    'winget|Git.Git'=$knownMissingPackage
    'winget|GitHub.cli'=$knownMissingPackage
    'msstore|9PLM9XGG6VKS'=$knownMissingPackage
    'winget|Microsoft.PowerShell'=$knownMissingPackage
    'winget|BurntSushi.ripgrep.MSVC'=$knownMissingPackage
    'winget|sharkdp.fd'=$knownMissingPackage
    'winget|jqlang.jq'=$knownMissingPackage
    'winget|OpenJS.NodeJS.LTS'=$knownMissingPackage
    'winget|astral-sh.uv'=$knownMissingPackage
}
$mockDetection = [pscustomobject]@{
    windows=[pscustomobject]@{ isWindows11=$true; isAdministrator=$true; build=26100 }
    windowsPackageCatalog=[pscustomobject]@{ state='Known'; packageStates=$packageStates; error=$null }
    windowsTerminal=[pscustomobject]@{ command=$missingTool; app=$missingTool }
    codexDesktop=$missingTool
    codexConfig=[pscustomobject]@{ ready=$false }
    globalAgents=[pscustomobject]@{ ready=$false }
    windowsGitConfig=[pscustomobject]@{ ready=$false; error=$null }
    git=$missingTool
    githubCli=$missingTool
    dockerDesktop=$missingTool
    docker=$missingTool
    powershell7=$missingTool
    uv=$missingTool
    wsl=[pscustomobject]@{ state='Ready'; error=$null; installed=$true; distributionInstalled=$true; distributionWsl2=$true; defaultDistribution='Ubuntu-24.04' }
    wslTools=[pscustomobject]@{ available=$true; readiness='NotReady'; environmentReady=$false }
    project=[pscustomobject]@{
        recommendedEnvironmentMode='WslFirst'
        configuredEnvironmentMode='WslFirst'
        matchesConfiguredMode=$true
        locationCompatible=$true
        reasons=@('Cross-platform project markers')
    }
    issues=@()
    healthScore=50
    healthLabel='Needs setup'
    detectionMode='Full'
}

$wslPlan = Get-CodexSetupPlan -Detection $mockDetection -Config $validatedConfig -ProjectPath $null
$wslActionIds = @($wslPlan.actions.id)
$wslActionTypes = @($wslPlan.actions.type)
$wslTargets = @($wslPlan.actions.target)
Assert-True ($wslPlan.environmentMode -eq 'WslFirst') 'The plan lost the configured mode.'
Assert-True ('ConfigureWsl' -in $wslActionIds) 'WslFirst must configure the Linux toolchain.'
Assert-True ('GlobalAgents' -in $wslActionIds) 'WslFirst must configure global environment rules.'
Assert-True ('NodeConfigure' -notin $wslActionTypes) 'WslFirst must not configure Windows Node.'
Assert-True ('PythonConfigure' -notin $wslActionTypes) 'WslFirst must not configure Windows Python.'
Assert-True ('WindowsGitConfig' -notin $wslActionTypes) 'WslFirst must not configure Windows Git for repository work.'
foreach ($packageId in @('OpenJS.NodeJS.LTS', 'Schniz.fnm', 'astral-sh.uv', 'BurntSushi.ripgrep.MSVC', 'sharkdp.fd', 'jqlang.jq')) {
    Assert-True ($packageId -notin $wslTargets) "WslFirst contains a Windows development package: $packageId"
}
$networkReadyDetection = $mockDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$networkReadyDetection | Add-Member -NotePropertyName wslNetwork -NotePropertyValue ([pscustomobject]@{
    networkingMode=$validatedConfig.wsl.networking.networkingMode
    dnsTunneling=$validatedConfig.wsl.networking.dnsTunneling
    autoProxy=$validatedConfig.wsl.networking.autoProxy
    firewall=$validatedConfig.wsl.networking.firewall
})
$networkReadyPlan = Get-CodexSetupPlan -Detection $networkReadyDetection -Config $validatedConfig -ProjectPath $null
Assert-True ('ConfigureWslNetwork' -notin @($networkReadyPlan.actions.id)) `
    'Planning retained a redundant WSL network action after the values matched.'
$configuredDetection = $networkReadyDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$configuredDetection.codexConfig.ready = $true
$configuredDetection.globalAgents.ready = $true
$configuredPlan = Get-CodexSetupPlan -Detection $configuredDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($configuredPlan.actions.id | Where-Object { $_ -in @('GlobalCodexConfig', 'GlobalAgents', 'ConfigureWslNetwork') }).Count -eq 0) `
    'Planning generated configuration actions after their target state was reached.'

$windowsConfig = $validatedConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$windowsConfig.environmentMode = 'WindowsNative'
$windowsPlan = Get-CodexSetupPlan -Detection $mockDetection -Config $windowsConfig -ProjectPath $null
$windowsActionTypes = @($windowsPlan.actions.type)
Assert-True ('WslConfigure' -notin $windowsActionTypes) 'WindowsNative must not configure a WSL toolchain.'
Assert-True (@($windowsPlan.actions | Where-Object { $_.type -eq 'WingetInstall' -and $_.target -eq 'OpenJS.NodeJS.LTS' }).Count -eq 1) `
    'WindowsNative must install one native Node.js LTS package.'
Assert-True ('PythonConfigure' -in $windowsActionTypes) 'WindowsNative must configure its Windows Python toolchain.'
Assert-True ('WindowsGitConfig' -in $windowsActionTypes) 'WindowsNative must configure Windows Git.'
$readyGitDetection = $mockDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$readyGitDetection.windowsPackageCatalog.packageStates.'winget|Git.Git' = [pscustomobject]@{
    state='KnownInstalled'; installed=$true; version='2.55.0'; error=$null
}
$readyGitDetection.git = [pscustomobject]@{ installed=$true; version='2.55.0'; path='C:\Program Files\Git\cmd\git.exe' }
$readyGitDetection.windowsGitConfig.ready = $true
$readyGitPlan = Get-CodexSetupPlan -Detection $readyGitDetection -Config $windowsConfig -ProjectPath $null
Assert-True ('WindowsGitConfig' -notin @($readyGitPlan.actions.type)) `
    'WindowsNative retained a redundant Git configuration action after the baseline matched.'
Write-Host 'PASS: mutually exclusive WslFirst and WindowsNative plans'

$catalogDetection = $mockDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
foreach ($key in @('winget|GitHub.cli', 'winget|Microsoft.WindowsTerminal', 'winget|Git.Git', 'msstore|9PLM9XGG6VKS')) {
    $catalogDetection.windowsPackageCatalog.packageStates.$key = [pscustomobject]@{
        state='KnownInstalled'; installed=$true; version='1.0.0'; error=$null
    }
}
$catalogDetection.githubCli = [pscustomobject]@{ installed=$false; version=''; path='' }
$catalogPlan = Get-CodexSetupPlan -Detection $catalogDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($catalogPlan.actions | Where-Object { $_.type -eq 'WingetInstall' -and $_.target -eq 'GitHub.cli' }).Count -eq 0) `
    'A missing PATH command must not override an exact installed-package identity.'

$missingIdentityDetection = $catalogDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$missingIdentityDetection.windowsPackageCatalog.packageStates.'winget|GitHub.cli' = [pscustomobject]@{
    state='KnownMissing'; installed=$false; version=$null; error=$null
}
$missingIdentityDetection.githubCli = [pscustomobject]@{ installed=$true; version='fake'; path='C:\fake\gh.exe' }
$missingIdentityPlan = Get-CodexSetupPlan -Detection $missingIdentityDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($missingIdentityPlan.actions | Where-Object { $_.type -eq 'WingetInstall' -and $_.target -eq 'GitHub.cli' }).Count -eq 1) `
    'A PATH command must not impersonate an absent WinGet package.'

$unknownCatalogDetection = $catalogDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$unknownCatalogDetection.windowsPackageCatalog.state = 'Unknown'
$unknownCatalogDetection.windowsPackageCatalog.error = 'fixture-query-failed'
$unknownCatalogDetection.windowsPackageCatalog.packageStates = [pscustomobject]@{}
$unknownCatalogPlan = Get-CodexSetupPlan -Detection $unknownCatalogDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($unknownCatalogPlan.actions | Where-Object type -eq 'WingetInstall').Count -eq 0) `
    'An unknown WinGet catalog must fail closed without install actions.'
Assert-True (@($unknownCatalogPlan.blockingReasons | Where-Object { $_ -match '无法确认 Windows 应用状态' }).Count -eq 1) `
    'An unknown WinGet catalog must produce one actionable blocker.'

$emptyCatalogDetection = $catalogDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$emptyCatalogDetection.windowsPackageCatalog = [pscustomobject]@{
    state='Unknown'
    complete=$false
    packages=@()
    packageStates=[pscustomobject]@{}
    error='winget-list-timeout:10s'
}
$emptyCatalogPlan = Get-CodexSetupPlan -Detection $emptyCatalogDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($emptyCatalogPlan.actions | Where-Object type -eq 'WingetInstall').Count -eq 0) `
    'An empty timed-out package state map must fail closed without throwing or installing.'
Assert-True (@($emptyCatalogPlan.blockingReasons | Where-Object { $_ -match 'WinGet 响应超时' }).Count -eq 1) `
    'An empty timed-out package state map must retain the actionable timeout reason.'
Write-Host 'PASS: empty strict-mode package states degrade without a fatal property error'

foreach ($case in @(
    @{ State='FeatureDisabled'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='NoDistribution'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='TargetMissing'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='Ready'; Required='ConfigureWsl'; Forbidden=@('InstallWslDistribution') }
    @{ State='Unknown'; Required=$null; Forbidden=@('InstallWslDistribution', 'ConfigureWsl', 'SetWsl2Default') }
    @{ State='UnsupportedWsl1'; Required=$null; Forbidden=@('InstallWslDistribution', 'ConfigureWsl', 'SetWsl2Default') }
)) {
    $stateDetection = $catalogDetection | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $stateDetection.wsl.state = $case.State
    $stateDetection.wsl.error = $(if ($case.State -eq 'Unknown') { 'fixture-unknown' } else { $null })
    $statePlan = Get-CodexSetupPlan -Detection $stateDetection -Config $validatedConfig -ProjectPath $null
    $ids = @($statePlan.actions.id)
    if ($case.Required) {
        Assert-True ($case.Required -in $ids) "WSL state $($case.State) did not produce $($case.Required)."
    }
    foreach ($forbidden in $case.Forbidden) {
        Assert-True ($forbidden -notin $ids) "WSL state $($case.State) produced forbidden action $forbidden."
    }
    Assert-True (@($statePlan.actions | Where-Object { $_.type -match 'Convert|Unregister' }).Count -eq 0) `
        "WSL state $($case.State) produced a conversion or unregister action."
}
Write-Host 'PASS: exact WinGet identity and fail-closed WSL2 lifecycle contracts'

Import-Module (Join-Path $root 'modules/CodexSetup.Reporting.psm1') -Force
$summaryText = Get-CodexSetupResultSummaryText -Summary (Get-CodexSetupResultSummary -Results @(
    [pscustomobject]@{ status='Changed' }, [pscustomobject]@{ status='NoChange' }
))
Assert-True ($summaryText -eq '更新 1 项；无需修改 1 项') 'Result summary includes zero-value counters or omits completed work.'
$gitConfigFixture = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-git-state-{0}" -f [guid]::NewGuid().ToString('N'))
$previousGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
try {
    $env:GIT_CONFIG_GLOBAL = $gitConfigFixture
    foreach ($entry in (Get-WindowsGitSettings).GetEnumerator()) {
        & git config --global $entry.Key $entry.Value
        if ($LASTEXITCODE -ne 0) { throw "Unable to prepare Git configuration fixture for $($entry.Key)." }
    }
    Assert-True ((Get-WindowsGitConfigState -GitPath (Get-Command git).Source -ConfigPath $gitConfigFixture).ready) `
        'A matching Windows Git baseline was not recognized.'
    & git config --global pull.ff false
    Assert-True (-not (Get-WindowsGitConfigState -GitPath (Get-Command git).Source -ConfigPath $gitConfigFixture).ready) `
        'A stale Windows Git baseline was accepted.'
}
finally {
    $env:GIT_CONFIG_GLOBAL = $previousGitConfigGlobal
    if (Test-Path -LiteralPath $gitConfigFixture) { Remove-Item -LiteralPath $gitConfigFixture -Force }
}
Import-Module (Join-Path $root 'modules/CodexSetup.Actions.psm1') -Force
$actionsModule = Get-Module 'CodexSetup.Actions'
$configFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-config-{0}" -f [guid]::NewGuid().ToString('N'))
$previousUserProfile = $env:USERPROFILE
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:USERPROFILE = $configFixtureRoot
    $env:LOCALAPPDATA = Join-Path $configFixtureRoot 'state'
    [void](New-Item -ItemType Directory -Path (Join-Path $configFixtureRoot '.codex') -Force)
    [System.IO.File]::WriteAllText((Join-Path $configFixtureRoot '.codex/config.toml'), '', [Text.UTF8Encoding]::new($false))
    Initialize-SetupRuntime | Out-Null
    $configOutcome = & $actionsModule { param($Config) Set-CodexGlobalConfig -Config $Config } $validatedConfig
    $agentsOutcome = & $actionsModule {
        Set-GlobalAgents -Action ([pscustomobject]@{ parameters=[pscustomobject]@{ mode='WslFirst' } })
    }
    Complete-SetupRuntime
    Assert-True ($configOutcome.status -eq 'Changed' -and (Get-CodexConfigState -Config $validatedConfig).ready) `
        'Writing an empty config.toml did not produce the configured state.'
    Assert-True ($agentsOutcome.status -eq 'Changed' -and (Get-GlobalAgentsState -EnvironmentMode WslFirst).ready) `
        'Writing global environment rules did not produce the configured state.'
}
finally {
    $env:USERPROFILE = $previousUserProfile
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $configFixtureRoot) { Remove-Item -LiteralPath $configFixtureRoot -Recurse -Force }
}
Write-Host 'PASS: empty Codex config and global rules converge to the detected target state'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-v2-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $nodeProject = Join-Path $fixtureRoot 'node'
    [void](New-Item -ItemType Directory -Path $nodeProject -Force)
    @{
        packageManager='pnpm@11.0.0'
        scripts=[ordered]@{ dev='vite'; test='vitest'; lint='eslint .' }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $nodeProject 'package.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $nodeProject 'pnpm-lock.yaml') -Value 'lockfileVersion: 11' -Encoding utf8
    $nodeCommands = & $actionsModule { param($Path) Get-DeclaredProjectCommands -ProjectPath $Path -EnvironmentMode 'WindowsNative' } $nodeProject
    Assert-True ($nodeCommands.Setup -eq 'pnpm install --frozen-lockfile') 'Node setup must follow the pnpm lockfile.'
    Assert-True ($nodeCommands.Dev -eq 'pnpm run dev') 'Declared Node dev command is missing.'
    Assert-True ($nodeCommands.Test -eq 'pnpm run test') 'Declared Node test command is missing.'
    Assert-True (-not $nodeCommands.Contains('Build')) 'An undeclared Node build command was invented.'

    $pythonProject = Join-Path $fixtureRoot 'python'
    [void](New-Item -ItemType Directory -Path (Join-Path $pythonProject 'tests') -Force)
    Set-Content -LiteralPath (Join-Path $pythonProject 'uv.lock') -Value 'version = 1' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $pythonProject 'pyproject.toml') -Encoding utf8 -Value @'
[project]
name = "fixture"
dependencies = ["pytest", "ruff"]

[tool.uv]
package = false

[tool.pytest.ini_options]
addopts = "-q"

[tool.ruff]
line-length = 100
'@
    $pythonCommands = & $actionsModule { param($Path) Get-DeclaredProjectCommands -ProjectPath $Path -EnvironmentMode 'WindowsNative' } $pythonProject
    Assert-True ($pythonCommands.Setup -eq 'uv sync --frozen') 'Python setup must follow uv.lock.'
    Assert-True ($pythonCommands.Test -eq 'uv run pytest') 'Declared pytest command is missing.'
    Assert-True ($pythonCommands.Lint -eq 'uv run ruff check .') 'Declared ruff lint command is missing.'

    $commentOnlyProject = Join-Path $fixtureRoot 'comment-only-python'
    [void](New-Item -ItemType Directory -Path (Join-Path $commentOnlyProject 'tests') -Force)
    Set-Content -LiteralPath (Join-Path $commentOnlyProject 'uv.lock') -Value 'version = 1' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $commentOnlyProject 'pyproject.toml') -Value "[tool.uv]`n# pytest and ruff are not configured" -Encoding utf8
    $commentCommands = & $actionsModule { param($Path) Get-DeclaredProjectCommands -ProjectPath $Path -EnvironmentMode 'WindowsNative' } $commentOnlyProject
    Assert-True (-not $commentCommands.Contains('Test')) 'A pyproject comment invented a pytest command.'
    Assert-True (-not $commentCommands.Contains('Lint')) 'A pyproject comment invented a ruff command.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
Write-Host 'PASS: evidence-driven project command templates'

function New-RollbackFixtureManifest {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [AllowEmptyCollection()][object[]]$InstalledPackages = @(),
        [ValidateSet('Completed', 'Interrupted')][string]$RunStatus = 'Completed'
    )
    $runRoot = Join-Path (Join-Path $StateRoot 'runs') $RunId
    [void](New-Item -ItemType Directory -Path (Join-Path $runRoot 'backups') -Force)
    $manifestPath = Join-Path $runRoot 'rollback-manifest.json'
    & $commonModule { param($Root, $Id) New-RollbackAuthenticationKey -RunRoot $Root -RunId $Id | Out-Null } $runRoot $RunId
    $binding = & $commonModule { Get-RollbackEnvironmentBinding }
    Write-RollbackManifestAtomic -Path $manifestPath -Manifest ([ordered]@{
        schemaVersion=3
        runId=$RunId
        createdAt=(Get-Date).ToString('o')
        hostBinding=$binding.hostBinding
        userBinding=$binding.userBinding
        manifestHmac=$null
        runStatus=$RunStatus
        completed=($RunStatus -eq 'Completed')
        completedAt=(Get-Date).ToString('o')
        changeCount=($Files.Count + $InstalledPackages.Count)
        hasChanges=(($Files.Count + $InstalledPackages.Count) -gt 0)
        rolledBackAt=$null
        files=$Files
        installedPackages=$InstalledPackages
        notes=@()
    })
    return $manifestPath
}

function New-NewFileRollbackRecord {
    param([Parameter(Mandatory)][string]$Path)
    [ordered]@{
        path=[System.IO.Path]::GetFullPath($Path)
        existed=$false
        backup=$null
        beforeSha256=$null
        appliedSha256=(Get-SetupSha256 -Path $Path)
        backupSha256=$null
        beforeSddl=$null
        appliedSddl=$null
        managedKind='ProjectTemplate'
        managedRoot=[System.IO.Path]::GetFullPath((Split-Path -Parent $Path))
        rollbackStatus='Pending'
        rollbackError=$null
    }
}

$rollbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-rollback-{0}" -f [guid]::NewGuid().ToString('N'))
$rollbackLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $rollbackRoot 'runtime'
    Initialize-SetupRuntime | Out-Null
    $projectRoot = Join-Path $rollbackRoot 'project'
    [void](New-Item -ItemType Directory -Path $projectRoot -Force)
    $targets = @('AGENTS.md', '.editorconfig') | ForEach-Object {
        $path = Join-Path $projectRoot $_
        [System.IO.File]::WriteAllText($path, "managed`n", [Text.UTF8Encoding]::new($false))
        $path
    }
    $stateRoot = Join-Path $rollbackRoot 'state'
    $manifest = New-RollbackFixtureManifest -StateRoot $stateRoot -RunId 'normal' `
        -Files @($targets | ForEach-Object { New-NewFileRollbackRecord -Path $_ })
    $preview = Invoke-CodexSetupRollback -ManifestPath $manifest -StateRoot $stateRoot -NonInteractive -WhatIf -Confirm:$false 6>$null
    Assert-True ($preview.status -eq 'Preview' -and @($targets | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) `
        'Rollback preview changed managed files.'
    $rollback = Invoke-CodexSetupRollback -ManifestPath $manifest -StateRoot $stateRoot -NonInteractive -Confirm:$false 6>$null
    Assert-True ($rollback.status -eq 'Completed' -and $rollback.removed -eq 2 -and
        @($targets | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) `
        'Rollback did not remove the files created by setup.'

    $tamperRoot = Join-Path $rollbackRoot 'tamper-project'
    [void](New-Item -ItemType Directory -Path $tamperRoot -Force)
    $firstTarget = Join-Path $tamperRoot 'AGENTS.md'
    $secondTarget = Join-Path $tamperRoot '.editorconfig'
    [System.IO.File]::WriteAllText($firstTarget, "managed`n", [Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($secondTarget, "managed`n", [Text.UTF8Encoding]::new($false))
    $tamperManifest = New-RollbackFixtureManifest -StateRoot (Join-Path $rollbackRoot 'tamper-state') -RunId 'tampered' `
        -Files @((New-NewFileRollbackRecord -Path $firstTarget), (New-NewFileRollbackRecord -Path $secondTarget))
    [System.IO.File]::WriteAllText($secondTarget, "user change`n", [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Invoke-CodexSetupRollback -ManifestPath $tamperManifest -StateRoot (Join-Path $rollbackRoot 'tamper-state') `
            -NonInteractive -Confirm:$false 6>$null
    } 'Rollback must stop before changing files when a target was edited later.'
    Assert-True (Test-Path -LiteralPath $firstTarget) 'Rollback changed an earlier file before validating every target.'
}
finally {
    Complete-SetupRuntime
    $env:LOCALAPPDATA = $rollbackLocalAppData
    if (Test-Path -LiteralPath $rollbackRoot) { Remove-Item -LiteralPath $rollbackRoot -Recurse -Force }
}
Write-Host 'PASS: rollback preview, apply, and changed-target prevalidation'

$entryPath = Join-Path $root 'Start-CodexSetup.ps1'
. $entryPath

$remainingFixturePlan = [pscustomobject]@{
    actions=@(
        [pscustomobject]@{ id='done' },
        [pscustomobject]@{ id='restart' },
        [pscustomobject]@{ id='failed' }
    )
    blockingReasons=@('original blocker')
}
$remainingFixture = Get-RemainingSetupPlan -Plan $remainingFixturePlan -Results @(
    [pscustomobject]@{ id='done'; status='Changed' },
    [pscustomobject]@{ id='restart'; status='RestartRequired' },
    [pscustomobject]@{ id='failed'; status='Failed' }
)
Assert-True ((@($remainingFixture.actions.id) -join ',') -eq 'restart,failed') `
    'Remaining-plan calculation did not remove only locally verified actions.'
Assert-True ($remainingFixture.blockingReasons[0] -eq 'original blocker') `
    'Remaining-plan calculation lost the original blocker.'

$baseWorkflow = [pscustomobject]@{
    runtime=[pscustomobject]@{ RunId='contract'; LogPath='contract.log'; ManifestPath='contract-manifest.json' }
    config=[pscustomobject]@{ environmentMode='WslFirst' }
    detection=[pscustomobject]@{ issues=@() }
    plan=[pscustomobject]@{ actions=@(); blockingReasons=@('fixture blocker') }
    results=@()
    remainingPlan=$null
    whatIfRun=$false
    reportPath='contract-report.md'
}
$blockedMachineResult = New-WorkflowMachineResult -WorkflowResult $baseWorkflow -InvocationMode Apply -RequestedApply:$true
Assert-True ($blockedMachineResult.status -eq 'NeedsAttention' -and $blockedMachineResult.exitCode -eq 20) `
    'An original planning blocker must produce NeedsAttention/20.'
Assert-True (@($blockedMachineResult.blockingReasons).Count -eq 1) `
    'The machine result must expose original planning blockers.'
$baseWorkflow.results = @([pscustomobject]@{ status='RestartRequired' })
$blockedRestartResult = New-WorkflowMachineResult -WorkflowResult $baseWorkflow -InvocationMode Apply -RequestedApply:$true
Assert-True ($blockedRestartResult.status -eq 'NeedsAttention' -and $blockedRestartResult.exitCode -eq 20) `
    'A planning blocker must not be hidden by a restart result.'
$baseWorkflow.results = @()

$baseWorkflow.plan = [pscustomobject]@{ actions=@(); blockingReasons=@() }
$baseWorkflow.remainingPlan = [pscustomobject]@{ actions=@(); blockingReasons=@('remaining blocker') }
$remainingBlockedResult = New-WorkflowMachineResult -WorkflowResult $baseWorkflow -InvocationMode Detect -RequestedApply:$false
Assert-True ($remainingBlockedResult.status -eq 'NeedsAttention' -and $remainingBlockedResult.exitCode -eq 20) `
    'A verification planning blocker must produce NeedsAttention/20.'
Assert-True ($remainingBlockedResult.blockingReasons[0] -eq 'remaining blocker') `
    'The machine result must prefer remaining-plan blockers after verification.'

$baseWorkflow.remainingPlan = [pscustomobject]@{ actions=@(); blockingReasons=@() }
$resolvedMachineResult = New-WorkflowMachineResult -WorkflowResult $baseWorkflow -InvocationMode Apply -RequestedApply:$true
Assert-True ($resolvedMachineResult.status -eq 'Succeeded' -and $resolvedMachineResult.exitCode -eq 0) `
    'Resolved blockers must not survive an empty verification plan.'

Assert-True (Test-SetupProcessExitRequired -InvocationMode Apply -WasModeExplicit:$true -WasDotSourced:$false `
    -IsNonInteractive:$false -MachineResultPath $null) 'An explicit Apply mode must return its process exit code.'
Assert-True (Test-SetupProcessExitRequired -InvocationMode Detect -WasModeExplicit:$false -WasDotSourced:$false `
    -IsNonInteractive:$false -MachineResultPath 'result.json') 'A result JSON request must return its process exit code.'
Assert-True (Test-SetupProcessExitRequired -InvocationMode Rollback -WasModeExplicit:$false -WasDotSourced:$false `
    -IsNonInteractive:$true -MachineResultPath $null) 'A non-interactive rollback must return its process exit code.'
Assert-True (-not (Test-SetupProcessExitRequired -InvocationMode Apply -WasModeExplicit:$true -WasDotSourced:$true `
    -IsNonInteractive:$true -MachineResultPath 'result.json')) 'Dot-sourcing must never terminate the test process.'
Write-Host 'PASS: planning blockers and entry-point exit code contracts'

Write-Host 'PASS: configuration and setup behaviors'
