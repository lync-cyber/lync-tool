Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
    $script:Passed++
}

$root = Split-Path -Parent $PSScriptRoot
$setupPath = Join-Path $root 'wsl\setup.sh'
$detectionPath = Join-Path $root 'modules\CodexSetup.Detection.psm1'
$configPath = Join-Path $root 'config\defaults.json'
$setup = Get-Content -LiteralPath $setupPath -Raw -Encoding utf8
$detection = Get-Content -LiteralPath $detectionPath -Raw -Encoding utf8
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8

Assert-True ($setup -match 'SUDO_AUTH_FAILURE_EXIT=77') 'WSL 脚本应保留可供 Windows 主流程识别的 sudo 失败退出码。'
Assert-True ($setup -match 'CODEX_SETUP_SUDO_AUTH_FAILED') 'WSL 脚本应输出稳定的 sudo 失败标记。'
Assert-True ($setup -match 'SUDO_UNAVAILABLE_EXIT=78') '缺少 sudo 应使用不同于密码失败的退出码。'
Assert-True ($setup -match 'CODEX_SETUP_SUDO_UNAVAILABLE') '缺少 sudo 应输出稳定的独立标记。'
Assert-True ($setup -match 'SHELL_MARKER_FAILURE_EXIT=79') '损坏的 .bashrc 管理标记应使用独立退出码。'
Assert-True ($setup -match 'CODEX_SETUP_SHELL_MARKERS_INVALID') '损坏的 .bashrc 管理标记应输出稳定诊断标记。'
Assert-True ($setup -match '请输入 Ubuntu 用户密码') 'WSL 脚本应在 sudo 前说明要输入哪一种密码。'
Assert-True ($setup -match '不会显示任何字符') 'WSL 脚本应说明 Linux 密码输入不会回显。'
Assert-True ($setup -match '密码验证通过') '密码验证成功后应立即给出反馈。'
Assert-True ($setup -match '步骤 1/2：正在更新软件列表') 'apt 执行前应显示当前阶段。'
Assert-True ($setup -match 'Acquire::http::Timeout=30') 'apt 网络访问应设置有限超时。'
Assert-True ($setup -match 'run_quiet_with_progress') 'WSL 长时间安装应显示简洁的等待进度，而不是倾倒底层包清单。'
Assert-True ($setup -match 'DETAIL_LOG=') '收起的 WSL 安装明细应保留在诊断记录中。'
Assert-True ($setup -match 'export PATH="\$HOME/\.local/bin:\$HOME/\.local/share/fnm:\$PATH"') '非交互 WSL 运行应识别之前已经安装的 fnm 和 uv。'
Assert-True ($setup -match '预览完成：以上命令尚未执行') 'WhatIf 不得误报基础工具已经安装。'
Assert-True ($setup -notmatch 'Done\. Open a new WSL shell') '面向用户的 WSL 完成提示不应遗留英文。'
Assert-True ($setup -notmatch 'run sudo apt-get update') '不得无条件执行 apt-get update。'
Assert-True ($setup -match 'if \[\[ "\$\{#missing_apt_packages\[@\]\}" -gt 0 \]\]') '只有缺少已配置软件包时才应进入 apt 分支。'
Assert-True ($setup -match 'if \[\[ "\$MODE" == "apply" \]\]; then\s+ensure_sudo') '只有实际安装缺少的基础包时才应验证 sudo。'
Assert-True ($setup -match 'if \[\[ -d "\$CODE_ROOT" \]\]; then') '创建项目目录应与 apt 安装分开处理。'
Assert-True ($setup -match 'CODE_ROOT="\$HOME/\$\{CODE_ROOT#~/' ) '从 Windows 传入的 ~/code 应在 WSL 内展开为 Linux 主目录。'
Assert-True ($setup -match 'Missing required argument: --code-root') '常规 WSL 设置必须从统一配置接收项目目录。'
Assert-True ($setup -match 'cmp -s "\$block_file" <\(extract_managed_block "\$BASHRC"\)') '托管 .bashrc 区块相同时应跳过写入。'
Assert-True ($setup -match 'block_needs_update=0') '托管 .bashrc 区块相同时应明确标记为无需更新。'
Assert-True ($setup -match 'WSL 终端快捷设置已符合当前选择') '无需重写 .bashrc 时应给出清楚说明。'
Assert-True ($setup -match 'validate_managed_markers') '改写 .bashrc 前应验证管理标记完整且顺序正确。'
Assert-True ($setup -match 'mktemp "\$\{BASHRC\}\.codex-setup\.XXXXXX"') '.bashrc 应通过同目录临时文件进行原子替换。'
Assert-True ($setup -match 'chmod --reference="\$BASHRC"') '替换 .bashrc 时应保留原文件权限。'
Assert-True ($setup -match 'trap cleanup_temp_files EXIT') '失败退出时应自动清理下载文件和临时文件。'
Assert-True ($setup -match '--network-only') 'WSL helper 应支持只配置网络，不触发 apt 或语言工具安装。'
Assert-True ($setup -match '\.config/codex/proxy\.sh') '持久代理应使用独立的 Codex proxy.sh。'
Assert-True ($setup -match 'PROFILE_START_MARKER') '持久代理应同时管理 ~/.profile 加载区块。'
Assert-True ($setup -match 'proxy_on 127\.0\.0\.1|proxy_on %q') '代理文件应在新 shell 启动时自动启用。'
Assert-True ($setup -match 'PROXY_HOST.*127\.0\.0\.1') '自动配置必须限制为 mirrored loopback 地址。'
Assert-True ($setup -match '--apt-package' -and $setup -match '--command-alias') 'WSL helper 应通过通用重复参数接收软件包和命令别名。'
Assert-True ($setup -notmatch 'BASE_PACKAGES=') 'WSL helper 不应另存一份硬编码软件包清单。'
Assert-True ($setup -match 'Invalid APT package name' -and $setup -match 'Invalid command alias') 'WSL helper 应再次校验配置输入。'
Assert-True ($setup -match 'dpkg-query.*\$\{Version\}') 'WSL 安装日志应显示实际安装的软件包版本。'
Assert-True ($config -match '"name": "gh"' -and $config -match '"id": "shell-quality"') '统一配置应包含默认 gh 和可选 Shell 质量工具组。'
Assert-True ($config -match '"name": "fd".*"target": "fdfind"') 'fd 兼容入口应来自统一配置。'
Assert-True ($detection -match 'windows-path') 'WSL 检测应区分 Linux 原生工具和继承的 Windows PATH 入口。'
Assert-True ($detection -match 'eval "\$\(fnm env --shell bash\)"') 'WSL 检测应加载已安装的 fnm 环境，避免误报 Node.js 缺失。'
Assert-True ($detection -match 'gh auth status' -and $detection -notmatch 'gh auth status --show-token') 'WSL 检测只应读取 GitHub 登录状态，不得输出令牌。'

foreach ($field in @('aptPackagesMissing', 'githubAuthStatus', 'configuredPackageGroups', 'codeRootExists', 'managedBlockPresent', 'managedBlockSharesCodexHome', 'sudoAvailable')) {
    Assert-True ($detection -match [regex]::Escape($field)) "完整 WSL 检测应包含 $field 字段。"
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($detectionPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'WSL 检测模块应保持 PowerShell 语法有效。'

Write-Host "WSL 专用检查通过：$script:Passed 项" -ForegroundColor Green
