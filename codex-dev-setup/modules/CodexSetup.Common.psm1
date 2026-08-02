Set-StrictMode -Version Latest

$script:Runtime = $null

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

    $runRoot = Join-Path $StateRoot (Join-Path 'runs' $RunId)
    $backupRoot = Join-Path $runRoot 'backups'
    $logRoot = Join-Path $StateRoot 'logs'
    foreach ($path in @($StateRoot, $runRoot, $backupRoot, $logRoot)) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    $script:Runtime = [ordered]@{
        RunId        = $RunId
        StateRoot    = $StateRoot
        RunRoot      = $runRoot
        BackupRoot   = $backupRoot
        LogPath      = Join-Path $logRoot "$RunId.jsonl"
        SummaryPath  = Join-Path $runRoot 'summary.md'
        ManifestPath = Join-Path $runRoot 'rollback-manifest.json'
        Manifest     = [ordered]@{
            schemaVersion     = 1
            runId             = $RunId
            createdAt         = (Get-Date).ToString('o')
            completed         = $false
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

    # A compact display-width approximation keeps Chinese continuation lines
    # aligned in the classic console while still behaving well for English paths.
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

        # Only unusually long unbroken values (for example a filesystem path)
        # are split character-by-character. Normal English terms remain intact.
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

function Read-SetupConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "配置文件不存在：$Path"
    }
    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        throw "配置文件不是有效 JSON：$Path。$($_.Exception.Message)"
    }
    if ($config.schemaVersion -ne 1) {
        throw "不支持的配置 schemaVersion：$($config.schemaVersion)"
    }
    return $config
}

function Export-SetupConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        if ($PSCmdlet.ShouldProcess($parent, '创建配置目录')) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($Path, '导出可复用 JSON 配置')) {
        $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
        Write-SetupLog -Message '配置已导出' -Data @{ path = $Path }
    }
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

function Resolve-SetupModuleChoice {
    <#
    .SYNOPSIS
    Converts a module-confirmation response into a controller-friendly choice.

    .DESCRIPTION
    A caller supplies the raw response and whether the current module includes
    a critical action. Choosing A only enables automatic application of later
    ordinary modules; critical modules must still be confirmed individually.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Answer,
        [bool]$HasCriticalAction = $false
    )

    $normalized = if ($null -eq $Answer) { '' } else { $Answer.Trim().ToUpperInvariant() }
    switch -Regex ($normalized) {
        '^(Y|YES|是|确认)$' {
            return [pscustomobject]@{ choice = 'ApplyModule'; applyRemainingOrdinary = $false; requiresSeparateConfirmation = $HasCriticalAction }
        }
        '^(A|ALL|全部)$' {
            return [pscustomobject]@{ choice = 'ApplyModule'; applyRemainingOrdinary = $true; requiresSeparateConfirmation = $HasCriticalAction }
        }
        '^(Q|QUIT|退出)$' {
            return [pscustomobject]@{ choice = 'Quit'; applyRemainingOrdinary = $false; requiresSeparateConfirmation = $false }
        }
        default {
            return [pscustomobject]@{ choice = 'SkipModule'; applyRemainingOrdinary = $false; requiresSeparateConfirmation = $false }
        }
    }
}

function Save-RollbackManifest {
    if ($null -eq $script:Runtime) { return }
    $script:Runtime.Manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:Runtime.ManifestPath -Encoding utf8
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
        [string]$Source = 'winget'
    )
    $script:Runtime.Manifest.installedPackages += [ordered]@{ id = $Id; source = $Source }
    Save-RollbackManifest
}

function Backup-SetupFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($null -eq $script:Runtime) { throw '尚未初始化运行环境。' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $existing = @($script:Runtime.Manifest.files | Where-Object { $_.path -eq $fullPath })
    if ($existing.Count -gt 0) { return $existing[0] }

    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    $record = [ordered]@{ path = $fullPath; existed = $exists; backup = $null }
    if ($exists) {
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fullPath))).Substring(0, 16)
        $leaf = Split-Path -Leaf $fullPath
        $backupPath = Join-Path $script:Runtime.BackupRoot "$hash-$leaf"
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
        $record.backup = $backupPath
    }
    $script:Runtime.Manifest.files += $record
    Save-RollbackManifest
    return [pscustomobject]$record
}

function Set-SetupFileContent {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$Description = '写入配置文件'
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $current = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { Get-Content -LiteralPath $fullPath -Raw -Encoding utf8 } else { $null }
    $normalized = $Content.TrimEnd("`r", "`n") + [Environment]::NewLine
    if ($current -eq $normalized) {
        Write-SetupLog -Message '文件内容已是目标状态，跳过' -Data @{ path = $fullPath }
        return $false
    }
    if ($PSCmdlet.ShouldProcess($fullPath, $Description)) {
        Backup-SetupFile -Path $fullPath | Out-Null
        $parent = Split-Path -Parent $fullPath
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        Set-Content -LiteralPath $fullPath -Value $normalized -Encoding utf8 -NoNewline
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
    Save-RollbackManifest
}

function Get-SetupModuleDisplayName {
    param([Parameter(Mandatory)][string]$Module)
    $names = @{
        Core = '基础工具'; Git = '代码版本管理'; CodexDesktop = 'Codex Desktop'
        Node = 'Node.js 开发环境'; Python = 'Python 开发环境'; WSL = 'WSL/Linux 开发环境'; Network = 'WSL 网络与代理'
        Terminal = '终端'; CodexConfig = 'Codex 设置'; Project = '项目配置文件'; Updates = '软件更新检查'
    }
    if ($names.ContainsKey($Module)) { return $names[$Module] }
    return $Module
}

function Get-SetupOrderedModules {
    param([AllowNull()]$Actions)
    $preferredOrder = @('Core', 'Git', 'CodexDesktop', 'Node', 'Python', 'WSL', 'Network', 'Terminal', 'CodexConfig', 'Project', 'Updates')
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

    # Portable WinGet packages may update the persistent PATH without refreshing
    # the current process. Search only this package's bounded install directory.
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

function Merge-MissingSetupConfig {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Defaults)
    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $targetProperty = $Target.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $targetProperty) {
            $Target | Add-Member -NotePropertyName $defaultProperty.Name -NotePropertyValue $defaultProperty.Value
            continue
        }
        if ($null -ne $targetProperty.Value -and $null -ne $defaultProperty.Value -and
            $targetProperty.Value -is [pscustomobject] -and $defaultProperty.Value -is [pscustomobject]) {
            Merge-MissingSetupConfig -Target $targetProperty.Value -Defaults $defaultProperty.Value
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-SetupRuntime', 'Get-SetupRuntime', 'Write-SetupLog', 'Write-SetupStatus',
    'Read-SetupConfig', 'Export-SetupConfig', 'Confirm-SetupChoice', 'Backup-SetupFile',
    'Set-SetupFileContent', 'Register-InstalledPackage', 'Add-RollbackNote',
    'Complete-SetupRuntime', 'ConvertTo-RedactedText', 'Get-SetupModuleDisplayName',
    'Resolve-SetupModuleChoice', 'Write-SetupWrappedText', 'Get-SetupOrderedModules',
    'Write-SetupSectionHeader', 'Resolve-SetupCommandPath', 'Merge-MissingSetupConfig'
)
