#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Apply', 'PostRestart', 'DesktopEvidence', 'Rollback', 'Report')]
    [string]$Phase,
    [string]$RunId,
    [switch]$ApplyChanges,
    [string]$ConfigPath,
    [string]$EvidenceRoot,
    [string]$BaselineDesktopScreenshotPath,
    [string]$DesktopScreenshotPath,
    [string]$AgentEvidenceJsonPath,
    [string]$TerminalEvidenceJsonPath,
    [ValidateSet('AgentWslOnly', 'TerminalWslOnly', 'BothWsl', 'BaselineRestored')]
    [string]$DesktopScenario = 'BothWsl',
    [switch]$ConfirmManualDesktopSettings,
    [switch]$ConfirmManualDesktopRollback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$startScript = Join-Path $repoRoot 'Start-CodexSetup.ps1'
Import-Module (Join-Path $repoRoot 'modules\CodexSetup.Common.psm1') -Force -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $repoRoot 'config\defaults.json' }
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA 不可用；请显式指定 -EvidenceRoot。' }
    $EvidenceRoot = Join-Path $env:LOCALAPPDATA 'CodexDevSetup\acceptance'
}
$EvidenceRoot = [System.IO.Path]::GetFullPath($EvidenceRoot)
if ($EvidenceRoot.StartsWith(([System.IO.Path]::GetFullPath($repoRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceRoot 不能位于验收源码仓库内，否则阶段证据会改变已固定的工作树。'
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-SetupJsonAtomic -Path ([System.IO.Path]::GetFullPath($Path)) -Value $Value
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "证据文件不存在：$Path" }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop }
    catch { throw "证据 JSON 无法解析：$Path。$($_.Exception.Message)" }
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-RepositoryIdentity {
    $cursor = [IO.DirectoryInfo]::new($repoRoot)
    $gitDirectory = $null
    while ($null -ne $cursor) {
        $candidate = Join-Path $cursor.FullName '.git'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $gitDirectory = $candidate; break }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $pointer = (Get-Content -LiteralPath $candidate -Raw -Encoding utf8).Trim()
            if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw '无法解析仓库 .git 指针。' }
            $gitDirectory = [IO.Path]::GetFullPath((Join-Path $cursor.FullName $Matches[1]))
            break
        }
        $cursor = $cursor.Parent
    }
    if ([string]::IsNullOrWhiteSpace($gitDirectory)) { throw '验收源码不在 Git 工作树中。' }
    $commonDirectory = $gitDirectory
    $commonPointerPath = Join-Path $gitDirectory 'commondir'
    if (Test-Path -LiteralPath $commonPointerPath -PathType Leaf) {
        $commonPointer = (Get-Content -LiteralPath $commonPointerPath -Raw -Encoding utf8).Trim()
        $commonDirectory = [IO.Path]::GetFullPath((Join-Path $gitDirectory $commonPointer))
    }
    $head = (Get-Content -LiteralPath (Join-Path $gitDirectory 'HEAD') -Raw -Encoding ascii).Trim()
    if ($head -match '^ref:\s*(.+)$') {
        $refName = $Matches[1]
        $refPath = Join-Path $commonDirectory $refName
        if (Test-Path -LiteralPath $refPath -PathType Leaf) { $commit = (Get-Content -LiteralPath $refPath -Raw -Encoding ascii).Trim() }
        else {
            $packed = Get-Content -LiteralPath (Join-Path $commonDirectory 'packed-refs') -Encoding ascii -ErrorAction Stop |
                Where-Object { $_ -match "^([0-9a-f]{40,64})\s+$([regex]::Escape($refName))$" } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($packed)) { throw '无法解析仓库 HEAD 引用。' }
            $commit = ($packed -split '\s+')[0]
        }
    }
    elseif ($head -match '^[0-9a-f]{40,64}$') { $commit = $head }
    else { throw '仓库 HEAD 格式无效。' }
    $entries = @(Get-ChildItem -LiteralPath $repoRoot -File -Recurse -Force | Where-Object {
        $_.FullName -notmatch '[\\/](?:\.git|node_modules|\.venv|__pycache__)(?:[\\/]|$)'
    } | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/')
        "$relative|$(Get-SetupSha256 -Path $_.FullName)"
    })
    [ordered]@{
        commit=$commit
        workingTreeSha256=Get-TextSha256 -Text ($entries -join "`n")
    }
}

function Get-CurrentHostIdentity {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [ordered]@{
        machineName = [Environment]::MachineName
        userName = [Environment]::UserName
        userSid = $sid
        osVersion = [Environment]::OSVersion.Version.ToString()
        osBuild = [Environment]::OSVersion.Version.Build
    }
}

function Assert-Windows11Host {
    if (-not $IsWindows) { throw '此验收脚本只能在当前 Windows 11 工作站的 PowerShell 7 中运行。' }
    if ([Environment]::OSVersion.Version.Build -lt 22000) { throw '当前系统不是 Windows 11。' }
}

function Assert-SameHost {
    param([Parameter(Mandatory)]$State)
    $current = Get-CurrentHostIdentity
    if ($State.host.machineName -ne $current.machineName -or $State.host.userSid -ne $current.userSid -or
        [int]$State.host.osBuild -ne [int]$current.osBuild -or [string]$State.host.osVersion -cne [string]$current.osVersion) {
        throw '证据属于另一台机器、用户或 Windows 构建；拒绝继续验收。'
    }
}

function Invoke-NativeCapture {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ exitCode=$LASTEXITCODE; output=$output; text=($output -join [Environment]::NewLine) }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WingetSourceAvailable {
    param([Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source)
    $packageId = if ($Source -eq 'winget') { 'Git.Git' } else { '9PLM9XGG6VKS' }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { return [ordered]@{ source=$Source; available=$false; exitCode=$null } }
    try {
        $result = Invoke-NativeCapture -FilePath $winget.Source -Arguments @(
            'search', '--id', $packageId, '--exact', '--source', $Source,
            '--accept-source-agreements', '--disable-interactivity'
        )
        return [ordered]@{ source=$Source; available=($result.exitCode -eq 0); exitCode=$result.exitCode }
    }
    catch { return [ordered]@{ source=$Source; available=$false; exitCode=$null } }
}

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    [ordered]@{
        path=$fullPath
        exists=$exists
        sha256=$(if ($exists) { Get-SetupSha256 -Path $fullPath } else { $null })
        sddl=$(if ($exists) { (Get-Acl -LiteralPath $fullPath).Sddl } else { $null })
    }
}

function Get-ManagedFileEvidence {
    param([Parameter(Mandatory)]$Config)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(
        (Join-Path $env:USERPROFILE '.codex\config.toml'),
        (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
        (Join-Path $env:USERPROFILE '.wslconfig'),
        (Join-Path $env:USERPROFILE '.gitconfig')
    )) { $paths.Add($path) }
    $projectPath = [Environment]::ExpandEnvironmentVariables([string]$Config.paths.projectPath)
    if (-not [string]::IsNullOrWhiteSpace($projectPath)) {
        foreach ($leaf in @('AGENTS.md', '.editorconfig', '.gitattributes', '.gitignore')) {
            $paths.Add((Join-Path $projectPath $leaf))
        }
    }
    @($paths | Select-Object -Unique | ForEach-Object { Get-FileEvidence -Path $_ })
}

function Get-CodexProcessEvidence {
    @(
        Get-Process -Name Codex -ErrorAction SilentlyContinue | Sort-Object Id | ForEach-Object {
            [ordered]@{ id=$_.Id; startTime=$(try { $_.StartTime.ToString('o') } catch { $null }) }
        }
    )
}

function Get-StablePackageEvidence {
    param([Parameter(Mandatory)]$Catalog)
    if ($Catalog.state -ne 'Known') { return [ordered]@{ state='Unknown'; packages=@(); error=$Catalog.error } }
    [ordered]@{
        state='Known'
        packages=@($Catalog.packages | Sort-Object source,id | ForEach-Object { "$(($_.source).ToLowerInvariant())|$(($_.id).ToLowerInvariant())|$($_.version)" })
        error=$null
    }
}

function Get-StableWslEvidence {
    param([AllowNull()]$Detection)
    if ($null -eq $Detection -or $Detection.PSObject.Properties.Name -notcontains 'wsl') { return $null }
    [ordered]@{
        state=[string]$Detection.wsl.state
        version=[string]$Detection.wsl.version
        distribution=[string]$Detection.wsl.distribution
        distributionInstalled=[bool]$Detection.wsl.distributionInstalled
        distributionWsl2=[bool]$Detection.wsl.distributionWsl2
        defaultDistribution=[string]$Detection.wsl.defaultDistribution
    }
}

function Test-EquivalentJson {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    return ($Before | ConvertTo-Json -Depth 30 -Compress) -ceq ($After | ConvertTo-Json -Depth 30 -Compress)
}

