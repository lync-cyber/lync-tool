# Offline fixtures: never consult today's network catalog in the test suite.
& {
    $module = Get-Module CodexSetup.Detection
    $fixtureConfig = Read-SetupConfig -Path (Join-Path $PSScriptRoot '../config/defaults.json')
    & {
        $Distribution = 'Ubuntu-26.04'
        $overridden = Resolve-SetupConfiguration -Path (Join-Path $PSScriptRoot '../config/defaults.json')
        Assert-True ($overridden.wsl.distribution -eq 'Ubuntu-26.04') 'The command-line distribution must override the config policy.'
        $Distribution = 'Ubuntu'
        Assert-Throws { Resolve-SetupConfiguration -Path (Join-Path $PSScriptRoot '../config/defaults.json') } `
            'The command-line override must use the same validation as JSON configuration.'
    }
    foreach ($selection in @('latest-stable', 'latest-lts', 'Ubuntu-24.04', 'Ubuntu-26.04', 'Ubuntu-25.10')) {
        $fixtureConfig.wsl.distribution = $selection
        [void](Assert-SetupConfiguration $fixtureConfig)
    }
    foreach ($selection in @('Ubuntu', 'ubuntu-24.04', 'Ubuntu-26.04-preview', 'Ubuntu-24.13', 'Ubuntu-24.04;exit', 'latest')) {
        $fixtureConfig.wsl.distribution = $selection
        Assert-Throws { Assert-SetupConfiguration $fixtureConfig } "Invalid distribution accepted: $selection"
    }
    $fixture = @{
        requests=0; fail=$false
        releases=@'
Dist: old
Version: 22.04.5 LTS
Date: Thu, 21 April 2022 00:22:04 UTC
Supported: 1

Dist: lts
Version: 24.04.3 LTS
Date: Thu, 25 April 2024 00:24:04 UTC
Supported: 1

Dist: interim
Version: 24.10
Date: Thu, 10 October 2024 00:24:10 UTC
Supported: 1

Dist: retired
Version: 25.04
Date: Thu, 17 April 2025 00:25:04 UTC
Supported: 0

Dist: preview
Version: 26.04 Beta
Date: Thu, 23 April 2026 00:26:04 UTC
Supported: 1

Dist: future
Version: 98.04 LTS
Date: 2098-04-01T00:00:00Z
Supported: 1
'@
        catalog=[pscustomobject]@{
            ModernDistributions=[pscustomobject]@{ Ubuntu=@(
                [pscustomobject]@{ Name='Ubuntu'; Amd64Url=[pscustomobject]@{ Url='https://example.test/generic.wsl' } }
                foreach ($version in @('24.04', '24.10', '25.04', '26.04', '98.04')) {
                    [pscustomobject]@{ Name="Ubuntu-$version"; Amd64Url=[pscustomobject]@{ Url='https://example.test/image.wsl' } }
                }
            ) }
            Distributions=@([pscustomobject]@{ Name='Ubuntu-22.04'; Arm64PackageUrl='https://example.test/legacy.appx' })
        }
    }
    $stable = & $module { param($F) Select-WslUbuntuDistribution latest-stable $F.releases $F.catalog X64 } $fixture
    $lts = & $module { param($F) Select-WslUbuntuDistribution latest-lts $F.releases $F.catalog X64 } $fixture
    $arm = & $module { param($F) Select-WslUbuntuDistribution latest-stable $F.releases $F.catalog Arm64 } $fixture
    Assert-True ($stable -eq 'Ubuntu-24.10' -and $lts -eq 'Ubuntu-24.04' -and $arm -eq 'Ubuntu-22.04') `
        'Selection must distinguish stable/LTS, normalize point releases, filter EOL/preview/future versions, and respect architecture.'
    Assert-Throws { & $module { param($F) Select-WslUbuntuDistribution latest-stable 'invalid metadata' $F.catalog X64 } $fixture } `
        'Malformed release metadata must not silently choose a default.'
    Assert-Throws { & $module { param($F) Select-WslUbuntuDistribution latest-stable $F.releases ([pscustomobject]@{}) X64 } $fixture } `
        'An empty WSL catalog must not silently choose a default.'
    Assert-Throws { & $module { param($F) Select-WslUbuntuDistribution latest-stable $F.releases $F.catalog X86 } $fixture } `
        'Unsupported architectures must not select an incompatible image.'
    try {
        & $module {
            param($F)
            $script:distributionFixture = $F
            function script:Invoke-WebRequest {
                param($Uri, $TimeoutSec, $ErrorAction)
                $script:distributionFixture.requests++
                if ($TimeoutSec -ne 15) { throw 'Unexpected network timeout.' }
                if ($script:distributionFixture.fail) { throw 'fixture-catalog-offline' }
                [pscustomobject]@{ Content=[Text.Encoding]::UTF8.GetBytes($script:distributionFixture.releases) }
            }
            function script:Invoke-RestMethod {
                param($Uri, $TimeoutSec, $ErrorAction)
                $script:distributionFixture.requests++
                $script:distributionFixture.catalog
            }
        } $fixture
        # Give both host architectures the same fixture for this public entry point.
        foreach ($entry in $fixture.catalog.ModernDistributions.Ubuntu) {
            $entry | Add-Member -NotePropertyName Arm64Url -NotePropertyValue $entry.Amd64Url
        }
        Assert-True ((Resolve-WslDistribution latest-stable) -eq 'Ubuntu-24.10' -and $fixture.requests -eq 2) `
            'Byte-array HTTP responses must decode as UTF-8 and use both official catalogs.'
        $fixture.fail = $true
        $fixture.requests = 0
        Assert-True ((Resolve-WslDistribution Ubuntu-24.04) -eq 'Ubuntu-24.04' -and $fixture.requests -eq 0) `
            'A pinned version must work offline without a network request.'
        $message = $null
        try { Resolve-WslDistribution latest-stable | Out-Null } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*fixture-catalog-offline*' -and $message -like '*-Distribution*' -and $fixture.requests -eq 1) `
            'Catalog failure must preserve the actual cause and offer an explicit version, without fallback.'
    }
    finally {
        & $module { Remove-Item Function:script:Invoke-WebRequest, Function:script:Invoke-RestMethod; Remove-Variable distributionFixture -Scope Script }
    }
    Write-Host 'PASS: configurable Ubuntu release selection, architecture filtering, offline pinning, and catalog failures'
}
