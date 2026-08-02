#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$modules = Join-Path $root 'modules'
foreach ($name in @('CodexSetup.Common.psm1', 'CodexSetup.Detection.psm1', 'CodexSetup.Planning.psm1', 'CodexSetup.Actions.psm1')) {
    Import-Module (Join-Path $modules $name) -Force
}

$script:Passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    $script:Passed++
    Write-Host "PASS $Message" -ForegroundColor Green
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-test-" + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$originalUserProfile = $env:USERPROFILE
$originalLocalAppData = $env:LOCALAPPDATA
try {
    $env:USERPROFILE = Join-Path $testRoot 'user'
    [System.IO.Directory]::CreateDirectory($env:USERPROFILE) | Out-Null
    $config = Read-SetupConfig -Path (Join-Path $root 'config\defaults.json')
    Assert-True ($config.schemaVersion -eq 1) 'default JSON configuration loads'
    Assert-True ($config.codex.manageMcpPluginsSkills -eq $false) 'v1 leaves MCP/plugins/skills unmanaged'
    Assert-True ($config.codex.sandboxMode -eq 'workspace-write' -and $config.codex.windowsSandbox -eq 'unelevated') 'default Codex sandbox is workspace-scoped and unelevated'
    Assert-True (-not $config.codex.shareWindowsHomeToWsl) 'default WSL setup does not share Windows Codex home'
    Assert-True (-not $config.wslNetworking.configure -and $config.wslNetworking.networkingMode -eq 'mirrored') 'WSL network changes are opt-in and mirrored is the recommended target'
    $wslPackages = Get-WslPackageConfiguration -Config $config
    Assert-True ('gh' -in $wslPackages.packageNames -and 'shellcheck' -notin $wslPackages.packageNames) 'default WSL package group installs gh but keeps Shell quality tools optional'
    $shellGroup = @($config.wslEnvironment.packageGroups | Where-Object id -eq 'shell-quality' | Select-Object -First 1)
    $shellGroup[0].enabled = $true
    $wslPackagesWithShell = Get-WslPackageConfiguration -Config $config
    Assert-True ('shellcheck' -in $wslPackagesWithShell.packageNames -and 'shfmt' -in $wslPackagesWithShell.packageNames) 'enabling a WSL package group requires only a configuration change'
    $shellGroup[0].enabled = $false
    $invalidPackageConfig = $config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $invalidPackageConfig.wslEnvironment.packageGroups[0].packages[0].name = 'git;echo unsafe'
    $invalidPackageRejected = $false
    try { Get-WslPackageConfiguration -Config $invalidPackageConfig | Out-Null } catch { $invalidPackageRejected = $true }
    Assert-True $invalidPackageRejected 'WSL package configuration rejects unsafe package names'
    $partialConfig = [pscustomobject]@{ wslNetworking=[pscustomobject]@{ configure=$true; httpPort=10900 } }
    Merge-MissingSetupConfig -Target $partialConfig -Defaults $config
    Assert-True ($partialConfig.wslNetworking.httpPort -eq 10900 -and $partialConfig.wslNetworking.proxyHost -eq '127.0.0.1' -and $partialConfig.wslNetworking.firewall) 'partial exported configuration keeps overrides and receives new nested defaults'
    Assert-True ((Get-SetupModuleDisplayName -Module 'Core') -eq '基础工具') 'module display names use the shared user-facing mapping'

    $availableCommand = [pscustomobject]@{ installed=$true; probeError=$null }
    $missingCommand = [pscustomobject]@{ installed=$false; probeError=$null }
    $failedCommand = [pscustomobject]@{ installed=$false; probeError='expected probe failure' }
    $partialDetection = [pscustomobject]@{
        windows=[pscustomobject]@{ isWindows11=$true; isAdministrator=$false }
        path=[pscustomobject]@{ conflicts=@(); shadowedTools=@(); duplicateEntrypoints=@(); appAliases=@(); duplicates=@(); missing=@() }
        powershell7=$failedCommand; winget=$availableCommand; git=$availableCommand; githubCli=$availableCommand
        windowsTerminal=[pscustomobject]@{ command=$availableCommand; app=[pscustomobject]@{ installed=$true; error=$null } }
        codexDesktop=[pscustomobject]@{ installed=$true; error=$null }
        fnm=$missingCommand; uv=$availableCommand
        wsl=[pscustomobject]@{ installed=$true; ubuntu=$true; ubuntuWsl2=$true; ubuntuName='Ubuntu-Test'; error=$null }
        project=[pscustomobject]@{ agent='WSL'; terminal='WSL'; confidence='medium'; reasons=@('test') }
        healthScore=80; healthLabel='基本可用'; detectionMode='快速'
        issues=@([pscustomobject]@{ stage=3; name='PowerShell probe'; error='expected probe failure' })
    }
    $savedPathForPlan = $env:PATH
    try {
        $env:PATH = $testRoot
        $partialPlan = Get-CodexSetupPlan -Detection $partialDetection -Config $config
    }
    finally { $env:PATH = $savedPathForPlan }
    Assert-True (@($partialPlan.actions | Where-Object id -eq 'PowerShell7').Count -eq 0) 'failed detection does not become an automatic install action'
    Assert-True (@($partialPlan.actions | Where-Object id -eq 'Fnm').Count -eq 1) 'confirmed missing tool still becomes an install action'
    $fdAction = @($partialPlan.actions | Where-Object id -eq 'Fd' | Select-Object -First 1)
    $jqAction = @($partialPlan.actions | Where-Object id -eq 'Jq' | Select-Object -First 1)
    Assert-True ($fdAction.Count -eq 1 -and $fdAction[0].title -match '快速查找文件' -and $fdAction[0].reason -match '文件和文件夹') 'fd action explains its purpose in plain language'
    Assert-True ($jqAction.Count -eq 1 -and $jqAction[0].title -match '查看和处理 JSON' -and $jqAction[0].reason -match '筛选和转换') 'jq action explains its purpose in plain language'
    $planningText = Get-Content -LiteralPath (Join-Path $root 'modules\CodexSetup.Planning.psm1') -Raw -Encoding utf8
    $terminalAction = @($partialPlan.actions | Where-Object id -eq 'TerminalProfiles' | Select-Object -First 1)
    $profileAction = @($partialPlan.actions | Where-Object id -eq 'PowerShellProfile' | Select-Object -First 1)
    Assert-True ($terminalAction[0].parameters.windowsProjects -eq $config.paths.windowsProjects -and $profileAction[0].parameters.windowsProjects -eq $config.paths.windowsProjects) 'configured Windows project path flows into terminal and PowerShell actions'
    Assert-True ($planningText -match '工作步骤.*moduleIndex' -and $planningText -match '\$actionNumber') 'plan output numbers work steps and their actions'

    $aliasDirectory = Join-Path $testRoot 'Microsoft\WindowsApps'
    [System.IO.Directory]::CreateDirectory($aliasDirectory) | Out-Null
    $fakeAlias = Join-Path $aliasDirectory 'fake-gui-tool.exe'
    [System.IO.File]::WriteAllBytes($fakeAlias, [byte[]]@())
    $aliasInfo = Get-CommandInfoSafe -Name $fakeAlias -SkipAppExecutionAliasProbe
    Assert-True $aliasInfo.installed 'WindowsApps alias is detected without execution'
    Assert-True $aliasInfo.appExecutionAlias 'WindowsApps zero-byte executable is classified as an app execution alias'
    Assert-True $aliasInfo.versionProbeSkipped 'version probing is skipped for app execution aliases'
    $missingInfo = Get-CommandInfoSafe -Name ('missing-' + [guid]::NewGuid().ToString('N') + '.exe') -SkipAppExecutionAliasProbe
    Assert-True (-not $missingInfo.installed -and -not $missingInfo.appExecutionAlias) 'missing command returns a complete safe detection result'

    $env:LOCALAPPDATA = Join-Path $testRoot 'local-app-data'
    $portablePackage = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Test.Portable_x64'
    [System.IO.Directory]::CreateDirectory($portablePackage) | Out-Null
    $portableCommand = Join-Path $portablePackage 'portable-test.exe'
    Copy-Item -LiteralPath (Get-Command pwsh.exe).Source -Destination $portableCommand
    $portableInfo = Get-CommandInfoSafe -Name 'portable-test.exe' -PackageId 'Test.Portable' -SkipVersionProbe
    Assert-True ($portableInfo.installed -and $portableInfo.path -eq $portableCommand) 'portable WinGet package is detected before the current PATH refreshes'

    $gitCmdRoot = Get-ToolInstallationRoot -Tool 'git' -Path 'C:\Tools\Git\cmd\git.exe'
    $gitBinRoot = Get-ToolInstallationRoot -Tool 'git' -Path 'C:\Tools\Git\bin\git.exe'
    Assert-True ($gitCmdRoot -eq $gitBinRoot) 'Git cmd and bin entrypoints map to one installation'
    $desktopCodexRoot = Get-ToolInstallationRoot -Tool 'codex' -Path 'C:\Users\person\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe'
    $packageCodexRoot = Get-ToolInstallationRoot -Tool 'codex' -Path 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0_x64__test\app\resources\codex.exe'
    Assert-True ($desktopCodexRoot -eq $packageCodexRoot) 'Codex Desktop package entrypoints map to one installation'
    Assert-True ((Convert-WindowsPathToWsl '\\wsl.localhost\Ubuntu-24.04\home\test\setup.sh') -eq '/home/test/setup.sh') 'WSL UNC paths convert back to Linux paths'
    $distroMismatchRejected = $false
    try { Convert-WindowsPathToWsl -Path '\\wsl.localhost\Ubuntu-A\home\test\setup.sh' -ExpectedDistro 'Ubuntu-B' | Out-Null }
    catch { $distroMismatchRejected = $true }
    Assert-True $distroMismatchRejected 'WSL UNC conversion rejects a helper path from a different distro'
    Assert-True ((Get-HealthLabel -Score 92) -eq '状态良好') 'health score has a readable status label'

    $emptyListenerDetection = [pscustomobject]@{
        wslNetwork = [pscustomobject]@{
            networkingMode='mirrored'; recommendedHttpPort=10808; recommendedSocksPort=10808; loopbackListeners=@()
        }
    }
    function global:Read-Host { return '3' }
    try {
        Select-WslNetworkConfiguration -Config $config -Detection $emptyListenerDetection
        Assert-True (-not $config.wslNetworking.configure) 'network selection tolerates an empty localhost-listener result under strict mode'
    }
    finally { Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue }

    $fastWsl = Get-WslToolchainInfo -WslInfo $null -Skip
    Assert-True ($fastWsl.skipped -and -not $fastWsl.available) 'fast detection skips starting a WSL distribution'

    $stageIssues = [System.Collections.Generic.List[object]]::new()
    $stageFallback = Invoke-DetectionStage -Index 1 -Name 'test fallback' -Issues $stageIssues `
        -Operation { throw 'expected stage failure' } -Fallback { param($message) [pscustomobject]@{ recovered=$true; error=$message } }
    Assert-True ($stageFallback.recovered -and $stageIssues.Count -eq 1) 'non-critical detection failure returns a partial fallback result'

    $stageSummaryOutput = & {
        Invoke-DetectionStage -Index 1 -Name 'test summary' -Issues $stageIssues `
            -Operation { [pscustomobject]@{ result='可用' } } `
            -Fallback { param($message) [pscustomobject]@{ result='失败' } } `
            -ResultSummary { param($value) "检测结果：$($value.result)" }
    } 6>&1 | Out-String
    Assert-True ($stageSummaryOutput -match '检测结果：可用') 'successful detection stages show a concise result instead of only completed'

    $webProject = Join-Path $testRoot 'web-project'
    [System.IO.Directory]::CreateDirectory($webProject) | Out-Null
    Set-Content -LiteralPath (Join-Path $webProject 'package.json') -Value '{}' -Encoding utf8
    $recommendation = Get-ProjectRecommendation -ProjectPath $webProject -WslProjects $config.paths.wslProjects
    Assert-True ($recommendation.agent -eq 'WSL') 'web project recommends WSL'

    $nativeProject = Join-Path $testRoot 'native-project'
    [System.IO.Directory]::CreateDirectory($nativeProject) | Out-Null
    Set-Content -LiteralPath (Join-Path $nativeProject 'app.csproj') -Value '<Project><PropertyGroup><UseWPF>true</UseWPF></PropertyGroup></Project>' -Encoding utf8
    $recommendation = Get-ProjectRecommendation -ProjectPath $nativeProject -WslProjects $config.paths.wslProjects
    Assert-True ($recommendation.agent -eq 'WindowsNative') 'WPF project recommends Windows native'

    $redacted = ConvertTo-RedactedText 'token=ghp_abcdefghijklmnopqrstuvwxyz123456 secret=hello'
    Assert-True ($redacted -notmatch 'abcdefghijklmnopqrstuvwxyz|hello') 'log redaction removes obvious secrets'

    Initialize-SetupRuntime -RunId 'smoke' -StateRoot (Join-Path $testRoot 'state') | Out-Null
    Write-SetupLog -Message 'structured redaction test' -Data @{
        token='supersecretvalue'; nested=@{ password='secretpass'; authorization='Bearer abcdefghijklmnop' }
    }
    $logText = Get-Content -LiteralPath (Get-SetupRuntime).LogPath -Raw -Encoding utf8
    Assert-True ($logText -notmatch 'supersecretvalue|secretpass|abcdefghijklmnop' -and $logText -match '\[REDACTED\]') 'structured log data redacts token, password, and authorization values'
    $globalAction = [pscustomobject]@{
        module='CodexConfig'; id='GlobalCodexConfig'; title='test config'; type='CodexGlobalConfig';
        target=(Join-Path $env:USERPROFILE '.codex\config.toml'); critical=$false; parameters=[pscustomobject]@{}
    }
    $plan = [pscustomobject]@{ actions=@($globalAction) }
    Invoke-CodexSetupPlan -Plan $plan -Config $config -Confirm:$false | Out-Null
    $firstToml = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex\config.toml') -Raw -Encoding utf8
    $firstHeader = $firstToml.IndexOf('[')
    $preservedToml = $firstToml.Insert($firstHeader, "model = `"gpt-test-preserved`"`n") + "`n[mcp_servers.preserved]`ncommand = `"example`"`n"
    Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex\config.toml') -Value $preservedToml -Encoding utf8
    Invoke-CodexSetupPlan -Plan $plan -Config $config -Confirm:$false | Out-Null
    $tomlPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    $toml = Get-Content -LiteralPath $tomlPath -Raw -Encoding utf8
    Assert-True (([regex]::Matches($toml, '(?m)^sandbox_mode\s*=')).Count -eq 1) 'global TOML merge is idempotent'
    Assert-True (([regex]::Matches($toml, '(?m)^\[windows\]')).Count -eq 1) 'global TOML keeps one windows section'
    Assert-True ($toml -match 'sandbox\s*=\s*"unelevated"') 'global TOML writes unelevated Windows sandbox by default'
    Assert-True ($toml -match 'sandbox_mode\s*=\s*"workspace-write"') 'global TOML uses workspace-write by default'
    Assert-True ($toml -match 'model\s*=\s*"gpt-test-preserved"' -and $toml -match '\[mcp_servers\.preserved\]') 'global TOML merge preserves unmanaged root keys and tables'
    $unsupportedToml = "windows = { sandbox = `"unelevated`" }`n"
    Set-Content -LiteralPath $tomlPath -Value $unsupportedToml -Encoding utf8
    $unsupportedResults = @(Invoke-CodexSetupPlan -Plan $plan -Config $config -Confirm:$false)
    Assert-True ($unsupportedResults[0].status -eq 'Failed' -and (Get-Content -LiteralPath $tomlPath -Raw -Encoding utf8).TrimEnd() -eq $unsupportedToml.TrimEnd()) 'global TOML refuses unsupported inline-table shapes without changing the file'
    Set-Content -LiteralPath $tomlPath -Value $toml -Encoding utf8

    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
    Set-Content -LiteralPath $wslConfigPath -Value "[wsl2]`nmemory=6GB`nnetworkingMode=nat`n`n[experimental]`nsparseVhd=true`n" -Encoding utf8
    Set-WslNetworkingConfig -Config $config
    Set-WslNetworkingConfig -Config $config
    $wslConfigText = Get-Content -LiteralPath $wslConfigPath -Raw -Encoding utf8
    Assert-True ($wslConfigText -match 'memory=6GB' -and $wslConfigText -match 'sparseVhd=true') '.wslconfig merge preserves unrelated VM and experimental settings'
    Assert-True (([regex]::Matches($wslConfigText, '(?m)^networkingMode=mirrored\r?$')).Count -eq 1) '.wslconfig merge is idempotent and enables mirrored mode'
    Assert-True ($wslConfigText -match '(?m)^dnsTunneling=true\r?$' -and $wslConfigText -match '(?m)^autoProxy=true\r?$' -and $wslConfigText -match '(?m)^firewall=true\r?$') '.wslconfig writes the recommended network safety settings'
    Assert-True ($wslConfigText -match '(?m)^initialAutoProxyTimeout=5000\r?$') '.wslconfig gives Windows proxy discovery a longer startup window'

    $projectAction = [pscustomobject]@{
        module='Project'; id='ProjectTemplates'; title='test templates'; type='ProjectTemplates'; target=$webProject;
        critical=$false; parameters=[pscustomobject]@{ projectPath=$webProject; agent='WSL' }
    }
    $projectPlan = [pscustomobject]@{ actions=@($projectAction) }
    Invoke-CodexSetupPlan -Plan $projectPlan -Config $config -NonInteractive -Confirm:$false | Out-Null
    foreach ($relative in @('AGENTS.md', '.codex\config.toml', '.editorconfig', '.gitattributes', '.gitignore')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $webProject $relative)) "project template exists: $relative"
    }

    $manifestPath = (Get-SetupRuntime).ManifestPath
    Invoke-CodexSetupRollback -ManifestPath $manifestPath -StateRoot (Join-Path $testRoot 'state') -NonInteractive -Confirm:$false
    Assert-True (-not (Test-Path -LiteralPath $tomlPath)) 'rollback removes a newly created global config'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $webProject 'AGENTS.md'))) 'rollback removes newly created project templates'

    $protectedFile = Join-Path $testRoot 'must-not-delete.txt'
    Set-Content -LiteralPath $protectedFile -Value 'keep' -Encoding utf8
    $evilRunRoot = Join-Path $testRoot 'state\runs\evil'
    [System.IO.Directory]::CreateDirectory($evilRunRoot) | Out-Null
    $evilManifest = [ordered]@{
        schemaVersion=1; runId='evil'; files=@([ordered]@{ path=$protectedFile; existed=$true; backup=$protectedFile })
        installedPackages=@(); notes=@()
    }
    $evilManifestPath = Join-Path $evilRunRoot 'rollback-manifest.json'
    $evilManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evilManifestPath -Encoding utf8
    $rollbackRejected = $false
    try { Invoke-CodexSetupRollback -ManifestPath $evilManifestPath -StateRoot (Join-Path $testRoot 'state') -WhatIf }
    catch { $rollbackRejected = $true }
    Assert-True ($rollbackRejected -and (Test-Path -LiteralPath $protectedFile)) 'rollback rejects backup paths outside the selected run before changing files'

    $whatIfProfile = Join-Path $testRoot 'whatif-user'
    $env:USERPROFILE = $whatIfProfile
    $previewResults = @(Invoke-CodexSetupPlan -Plan $plan -Config $config -WhatIf -Confirm:$false)
    Assert-True ($previewResults.Count -eq 1 -and $previewResults[0].status -eq 'Preview') 'preview mode returns a user-facing preview result'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $whatIfProfile '.codex\config.toml'))) 'WhatIf does not create Codex config'

    Write-Host "All $script:Passed smoke assertions passed." -ForegroundColor Cyan
}
finally {
    $env:USERPROFILE = $originalUserProfile
    $env:LOCALAPPDATA = $originalLocalAppData
    if ([System.IO.Path]::GetFullPath($testRoot).StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
