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
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim() -eq '0.1.0') 'The repository version must remain 0.1.0.'
Assert-True ('scriptVersion' -notin $config.PSObject.Properties.Name) 'Config must not duplicate the program version.'
Assert-True ('profileName' -notin $config.PSObject.Properties.Name) 'Config must not contain an unused profile name.'
Assert-True ($config.environmentMode -eq 'WslFirst') 'WslFirst must be the default mode.'
Assert-True ('language' -notin $config.preferences.PSObject.Properties.Name) 'Config must not contain an unused language field.'
Assert-True ('failurePolicy' -notin $config.preferences.PSObject.Properties.Name) 'Config must not contain an unused failure policy.'
Assert-True ($config.wsl.distribution -eq 'Ubuntu-24.04') 'The WSL distribution must be exact.'
Assert-True ($config.wsl.packages.Count -gt 0) 'The WSL package list must not be empty.'
Assert-True ('packageGroups' -notin $config.wsl.PSObject.Properties.Name) 'Pseudo-optional package groups must not remain.'
Assert-True ($config.wsl.installCodexCli -eq $true) 'Codex CLI must be installed in WSL.'
Assert-True ($config.wsl.installPnpm -eq $true) 'pnpm must be installed in WSL.'
Assert-True ($config.wsl.configureGit -eq $true) 'Git baseline must be configured in WSL.'
Assert-True ((@($config.toolchains.node.PSObject.Properties.Name) -join ',') -eq 'enabled') 'Node manager is fixed by v2 and must not be duplicated in config.'
Assert-True ((@($config.toolchains.python.PSObject.Properties.Name) -join ',') -eq 'enabled') 'Python manager is fixed to uv and must not be duplicated in config.'
Assert-True ($config.codex.windowsSandbox -eq 'elevated') 'Windows native sandbox must default to elevated.'

$legacyNames = @(
    'agentStrategy',
    'terminalStrategy',
    'shareWindowsHomeToWsl',
    'manageMcpPluginsSkills',
    'wslEnvironment',
    'wslNetworking',
    'interviewAnswers',
    'configureWindowsGit',
    'overwriteExistingWithoutConfirmation',
    'Merge-MissingSetupConfig',
    'CheckAndPrompt',
    'packageGroups',
    'profileName',
    'failurePolicy'
)

$implementationFiles = @(
    $configPath
    Join-Path $root 'Start-CodexSetup.ps1'
    Join-Path $root 'Bootstrap-CodexSetup.ps1'
    Get-ChildItem -LiteralPath (Join-Path $root 'modules') -File -Filter '*.psm1' | Select-Object -ExpandProperty FullName
    Get-ChildItem -LiteralPath (Join-Path $root 'wsl') -File | Select-Object -ExpandProperty FullName
    Get-ChildItem -LiteralPath (Join-Path $root 'templates') -File -Recurse | Select-Object -ExpandProperty FullName
)
$implementationText = ($implementationFiles | ForEach-Object {
    Get-Content -LiteralPath $_ -Raw
}) -join "`n"

foreach ($legacyName in $legacyNames) {
    Assert-True (-not $implementationText.Contains($legacyName)) "Legacy field remains: $legacyName"
}
Assert-True (-not $implementationText.Contains('on-failure')) 'Deprecated approval policy remains.'
Assert-True (-not $implementationText.Contains('.recommendation.agent')) 'Reporting still reads the v1 agent recommendation.'
Assert-True (-not $implementationText.Contains('.recommendation.terminal')) 'Reporting still reads the v1 terminal recommendation.'
Assert-True (-not $implementationText.Contains('Codex WSL (Ubuntu)')) 'Legacy Terminal profile guidance remains.'
$literalVersionPattern = [regex]::Escape("`$scriptVersion = '") + '[0-9]'
Assert-True (-not [regex]::IsMatch($implementationText, $literalVersionPattern)) 'Program version must be read from VERSION, not duplicated in source.'

Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'templates/project/config.toml.template'))) 'Project personal config template must not exist.'
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

Import-Module (Join-Path $root 'modules/CodexSetup.Planning.psm1') -Force
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

