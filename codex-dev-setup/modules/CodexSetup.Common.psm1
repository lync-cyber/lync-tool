Set-StrictMode -Version Latest

$script:Runtime = $null
$script:ManagedWindowsPackages = [ordered]@{
    'GitHub.cli'                    = 'winget'
    'Microsoft.WindowsTerminal'     = 'winget'
    'Git.Git'                       = 'winget'
    '9PLM9XGG6VKS'                  = 'msstore'
    'Docker.DockerDesktop'          = 'winget'
    'Microsoft.PowerShell'          = 'winget'
    'BurntSushi.ripgrep.MSVC'       = 'winget'
    'sharkdp.fd'                    = 'winget'
    'jqlang.jq'                     = 'winget'
    'OpenJS.NodeJS.LTS'             = 'winget'
    'astral-sh.uv'                  = 'winget'
}

function Test-ManagedWindowsPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source
    )
    foreach ($entry in $script:ManagedWindowsPackages.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Key, $Id, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]::Equals([string]$entry.Value, $Source, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $false
}

function Get-SetupSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return ([Convert]::ToHexString($algorithm.ComputeHash($stream))).ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-SetupTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Assert-SetupManagedFileTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('CodexConfig', 'GlobalAgents', 'WslConfig', 'GitConfig', 'ProjectTemplate')][string]$ManagedKind,
        [AllowNull()][string]$ManagedRoot
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $equals = {
        param([string]$Left, [string]$Right)
        [string]::Equals(
            [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/'),
            [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    $assertNoReparse = {
        param([string]$Target, [string]$Boundary)
        $current = [System.IO.Path]::GetFullPath($Target)
        $boundaryPath = [System.IO.Path]::GetFullPath($Boundary).TrimEnd('\', '/')
        while ($true) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "受管路径不能经过符号链接或重解析点：$current"
                }
            }
            if (& $equals $current $boundaryPath) { break }
            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($parent) -or (& $equals $parent $current)) {
                throw "受管路径越过允许的根目录：$Target"
            }
            $current = $parent
        }
    }
    if ($ManagedKind -eq 'ProjectTemplate') {
        if ([string]::IsNullOrWhiteSpace($ManagedRoot) -or -not [System.IO.Path]::IsPathFullyQualified($ManagedRoot)) {
            throw "项目模板缺少有效项目根：$fullPath"
        }
        $fullRoot = [System.IO.Path]::GetFullPath($ManagedRoot)
        if (-not (& $equals (Split-Path -Parent $fullPath) $fullRoot) -or
            (Split-Path -Leaf $fullPath) -notin @('AGENTS.md', '.editorconfig', '.gitattributes', '.gitignore')) {
            throw "目标不属于受管项目模板：$fullPath"
        }
        & $assertNoReparse $fullPath $fullRoot
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ManagedRoot)) { throw "用户配置文件不能声明项目根：$fullPath" }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw '无法解析受管用户配置根目录。' }
    $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE)
    $expected = switch ($ManagedKind) {
        'CodexConfig' { Join-Path $userProfile '.codex\config.toml' }
        'GlobalAgents' { Join-Path $userProfile '.codex\AGENTS.md' }
        'WslConfig' { Join-Path $userProfile '.wslconfig' }
        'GitConfig' { Join-Path $userProfile '.gitconfig' }
    }
    if (-not (& $equals $fullPath $expected)) { throw "目标不属于受管用户配置：$fullPath" }
    & $assertNoReparse $fullPath $userProfile
}

function Write-SetupJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath)) | Out-Null
    $temporaryPath = "$fullPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ($Value | ConvertTo-Json -Depth 30).TrimEnd("`r", "`n") + [Environment]::NewLine
        [System.IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-SetupCanonicalValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-SetupCanonicalValue -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)) {
            $result[$property.Name] = ConvertTo-SetupCanonicalValue -Value $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-SetupCanonicalValue -Value $_ })
    }
    return $Value
}

function Get-RollbackEnvironmentBinding {
    $hostIdentity = if ($IsWindows) {
        $machineGuid = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop)
        "windows|$machineGuid"
    }
    else {
        $machineId = if (Test-Path -LiteralPath '/etc/machine-id' -PathType Leaf) {
            (Get-Content -LiteralPath '/etc/machine-id' -Raw -Encoding utf8).Trim()
        }
        else { [Environment]::MachineName }
        "unix|$machineId"
    }
    $userIdentity = if ($IsWindows) {
        "windows|$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
    }
    else {
        "unix|$([Environment]::UserDomainName)|$([Environment]::UserName)"
    }
    [pscustomobject]@{
        hostBinding=Get-SetupTextSha256 -Text "CodexDevSetup|host|$hostIdentity"
        userBinding=Get-SetupTextSha256 -Text "CodexDevSetup|user|$userIdentity"
    }
}

function Get-RollbackKeyEntropy {
    param([Parameter(Mandatory)][string]$RunId)
    return [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes("CodexDevSetup|rollback-v3|$RunId"))
}