function Copy-EvidenceFile {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "证据文件不存在：$Source" }
    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    $destinationPath = [System.IO.Path]::GetFullPath($Destination)
    if (-not [string]::Equals($sourcePath, $destinationPath, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
    [ordered]@{ path=$destinationPath; sha256=(Get-SetupSha256 -Path $destinationPath) }
}

function Invoke-SetupEntryPoint {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$TranscriptPath,
        [string]$EffectiveConfigPath,
        [string]$ManifestPath,
        [switch]$Mutate
    )
    if ([string]::IsNullOrWhiteSpace($EffectiveConfigPath)) { $EffectiveConfigPath = $ConfigPath }
    $arguments = @('-NoProfile', '-File', $startScript, '-Mode', $Mode, '-NonInteractive', '-ConfigPath', $EffectiveConfigPath, '-ResultJsonPath', $ResultPath)
    if ($Mode -in @('Apply', 'Detect')) { $arguments += '-DeepDetection' }
    if ($ManifestPath) { $arguments += @('-RollbackManifest', $ManifestPath) }
    if ($Mutate) { $arguments += '-ApplyChanges' }
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    Write-Host "运行 $Mode；实时输出同时记录到 $TranscriptPath"
    $lines = [System.Collections.Generic.List[string]]::new()
    & $pwsh @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        Write-Host $line
    }
    $exitCode = $LASTEXITCODE
    $text = @($lines) -join [Environment]::NewLine
    $text | Set-Content -LiteralPath $TranscriptPath -Encoding utf8
    return [pscustomobject]@{ exitCode=$exitCode; output=@($lines); text=$text }
}

function Test-CatalogPackageInstalled {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$Package)
    $state = Get-WindowsPackageState -PackageId ([string]$Package.id) -Source ([string]$Package.source) -Catalog $Catalog
    if ($state.state -eq 'Unknown') { throw "无法精确确认 $($Package.source)/$($Package.id)：$($state.error)" }
    return [bool]$state.installed
}

function Get-PackageBaseline {
    param([Parameter(Mandatory)]$Catalog)
    $packages = @(
        [pscustomobject]@{ id='GitHub.cli'; source='winget'; label='GitHub CLI' }
        [pscustomobject]@{ id='Microsoft.WindowsTerminal'; source='winget'; label='Windows Terminal' }
        [pscustomobject]@{ id='Git.Git'; source='winget'; label='Git for Windows' }
        [pscustomobject]@{ id='9PLM9XGG6VKS'; source='msstore'; label='Codex Desktop' }
        [pscustomobject]@{ id='Docker.DockerDesktop'; source='winget'; label='Docker Desktop' }
        [pscustomobject]@{ id='Microsoft.PowerShell'; source='winget'; label='PowerShell 7' }
        [pscustomobject]@{ id='OpenJS.NodeJS.LTS'; source='winget'; label='Node.js LTS' }
        [pscustomobject]@{ id='astral-sh.uv'; source='winget'; label='uv' }
        [pscustomobject]@{ id='BurntSushi.ripgrep.MSVC'; source='winget'; label='ripgrep' }
        [pscustomobject]@{ id='sharkdp.fd'; source='winget'; label='fd' }
        [pscustomobject]@{ id='jqlang.jq'; source='winget'; label='jq' }
    )
    @($packages | ForEach-Object {
        $state = Get-WindowsPackageState -PackageId $_.id -Source $_.source -Catalog $Catalog
        [ordered]@{
            id=$_.id; source=$_.source; label=$_.label; state=$state.state
            installed=$(if ($state.state -eq 'Unknown') { $null } else { [bool]$state.installed })
            version=$state.version; error=$state.error
        }
    })
}

function Get-SelectedMissingTarget {
    param([Parameter(Mandatory)]$Baseline)
    foreach ($id in @('GitHub.cli', 'Microsoft.WindowsTerminal', 'Git.Git')) {
        $item = @($Baseline | Where-Object id -eq $id | Select-Object -First 1)
        if ($item.Count -eq 1 -and $item[0].state -eq 'KnownMissing') { return $item[0] }
    }
    return $null
}

function Get-RunDirectory {
    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        if ($Phase -eq 'Preflight') {
            $script:RunId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        }
        else {
            $latest = @(Get-ChildItem -LiteralPath $EvidenceRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'acceptance-state.json') -PathType Leaf } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($latest.Count -ne 1) { throw '未找到可继续的验收 RunId；请显式传入 -RunId。' }
            $script:RunId = $latest[0].Name
        }
    }
    if ($script:RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') { throw 'RunId 只能包含字母、数字、点、下划线和短横线。' }
    return Join-Path $EvidenceRoot $script:RunId
}

function Read-State {
    param([Parameter(Mandatory)][string]$RunDirectory)
    $state = Read-JsonFile -Path (Join-Path $RunDirectory 'acceptance-state.json')
    Assert-SameHost -State $state
    if ($state.schemaVersion -ne 2 -or [string]$state.runId -cne [string]$script:RunId) { throw '验收状态标识不匹配。' }
    if ((Get-SetupSha256 -Path ([string]$state.acceptanceConfigPath)) -cne [string]$state.anchors.configSha256) {
        throw '验收配置已在 Preflight 后改变。'
    }
    $repository = Get-RepositoryIdentity
    if ([string]$repository.commit -cne [string]$state.anchors.repoCommit -or
        [string]$repository.workingTreeSha256 -cne [string]$state.anchors.repoWorkingTreeSha256) {
        throw '验收仓库在 Preflight 后改变；请使用新 RunId 重新开始。'
    }
    $previous = 'GENESIS'
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($state.artifactChain)) {
        if (-not $names.Add([string]$entry.name)) { throw "阶段证据重复登记：$($entry.name)" }
        $path = Join-Path $RunDirectory ([string]$entry.name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "阶段证据缺失：$($entry.name)" }
        $artifactHash = Get-SetupSha256 -Path $path
        if ($artifactHash -cne [string]$entry.sha256) { throw "阶段证据已改变：$($entry.name)" }
        $chainHash = Get-TextSha256 -Text "$previous|$($entry.name)|$artifactHash"
        if ($chainHash -cne [string]$entry.chainSha256 -or [string]$entry.previousChainSha256 -cne $previous) {
            throw "阶段证据链断裂：$($entry.name)"
        }
        $previous = $chainHash
    }
    $orderedStages = @(
        'preflight.json', 'apply.json', 'post-restart.json', 'desktop-AgentWslOnly.json',
        'desktop-TerminalWslOnly.json', 'desktop-BothWsl.json', 'desktop-evidence.json', 'rollback.json',
        'desktop-BaselineRestored-final.json', 'final-reapply-baseline.json', 'final-reapply-apply.json',
        'final-reapply.json', 'desktop-BothWsl-final.json'
    )
    $lastIndex = -1
    foreach ($name in $orderedStages) {
        $matchingIndex = -1
        for ($index = 0; $index -lt @($state.artifactChain).Count; $index++) {
            if ([string]@($state.artifactChain)[$index].name -ieq $name) { $matchingIndex = $index; break }
        }
        if ($matchingIndex -ge 0 -and $matchingIndex -le $lastIndex) { throw "阶段证据顺序无效：$name" }
        if ($matchingIndex -ge 0) { $lastIndex = $matchingIndex }
    }
    return $state
}

function Write-TrackedArtifact {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)]$Value
    )
    if ([IO.Path]::GetFileName($FileName) -cne $FileName) { throw '阶段证据名称不能包含目录。' }
    if (@($State.artifactChain | Where-Object { [string]$_.name -ieq $FileName }).Count -gt 0) {
        throw "阶段证据已存在，拒绝覆盖：$FileName"
    }
    $path = Join-Path $RunDirectory $FileName
    Write-JsonFile -Path $path -Value $Value
    $artifactHash = Get-SetupSha256 -Path $path
    $previous = if (@($State.artifactChain).Count -eq 0) { 'GENESIS' } else { [string]@($State.artifactChain)[-1].chainSha256 }
    $entry = [ordered]@{
        name=$FileName
        sha256=$artifactHash
        previousChainSha256=$previous
        chainSha256=Get-TextSha256 -Text "$previous|$FileName|$artifactHash"
    }
    $State.artifactChain = @($State.artifactChain) + @($entry)
    Write-JsonFile -Path (Join-Path $RunDirectory 'acceptance-state.json') -Value $State
}

function Assert-PhasePassed {
    param([Parameter(Mandatory)][string]$RunDirectory, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$FileName)
    if (@($State.artifactChain | Where-Object { [string]$_.name -ieq $FileName }).Count -ne 1) {
        throw "阶段证据未登记：$FileName"
    }
    $result = Read-JsonFile -Path (Join-Path $RunDirectory $FileName)
    if ($result.schemaVersion -ne 2 -or [string]$result.runId -ne $script:RunId -or [string]$result.verdict -ne 'PASS') {
        throw "前置阶段未通过：$FileName"
    }
    return $result
}

function Test-VerifierEvidence {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$State)
    foreach ($property in @('schemaVersion', 'verdict', 'codeRoot', 'workingDirectory', 'currentDistro', 'shell', 'checks')) {
        if ($Evidence.PSObject.Properties.Name -notcontains $property) { return $false }
    }
    $codeRoot = [string]$Evidence.codeRoot
    $workingDirectory = [string]$Evidence.workingDirectory
    $checkIds = @($Evidence.checks | Where-Object status -eq 'PASS' | ForEach-Object id)
    $requiredCheckIds = @(
        'kernel', 'distro', 'shell', 'code-root', 'working-directory', 'command:git', 'command:pwsh',
        'command:fnm', 'command:node', 'command:npm', 'command:pnpm', 'command:python3', 'command:uv', 'command:codex'
    )
    $nonNative = @($Evidence.checks | Where-Object { $_.id -like 'command:*' -and ([string]$_.detail -match '^/mnt/') })
    return @($requiredCheckIds | Where-Object { $_ -notin $checkIds }).Count -eq 0 -and
        $nonNative.Count -eq 0 -and
        $Evidence.schemaVersion -eq 2 -and $Evidence.verdict -eq 'PASS' -and
        $Evidence.currentDistro -eq $State.expectedDistro -and $Evidence.shell -match '/bash$' -and
        $codeRoot -match '^/home/' -and ($workingDirectory -eq $codeRoot -or $workingDirectory.StartsWith("$codeRoot/"))
}