$windowsConfig = $validatedConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$windowsConfig.environmentMode = 'WindowsNative'
$windowsPlan = Get-CodexSetupPlan -Detection $mockDetection -Config $windowsConfig -ProjectPath $null
$windowsActionTypes = @($windowsPlan.actions.type)
Assert-True ('WslConfigure' -notin $windowsActionTypes) 'WindowsNative must not configure a WSL toolchain.'
Assert-True (@($windowsPlan.actions | Where-Object { $_.type -eq 'WingetInstall' -and $_.target -eq 'OpenJS.NodeJS.LTS' }).Count -eq 1) `
    'WindowsNative must install one native Node.js LTS package.'
Assert-True ('PythonConfigure' -in $windowsActionTypes) 'WindowsNative must configure its Windows Python toolchain.'
Assert-True ('WindowsGitConfig' -in $windowsActionTypes) 'WindowsNative must configure Windows Git.'
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
$unknownCatalogPlan = Get-CodexSetupPlan -Detection $unknownCatalogDetection -Config $validatedConfig -ProjectPath $null
Assert-True (@($unknownCatalogPlan.actions | Where-Object type -eq 'WingetInstall').Count -eq 0) `
    'An unknown WinGet catalog must fail closed without install actions.'
Assert-True (@($unknownCatalogPlan.warnings | Where-Object { $_ -match '状态未知|可信' }).Count -gt 0) `
    'An unknown WinGet catalog must produce an actionable warning.'

foreach ($case in @(
    @{ State='FeatureDisabled'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='NoDistribution'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='TargetMissing'; Required='InstallWslDistribution'; Forbidden=@('ConfigureWsl') }
    @{ State='Ready'; Required='ConfigureWsl'; Forbidden=@('InstallWslDistribution') }
    @{ State='Unknown'; Required=$null; Forbidden=@('InstallWslDistribution', 'ConfigureWsl', 'UpdateWsl', 'SetWsl2Default') }
    @{ State='UnsupportedWsl1'; Required=$null; Forbidden=@('InstallWslDistribution', 'ConfigureWsl', 'UpdateWsl', 'SetWsl2Default') }
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

Import-Module (Join-Path $root 'modules/CodexSetup.Actions.psm1') -Force
$actionsModule = Get-Module 'CodexSetup.Actions'
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
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'templates/project/.codex/config.toml.template'))) 'Project templates must not contain personal Codex policy.'

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

$rollbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-rollback-v3-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $rollbackRoot -Force)

    $thousandRecords = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 1000; $index++) {
        $projectRoot = Join-Path $rollbackRoot ("projects/{0:D4}" -f $index)
        [void](New-Item -ItemType Directory -Path $projectRoot -Force)
        $target = Join-Path $projectRoot 'AGENTS.md'
        [System.IO.File]::WriteAllText($target, "managed-$index`n", [Text.UTF8Encoding]::new($false))
        $thousandRecords.Add((New-NewFileRollbackRecord -Path $target))
    }
    $thousandStateRoot = Join-Path $rollbackRoot 'state-1000'
    $thousandManifest = New-RollbackFixtureManifest -StateRoot $thousandStateRoot -RunId 'exactly-1000' -Files @($thousandRecords)
    $preview = Invoke-CodexSetupRollback -ManifestPath $thousandManifest -StateRoot $thousandStateRoot -NonInteractive -WhatIf -Confirm:$false
    Assert-True ($preview.status -eq 'Preview') 'Rollback preview did not report Preview.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $rollbackRoot 'projects') -Filter AGENTS.md -File -Recurse).Count -eq 1000) `
        'Rollback preview changed one or more files.'
    $rolledBack = Invoke-CodexSetupRollback -ManifestPath $thousandManifest -StateRoot $thousandStateRoot -NonInteractive -Confirm:$false
    Assert-True ($rolledBack.status -eq 'Completed' -and $rolledBack.removed -eq 1000) `
        'Rollback did not process all 1000 records.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $rollbackRoot 'projects') -Filter AGENTS.md -File -Recurse).Count -eq 0) `
        'Rollback truncated the 1000-record manifest.'
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $thousandManifest -StateRoot $thousandStateRoot -NonInteractive -Confirm:$false } `
        'A completed rollback must be rejected on the second attempt.'

    $legacyProject = Join-Path $rollbackRoot 'legacy-project'
    [void](New-Item -ItemType Directory -Path $legacyProject -Force)
    $legacyTarget = Join-Path $legacyProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($legacyTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $legacyStateRoot = Join-Path $rollbackRoot 'state-legacy'
    $legacyManifest = New-RollbackFixtureManifest -StateRoot $legacyStateRoot -RunId 'legacy-schema' `
        -Files @((New-NewFileRollbackRecord -Path $legacyTarget))
    $legacyDocument = Get-Content -LiteralPath $legacyManifest -Raw | ConvertFrom-Json -DateKind String
    $legacyDocument.schemaVersion = 2
    Write-RollbackManifestAtomic -Path $legacyManifest -Manifest $legacyDocument
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $legacyManifest -StateRoot $legacyStateRoot -NonInteractive -Confirm:$false } `
        'A v2 rollback manifest must be rejected without migration or a compatibility wrapper.'
    Assert-True (Test-Path -LiteralPath $legacyTarget -PathType Leaf) 'Rejecting a legacy manifest modified its target.'

    $integrityProject = Join-Path $rollbackRoot 'integrity-project'
    [void](New-Item -ItemType Directory -Path $integrityProject -Force)
    $integrityTarget = Join-Path $integrityProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($integrityTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $integrityStateRoot = Join-Path $rollbackRoot 'state-integrity'
    $integrityManifest = New-RollbackFixtureManifest -StateRoot $integrityStateRoot -RunId 'manifest-integrity' `
        -Files @((New-NewFileRollbackRecord -Path $integrityTarget))
    $integrityDocument = Get-Content -LiteralPath $integrityManifest -Raw | ConvertFrom-Json -DateKind String
    $integrityDocument.files[0].managedRoot = [System.IO.Path]::GetFullPath($rollbackRoot)
    Write-SetupJsonAtomic -Path $integrityManifest -Value $integrityDocument
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $integrityManifest -StateRoot $integrityStateRoot -NonInteractive -Confirm:$false } `
        'An unsigned managed-root edit must fail manifest authentication.'
    Assert-True (Test-Path -LiteralPath $integrityTarget -PathType Leaf) 'Manifest tampering modified its target.'

    $bindingProject = Join-Path $rollbackRoot 'binding-project'
    [void](New-Item -ItemType Directory -Path $bindingProject -Force)
    $bindingTarget = Join-Path $bindingProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($bindingTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $bindingStateRoot = Join-Path $rollbackRoot 'state-binding'
    $bindingManifest = New-RollbackFixtureManifest -StateRoot $bindingStateRoot -RunId 'wrong-user-binding' `
        -Files @((New-NewFileRollbackRecord -Path $bindingTarget))
    $bindingDocument = Get-Content -LiteralPath $bindingManifest -Raw | ConvertFrom-Json -DateKind String
    $bindingDocument.userBinding = '0' * 64
    Write-RollbackManifestAtomic -Path $bindingManifest -Manifest $bindingDocument
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $bindingManifest -StateRoot $bindingStateRoot -NonInteractive -Confirm:$false } `
        'A manifest bound to another user must be rejected.'
    Assert-True (Test-Path -LiteralPath $bindingTarget -PathType Leaf) 'Binding validation modified its target.'

    $keyProject = Join-Path $rollbackRoot 'key-project'
    [void](New-Item -ItemType Directory -Path $keyProject -Force)
    $keyTarget = Join-Path $keyProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($keyTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $keyStateRoot = Join-Path $rollbackRoot 'state-key'
    $keyManifest = New-RollbackFixtureManifest -StateRoot $keyStateRoot -RunId 'tampered-key' `
        -Files @((New-NewFileRollbackRecord -Path $keyTarget))
    $keyPath = Join-Path (Split-Path -Parent $keyManifest) 'rollback-auth.key'
    $keyBytes = [System.IO.File]::ReadAllBytes($keyPath)
    $keyBytes[$keyBytes.Length - 1] = $keyBytes[$keyBytes.Length - 1] -bxor 1
    [System.IO.File]::WriteAllBytes($keyPath, $keyBytes)
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $keyManifest -StateRoot $keyStateRoot -NonInteractive -Confirm:$false } `
        'A tampered rollback authentication key must be rejected.'
    Assert-True (Test-Path -LiteralPath $keyTarget -PathType Leaf) 'Key validation modified its target.'

    $statusProject = Join-Path $rollbackRoot 'status-project'
    [void](New-Item -ItemType Directory -Path $statusProject -Force)
    $statusTarget = Join-Path $statusProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($statusTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $statusStateRoot = Join-Path $rollbackRoot 'state-status'
    $statusManifest = New-RollbackFixtureManifest -StateRoot $statusStateRoot -RunId 'status-contradiction' `
        -Files @((New-NewFileRollbackRecord -Path $statusTarget))
    $statusDocument = Get-Content -LiteralPath $statusManifest -Raw | ConvertFrom-Json -DateKind String
    $statusDocument.completed = $false
    Write-RollbackManifestAtomic -Path $statusManifest -Manifest $statusDocument
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $statusManifest -StateRoot $statusStateRoot -AllowIncompleteRun -NonInteractive -Confirm:$false } `
        'A signed but contradictory run status must be rejected.'
    Assert-True (Test-Path -LiteralPath $statusTarget -PathType Leaf) 'Status validation modified its target.'

    $packageProject = Join-Path $rollbackRoot 'package-version-project'
    [void](New-Item -ItemType Directory -Path $packageProject -Force)
    $packageTarget = Join-Path $packageProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($packageTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $packageStateRoot = Join-Path $rollbackRoot 'state-package-version'
    $packageRecord = [ordered]@{
        id='GitHub.cli'
        source='winget'
        installedVersion='1.0.0'
        rollbackStatus='Pending'
        rollbackError=$null
    }
    $packageManifest = New-RollbackFixtureManifest -StateRoot $packageStateRoot -RunId 'package-version-changed' `
        -Files @((New-NewFileRollbackRecord -Path $packageTarget)) -InstalledPackages @($packageRecord)
    & $actionsModule {
        Set-Item -Path Function:script:Get-WindowsPackageCatalog -Value {
            [pscustomobject]@{ state='Known'; complete=$false; packages=@(); error=$null }
        }
        Set-Item -Path Function:script:Get-WindowsPackageState -Value {
            param($PackageId, $Source, $Catalog)
            [pscustomobject]@{ state='KnownInstalled'; installed=$true; version='2.0.0'; error=$null }
        }
    }
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $packageManifest -StateRoot $packageStateRoot -NonInteractive -Confirm:$false } `
        'A package upgraded after setup must be rejected before rollback mutations.'
    Assert-True (Test-Path -LiteralPath $packageTarget -PathType Leaf) 'Package version prevalidation modified an earlier file target.'

    $missingPackageStateRoot = Join-Path $rollbackRoot 'state-package-missing'
    $missingPackageRecord = [ordered]@{
        id='GitHub.cli'
        source='winget'
        installedVersion='1.0.0'
        rollbackStatus='Pending'
        rollbackError=$null
    }
    $missingPackageManifest = New-RollbackFixtureManifest -StateRoot $missingPackageStateRoot -RunId 'package-already-missing' `
        -Files @() -InstalledPackages @($missingPackageRecord)
    & $actionsModule {
        Set-Item -Path Function:script:Get-WindowsPackageState -Value {
            param($PackageId, $Source, $Catalog)
            [pscustomobject]@{ state='KnownMissing'; installed=$false; version=$null; error=$null }
        }
    }
    $missingPackageRollback = Invoke-CodexSetupRollback -ManifestPath $missingPackageManifest -StateRoot $missingPackageStateRoot `
        -NonInteractive -Confirm:$false
    Assert-True ($missingPackageRollback.status -eq 'Completed' -and $missingPackageRollback.uninstalled -eq 0) `
        'An already absent package did not converge as NoChange.'
    & $actionsModule {
        Remove-Item -Path Function:script:Get-WindowsPackageState -Force
        Remove-Item -Path Function:script:Get-WindowsPackageCatalog -Force
    }

    $tamperRoot = Join-Path $rollbackRoot 'tamper-project'
    [void](New-Item -ItemType Directory -Path $tamperRoot -Force)
    $untouchedTarget = Join-Path $tamperRoot 'AGENTS.md'
    $tamperedTarget = Join-Path $tamperRoot '.editorconfig'
    [System.IO.File]::WriteAllText($untouchedTarget, "applied-one`n", [Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($tamperedTarget, "applied-two`n", [Text.UTF8Encoding]::new($false))
    $tamperRecords = @(
        New-NewFileRollbackRecord -Path $untouchedTarget
        New-NewFileRollbackRecord -Path $tamperedTarget
    )
    [System.IO.File]::WriteAllText($tamperedTarget, "user-change`n", [Text.UTF8Encoding]::new($false))
    $tamperStateRoot = Join-Path $rollbackRoot 'state-tamper'
    $tamperManifest = New-RollbackFixtureManifest -StateRoot $tamperStateRoot -RunId 'tampered-target' -Files $tamperRecords
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $tamperManifest -StateRoot $tamperStateRoot -NonInteractive -Confirm:$false } `
        'A tampered target must fail the complete prevalidation.'
    Assert-True (Test-Path -LiteralPath $untouchedTarget -PathType Leaf) `
        'Rollback modified an earlier record before discovering a later tampered target.'

    $backupProject = Join-Path $rollbackRoot 'backup-project'
    $backupStateRoot = Join-Path $rollbackRoot 'state-backup'
    $backupRunRoot = Join-Path (Join-Path $backupStateRoot 'runs') 'wrong-backup-hash'
    $backupRoot = Join-Path $backupRunRoot 'backups'
    [void](New-Item -ItemType Directory -Path $backupProject -Force)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    $backupTarget = Join-Path $backupProject 'AGENTS.md'
    $backupPath = Join-Path $backupRoot 'AGENTS.md'
    [System.IO.File]::WriteAllText($backupTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($backupPath, "before`n", [Text.UTF8Encoding]::new($false))
    $backupRecord = [ordered]@{
        path=[System.IO.Path]::GetFullPath($backupTarget); existed=$true; backup=[System.IO.Path]::GetFullPath($backupPath)
        beforeSha256=(Get-SetupSha256 -Path $backupPath); appliedSha256=(Get-SetupSha256 -Path $backupTarget)
        backupSha256=('0' * 64); beforeSddl=$null; appliedSddl=$null
        managedKind='ProjectTemplate'; managedRoot=[System.IO.Path]::GetFullPath($backupProject)
        rollbackStatus='Pending'; rollbackError=$null
    }
    $backupManifest = New-RollbackFixtureManifest -StateRoot $backupStateRoot -RunId 'wrong-backup-hash' -Files @($backupRecord)
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $backupManifest -StateRoot $backupStateRoot -NonInteractive -Confirm:$false } `
        'A bad backup hash must fail before modifying its target.'
    Assert-True ((Get-Content -LiteralPath $backupTarget -Raw) -eq "applied`n") 'Bad backup validation modified the target.'

    if ($IsLinux) {
        $hardlinkProject = Join-Path $rollbackRoot 'hardlink-project'
        $hardlinkStateRoot = Join-Path $rollbackRoot 'state-hardlink'
        $hardlinkRunRoot = Join-Path (Join-Path $hardlinkStateRoot 'runs') 'hardlink-restore'
        $hardlinkBackupRoot = Join-Path $hardlinkRunRoot 'backups'
        [void](New-Item -ItemType Directory -Path $hardlinkProject -Force)
        [void](New-Item -ItemType Directory -Path $hardlinkBackupRoot -Force)
        $hardlinkTarget = Join-Path $hardlinkProject 'AGENTS.md'
        $hardlinkPeer = Join-Path $hardlinkProject 'peer.txt'
        $hardlinkBackup = Join-Path $hardlinkBackupRoot 'AGENTS.md'
        [System.IO.File]::WriteAllText($hardlinkPeer, "applied`n", [Text.UTF8Encoding]::new($false))
        & ln $hardlinkPeer $hardlinkTarget
        [System.IO.File]::WriteAllText($hardlinkBackup, "before`n", [Text.UTF8Encoding]::new($false))
        $hardlinkRecord = [ordered]@{
            path=[System.IO.Path]::GetFullPath($hardlinkTarget); existed=$true; backup=[System.IO.Path]::GetFullPath($hardlinkBackup)
            beforeSha256=(Get-SetupSha256 -Path $hardlinkBackup); appliedSha256=(Get-SetupSha256 -Path $hardlinkTarget)
            backupSha256=(Get-SetupSha256 -Path $hardlinkBackup); beforeSddl=$null; appliedSddl=$null
            managedKind='ProjectTemplate'; managedRoot=[System.IO.Path]::GetFullPath($hardlinkProject)
            rollbackStatus='Pending'; rollbackError=$null
        }
        $hardlinkManifest = New-RollbackFixtureManifest -StateRoot $hardlinkStateRoot -RunId 'hardlink-restore' -Files @($hardlinkRecord)
        $hardlinkRollback = Invoke-CodexSetupRollback -ManifestPath $hardlinkManifest -StateRoot $hardlinkStateRoot -NonInteractive -Confirm:$false
        Assert-True ($hardlinkRollback.status -eq 'Completed' -and $hardlinkRollback.restored -eq 1) `
            'An existing file was not restored through atomic replacement.'
        Assert-True ((Get-Content -LiteralPath $hardlinkTarget -Raw) -eq "before`n") 'The restored target has the wrong content.'
        Assert-True ((Get-Content -LiteralPath $hardlinkPeer -Raw) -eq "applied`n") 'Rollback wrote through a hardlink into an unrelated peer.'
    }

    $interruptedProject = Join-Path $rollbackRoot 'interrupted-project'
    [void](New-Item -ItemType Directory -Path $interruptedProject -Force)
    $interruptedTarget = Join-Path $interruptedProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($interruptedTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $interruptedStateRoot = Join-Path $rollbackRoot 'state-interrupted'
    $interruptedManifest = New-RollbackFixtureManifest -StateRoot $interruptedStateRoot -RunId 'interrupted' `
        -RunStatus Interrupted -Files @((New-NewFileRollbackRecord -Path $interruptedTarget))
    Assert-Throws { Invoke-CodexSetupRollback -ManifestPath $interruptedManifest -StateRoot $interruptedStateRoot -NonInteractive -Confirm:$false } `
        'An interrupted run must require explicit rollback authorization.'
    $interruptedRollback = Invoke-CodexSetupRollback -ManifestPath $interruptedManifest -StateRoot $interruptedStateRoot `
        -AllowIncompleteRun -NonInteractive -Confirm:$false
    Assert-True ($interruptedRollback.status -eq 'Completed' -and -not (Test-Path -LiteralPath $interruptedTarget)) `
        'An explicitly authorized interrupted run did not converge.'

    $partialProject = Join-Path $rollbackRoot 'partial-project'
    [void](New-Item -ItemType Directory -Path $partialProject -Force)
    $partialTarget = Join-Path $partialProject 'AGENTS.md'
    [System.IO.File]::WriteAllText($partialTarget, "applied`n", [Text.UTF8Encoding]::new($false))
    $partialStateRoot = Join-Path $rollbackRoot 'state-partial'
    $partialManifest = New-RollbackFixtureManifest -StateRoot $partialStateRoot -RunId 'partial-retry' `
        -Files @((New-NewFileRollbackRecord -Path $partialTarget))
    $lockStream = $null
    if ($IsLinux) { & chmod 500 -- $partialProject }
    else { $lockStream = [System.IO.File]::Open($partialTarget, 'Open', 'Read', 'Read') }
    try {
        $partial = Invoke-CodexSetupRollback -ManifestPath $partialManifest -StateRoot $partialStateRoot -NonInteractive -Confirm:$false
        Assert-True ($partial.status -eq 'Partial' -and $partial.failed -eq 1) 'A locked target did not produce Partial.'
    }
    finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if ($IsLinux) { & chmod 700 -- $partialProject }
    }
    $retry = Invoke-CodexSetupRollback -ManifestPath $partialManifest -StateRoot $partialStateRoot -NonInteractive -Confirm:$false
    Assert-True ($retry.status -eq 'Completed' -and -not (Test-Path -LiteralPath $partialTarget)) `
        'A retried Partial rollback did not converge.'
}
finally {
    if (Test-Path -LiteralPath $rollbackRoot) { Remove-Item -LiteralPath $rollbackRoot -Recurse -Force }
}
Write-Host 'PASS: strict rollback v3 preview, tamper safety, interruption, retry, and 1000-record contracts'

$entryPath = Join-Path $root 'Start-CodexSetup.ps1'
$entryText = Get-Content -LiteralPath $entryPath -Raw
$projectInitBlock = [regex]::Match(
    $entryText,
    '(?s)if \(\$WorkflowMode -eq ''ProjectInit''\) \{.*?\}\s*Show-CodexSetupPlan'
)
Assert-True $projectInitBlock.Success 'ProjectInit plan shaping block is missing.'
Assert-True (-not $projectInitBlock.Value.Contains('$plan.blockingReasons')) `
    'ProjectInit must preserve planning blockers.'

. $entryPath

$baseWorkflow = [pscustomobject]@{
    runtime=[pscustomobject]@{ RunId='contract'; LogPath='contract.log'; ManifestPath='contract-manifest.json' }
    config=[pscustomobject]@{ environmentMode='WslFirst' }
    detection=[pscustomobject]@{ issues=@() }
    verificationDetection=$null
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

Write-Host 'PASS: v2 configuration and template contract'