function New-RollbackAuthenticationKey {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    $keyPath = Join-Path $RunRoot 'rollback-auth.key'
    if (Test-Path -LiteralPath $keyPath) { throw "回滚认证密钥已存在：$keyPath" }
    $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    try {
        if ($IsWindows) {
            $protected = [Security.Cryptography.ProtectedData]::Protect(
                $key,
                (Get-RollbackKeyEntropy -RunId $RunId),
                [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $payload = [byte[]]([Text.Encoding]::ASCII.GetBytes('DPV1') + $protected)
        }
        else {
            $payload = [byte[]]([Text.Encoding]::ASCII.GetBytes('RAW1') + $key)
        }
        [System.IO.File]::WriteAllBytes($keyPath, $payload)
        if (-not $IsWindows) {
            [System.IO.File]::SetUnixFileMode(
                $keyPath,
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            )
        }
    }
    finally { [Array]::Clear($key, 0, $key.Length) }
    return $keyPath
}

function Get-RollbackAuthenticationKey {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    $keyPath = Join-Path $RunRoot 'rollback-auth.key'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw '回滚认证密钥缺失。' }
    $keyItem = Get-Item -LiteralPath $keyPath -Force
    if (($keyItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw '回滚认证密钥不能是重解析点。' }
    $payload = [System.IO.File]::ReadAllBytes($keyPath)
    if ($payload.Length -lt 5) { throw '回滚认证密钥无效。' }
    $format = [Text.Encoding]::ASCII.GetString($payload, 0, 4)
    $body = $payload[4..($payload.Length - 1)]
    if ($format -eq 'DPV1' -and $IsWindows) {
        return [Security.Cryptography.ProtectedData]::Unprotect(
            $body,
            (Get-RollbackKeyEntropy -RunId $RunId),
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    }
    if ($format -eq 'RAW1' -and -not $IsWindows -and $body.Length -eq 32) { return [byte[]]$body }
    throw '回滚认证密钥与当前平台或用户不匹配。'
}

function Get-RollbackManifestHmac {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $unsigned = [ordered]@{}
    if ($Manifest -is [System.Collections.IDictionary]) {
        foreach ($entry in $Manifest.GetEnumerator()) {
            if ([string]$entry.Key -ne 'manifestHmac') { $unsigned[[string]$entry.Key] = $entry.Value }
        }
    }
    else {
        foreach ($property in $Manifest.PSObject.Properties) {
            if ($property.Name -ne 'manifestHmac') { $unsigned[$property.Name] = $property.Value }
        }
    }
    $canonical = ConvertTo-SetupCanonicalValue -Value $unsigned
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($canonical | ConvertTo-Json -Depth 30 -Compress))
    $algorithm = [Security.Cryptography.HMACSHA256]::new($Key)
    try { return ([Convert]::ToHexString($algorithm.ComputeHash($bytes))).ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Write-RollbackManifestAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Manifest
    )
    $runRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $runId = Split-Path -Leaf $runRoot
    [byte[]]$key = @(Get-RollbackAuthenticationKey -RunRoot $runRoot -RunId $runId)
    try {
        $mac = Get-RollbackManifestHmac -Manifest $Manifest -Key $key
        if ($Manifest -is [System.Collections.IDictionary]) { $Manifest.manifestHmac = $mac }
        else { $Manifest.manifestHmac = $mac }
        Write-SetupJsonAtomic -Path $Path -Value $Manifest
    }
    finally { [Array]::Clear($key, 0, $key.Length) }
}

function Assert-RollbackManifestAuthentication {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Manifest
    )
    foreach ($field in @('hostBinding', 'userBinding', 'manifestHmac')) {
        if ($Manifest.PSObject.Properties.Name -notcontains $field -or [string]$Manifest.$field -notmatch '^[a-f0-9]{64}$') {
            throw "回滚清单缺少有效认证字段：$field。"
        }
    }
    $binding = Get-RollbackEnvironmentBinding
    if (-not [string]::Equals([string]$Manifest.hostBinding, [string]$binding.hostBinding, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$Manifest.userBinding, [string]$binding.userBinding, [StringComparison]::Ordinal)) {
        throw '回滚清单不属于当前主机和用户。'
    }
    $runRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $runId = Split-Path -Leaf $runRoot
    [byte[]]$key = @(Get-RollbackAuthenticationKey -RunRoot $runRoot -RunId $runId)
    try {
        $expectedText = Get-RollbackManifestHmac -Manifest $Manifest -Key $key
        $expected = [Convert]::FromHexString($expectedText)
        $actual = [Convert]::FromHexString([string]$Manifest.manifestHmac)
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $actual)) {
            throw '回滚清单完整性校验失败。'
        }
    }
    finally {
        if ($null -ne $key) { [Array]::Clear($key, 0, $key.Length) }
    }
}