function Test-ExpectedFailureEvidence {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$State)
    if ($Evidence.PSObject.Properties.Name -notcontains 'verifier') { return $false }
    if ($null -ne $Evidence.verifier) {
        if (Test-VerifierEvidence -Evidence $Evidence.verifier -State $State) { return $false }
        $verifier = $Evidence.verifier
        return $verifier.schemaVersion -eq 2 -and $verifier.verdict -eq 'FAIL' -and
            @($verifier.checks | Where-Object { $_.id -in @('kernel', 'distro', 'shell') -and $_.status -eq 'FAIL' }).Count -gt 0
    }
    $missingCaptureFields = @(@('schemaVersion', 'captureType', 'command', 'exitCode', 'os', 'shell') | Where-Object {
        $Evidence.PSObject.Properties.Name -notcontains $_
    })
    if ($missingCaptureFields.Count -eq 0) {
        return $Evidence.schemaVersion -eq 2 -and $Evidence.captureType -eq 'CodexDesktopChannelEvidence' -and
            $Evidence.command -eq 'codex-env-check --json' -and [int]$Evidence.exitCode -ne 0 -and
            ([string]$Evidence.os -ne 'Linux' -or [string]$Evidence.shell -notmatch 'bash$')
    }
    return $false
}

function Test-DesktopEvidenceEnvelope {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('Agent', 'Terminal')][string]$ExpectedChannel,
        [Parameter(Mandatory)]$CurrentProcesses
    )
    foreach ($property in @('schemaVersion', 'captureType', 'runId', 'nonce', 'channel', 'capturedAt', 'command', 'exitCode', 'verifier')) {
        if ($Evidence.PSObject.Properties.Name -notcontains $property) { return $false }
    }
    try {
        $capturedAt = [DateTimeOffset]::Parse([string]$Evidence.capturedAt).ToUniversalTime()
        $createdAt = [DateTimeOffset]::Parse([string]$State.createdAt).ToUniversalTime()
        $processStarts = @($CurrentProcesses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.startTime) } |
            ForEach-Object { [DateTimeOffset]::Parse([string]$_.startTime).ToUniversalTime() })
    }
    catch { return $false }
    if ($processStarts.Count -eq 0) { return $false }
    $sessionStartedAt = @($processStarts | Sort-Object | Select-Object -First 1)[0]
    return $Evidence.schemaVersion -eq 2 -and $Evidence.captureType -eq 'CodexDesktopChannelEvidence' -and
        [string]$Evidence.runId -ceq [string]$State.runId -and [string]$Evidence.nonce -ceq [string]$State.desktopEvidenceNonce -and
        [string]$Evidence.channel -ceq $ExpectedChannel -and [string]$Evidence.command -ceq 'codex-env-check --json' -and
        $capturedAt -ge $createdAt -and $capturedAt -ge $sessionStartedAt -and
        $capturedAt -le [DateTimeOffset]::UtcNow.AddMinutes(2)
}

function Get-ScreenshotMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -notin @('.png', '.jpg', '.jpeg')) {
        return [ordered]@{ valid=$false; width=0; height=0; capturedFileTime=$null }
    }
    try {
        $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
            try {
                return [ordered]@{
                    valid=$image.Width -ge 640 -and $image.Height -ge 360
                    width=$image.Width; height=$image.Height; capturedFileTime=(Get-Item -LiteralPath $fullPath).LastWriteTimeUtc.ToString('o')
                }
            }
            finally { $image.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return [ordered]@{ valid=$false; width=0; height=0; capturedFileTime=$null } }
}

function Test-ScreenshotFile {
    param([Parameter(Mandatory)][string]$Path)
    return [bool](Get-ScreenshotMetadata -Path $Path).valid
}