function Get-WindowsPackageCatalog {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) {
        return [pscustomobject]@{ state='Unknown'; packages=@(); error='windows-host-required' }
    }
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        return [pscustomobject]@{ state='Unknown'; packages=@(); error='winget-command-not-found' }
    }
    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-dev-setup-winget-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $output = @(& $winget.Source export --output $temporaryPath --include-versions --accept-source-agreements --disable-interactivity 2>&1)
        $exitCode = $LASTEXITCODE
        Write-SetupLog -Level Debug -Message 'WinGet 结构化软件包清单查询完成' -Data @{
            exitCode=$exitCode
            output=(ConvertTo-RedactedText (($output | ForEach-Object { [string]$_ }) -join "`n"))
        }
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            return [pscustomobject]@{ state='Unknown'; packages=@(); error="winget-export-failed:$exitCode" }
        }
        try { $document = Get-Content -LiteralPath $temporaryPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ state='Unknown'; packages=@(); error="winget-export-invalid-json:$($_.Exception.Message)" } }
        if ($null -eq $document -or $document.PSObject.Properties.Name -notcontains 'Sources') {
            return [pscustomobject]@{ state='Unknown'; packages=@(); error='winget-export-missing-sources' }
        }

        $packages = [System.Collections.Generic.List[object]]::new()
        foreach ($sourceEntry in @($document.Sources)) {
            $details = $sourceEntry.SourceDetails
            $sourceCandidates = @(
                [string]$details.Name
                [string]$details.Identifier
                [string]$details.Argument
            ) -join '|'
            $source = if ($sourceCandidates -match '(?i)(^|\|)msstore(\||$)|storeedgefd') {
                'msstore'
            }
            elseif ($sourceCandidates -match '(?i)(^|\|)winget(\||$)|winget\.source') {
                'winget'
            }
            else { $null }
            if (-not $source) { continue }
            foreach ($package in @($sourceEntry.Packages)) {
                $id = [string]$package.PackageIdentifier
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                $name = if ($package.PSObject.Properties.Name -contains 'PackageName') { [string]$package.PackageName } else { $null }
                $version = if ($package.PSObject.Properties.Name -contains 'Version') { [string]$package.Version } else { $null }
                $packages.Add([pscustomobject]@{ id=$id; source=$source; version=$version; name=$name })
            }
        }
        return [pscustomobject]@{ state='Known'; complete=$false; packages=@($packages); error=$null }
    }
    catch {
        return [pscustomobject]@{ state='Unknown'; packages=@(); error=(ConvertTo-RedactedText $_.Exception.Message) }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-WindowsPackageState {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][ValidateSet('winget', 'msstore')][string]$Source,
        [AllowNull()]$Catalog
    )
    if (-not $IsWindows) {
        return [pscustomobject]@{ state='Unknown'; installed=$false; version=$null; error='windows-host-required' }
    }
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        return [pscustomobject]@{ state='Unknown'; installed=$false; version=$null; error='winget-command-not-found' }
    }
    $output = @(& $winget.Source list --id $PackageId --exact --source $Source --accept-source-agreements --disable-interactivity 2>&1)
    $exitCode = $LASTEXITCODE
    Write-SetupLog -Level Debug -Message 'WinGet 精确软件包查询完成' -Data @{
        packageId=$PackageId
        source=$Source
        exitCode=$exitCode
        output=(ConvertTo-RedactedText (($output | ForEach-Object { [string]$_ }) -join "`n"))
    }
    if ($exitCode -eq -1978335212) {
        return [pscustomobject]@{ state='KnownMissing'; installed=$false; version=$null; error=$null }
    }
    if ($exitCode -ne 0) {
        return [pscustomobject]@{ state='Unknown'; installed=$false; version=$null; error="winget-list-failed:$exitCode" }
    }
    if ($null -eq $Catalog) { $Catalog = Get-WindowsPackageCatalog }
    if ($Catalog.state -ne 'Known') {
        return [pscustomobject]@{ state='Unknown'; installed=$false; version=$null; error=[string]$Catalog.error }
    }
    $matches = @($Catalog.packages | Where-Object {
        [string]::Equals([string]$_.id, $PackageId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.source, $Source, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$matches[0].version)) {
        return [pscustomobject]@{
            state='Unknown'
            installed=$false
            version=$null
            error='精确查询确认已安装，但结构化清单无法提供唯一版本。'
        }
    }
    return [pscustomobject]@{ state='KnownInstalled'; installed=$true; version=[string]$matches[0].version; error=$null }
}

function ConvertTo-RedactedText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }

    $result = $Text
    $patterns = @(
        @{
            pattern='(?i)(["'']?(?:api[_-]?key|token|secret|password|authorization)["'']?\s*[:=]\s*)(?:"(?:\\.|[^"])*"|''[^'']*''|[^\s,;}\]]+)'
            replacement='${1}"[REDACTED]"'
        },
        @{ pattern='(?i)bearer\s+[a-z0-9._~+/=-]+'; replacement='Bearer [REDACTED]' },
        @{ pattern='(?i)gh[pousr]_[a-z0-9_]{20,}'; replacement='[REDACTED]' },
        @{ pattern='(?i)sk-[a-z0-9_-]{16,}'; replacement='[REDACTED]' }
    )
    foreach ($item in $patterns) {
        $result = [regex]::Replace($result, $item.pattern, $item.replacement)
    }
    return $result
}

function Initialize-SetupRuntime {
    [CmdletBinding()]
    param(
        [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),
        [string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
        $StateRoot = Join-Path $base 'CodexDevSetup'
    }

    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $RunId -in @('.', '..')) {
        throw 'RunId 只能包含字母、数字、点、下划线和连字符。'
    }
    $runRoot = Join-Path $StateRoot (Join-Path 'runs' $RunId)
    $backupRoot = Join-Path $runRoot 'backups'
    $logRoot = Join-Path $StateRoot 'logs'
    if (Test-Path -LiteralPath $runRoot) { throw "运行目录已存在：$runRoot" }
    foreach ($path in @($StateRoot, $runRoot, $backupRoot, $logRoot)) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    New-RollbackAuthenticationKey -RunRoot $runRoot -RunId $RunId | Out-Null
    $binding = Get-RollbackEnvironmentBinding

    $script:Runtime = [ordered]@{
        RunId        = $RunId
        StateRoot    = $StateRoot
        RunRoot      = $runRoot
        BackupRoot   = $backupRoot
        LogPath      = Join-Path $logRoot "$RunId.jsonl"
        SummaryPath  = Join-Path $runRoot 'summary.md'
        ManifestPath = Join-Path $runRoot 'rollback-manifest.json'
        Manifest     = [ordered]@{
            schemaVersion     = 3
            runId             = $RunId
            createdAt         = (Get-Date).ToString('o')
            hostBinding       = $binding.hostBinding
            userBinding       = $binding.userBinding
            manifestHmac      = $null
            runStatus         = 'InProgress'
            completed         = $false
            completedAt       = $null
            changeCount       = 0
            hasChanges        = $false
            rolledBackAt      = $null
            files             = @()
            installedPackages = @()
            notes             = @()
        }
    }
    Save-RollbackManifest
    Write-SetupLog -Level Info -Message '运行环境已初始化' -Data @{ runId = $RunId; stateRoot = $StateRoot }
    return [pscustomobject]$script:Runtime
}

function Get-SetupRuntime {
    if ($null -eq $script:Runtime) { throw '尚未初始化运行环境。请先调用 Initialize-SetupRuntime。' }
    return [pscustomobject]$script:Runtime
}

function Write-SetupLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level = 'Info',
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()]$Data
    )

    $safeMessage = ConvertTo-RedactedText $Message
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level     = $Level
        message   = $safeMessage
    }
    if ($null -ne $Data) {
        $serialized = $Data | ConvertTo-Json -Depth 12 -Compress
        $entry.data = (ConvertTo-RedactedText $serialized | ConvertFrom-Json)
    }

    if ($null -ne $script:Runtime) {
        ($entry | ConvertTo-Json -Depth 12 -Compress) | Add-Content -LiteralPath $script:Runtime.LogPath -Encoding utf8
    }
}

function Write-SetupStatus {
    [CmdletBinding()]
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Plan')][string]$Kind = 'Info',
        [Parameter(Mandatory)][string]$Message
    )

    $colors = @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red'; Plan = 'Magenta' }
    $prefix = @{ Info = '[信息]'; Success = '[完成]'; Warning = '[注意]'; Error = '[错误]'; Plan = '[计划]' }
    Write-Host "$($prefix[$Kind]) $Message" -ForegroundColor $colors[$Kind]
    Write-SetupLog -Level $(if ($Kind -eq 'Error') { 'Error' } elseif ($Kind -eq 'Warning') { 'Warning' } else { 'Info' }) -Message $Message
}

function Write-SetupWrappedText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [string]$FirstIndent = '',
        [string]$ContinuationIndent = $FirstIndent,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [int]$Width
    )

    if ($Width -le 0) {
        try {
            $consoleWidth = [Console]::WindowWidth
            $Width = if ($consoleWidth -lt 40) { 76 } else { [math]::Min(88, [math]::Max(60, $consoleWidth - 2)) }
        }
        catch { $Width = 72 }
    }

    function Get-DisplayWidth([string]$Value) {
        $total = 0
        foreach ($character in $Value.ToCharArray()) {
            $total += $(if ([int]$character -gt 255) { 2 } else { 1 })
        }
        return $total
    }

    $indent = $FirstIndent
    $line = $indent
    $lineWidth = Get-DisplayWidth $line
    $tokens = [regex]::Matches(
        $Text,
        '[A-Za-z]:\\[A-Za-z0-9_.~=@%+-]+|[\\/][A-Za-z0-9_.~=@%+-]+|[A-Za-z0-9_.:~=@%+-]+|[^\x00-\xFF，。；：！？、]+[，。；：！？、]?|\s+|.',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    foreach ($match in $tokens) {
        $token = $match.Value
        if ($token -match '^\s+$') {
            if ($line.Length -gt $indent.Length -and -not $line.EndsWith(' ')) {
                $token = ' '
            }
            else { continue }
        }
        $tokenWidth = Get-DisplayWidth $token
        $isClosingPunctuation = $token -match "^[，。；：！？、）】》\u201D\u2019]$"
        if ($lineWidth + $tokenWidth -gt $Width -and $line.Length -gt $indent.Length -and -not $isClosingPunctuation) {
            Write-Host $line.TrimEnd() -ForegroundColor $ForegroundColor
            $indent = $ContinuationIndent
            $line = $indent
            $lineWidth = Get-DisplayWidth $line
            if ($token -eq ' ') { continue }
        }

        if ($lineWidth + $tokenWidth -gt $Width -and $line.Length -eq $indent.Length -and -not $isClosingPunctuation) {
            foreach ($character in $token.ToCharArray()) {
                $characterText = [string]$character
                $characterWidth = Get-DisplayWidth $characterText
                if ($lineWidth + $characterWidth -gt $Width -and $line.Length -gt $indent.Length) {
                    Write-Host $line.TrimEnd() -ForegroundColor $ForegroundColor
                    $indent = $ContinuationIndent
                    $line = $indent
                    $lineWidth = Get-DisplayWidth $line
                }
                $line += $characterText
                $lineWidth += $characterWidth
            }
            continue
        }
        $line += $token
        $lineWidth += $tokenWidth
    }
    Write-Host $line.TrimEnd() -ForegroundColor $ForegroundColor
}

function Assert-SetupObjectShape {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Required,
        [string[]]$Optional = @()
    )
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Path 必须是 JSON 对象。"
    }
    $actual = @($Value.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($name -notin $actual) { throw "$Path 缺少必填字段 $name。" }
    }
    $allowed = @($Required + $Optional)
    $unknown = @($actual | Where-Object { $_ -notin $allowed })
    if ($unknown.Count -gt 0) { throw "$Path 包含不支持的字段：$($unknown -join '、')。" }
}

function Assert-SetupBoolean {
    param($Value, [Parameter(Mandatory)][string]$Path)
    if ($Value -isnot [bool]) { throw "$Path 必须是布尔值。" }
}