Assert-Windows11Host
$runDirectory = Get-RunDirectory
[System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$statePath = Join-Path $runDirectory 'acceptance-state.json'

switch ($Phase) {
    'Preflight' {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) { throw "RunId 已存在，拒绝覆盖：$script:RunId" }
        $blocked = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-IsAdministrator)) { $blocked.Add('需要管理员权限运行 Windows 真实机验收。') }
        if ([string]::IsNullOrWhiteSpace($BaselineDesktopScreenshotPath) -or
            -not (Test-Path -LiteralPath $BaselineDesktopScreenshotPath -PathType Leaf) -or
            -not (Test-ScreenshotFile -Path $BaselineDesktopScreenshotPath)) {
            $blocked.Add('Preflight 需要 -BaselineDesktopScreenshotPath 指向当前 Codex Desktop 设置的 PNG/JPEG 基线截图。')
        }
        $sources = @(@('winget', 'msstore') | ForEach-Object { Test-WingetSourceAvailable -Source $_ })
        foreach ($source in @($sources | Where-Object available -eq $false)) {
            $blocked.Add("WinGet source 不可用：$($source.source)（exit=$($source.exitCode)）。")
        }
        $catalog = Get-WindowsPackageCatalog
        if ($catalog.state -ne 'Known') {
            $blocked.Add("WinGet 结构化清单不可用：$($catalog.error)。")
        }
        $baseline = if ($catalog.state -eq 'Known') { Get-PackageBaseline -Catalog $catalog } else { @() }
        foreach ($package in @($baseline | Where-Object state -eq 'Unknown')) {
            $blocked.Add("无法精确确认预装包 $($package.source)/$($package.id)：$($package.error)。")
        }
        $selected = Get-SelectedMissingTarget -Baseline $baseline
        $config = Read-JsonFile -Path ([System.IO.Path]::GetFullPath($ConfigPath))
        $codexPackage = @($baseline | Where-Object id -eq '9PLM9XGG6VKS' | Select-Object -First 1)
        if ($codexPackage.Count -ne 1 -or -not $codexPackage[0].installed) {
            $blocked.Add('当前工作站未精确检测到 Microsoft Store Codex Desktop（9PLM9XGG6VKS）；无法执行 GUI 集成验收。')
        }
        $config.windows.installDesktop = $false
        $config.windows.installTerminal = $null -ne $selected -and $selected.id -eq 'Microsoft.WindowsTerminal'
        $config.windows.installUiGit = $null -ne $selected -and $selected.id -eq 'Git.Git'
        $config.windows.installGitHubCli = $null -ne $selected -and $selected.id -eq 'GitHub.cli'
        $acceptanceConfigPath = Join-Path $runDirectory 'acceptance-config.json'
        Write-JsonFile -Path $acceptanceConfigPath -Value $config
        $detectResultPath = Join-Path $runDirectory 'preflight-detection.json'
        $detectInvocation = Invoke-SetupEntryPoint -Mode Detect -ResultPath $detectResultPath `
            -TranscriptPath (Join-Path $runDirectory 'preflight-detection.txt') -EffectiveConfigPath $acceptanceConfigPath
        $detectionResult = if (Test-Path -LiteralPath $detectResultPath) { Read-JsonFile -Path $detectResultPath } else { $null }
        if ($detectInvocation.exitCode -ne 0 -or $null -eq $detectionResult) {
            $blocked.Add("环境检测失败（exit=$($detectInvocation.exitCode)）。")
        }
        elseif ($detectionResult.detection.wsl.state -ne 'Ready' -or
            $detectionResult.detection.wsl.distribution -ne [string]$config.wsl.distribution -or
            $detectionResult.detection.wsl.distributionWsl2 -ne $true) {
            $blocked.Add("仅验收现有 $($config.wsl.distribution) WSL2；当前状态为 $($detectionResult.detection.wsl.state)。")
        }
        elseif ($detectionResult.detection.wslTools.sudoAvailable -ne $true -and
            (@($detectionResult.detection.wslTools.aptPackagesMissing).Count -gt 0 -or
             'pwsh' -in @($detectionResult.detection.wslTools.missingRequiredCommands))) {
            $blocked.Add('无人值守 Apply 需要安装 Linux 系统包，但当前没有 passwordless sudo。请先在交互式 WSL 中完成系统包安装；本工具不会从 .env 读取 sudo 密码。')
        }

        $filesBefore = Get-ManagedFileEvidence -Config $config
        $packagesBefore = Get-StablePackageEvidence -Catalog $catalog
        $wslBefore = if ($null -ne $detectionResult) { Get-StableWslEvidence -Detection $detectionResult.detection } else { $null }
        $codexProcessesBefore = Get-CodexProcessEvidence
        if ($codexProcessesBefore.Count -eq 0) { $blocked.Add('未检测到正在运行的 Codex Desktop；无法建立进程重启基线。') }
        $previewResultPath = Join-Path $runDirectory 'preflight-whatif-result.json'
        $previewInvocation = Invoke-SetupEntryPoint -Mode Apply -ResultPath $previewResultPath `
            -TranscriptPath (Join-Path $runDirectory 'preflight-whatif.txt') -EffectiveConfigPath $acceptanceConfigPath
        $previewResult = Read-JsonFile -Path $previewResultPath
        $catalogAfterPreview = Get-WindowsPackageCatalog
        $filesAfterPreview = Get-ManagedFileEvidence -Config $config
        $packagesAfterPreview = Get-StablePackageEvidence -Catalog $catalogAfterPreview
        $codexProcessesAfter = Get-CodexProcessEvidence
        $wslAfterPreview = Get-StableWslEvidence -Detection $previewResult.detection
        $wslZeroDrift = $null -ne $wslBefore -and $null -ne $wslAfterPreview -and
            (Test-EquivalentJson -Before $wslBefore -After $wslAfterPreview)
        $whatIfZeroDrift = $previewInvocation.exitCode -eq 0 -and
            (Test-EquivalentJson -Before $filesBefore -After $filesAfterPreview) -and
            (Test-EquivalentJson -Before $packagesBefore -After $packagesAfterPreview) -and
            $wslZeroDrift -and
            (Test-EquivalentJson -Before $codexProcessesBefore -After $codexProcessesAfter)
        if (-not $whatIfZeroDrift) { $blocked.Add('WhatIf 前后包、受管文件或 Codex 进程发生漂移。') }

        $baselineScreenshot = $null
        if (-not [string]::IsNullOrWhiteSpace($BaselineDesktopScreenshotPath) -and
            (Test-Path -LiteralPath $BaselineDesktopScreenshotPath -PathType Leaf) -and
            (Test-ScreenshotFile -Path $BaselineDesktopScreenshotPath)) {
            $extension = [System.IO.Path]::GetExtension($BaselineDesktopScreenshotPath).ToLowerInvariant()
            $baselineScreenshot = Copy-EvidenceFile -Source $BaselineDesktopScreenshotPath `
                -Destination (Join-Path $runDirectory "desktop-baseline$extension")
        }
        $exclusions = @('INITIAL_WSL2_INSTALL_NOT_EXERCISED_EXISTING_WSL2_ONLY')
        if ($null -eq $selected) { $exclusions += 'PACKAGE_INSTALL_ROLLBACK_NOT_EXERCISED_NO_MISSING_GH_TERMINAL_GIT' }
        $coverage = [ordered]@{
            windows11='PASS'; administrator=$(if (Test-IsAdministrator) { 'PASS' } else { 'BLOCKED' })
            wingetCatalog=$(if ($catalog.state -eq 'Known') { 'PASS' } else { 'BLOCKED' })
            wingetSources=$(if (@($sources | Where-Object available -eq $false).Count -eq 0) { 'PASS' } else { 'BLOCKED' })
            targetWsl2=$(if ($null -ne $detectionResult -and $detectionResult.detection.wsl.state -eq 'Ready') { 'PASS' } else { 'BLOCKED' })
            initialWsl2Install='NOT_RUN'; managedFileSha256Acl='BASELINE_RECORDED'
            whatIfZeroDrift=$(if ($whatIfZeroDrift) { 'PASS' } else { 'FAIL' })
            packageMutation=$(if ($null -eq $selected) { 'NOT_RUN' } else { 'PENDING' })
            wslShutdownResume='PENDING'; idempotentSecondApply='PENDING'
            desktopAgentWslOnly='PENDING'; desktopTerminalWslOnly='PENDING'; desktopBothWsl='PENDING'
            codexPidLifecycle='PENDING'; rollbackPreviewZeroDrift='PENDING'; rollbackRestoreSha256Acl='PENDING'
            isolatedRollbackFaults='PENDING'; manualDesktopRollback='PENDING'; finalReapply='PENDING'; finalDesktopWsl='PENDING'
        }
        $repositoryIdentity = Get-RepositoryIdentity
        $state = [ordered]@{
            schemaVersion=2
            runId=$script:RunId
            createdAt=(Get-Date).ToString('o')
            desktopEvidenceNonce=[guid]::NewGuid().ToString('N')
            host=(Get-CurrentHostIdentity)
            expectedDistro=[string]$config.wsl.distribution
            codeRoot=[string]$config.paths.wslProjects
            acceptanceConfigPath=$acceptanceConfigPath
            baselinePackages=$baseline
            baselineWsl=$wslBefore
            baselineManagedFiles=$filesBefore
            baselineCodexProcesses=$codexProcessesBefore
            baselineDesktopScreenshot=$baselineScreenshot
            selectedMissingTarget=$selected
            preflightResultPath=$previewResultPath
            applyResultPath=''
            setupManifestPath=''
            setupManifestSha256BeforeRollback=''
            initialApplyStartedAt=$null
            firstApplyManagedFiles=@()
            firstApplyPackages=$null
            postRestartEvidencePath=''
            finalReapplyResultPath=''
            finalReapplyBaseline=$null
            finalReapplyAppliedManagedFiles=@()
            finalReapplyAppliedPackages=$null
            exclusions=$exclusions
            validationCoverage=$coverage
            rollbackCompletedAt=$null
            lastCodexProcesses=$codexProcessesBefore
            desktopScreenshotHashes=@($(if ($null -ne $baselineScreenshot) { $baselineScreenshot.sha256 } else { @() }))
            artifactChain=@()
            anchors=[ordered]@{
                configSha256=Get-SetupSha256 -Path $acceptanceConfigPath
                repoCommit=$repositoryIdentity.commit
                repoWorkingTreeSha256=$repositoryIdentity.workingTreeSha256
                stateRootTrustBoundary=$runDirectory
            }
        }
        Write-JsonFile -Path $statePath -Value $state
        $result = [ordered]@{
            schemaVersion=2; phase='Preflight'; runId=$script:RunId; host=$state.host
            verdict=$(if ($blocked.Count -eq 0) { 'PASS' } else { 'BLOCKED' })
            setupExitCode=$previewInvocation.exitCode; selectedMissingTarget=$selected; exclusions=$exclusions
            blockers=@($blocked); sources=$sources; packageBaseline=$baseline; managedFiles=$filesBefore
            codexProcesses=$codexProcessesBefore; desktopBaseline=$baselineScreenshot
            validationCoverage=$state.validationCoverage
            safetyBoundary=@{
                currentHostOnly=$true; unregisterDistribution=$false; uninstallPreinstalledPackages=$false
                missingTargetOrder=@('GitHub.cli', 'Microsoft.WindowsTerminal', 'Git.Git')
            }
        }
        Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'preflight.json' -Value $result
        Write-Host "RunId: $script:RunId"
        Write-Host "Desktop evidence nonce: $($state.desktopEvidenceNonce)"
        Write-Host "Preflight evidence: $runDirectory"
        if ($result.verdict -eq 'BLOCKED') {
            foreach ($blocker in $blocked) { Write-Host "BLOCKED: $blocker" -ForegroundColor Yellow }
            exit 20
        }
        if ($result.verdict -ne 'PASS') { exit 1 }
    }
    'Apply' {
        if (-not $ApplyChanges) { throw 'Apply 阶段必须显式传入 -ApplyChanges。' }
        $state = Read-State -RunDirectory $runDirectory
        if ([string]::IsNullOrWhiteSpace([string]$state.rollbackCompletedAt)) {
            [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'preflight.json')
        }
        else {
            [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'rollback.json')
            if ([string]$state.validationCoverage.manualDesktopRollback -ne 'PASS') {
                throw '最终重新 Apply 前，必须先完成 BaselineRestored 人工 GUI 回滚证据。'
            }
        }
        $isFinalReapply = -not [string]::IsNullOrWhiteSpace([string]$state.rollbackCompletedAt)
        if (-not $isFinalReapply -and (-not [string]::IsNullOrWhiteSpace([string]$state.initialApplyStartedAt) -or
            -not [string]::IsNullOrWhiteSpace([string]$state.applyResultPath) -or
            @($state.artifactChain | Where-Object { [string]$_.name -ieq 'apply.json' }).Count -gt 0)) {
            throw '首次 Apply 已有受管清单；拒绝覆盖。请继续后续阶段或使用新 RunId。'
        }
        if ($isFinalReapply -and @($state.artifactChain | Where-Object { [string]$_.name -ieq 'final-reapply-baseline.json' }).Count -gt 0) {
            throw '最终重新 Apply 已经开始；拒绝覆盖独立基线。'
        }
        if ($isFinalReapply) {
            $finalBaselineCatalog = Get-WindowsPackageCatalog
            if ($finalBaselineCatalog.state -ne 'Known') { throw '最终重新 Apply 前无法建立 WinGet 基线。' }
            $finalBaselineConfig = Read-JsonFile -Path $state.acceptanceConfigPath
            $state.finalReapplyBaseline = [ordered]@{
                schemaVersion=2
                phase='FinalReapplyBaseline'
                runId=$script:RunId
                verdict='PASS'
                capturedAt=(Get-Date).ToString('o')
                managedFiles=Get-ManagedFileEvidence -Config $finalBaselineConfig
                packages=Get-StablePackageEvidence -Catalog $finalBaselineCatalog
            }
            Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'final-reapply-baseline.json' -Value $state.finalReapplyBaseline
        }
        else {
            $state.initialApplyStartedAt = (Get-Date).ToString('o')
            Write-JsonFile -Path $statePath -Value $state
        }
        $resultPath = Join-Path $runDirectory $(if ($isFinalReapply) { 'final-reapply-setup-result.json' } else { 'apply-setup-result.json' })
        $transcriptPath = Join-Path $runDirectory $(if ($isFinalReapply) { 'final-reapply-transcript.txt' } else { 'apply-transcript.txt' })
        $invocation = Invoke-SetupEntryPoint -Mode Apply -ResultPath $resultPath -TranscriptPath $transcriptPath -EffectiveConfigPath $state.acceptanceConfigPath -Mutate
        $setupResult = Read-JsonFile -Path $resultPath
        if ([int]$setupResult.exitCode -ne $invocation.exitCode) { throw 'Apply 进程退出码与结果 JSON 不一致。' }
        if ($invocation.exitCode -notin @(0, 10, 20, 1)) { throw "Apply 返回未定义退出码：$($invocation.exitCode)" }
        if ($isFinalReapply) {
            $finalCatalog = Get-WindowsPackageCatalog
            $selectedRestored = $finalCatalog.state -eq 'Known' -and
                ($null -eq $state.selectedMissingTarget -or (Test-CatalogPackageInstalled -Catalog $finalCatalog -Package $state.selectedMissingTarget))
            $finalApplyPassed = $invocation.exitCode -in @(0, 10) -and $selectedRestored
            $state.finalReapplyResultPath = $resultPath
            $finalAppliedConfig = Read-JsonFile -Path $state.acceptanceConfigPath
            $state.finalReapplyAppliedManagedFiles = Get-ManagedFileEvidence -Config $finalAppliedConfig
            $state.finalReapplyAppliedPackages = Get-StablePackageEvidence -Catalog $finalCatalog
            $state.validationCoverage.finalReapply = $(if ($invocation.exitCode -eq 0 -and $selectedRestored) { 'PASS' } elseif ($invocation.exitCode -eq 10 -and $selectedRestored) { 'PENDING' } else { 'FAIL' })
            Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'final-reapply-apply.json' -Value ([ordered]@{
                schemaVersion=2; phase='FinalReapply'; runId=$script:RunId
                verdict=$(if ($finalApplyPassed) { 'PASS' } else { 'FAIL' })
                setupExitCode=$invocation.exitCode; setupStatus=$setupResult.status; manifestPath=$setupResult.manifestPath
                selectedMissingTargetRestored=$selectedRestored
            })
            if ($invocation.exitCode -eq 0 -and $selectedRestored) {
                Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'final-reapply.json' -Value ([ordered]@{
                    schemaVersion=2; phase='FinalReapply'; runId=$script:RunId; verdict='PASS'
                    setupExitCode=0; restartRequired=$false
                })
            }
            exit $(if ($finalApplyPassed) { $invocation.exitCode } else { 1 })
        }
        $state.applyResultPath = $resultPath
        $state.setupManifestPath = [string]$setupResult.manifestPath
        $manifest = if (-not [string]::IsNullOrWhiteSpace($state.setupManifestPath) -and
            (Test-Path -LiteralPath $state.setupManifestPath -PathType Leaf)) {
            Read-JsonFile -Path $state.setupManifestPath
        } else { $null }
        if ($null -eq $manifest -or $manifest.schemaVersion -ne 3) { throw 'Apply 没有生成严格的 v3 回滚清单。' }
        $state.setupManifestSha256BeforeRollback = Get-SetupSha256 -Path $state.setupManifestPath
        $afterCatalog = Get-WindowsPackageCatalog
        if ($afterCatalog.state -ne 'Known') { throw "Apply 后无法读取 WinGet 结构化清单：$($afterCatalog.error)" }
        foreach ($baselinePackage in @($state.baselinePackages | Where-Object installed -eq $true)) {
            if (-not (Test-CatalogPackageInstalled -Catalog $afterCatalog -Package $baselinePackage)) {
                throw "Apply 移除了预装软件：$($baselinePackage.id)"
            }
        }
        if ($null -ne $state.selectedMissingTarget) {
            $selectedInstalled = Test-CatalogPackageInstalled -Catalog $afterCatalog -Package $state.selectedMissingTarget
            $state.validationCoverage.packageMutation = $(if ($selectedInstalled) { 'PASS' } else { 'FAIL' })
            if (-not $selectedInstalled) { throw "首个缺失目标未完成安装：$($state.selectedMissingTarget.id)" }
        }
        $config = Read-JsonFile -Path $state.acceptanceConfigPath
        $state.firstApplyManagedFiles = Get-ManagedFileEvidence -Config $config
        $state.firstApplyPackages = Get-StablePackageEvidence -Catalog $afterCatalog
        Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'apply.json' -Value ([ordered]@{
            schemaVersion=2; phase='Apply'; runId=$script:RunId; verdict=$(if ($invocation.exitCode -in @(0, 10)) { 'PASS' } else { 'FAIL' })
            setupExitCode=$invocation.exitCode; setupStatus=$setupResult.status; manifestPath=$setupResult.manifestPath
            manifestSchemaVersion=$manifest.schemaVersion; manifestSha256=$state.setupManifestSha256BeforeRollback
            selectedMissingTarget=$state.selectedMissingTarget
        })
        if ($invocation.exitCode -eq 1) { exit 1 }
        exit $invocation.exitCode
    }
    'PostRestart' {
        if (-not $ApplyChanges) { throw 'PostRestart 会执行 wsl --shutdown；请保存 WSL 工作后显式传入 -ApplyChanges。' }
        $state = Read-State -RunDirectory $runDirectory
        $isFinalReapply = -not [string]::IsNullOrWhiteSpace([string]$state.rollbackCompletedAt)
        if (-not $isFinalReapply) {
            [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'apply.json')
        }
        else { [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'final-reapply-apply.json') }
        if ($isFinalReapply -and @($state.artifactChain | Where-Object { [string]$_.name -ieq 'final-reapply.json' }).Count -gt 0) {
            throw '最终重新 Apply 已完成且不需要 PostRestart；拒绝重复执行。'
        }
        if (-not $isFinalReapply -and @($state.artifactChain | Where-Object { [string]$_.name -ieq 'post-restart.json' }).Count -gt 0) {
            throw 'PostRestart 已完成；拒绝重复执行。'
        }
        if ([string]::IsNullOrWhiteSpace([string]$state.applyResultPath)) { throw '请先完成 Apply 阶段。' }
        $artifactPrefix = if ($isFinalReapply) { 'final-reapply-post-restart' } else { 'post-restart' }
        $wsl = Get-Command wsl.exe -ErrorAction Stop
        $shutdownInvocation = Invoke-NativeCapture -FilePath $wsl.Source -Arguments @('--shutdown')
        if ($shutdownInvocation.exitCode -ne 0) { throw "wsl --shutdown 失败（exit=$($shutdownInvocation.exitCode)）。" }
        $resumeInvocation = Invoke-NativeCapture -FilePath $wsl.Source -Arguments @(
            '-d', [string]$state.expectedDistro, '--', 'bash', '-lc', 'true'
        )
        if ($resumeInvocation.exitCode -ne 0) { throw "目标发行版在 shutdown 后无法恢复（exit=$($resumeInvocation.exitCode)）。" }
        $detectResultPath = Join-Path $runDirectory "$artifactPrefix-setup-result.json"
        $transcriptPath = Join-Path $runDirectory "$artifactPrefix-transcript.txt"
        $detectInvocation = Invoke-SetupEntryPoint -Mode Detect -ResultPath $detectResultPath -TranscriptPath $transcriptPath -EffectiveConfigPath $state.acceptanceConfigPath
        $detectResult = Read-JsonFile -Path $detectResultPath
        $linuxCheck = 'code_root=$1; case "$code_root" in "~") code_root="$HOME" ;; "~/"*) code_root="$HOME/${code_root:2}" ;; esac; cd -- "$code_root" && "$HOME/.local/bin/codex-env-check" --json'
        $wslInvocation = Invoke-NativeCapture -FilePath $wsl.Source -Arguments @(
            '-d', [string]$state.expectedDistro, '--', 'bash', '-lc', $linuxCheck, 'codex-acceptance', [string]$state.codeRoot
        )
        $wslInvocation.text | Set-Content -LiteralPath (Join-Path $runDirectory "$artifactPrefix-wsl-transcript.txt") -Encoding utf8
        $jsonLine = @($wslInvocation.output | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $wslEvidence = if ($jsonLine.Count -eq 1) { $jsonLine[0] | ConvertFrom-Json -ErrorAction Stop } else { $null }
        if ($null -ne $wslEvidence) { Write-JsonFile -Path (Join-Path $runDirectory "$artifactPrefix-wsl.json") -Value $wslEvidence }
        $secondResultPath = Join-Path $runDirectory "$artifactPrefix-second-apply-result.json"
        $secondInvocation = Invoke-SetupEntryPoint -Mode Apply -ResultPath $secondResultPath `
            -TranscriptPath (Join-Path $runDirectory "$artifactPrefix-second-apply.txt") -EffectiveConfigPath $state.acceptanceConfigPath -Mutate
        $secondResult = Read-JsonFile -Path $secondResultPath
        $config = Read-JsonFile -Path $state.acceptanceConfigPath
        $secondFiles = Get-ManagedFileEvidence -Config $config
        $secondCatalog = Get-WindowsPackageCatalog
        $secondPackages = Get-StablePackageEvidence -Catalog $secondCatalog
        $repeatedInstalls = @($secondResult.results | Where-Object { $_.id -in @('WindowsGitHubCli', 'WindowsTerminal', 'WindowsGit') -and $_.status -eq 'Changed' })
        $repeatedWslConfigure = @($secondResult.results | Where-Object { $_.id -eq 'ConfigureWsl' -and $_.status -eq 'Changed' })
        $expectedFiles = if ($isFinalReapply) { $state.finalReapplyAppliedManagedFiles } else { $state.firstApplyManagedFiles }
        $expectedPackages = if ($isFinalReapply) { $state.finalReapplyAppliedPackages } else { $state.firstApplyPackages }
        $idempotent = $secondInvocation.exitCode -eq 0 -and $repeatedInstalls.Count -eq 0 -and
            $repeatedWslConfigure.Count -eq 0 -and
            (Test-EquivalentJson -Before $expectedFiles -After $secondFiles) -and
            (Test-EquivalentJson -Before $expectedPackages -After $secondPackages)
        $passed = $shutdownInvocation.exitCode -eq 0 -and $resumeInvocation.exitCode -eq 0 -and
            $detectInvocation.exitCode -eq 0 -and $detectResult.detection.wsl.state -eq 'Ready' -and
            $wslInvocation.exitCode -eq 0 -and $null -ne $wslEvidence -and
            (Test-VerifierEvidence -Evidence $wslEvidence -State $state) -and $idempotent -and
            $secondResult.detection.wsl.state -eq 'Ready'
        if (-not $isFinalReapply) {
            $state.validationCoverage.wslShutdownResume = $(if ($shutdownInvocation.exitCode -eq 0 -and $resumeInvocation.exitCode -eq 0) { 'PASS' } else { 'FAIL' })
            $state.validationCoverage.idempotentSecondApply = $(if ($idempotent) { 'PASS' } else { 'FAIL' })
            $state.postRestartEvidencePath = Join-Path $runDirectory "$artifactPrefix-wsl.json"
        }
        else { $state.validationCoverage.finalReapply = $(if ($passed) { 'PASS' } else { 'FAIL' }) }
        $phaseResult = [ordered]@{
            schemaVersion=2; phase=$(if ($isFinalReapply) { 'FinalReapply' } else { 'PostRestart' }); runId=$script:RunId
            verdict=$(if ($passed) { 'PASS' } else { 'FAIL' })
            shutdownExitCode=$shutdownInvocation.exitCode; resumeExitCode=$resumeInvocation.exitCode
            setupExitCode=$detectInvocation.exitCode; wslExitCode=$wslInvocation.exitCode; wslEvidence=$wslEvidence
            secondApplyExitCode=$secondInvocation.exitCode; idempotentSecondApply=$idempotent
        }
        Write-TrackedArtifact -RunDirectory $runDirectory -State $state `
            -FileName $(if ($isFinalReapply) { 'final-reapply.json' } else { 'post-restart.json' }) -Value $phaseResult
        if (-not $passed) { exit 1 }
    }
    'DesktopEvidence' {
        $state = Read-State -RunDirectory $runDirectory
        if (-not $ConfirmManualDesktopSettings) {
            throw 'Desktop 没有公开可信的设置读取 API。请人工核对当前场景、证据来源和截图后传入 -ConfirmManualDesktopSettings。'
        }
        if ([string]::IsNullOrWhiteSpace($DesktopScreenshotPath) -or
            -not (Test-Path -LiteralPath $DesktopScreenshotPath -PathType Leaf) -or
            -not (Test-ScreenshotFile -Path $DesktopScreenshotPath)) {
            throw 'DesktopEvidence 需要 -DesktopScreenshotPath 指向当前场景的有效 PNG/JPEG 设置截图。'
        }
        $afterRollback = -not [string]::IsNullOrWhiteSpace([string]$state.rollbackCompletedAt)
        if (-not $afterRollback) {
            switch ($DesktopScenario) {
                'AgentWslOnly' { [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'post-restart.json') }
                'TerminalWslOnly' { [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'desktop-AgentWslOnly.json') }
                'BothWsl' { [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'desktop-TerminalWslOnly.json') }
                default { throw 'BaselineRestored 只能在真实回滚后记录。' }
            }
        }
        elseif ($DesktopScenario -eq 'BaselineRestored') { [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'rollback.json') }
        elseif ($DesktopScenario -eq 'BothWsl') {
            [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'final-reapply.json')
            if ([string]$state.validationCoverage.manualDesktopRollback -ne 'PASS') { throw '最终 WSL/WSL 验收前必须完成人工 Desktop 基线恢复。' }
        }
        else { throw '回滚后只接受 BaselineRestored 和最终 BothWsl 场景。' }
        if ($DesktopScenario -eq 'BaselineRestored' -and (-not $afterRollback -or -not $ConfirmManualDesktopRollback)) {
            throw 'BaselineRestored 仅能在真实回滚后使用，并需显式传入 -ConfirmManualDesktopRollback。'
        }
        if ($DesktopScenario -ne 'BaselineRestored') {
            foreach ($path in @($AgentEvidenceJsonPath, $TerminalEvidenceJsonPath)) {
                if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw '该 Desktop 场景需要独立的 -AgentEvidenceJsonPath 和 -TerminalEvidenceJsonPath。'
                }
            }
            $agentEvidencePath = [System.IO.Path]::GetFullPath($AgentEvidenceJsonPath)
            $terminalEvidencePath = [System.IO.Path]::GetFullPath($TerminalEvidenceJsonPath)
            if ($agentEvidencePath -eq $terminalEvidencePath) { throw 'Agent environment 与 Integrated terminal 必须分别提供证据 JSON。' }
        }
        $suffix = if ($afterRollback) { "$DesktopScenario-final" } else { $DesktopScenario }
        if (@($state.artifactChain | Where-Object { [string]$_.name -ieq "desktop-$suffix.json" }).Count -gt 0) {
            throw "Desktop 场景已记录，拒绝覆盖：$DesktopScenario"
        }
        $extension = [System.IO.Path]::GetExtension($DesktopScreenshotPath).ToLowerInvariant()
        $screenshot = Copy-EvidenceFile -Source $DesktopScreenshotPath -Destination (Join-Path $runDirectory "desktop-$suffix$extension")
        $screenshotMetadata = Get-ScreenshotMetadata -Path $screenshot.path
        $screenshotDistinct = [string]$screenshot.sha256 -notin @($state.desktopScreenshotHashes)
        $currentProcesses = Get-CodexProcessEvidence
        $previousProcesses = @($state.lastCodexProcesses)
        $previousIds = @($previousProcesses | ForEach-Object id)
        $currentIds = @($currentProcesses | ForEach-Object id)
        $pidRestarted = $previousIds.Count -gt 0 -and $currentIds.Count -gt 0 -and
            @($currentIds | Where-Object { $_ -in $previousIds }).Count -eq 0
        $currentProcessStarts = @($currentProcesses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.startTime) } |
            ForEach-Object { [DateTimeOffset]::Parse([string]$_.startTime).ToUniversalTime() })
        $screenshotFresh = $false
        if ($currentProcessStarts.Count -gt 0 -and $screenshotMetadata.valid) {
            $sessionStartedAt = @($currentProcessStarts | Sort-Object | Select-Object -First 1)[0]
            $screenshotTime = [DateTimeOffset]::Parse([string]$screenshotMetadata.capturedFileTime).ToUniversalTime()
            $now = [DateTimeOffset]::UtcNow
            $screenshotFresh = $screenshotTime -ge $sessionStartedAt -and $screenshotTime -ge $now.AddMinutes(-10) -and
                $screenshotTime -le $now.AddMinutes(2)
        }
        $agentEvidence = $null
        $terminalEvidence = $null
        $agentEvidenceFile = $null
        $terminalEvidenceFile = $null
        $agentPassed = $false
        $terminalPassed = $false
        if ($DesktopScenario -ne 'BaselineRestored') {
            $agentEvidenceFile = Copy-EvidenceFile -Source $agentEvidencePath -Destination (Join-Path $runDirectory "desktop-$suffix-agent.json")
            $terminalEvidenceFile = Copy-EvidenceFile -Source $terminalEvidencePath -Destination (Join-Path $runDirectory "desktop-$suffix-terminal.json")
            $agentEvidence = Read-JsonFile -Path $agentEvidenceFile.path
            $terminalEvidence = Read-JsonFile -Path $terminalEvidenceFile.path
            $agentEnvelopeValid = Test-DesktopEvidenceEnvelope -Evidence $agentEvidence -State $state -ExpectedChannel Agent -CurrentProcesses $currentProcesses
            $terminalEnvelopeValid = Test-DesktopEvidenceEnvelope -Evidence $terminalEvidence -State $state -ExpectedChannel Terminal -CurrentProcesses $currentProcesses
            $agentPassed = $agentEnvelopeValid -and $null -ne $agentEvidence.verifier -and (Test-VerifierEvidence -Evidence $agentEvidence.verifier -State $state)
            $terminalPassed = $terminalEnvelopeValid -and $null -ne $terminalEvidence.verifier -and (Test-VerifierEvidence -Evidence $terminalEvidence.verifier -State $state)
        }
        $scenarioPassed = switch ($DesktopScenario) {
            'AgentWslOnly' { $agentPassed -and $terminalEnvelopeValid -and (Test-ExpectedFailureEvidence -Evidence $terminalEvidence -State $state) }
            'TerminalWslOnly' { $agentEnvelopeValid -and (Test-ExpectedFailureEvidence -Evidence $agentEvidence -State $state) -and $terminalPassed }
            'BothWsl' { $agentPassed -and $terminalPassed }
            'BaselineRestored' { $ConfirmManualDesktopRollback -and $afterRollback }
        }
        $passed = $scenarioPassed -and $pidRestarted -and $screenshotFresh -and $screenshotDistinct
        $coverageValue = $(if ($passed) { 'PASS' } else { 'FAIL' })
        switch ($DesktopScenario) {
            'AgentWslOnly' { $state.validationCoverage.desktopAgentWslOnly = $coverageValue }
            'TerminalWslOnly' { $state.validationCoverage.desktopTerminalWslOnly = $coverageValue }
            'BothWsl' {
                if ($afterRollback) { $state.validationCoverage.finalDesktopWsl = $coverageValue }
                else { $state.validationCoverage.desktopBothWsl = $coverageValue }
            }
            'BaselineRestored' { $state.validationCoverage.manualDesktopRollback = $coverageValue }
        }
        if ($passed) {
            $state.lastCodexProcesses = $currentProcesses
            $state.desktopScreenshotHashes = @($state.desktopScreenshotHashes) + @([string]$screenshot.sha256)
            $state.validationCoverage.codexPidLifecycle = 'PASS'
        }
        else { $state.validationCoverage.codexPidLifecycle = 'FAIL' }
        $scenarioResult = [ordered]@{
            schemaVersion=2; phase='DesktopEvidence'; scenario=$DesktopScenario; afterRollback=$afterRollback
            runId=$script:RunId; verdict=$(if ($passed) { 'PASS' } else { 'FAIL' })
            screenshot=@{ path=$screenshot.path; sha256=$screenshot.sha256; width=$screenshotMetadata.width; height=$screenshotMetadata.height; freshForCurrentProcess=$screenshotFresh; distinctFromPriorScenarios=$screenshotDistinct; contentMachineVerified=$false }
            processRestart=@{ passed=$pidRestarted; before=$previousProcesses; after=$currentProcesses }
            agentEnvironmentCheck=@{ passed=$agentPassed; evidenceFile=$agentEvidenceFile; evidence=$agentEvidence }
            integratedTerminalCheck=@{ passed=$terminalPassed; evidenceFile=$terminalEvidenceFile; evidence=$terminalEvidence }
            manualDesktopSettingsAttested=[bool]$ConfirmManualDesktopSettings
            manualDesktopRollbackConfirmed=[bool]$ConfirmManualDesktopRollback
            channelOriginMachineVerified=$false
            method='The operator attested the GUI scenario and channel origins. The script only validates file envelopes, runtime content, timestamps, hashes, and Codex PID replacement.'
        }
        Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName "desktop-$suffix.json" -Value $scenarioResult
        $initialComplete = @(
            $state.validationCoverage.desktopAgentWslOnly,
            $state.validationCoverage.desktopTerminalWslOnly,
            $state.validationCoverage.desktopBothWsl,
            $state.validationCoverage.codexPidLifecycle
        ) -notcontains 'PENDING'
        if ($initialComplete) {
            Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'desktop-evidence.json' -Value ([ordered]@{
                schemaVersion=2; phase='DesktopEvidence'; runId=$script:RunId
                verdict=$(if (@(
                    $state.validationCoverage.desktopAgentWslOnly,
                    $state.validationCoverage.desktopTerminalWslOnly,
                    $state.validationCoverage.desktopBothWsl,
                    $state.validationCoverage.codexPidLifecycle
                ) -contains 'FAIL') { 'FAIL' } else { 'PASS' })
                scenarios=@('AgentWslOnly', 'TerminalWslOnly', 'BothWsl')
            })
        }
        if (-not $passed) { exit 1 }
    }
    'Rollback' {
        if (-not $ApplyChanges) { throw 'Rollback 阶段必须显式传入 -ApplyChanges。' }
        $state = Read-State -RunDirectory $runDirectory
        [void](Assert-PhasePassed -RunDirectory $runDirectory -State $state -FileName 'desktop-evidence.json')
        if ([string]::IsNullOrWhiteSpace([string]$state.setupManifestPath)) { throw 'Apply 阶段没有记录回滚清单。' }
        if ((Get-SetupSha256 -Path ([string]$state.setupManifestPath)) -cne [string]$state.setupManifestSha256BeforeRollback) {
            throw 'Apply 回滚清单在真实回滚前已改变。'
        }
        $manifest = Read-JsonFile -Path ([string]$state.setupManifestPath)
        if ($manifest.schemaVersion -ne 3) { throw '真实回滚只接受 v3 清单。' }
        $baselineById = @{}
        foreach ($item in @($state.baselinePackages)) { $baselineById[[string]$item.id] = [bool]$item.installed }
        foreach ($package in @($manifest.installedPackages)) {
            if (-not $baselineById.ContainsKey([string]$package.id)) { throw "缺少软件包基线，拒绝卸载：$($package.id)" }
            if ($baselineById[[string]$package.id]) { throw "软件包在验收前已经安装，拒绝卸载：$($package.id)" }
        }
        $config = Read-JsonFile -Path $state.acceptanceConfigPath
        $beforePreviewFiles = Get-ManagedFileEvidence -Config $config
        $beforePreviewCatalog = Get-WindowsPackageCatalog
        if ($beforePreviewCatalog.state -ne 'Known') { throw '回滚 Preview 前 WinGet 清单状态未知。' }
        $beforePreviewPackages = Get-StablePackageEvidence -Catalog $beforePreviewCatalog
        $previewResultPath = Join-Path $runDirectory 'rollback-preview-result.json'
        $previewInvocation = Invoke-SetupEntryPoint -Mode Rollback -ResultPath $previewResultPath `
            -TranscriptPath (Join-Path $runDirectory 'rollback-preview.txt') -EffectiveConfigPath $state.acceptanceConfigPath `
            -ManifestPath $state.setupManifestPath
        $afterPreviewCatalog = Get-WindowsPackageCatalog
        $previewZeroDrift = $previewInvocation.exitCode -eq 0 -and
            (Test-EquivalentJson -Before $beforePreviewFiles -After (Get-ManagedFileEvidence -Config $config)) -and
            (Test-EquivalentJson -Before $beforePreviewPackages -After (Get-StablePackageEvidence -Catalog $afterPreviewCatalog))
        $state.validationCoverage.rollbackPreviewZeroDrift = $(if ($previewZeroDrift) { 'PASS' } else { 'FAIL' })
        if (-not $previewZeroDrift) { throw '回滚 Preview 产生了持久化漂移。' }
        $resultPath = Join-Path $runDirectory 'rollback-setup-result.json'
        $transcriptPath = Join-Path $runDirectory 'rollback-transcript.txt'
        $invocation = Invoke-SetupEntryPoint -Mode Rollback -ResultPath $resultPath -TranscriptPath $transcriptPath `
            -EffectiveConfigPath $state.acceptanceConfigPath -ManifestPath $state.setupManifestPath -Mutate
        $afterCatalog = Get-WindowsPackageCatalog
        $packageChecks = if ($afterCatalog.state -eq 'Known') { @($manifest.installedPackages | ForEach-Object {
            [ordered]@{ id=$_.id; source=$_.source; state='Known'; installedAfterRollback=[bool](Test-CatalogPackageInstalled -Catalog $afterCatalog -Package $_) }
        }) } else { @($manifest.installedPackages | ForEach-Object {
            [ordered]@{ id=$_.id; source=$_.source; state='Unknown'; installedAfterRollback=$null; error=$afterCatalog.error }
        }) }
        $restoredFiles = Get-ManagedFileEvidence -Config $config
        $fileRestorePassed = Test-EquivalentJson -Before $state.baselineManagedFiles -After $restoredFiles
        $preinstalledPreserved = $afterCatalog.state -eq 'Known' -and @($state.baselinePackages | Where-Object installed -eq $true | Where-Object {
            -not (Test-CatalogPackageInstalled -Catalog $afterCatalog -Package $_)
        }).Count -eq 0
        $newPackagesRemoved = @($packageChecks | Where-Object installedAfterRollback -eq $true).Count -eq 0
        $wsl = Get-Command wsl.exe -ErrorAction Stop
        $linuxCheck = 'code_root=$1; case "$code_root" in "~") code_root="$HOME" ;; "~/"*) code_root="$HOME/${code_root:2}" ;; esac; cd -- "$code_root" && "$HOME/.local/bin/codex-env-check" --json'
        $wslInvocation = Invoke-NativeCapture -FilePath $wsl.Source -Arguments @(
            '-d', [string]$state.expectedDistro, '--', 'bash', '-lc', $linuxCheck, 'codex-rollback', [string]$state.codeRoot
        )
        $wslJsonLine = @($wslInvocation.output | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        $wslEvidence = if ($wslJsonLine.Count -eq 1) { $wslJsonLine[0] | ConvertFrom-Json -ErrorAction Stop } else { $null }
        $toolchainPreserved = $wslInvocation.exitCode -eq 0 -and $null -ne $wslEvidence -and
            (Test-VerifierEvidence -Evidence $wslEvidence -State $state)
        $state.validationCoverage.rollbackRestoreSha256Acl = $(if ($fileRestorePassed -and $preinstalledPreserved -and $newPackagesRemoved -and $toolchainPreserved) { 'PASS' } else { 'FAIL' })
        $state.validationCoverage.managedFileSha256Acl = $(if ($fileRestorePassed) { 'PASS' } else { 'FAIL' })

        $repeatResultPath = Join-Path $runDirectory 'rollback-repeat-result.json'
        $repeatInvocation = Invoke-SetupEntryPoint -Mode Rollback -ResultPath $repeatResultPath `
            -TranscriptPath (Join-Path $runDirectory 'rollback-repeat.txt') -EffectiveConfigPath $state.acceptanceConfigPath `
            -ManifestPath $state.setupManifestPath -Mutate
        $repeatRejected = $repeatInvocation.exitCode -eq 1

        $faultInvocation = Invoke-NativeCapture -FilePath (Join-Path $PSHOME 'pwsh.exe') -Arguments @(
            '-NoProfile', '-File', (Join-Path $repoRoot 'tests\Run-All.Tests.ps1')
        )
        $faultInvocation.text | Set-Content -LiteralPath (Join-Path $runDirectory 'rollback-fault-matrix.txt') -Encoding utf8
        $state.validationCoverage.isolatedRollbackFaults = $(if ($faultInvocation.exitCode -eq 0) { 'PASS' } else { 'FAIL' })

        $passed = $invocation.exitCode -eq 0 -and $afterCatalog.state -eq 'Known' -and
            $fileRestorePassed -and $preinstalledPreserved -and $newPackagesRemoved -and $toolchainPreserved -and
            $repeatRejected -and $faultInvocation.exitCode -eq 0
        if ($passed) { $state.rollbackCompletedAt = (Get-Date).ToString('o') }
        Write-TrackedArtifact -RunDirectory $runDirectory -State $state -FileName 'rollback.json' -Value ([ordered]@{
            schemaVersion=2; phase='Rollback'; runId=$script:RunId; verdict=$(if ($passed) { 'PASS' } else { 'FAIL' })
            previewZeroDrift=$previewZeroDrift; setupExitCode=$invocation.exitCode; packages=$packageChecks
            filesRestoredWithAcl=$fileRestorePassed; preinstalledPackagesPreserved=$preinstalledPreserved
            linuxToolchainPreserved=$toolchainPreserved; repeatedRollbackRejected=$repeatRejected
            isolatedFaultMatrixExitCode=$faultInvocation.exitCode
            safety=@{ unregisteredDistributions=@(); preinstalledPackagesUninstalled=@() }
        })
        if (-not $passed) { exit 1 }
    }
    'Report' {
        $state = Read-State -RunDirectory $runDirectory
        $phaseFiles = [ordered]@{
            preflight='preflight.json'; apply='apply.json'; postRestart='post-restart.json'
            desktopEvidence='desktop-evidence.json'; rollback='rollback.json'; finalReapply='final-reapply.json'
            baselineRestored='desktop-BaselineRestored-final.json'
            finalReapplyBaseline='final-reapply-baseline.json'; finalReapplyApply='final-reapply-apply.json'
            finalDesktop='desktop-BothWsl-final.json'
        }
        $phaseResults = [ordered]@{}
        $missingPhases = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $phaseFiles.GetEnumerator()) {
            $path = Join-Path $runDirectory $entry.Value
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and
                @($state.artifactChain | Where-Object { [string]$_.name -ieq $entry.Value }).Count -eq 1) {
                $phaseResults[$entry.Key] = Read-JsonFile -Path $path
            }
            else { $missingPhases.Add($entry.Key) }
        }
        $finalDetectPath = Join-Path $runDirectory 'final-detection.json'
        $finalDetectInvocation = Invoke-SetupEntryPoint -Mode Detect -ResultPath $finalDetectPath `
            -TranscriptPath (Join-Path $runDirectory 'final-detection.txt') -EffectiveConfigPath $state.acceptanceConfigPath
        $finalDetection = if ($finalDetectInvocation.exitCode -eq 0) { Read-JsonFile -Path $finalDetectPath } else { $null }
        $finalConfig = Read-JsonFile -Path $state.acceptanceConfigPath
        $finalManagedFiles = Get-ManagedFileEvidence -Config $finalConfig
        $finalCatalog = Get-WindowsPackageCatalog
        $managedFilesReady = @($state.finalReapplyAppliedManagedFiles).Count -gt 0 -and
            (Test-EquivalentJson -Before $state.finalReapplyAppliedManagedFiles -After $finalManagedFiles)
        $baselinePackagesPreserved = $finalCatalog.state -eq 'Known' -and @($state.baselinePackages | Where-Object installed -eq $true | Where-Object {
            -not (Test-CatalogPackageInstalled -Catalog $finalCatalog -Package $_)
        }).Count -eq 0
        $selectedPackageReady = $null -eq $state.selectedMissingTarget -or
            ($finalCatalog.state -eq 'Known' -and (Test-CatalogPackageInstalled -Catalog $finalCatalog -Package $state.selectedMissingTarget))
        $finalMachineReady = $null -ne $finalDetection -and $finalDetectInvocation.exitCode -eq 0 -and
            $finalDetection.detection.wsl.state -eq 'Ready' -and
            $finalDetection.detection.wslTools.environmentReady -eq $true -and
            @($finalDetection.blockingReasons).Count -eq 0 -and $managedFilesReady -and
            $baselinePackagesPreserved -and $selectedPackageReady
        $requiredCoverage = @(
            'windows11', 'administrator', 'wingetCatalog', 'wingetSources', 'targetWsl2',
            'managedFileSha256Acl', 'whatIfZeroDrift', 'wslShutdownResume', 'idempotentSecondApply',
            'desktopAgentWslOnly', 'desktopTerminalWslOnly', 'desktopBothWsl', 'codexPidLifecycle',
            'rollbackPreviewZeroDrift', 'rollbackRestoreSha256Acl', 'isolatedRollbackFaults',
            'manualDesktopRollback', 'finalReapply', 'finalDesktopWsl'
        )
        $badCoverage = @($requiredCoverage | Where-Object { [string]$state.validationCoverage.$_ -ne 'PASS' })
        if ([string]$state.validationCoverage.packageMutation -notin @('PASS', 'NOT_RUN')) { $badCoverage += 'packageMutation' }
        if ([string]$state.validationCoverage.initialWsl2Install -ne 'NOT_RUN') { $badCoverage += 'initialWsl2Install' }
        $failedPhases = @($phaseResults.GetEnumerator() | Where-Object {
            $_.Value.schemaVersion -ne 2 -or [string]$_.Value.runId -ne $script:RunId -or $_.Value.verdict -ne 'PASS'
        } | ForEach-Object Key)
        $verdict = if ($missingPhases.Count -gt 0) {
            'INCOMPLETE_CURRENT_HOST_WSL2'
        }
        elseif ($failedPhases.Count -gt 0 -or $badCoverage.Count -gt 0 -or -not $finalMachineReady) {
            'FAIL_CURRENT_HOST_WSL2'
        }
        else { 'PASS_CURRENT_HOST_WSL2' }
        $exclusions = @($state.exclusions) + @(
            'DESKTOP_SETTINGS_SCREENSHOT_CONTENT_ATTESTED_BY_USER_NOT_MACHINE_PARSED'
            'NO_PRIVATE_CODEX_SETTINGS_API_OR_GUI_AUTOMATION_USED'
            'RESULT_APPLIES_ONLY_TO_RECORDED_WINDOWS_HOST_AND_USER'
        )
        $evidenceIndex = @(
            Get-ChildItem -LiteralPath $runDirectory -File | Where-Object { $_.Name -notin @('acceptance-report.json', 'acceptance-report.md') } |
                Sort-Object Name | ForEach-Object { [ordered]@{ name=$_.Name; sha256=(Get-SetupSha256 -Path $_.FullName); length=$_.Length } }
        )
        $report = [ordered]@{
            schemaVersion=2; generatedAt=(Get-Date).ToString('o'); runId=$script:RunId; verdict=$verdict
            host=$state.host; expectedDistro=$state.expectedDistro; phases=$phaseResults
            missingPhases=@($missingPhases); failedPhases=$failedPhases; failedCoverage=$badCoverage
            validationCoverage=$state.validationCoverage; finalMachineReady=$finalMachineReady
            finalTargetChecks=[ordered]@{
                detectExitCode=$finalDetectInvocation.exitCode
                wslAndToolchainReady=($null -ne $finalDetection -and $finalDetection.detection.wsl.state -eq 'Ready' -and $finalDetection.detection.wslTools.environmentReady -eq $true)
                blockingReasons=@($(if ($null -ne $finalDetection) { $finalDetection.blockingReasons } else { @('final detection unavailable') }))
                managedFilesMatchFinalApply=$managedFilesReady
                baselinePackagesPreserved=$baselinePackagesPreserved
                selectedPackageInstalled=$selectedPackageReady
            }
            finalDetection=$finalDetection; exclusions=@($exclusions | Select-Object -Unique)
            evidenceIndex=$evidenceIndex
            safetyBoundary=@{
                currentHostOnly=$true; unregisteredDistributions=@(); preinstalledPackagesUninstalled=@()
                guiAutomationUsed=$false; privateDesktopSettingsRead=$false
                stateRootTrustedBoundary=[string]$state.anchors.stateRootTrustBoundary
                desktopChannelOriginMachineVerified=$false
            }
        }
        Write-JsonFile -Path (Join-Path $runDirectory 'acceptance-report.json') -Value $report
        $markdown = @(
            '# Windows 11 Codex WSL2 acceptance'
            ''
            "- RunId: $script:RunId"
            "- Verdict: **$verdict**"
            "- Host: $($state.host.machineName)"
            "- User SID: $($state.host.userSid)"
            "- Expected distro: $($state.expectedDistro)"
            ''
            '## Phase verdicts'
            ''
            @($phaseResults.GetEnumerator() | ForEach-Object { "- $($_.Key): $($_.Value.verdict)" })
            @($missingPhases | ForEach-Object { "- $($_): MISSING" })
            @($badCoverage | ForEach-Object { "- coverage.$($_): $($state.validationCoverage.$_)" })
            "- finalMachineReady: $finalMachineReady"
            ''
            '## Exclusions'
            ''
            @($exclusions | Select-Object -Unique | ForEach-Object { "- $_" })
            ''
            'No WSL distribution was unregistered, no package present before the run was approved for uninstall, and no private Codex GUI interface was read.'
        )
        $markdown | Set-Content -LiteralPath (Join-Path $runDirectory 'acceptance-report.md') -Encoding utf8
        Write-Host "$verdict — $runDirectory"
        if ($verdict -ne 'PASS_CURRENT_HOST_WSL2') { exit 1 }
    }
}