function Assert-SetupString {
    param(
        $Value,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Allowed,
        [switch]$AllowEmpty
    )
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "$Path 必须是$(if ($AllowEmpty) { '' } else { '非空' })字符串。"
    }
    if ($null -ne $Allowed -and $Allowed.Count -gt 0 -and $Value -notin $Allowed) {
        throw "$Path 的值无效：$Value；允许值为 $($Allowed -join '、')。"
    }
}

function Test-SetupStringArray {
    param($Value, [Parameter(Mandatory)][string]$Path, [string]$Pattern = '^.+$')
    if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
        throw "$Path 必须是字符串数组。"
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or $item -notmatch $Pattern) { throw "$Path 包含无效值：$item。" }
        if (-not $seen.Add($item)) { throw "$Path 包含重复值：$item。" }
    }
}

function Assert-SetupConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    Assert-SetupObjectShape -Value $Config -Path 'config' -Required @(
        'schemaVersion', 'environmentMode', 'preferences', 'paths',
        'windows', 'codex', 'wsl', 'toolchains', 'projectTemplates'
    )
    if ($Config.schemaVersion -ne 2) { throw "不支持的配置 schemaVersion：$($Config.schemaVersion)；需要 2。" }
    Assert-SetupString $Config.environmentMode 'environmentMode' -Allowed @('WslFirst', 'WindowsNative')

    Assert-SetupObjectShape $Config.preferences 'preferences' @('moduleConfirmation', 'firstRunWhatIf', 'updatePolicy')
    Assert-SetupString $Config.preferences.moduleConfirmation 'preferences.moduleConfirmation' -Allowed @('Prompt', 'Never')
    Assert-SetupBoolean $Config.preferences.firstRunWhatIf 'preferences.firstRunWhatIf'
    Assert-SetupString $Config.preferences.updatePolicy 'preferences.updatePolicy' -Allowed @('CheckOnly', 'Skip')

    Assert-SetupObjectShape $Config.paths 'paths' @('windowsProjects', 'wslProjects', 'projectPath')
    Assert-SetupString $Config.paths.windowsProjects 'paths.windowsProjects'
    Assert-SetupString $Config.paths.wslProjects 'paths.wslProjects'
    Assert-SetupString $Config.paths.projectPath 'paths.projectPath' -AllowEmpty
    if ([string]$Config.paths.wslProjects -ne '~/code') { throw 'paths.wslProjects 必须是 ~/code。' }

    Assert-SetupObjectShape $Config.windows 'windows' @('installDesktop', 'installTerminal', 'installUiGit', 'installGitHubCli')
    foreach ($name in @('installDesktop', 'installTerminal', 'installUiGit', 'installGitHubCli')) {
        Assert-SetupBoolean $Config.windows.$name "windows.$name"
    }

    Assert-SetupObjectShape $Config.codex 'codex' @(
        'approvalPolicy', 'sandboxMode', 'windowsSandbox', 'networkAccess', 'webSearch', 'checkForUpdateOnStartup'
    )
    Assert-SetupString $Config.codex.approvalPolicy 'codex.approvalPolicy' -Allowed @('untrusted', 'on-request', 'never')
    Assert-SetupString $Config.codex.sandboxMode 'codex.sandboxMode' -Allowed @('read-only', 'workspace-write', 'danger-full-access')
    Assert-SetupString $Config.codex.windowsSandbox 'codex.windowsSandbox' -Allowed @('elevated', 'unelevated')
    Assert-SetupBoolean $Config.codex.networkAccess 'codex.networkAccess'
    Assert-SetupString $Config.codex.webSearch 'codex.webSearch' -Allowed @('disabled', 'cached', 'indexed', 'live')
    Assert-SetupBoolean $Config.codex.checkForUpdateOnStartup 'codex.checkForUpdateOnStartup'

    Assert-SetupObjectShape $Config.wsl 'wsl' @(
        'distribution', 'ensureLatest', 'installCodexCli', 'installPnpm', 'configureGit',
        'packages', 'aliases', 'networking'
    )
    Assert-SetupString $Config.wsl.distribution 'wsl.distribution' -Allowed @('Ubuntu-24.04')
    foreach ($name in @('ensureLatest', 'installCodexCli', 'installPnpm', 'configureGit')) {
        Assert-SetupBoolean $Config.wsl.$name "wsl.$name"
    }
    Test-SetupStringArray $Config.wsl.packages 'wsl.packages' '^[a-z0-9][a-z0-9+.-]*$'
    $requiredWslPackages = @(
        'build-essential', 'ca-certificates', 'curl', 'fd-find', 'gh', 'git', 'jq',
        'ripgrep', 'shellcheck', 'shfmt', 'unzip'
    )
    $missingWslPackages = @($requiredWslPackages | Where-Object { $_ -notin @($Config.wsl.packages) })
    if ($missingWslPackages.Count -gt 0) {
        throw "wsl.packages 缺少 v2 必需软件包：$($missingWslPackages -join '、')。"
    }
    if ($Config.wsl.aliases -isnot [pscustomobject]) { throw 'wsl.aliases 必须是 JSON 对象。' }
    foreach ($alias in $Config.wsl.aliases.PSObject.Properties) {
        if ($alias.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or $alias.Value -isnot [string] -or $alias.Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
            throw "WSL 命令别名无效：$($alias.Name)=$($alias.Value)。"
        }
    }
    if ($Config.wsl.aliases.PSObject.Properties.Name -notcontains 'fd' -or [string]$Config.wsl.aliases.fd -ne 'fdfind') {
        throw 'wsl.aliases 必须包含 fd=fdfind。'
    }

    Assert-SetupObjectShape $Config.wsl.networking 'wsl.networking' @(
        'enabled', 'manageWslConfig', 'networkingMode', 'dnsTunneling', 'autoProxy', 'firewall'
    )
    foreach ($name in @('enabled', 'manageWslConfig', 'dnsTunneling', 'autoProxy', 'firewall')) {
        Assert-SetupBoolean $Config.wsl.networking.$name "wsl.networking.$name"
    }
    Assert-SetupString $Config.wsl.networking.networkingMode 'wsl.networking.networkingMode' -Allowed @('nat', 'mirrored')

    Assert-SetupObjectShape $Config.toolchains 'toolchains' @('node', 'python', 'docker')
    Assert-SetupObjectShape $Config.toolchains.node 'toolchains.node' @('enabled')
    Assert-SetupBoolean $Config.toolchains.node.enabled 'toolchains.node.enabled'
    Assert-SetupObjectShape $Config.toolchains.python 'toolchains.python' @('enabled')
    Assert-SetupBoolean $Config.toolchains.python.enabled 'toolchains.python.enabled'
    Assert-SetupObjectShape $Config.toolchains.docker 'toolchains.docker' @('enabled', 'provider')
    Assert-SetupBoolean $Config.toolchains.docker.enabled 'toolchains.docker.enabled'
    Assert-SetupString $Config.toolchains.docker.provider 'toolchains.docker.provider' -Allowed @('DockerDesktop')

    Assert-SetupObjectShape $Config.projectTemplates 'projectTemplates' @('enabled')
    Assert-SetupBoolean $Config.projectTemplates.enabled 'projectTemplates.enabled'
    [void](Get-WslPackageConfiguration -Config $Config)
    return $Config
}

function Read-SetupConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "配置文件不存在：$Path" }
    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        throw "配置文件不是有效 JSON：$Path。$($_.Exception.Message)"
    }
    return Assert-SetupConfiguration -Config $config
}

function Export-SetupConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $desired = ($Config | ConvertTo-Json -Depth 20).TrimEnd("`r", "`n") + [Environment]::NewLine
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        if ($current -eq $desired) { return [pscustomobject]@{ status='NoChange'; path=$Path } }
        throw "导出文件已存在且内容不同：$Path。请指定新的 -ExportPath。"
    }
    if ($WhatIfPreference) { return [pscustomobject]@{ status='Preview'; path=$Path } }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        if ($PSCmdlet.ShouldProcess($parent, '创建配置目录')) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($Path, '导出可复用 JSON 配置')) {
        Set-Content -LiteralPath $Path -Value $desired -Encoding utf8 -NoNewline
        Write-SetupLog -Message '配置已导出' -Data @{ path = $Path }
        return [pscustomobject]@{ status='Changed'; path=$Path }
    }
    return [pscustomobject]@{ status='Cancelled'; path=$Path }
}

function Confirm-SetupChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$DefaultYes = $false,
        [switch]$NonInteractive
    )
    if ($NonInteractive) { return $DefaultYes }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer.Trim() -match '^(?i:y|yes|是|确认)$'
}

function Save-RollbackManifest {
    if ($null -eq $script:Runtime) { return }
    Write-RollbackManifestAtomic -Path $script:Runtime.ManifestPath -Manifest $script:Runtime.Manifest
}

function Add-RollbackNote {
    param([Parameter(Mandatory)][string]$Note)
    if ($null -eq $script:Runtime) { return }
    $script:Runtime.Manifest.notes += $Note
    Save-RollbackManifest
}

function Register-InstalledPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget',
        [Parameter(Mandatory)][string]$Version
    )
    if (-not (Test-ManagedWindowsPackage -Id $Id -Source $Source)) {
        throw '拒绝登记无效的软件包回滚目标。'
    }
    $duplicate = @($script:Runtime.Manifest.installedPackages | Where-Object {
        [string]::Equals([string]$_.id, $Id, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.source, $Source, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($duplicate.Count -gt 0) { throw "软件包已登记到当前回滚清单：$Id" }
    if ([string]::IsNullOrWhiteSpace($Version)) { throw "无法登记缺少安装版本的软件包：$Id" }
    $script:Runtime.Manifest.installedPackages += [ordered]@{
        id = $Id
        source = $Source
        installedVersion = $Version
        rollbackStatus = 'Pending'
        rollbackError = $null
    }
    $script:Runtime.Manifest.changeCount++
    $script:Runtime.Manifest.hasChanges = $true
    Save-RollbackManifest
}

function Backup-SetupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AppliedSha256,
        [Parameter(Mandatory)][ValidateSet('CodexConfig', 'GlobalAgents', 'WslConfig', 'GitConfig', 'ProjectTemplate')][string]$ManagedKind,
        [AllowNull()][string]$ManagedRoot
    )

    if ($null -eq $script:Runtime) { throw '尚未初始化运行环境。' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    Assert-SetupManagedFileTarget -Path $fullPath -ManagedKind $ManagedKind -ManagedRoot $ManagedRoot
    $existing = @($script:Runtime.Manifest.files | Where-Object { $_.path -eq $fullPath })
    if ($existing.Count -gt 0) { return $existing[0] }

    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($AppliedSha256 -notmatch '^[a-f0-9]{64}$') { throw '应用后文件 SHA-256 无效。' }
    $record = [ordered]@{
        path = $fullPath
        existed = $exists
        backup = $null
        beforeSha256 = $null
        appliedSha256 = $AppliedSha256
        backupSha256 = $null
        beforeSddl = $null
        appliedSddl = $null
        managedKind = $ManagedKind
        managedRoot = $(if ($ManagedRoot) { [System.IO.Path]::GetFullPath($ManagedRoot) } else { $null })
        rollbackStatus = 'Pending'
        rollbackError = $null
    }
    if ($exists) {
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fullPath))).Substring(0, 16)
        $leaf = Split-Path -Leaf $fullPath
        $backupPath = Join-Path $script:Runtime.BackupRoot "$hash-$leaf"
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
        $record.backup = $backupPath
        $record.beforeSha256 = Get-SetupSha256 -Path $fullPath
        $record.backupSha256 = Get-SetupSha256 -Path $backupPath
        if ($IsWindows) {
            $record.beforeSddl = (Get-Acl -LiteralPath $fullPath).Sddl
            $record.appliedSddl = $record.beforeSddl
        }
        if ($record.beforeSha256 -ne $record.backupSha256) { throw "备份复核失败：$fullPath" }
    }
    $script:Runtime.Manifest.files += $record
    $script:Runtime.Manifest.changeCount++
    $script:Runtime.Manifest.hasChanges = $true
    Save-RollbackManifest
    return [pscustomobject]$record
}

function Set-SetupFileContent {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$Description = '写入配置文件',
        [Parameter(Mandatory)][ValidateSet('CodexConfig', 'GlobalAgents', 'WslConfig', 'GitConfig', 'ProjectTemplate')][string]$ManagedKind,
        [AllowNull()][string]$ManagedRoot
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $current = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { Get-Content -LiteralPath $fullPath -Raw -Encoding utf8 } else { $null }
    $normalized = $Content.TrimEnd("`r", "`n") + [Environment]::NewLine
    if ($current -eq $normalized) {
        Write-SetupLog -Message '文件内容已是目标状态，跳过' -Data @{ path = $fullPath }
        return $false
    }
    if ($PSCmdlet.ShouldProcess($fullPath, $Description)) {
        $appliedSha256 = Get-SetupTextSha256 -Text $normalized
        Backup-SetupFile -Path $fullPath -AppliedSha256 $appliedSha256 -ManagedKind $ManagedKind -ManagedRoot $ManagedRoot | Out-Null
        $parent = Split-Path -Parent $fullPath
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        $temporaryPath = Join-Path $parent ('.{0}.{1}.tmp' -f (Split-Path -Leaf $fullPath), [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($temporaryPath, $normalized, [Text.UTF8Encoding]::new($false))
            $record = @($script:Runtime.Manifest.files | Where-Object { $_.path -eq $fullPath } | Select-Object -First 1)
            if ($record.Count -ne 1) { throw "写入前找不到回滚记录：$fullPath" }
            if ($IsWindows) {
                if ($record[0].existed) {
                    $temporaryAcl = Get-Acl -LiteralPath $temporaryPath
                    $temporaryAcl.SetSecurityDescriptorSddlForm([string]$record[0].beforeSddl)
                    Set-Acl -LiteralPath $temporaryPath -AclObject $temporaryAcl
                }
                $record[0].appliedSddl = (Get-Acl -LiteralPath $temporaryPath).Sddl
            }
            Save-RollbackManifest
            if ($record[0].existed) {
                if ((Get-SetupSha256 -Path $fullPath) -ne [string]$record[0].beforeSha256) {
                    throw "受管文件在备份后发生变化，拒绝覆盖：$fullPath"
                }
                if ($IsWindows -and -not [string]::Equals((Get-Acl -LiteralPath $fullPath).Sddl, [string]$record[0].beforeSddl, [StringComparison]::Ordinal)) {
                    throw "受管文件 ACL 在备份后发生变化，拒绝覆盖：$fullPath"
                }
            }
            elseif (Test-Path -LiteralPath $fullPath) { throw "受管文件在写入前由其他进程创建，拒绝覆盖：$fullPath" }
            [System.IO.File]::Move($temporaryPath, $fullPath, $true)
            if ((Get-SetupSha256 -Path $fullPath) -ne $appliedSha256) { throw "写入后复核失败：$fullPath" }
            if ($IsWindows -and -not [string]::Equals((Get-Acl -LiteralPath $fullPath).Sddl, [string]$record[0].appliedSddl, [StringComparison]::Ordinal)) {
                throw "写入后 ACL 复核失败：$fullPath"
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
        Write-SetupLog -Message $Description -Data @{ path = $fullPath }
        return $true
    }
    return $false
}

function Complete-SetupRuntime {
    param([bool]$Succeeded = $true)
    if ($null -eq $script:Runtime) { return }
    $script:Runtime.Manifest.completed = $Succeeded
    $script:Runtime.Manifest.completedAt = (Get-Date).ToString('o')
    $script:Runtime.Manifest.runStatus = $(if ($Succeeded) { 'Completed' } else { 'Interrupted' })
    $script:Runtime.Manifest.hasChanges = [int]$script:Runtime.Manifest.changeCount -gt 0
    Save-RollbackManifest
}

function Get-SetupModuleDisplayName {
    param([Parameter(Mandatory)][string]$Module)
    $names = @{
        Core = 'Windows 基础应用'; Git = '代码版本管理'; CodexDesktop = 'Codex Desktop'
        Node = 'Node.js 工具链'; Python = 'Python 工具链'; Docker = 'Docker'
        WSL = 'WSL/Linux 开发环境'; Network = 'WSL 网络'
        CodexConfig = 'Codex 设置'; Project = '项目配置文件'; Updates = '软件更新检查'
    }
    if ($names.ContainsKey($Module)) { return $names[$Module] }
    return $Module
}

function Get-SetupOrderedModules {
    param([AllowNull()]$Actions)
    $preferredOrder = @('Core', 'Git', 'CodexDesktop', 'WSL', 'Node', 'Python', 'Docker', 'Network', 'CodexConfig', 'Project', 'Updates')
    $actionModules = @($Actions | ForEach-Object { $_.module } | Where-Object { $_ } | Select-Object -Unique)
    $extraModules = @($actionModules | Where-Object { $_ -notin $preferredOrder })
    return @($preferredOrder + $extraModules | Where-Object { $_ -in $actionModules })
}

function Resolve-SetupCommandPath {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$PackageId
    )
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }

    $wingetLink = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Name"
    if (Test-Path -LiteralPath $wingetLink -PathType Leaf) { return $wingetLink }
    if ([string]::IsNullOrWhiteSpace($PackageId)) { return $null }

    $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $packageDirectories = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter "$PackageId`_*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    foreach ($directory in $packageDirectories) {
        $candidate = Get-ChildItem -LiteralPath $directory.FullName -File -Filter $Name -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

function Write-SetupSectionHeader {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$ForegroundColor = 'White',
        [ValidateRange(24, 100)][int]$Width = 72
    )
    Write-Host ''
    Write-Host ('─' * $Width) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor $ForegroundColor
    Write-Host ('─' * $Width) -ForegroundColor DarkGray
}

function Get-WslPackageConfiguration {
    param([Parameter(Mandatory)]$Config)

    $environmentProperty = $Config.PSObject.Properties['wsl']
    if ($null -eq $environmentProperty -or $null -eq $environmentProperty.Value) { throw '配置缺少 wsl。' }
    $environment = $environmentProperty.Value
    if ($null -eq $environment.PSObject.Properties['packages']) { throw 'wsl.packages 必须存在。' }

    $commands = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($commandValue in @('curl', 'fd', 'gh', 'git', 'jq', 'rg', 'shellcheck', 'shfmt', 'unzip')) {
        [void]$commands.Add($commandValue)
    }
    $aliases = @($environment.aliases.PSObject.Properties | ForEach-Object {
        [void]$commands.Add([string]$_.Name)
        [void]$commands.Add([string]$_.Value)
        [pscustomobject]@{ name=[string]$_.Name; target=[string]$_.Value }
    })
    return [pscustomobject]@{
        packageNames=@($environment.packages)
        commandNames=@($commands | Sort-Object)
        aliases=$aliases
    }
}

function Resolve-WslUserPath {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Path
    )
    if ($Path.StartsWith('/')) { return $Path }
    if ($Path -ne '~' -and -not $Path.StartsWith('~/')) {
        throw "WSL 路径必须是 ~/... 或 Linux 绝对路径：$Path"
    }
    $homeOutput = @(& wsl.exe -d $Distro -- bash -lc 'printf "%s" "$HOME"' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $homeOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$homeOutput[0])) {
        throw "无法解析 $Distro 的 Linux 主目录。"
    }
    $linuxHome = ([string]$homeOutput[0]).Trim().TrimEnd('/')
    return $(if ($Path -eq '~') { $linuxHome } else { "$linuxHome/$($Path.Substring(2))" })
}

function Get-CodexDesktopChecklist {
    param([Parameter(Mandatory)]$Config)
    if ($Config.environmentMode -eq 'WslFirst') {
        return [pscustomobject]@{
            items=@(
                '打开 Codex Desktop Settings。'
                '将 Agent environment 设置为 Windows Subsystem for Linux。'
                '将 Integrated terminal shell 单独设置为 WSL。'
                '完全退出并重启 Codex Desktop。'
                '在重启后的新 Agent 任务中运行 codex-env-check。'
                '另开一个新的 Integrated terminal，再运行一次 codex-env-check。'
                '只有两次检查都通过，才视为 Desktop 已进入 WSL。'
                ('全部检查通过后，从 \\wsl$\{0}\home\<user>\code 打开项目。' -f $Config.wsl.distribution)
            )
            verificationCommand='codex-env-check'
        }
    }
    return [pscustomobject]@{
        items=@(
            '打开 Codex Desktop Settings。'
            '将 Agent environment 设置为 Windows Native。'
            '将 Integrated terminal shell 单独设置为 PowerShell。'
            '完全退出并重启 Codex Desktop。'
            '在重启后的新 Agent 集成终端确认 Git、Node、Python 与 Codex 都来自 Windows 路径。'
        )
        verificationCommand='Get-Command git,node,python,codex'
    }
}

Export-ModuleMember -Function @(
    'Initialize-SetupRuntime', 'Get-SetupRuntime', 'Write-SetupLog', 'Write-SetupStatus',
    'Read-SetupConfig', 'Export-SetupConfig', 'Confirm-SetupChoice', 'Backup-SetupFile',
    'Set-SetupFileContent', 'Register-InstalledPackage', 'Add-RollbackNote',
    'Complete-SetupRuntime', 'ConvertTo-RedactedText', 'Get-SetupModuleDisplayName',
    'Write-SetupWrappedText', 'Get-SetupOrderedModules',
    'Write-SetupSectionHeader', 'Resolve-SetupCommandPath', 'Assert-SetupConfiguration',
    'Get-WslPackageConfiguration', 'Resolve-WslUserPath', 'Get-CodexDesktopChecklist',
    'Get-WindowsPackageCatalog', 'Get-WindowsPackageState', 'Get-SetupSha256', 'Get-SetupTextSha256', 'Write-SetupJsonAtomic',
    'Test-ManagedWindowsPackage', 'Assert-SetupManagedFileTarget',
    'Write-RollbackManifestAtomic', 'Assert-RollbackManifestAuthentication'
)
