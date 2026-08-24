# Codex Desktop 单一开发环境向导

本工具为 Windows 11 上的 Codex Desktop 建立没有 Shell、路径和运行时歧义的开发环境。默认模式是 `WslFirst`：Windows 只承载 Desktop、浏览器、Office 和必要的 GUI 组件；仓库、Git、Codex CLI、Linux 原生 PowerShell、Node、pnpm、Python、uv、依赖与测试全部位于 WSL2 Ubuntu 24.04。

`WindowsNative` 是显式例外，只用于 WPF、WinUI、COM、Windows Service、MSVC、驱动、注册表和原生 .NET Desktop 等 Windows 专属工作。两种模式不会在同一仓库中同时配置两套开发工具链。

## 快速开始

在 Windows 上双击 `Launch-CodexSetup.cmd`，或从 PowerShell 7 启动：

```powershell
Set-Location <工具目录>
./Start-CodexSetup.ps1
```

先检测与演练，再实际应用：

```powershell
./Start-CodexSetup.ps1 -Mode Detect -DeepDetection
./Start-CodexSetup.ps1 -Mode Plan
./Start-CodexSetup.ps1 -Mode Apply -ApplyChanges
```

配置文件使用严格的 v2 schema。旧版配置不会被合并或迁移；请基于 `config/defaults.json` 创建新配置。

## 阶段 1：准备 Windows 与精确的 WSL 发行版

向导检查 Windows 11、PowerShell 7、Windows Terminal、WSL2 与名称精确为 `Ubuntu-24.04` 的发行版。实际应用可以执行对应的 WSL 安装、更新和默认版本设置；不会接受 WSL1，也不会把任意名称包含 Ubuntu 的发行版当作目标。

`WslFirst` 只在 Windows 侧保留以下组件：

- Codex Desktop；
- Windows Terminal；
- Desktop UI 可能使用的 Git for Windows 和 GitHub CLI；
- 可选的 Docker Desktop。

Windows 侧不会安装 fnm、Node、pnpm、uv、Python、ripgrep、jq 或其他仓库工具。

## 阶段 2：建立唯一的 WSL 工具链

WSL helper 在 Ubuntu 24.04 中完成以下工作：

- 创建 `~/code`；
- 安装 Linux 原生 Git、curl、构建工具、ripgrep、jq、fd、ShellCheck、shfmt 和 GitHub CLI；
- 安装 fnm 与 Node LTS；
- 安装 pnpm；
- 安装 uv 与由 uv 管理的 Python 3.12；
- 从 Microsoft Ubuntu 软件源安装 Linux 原生 `pwsh`；
- 安装 Linux 版 Codex CLI；
- 写入幂等的 Bash PATH 区块和 WSL Git 基线；
- 安装 `codex-env-check` 环境验收命令。

交互式 Apply 仅在缺少 Ubuntu 系统包时让 Linux 原生 `sudo` 直接提示输入密码；脚本不会接收、缓存、输出或写入该密码。无人值守 Apply 不读取 `.env`，没有 passwordless sudo 时会停止并给出明确处理方式。

项目必须位于 `/home/<user>/code/...`。工具不会把项目放到 `/mnt/c`，也不会用 Windows Git、Node、Python 或 Codex 对 `\\wsl$` 仓库执行开发命令，更不会跨操作系统共享 `node_modules`、`.venv`、包缓存或 Codex 主目录。

默认网络配置只管理 `%USERPROFILE%\.wslconfig` 中的 `networkingMode=mirrored`、`dnsTunneling`、`autoProxy` 和 `firewall`，并保留其他 WSL 设置。它不写 Git proxy、Shell proxy、v2rayN 端口或防火墙入站规则。网络设置变化后，保存 WSL 工作并在 Windows PowerShell 中运行 `wsl --shutdown`，再重启 Desktop。

## 阶段 3：设置 Desktop 并重启

在 Codex Desktop 中分别设置：

```text
Settings
  Agent environment      → Windows Subsystem for Linux
  Integrated terminal    → WSL
```

这两项是独立设置。修改 Agent environment 后必须完全退出并重启 Desktop。

Desktop 没有供本工具可靠读取或写入这两项的公开稳定接口，因此向导只生成明确的人工检查清单并打开 Settings；报告不会把截图或自报通道 JSON 伪装成 GUI 来源的机器证明。重启后，在新的 WSL Agent 中运行：

```bash
codex-env-check
```

验收必须看到 Linux、`Ubuntu-24.04`、`/home/...` 路径以及全部 Linux 原生命令，且不得出现 `/mnt` 或 Windows 可执行文件路径。

## 阶段 4：分层指令与项目稳定入口

工具分别管理两个互不共享的全局指令文件：

- Windows Desktop：`%USERPROFILE%\.codex\AGENTS.md`；
- WSL Codex CLI：`~/.codex/AGENTS.md`。

`WslFirst` 的两份全局指令都规定仓库工作直接进入 WSL Bash。它们不会通过共享 `CODEX_HOME` 混合身份、历史或配置。

项目初始化只生成仓库约定文件，不生成项目级个人安全策略：

```text
project/
├── AGENTS.md
├── .editorconfig
├── .gitattributes
└── .gitignore
```

项目 `AGENTS.md` 从已存在的 lockfile、`package.json` scripts、`pyproject.toml` 和测试目录提取可证明的 setup、test、lint、format、typecheck、build、dev 命令。没有声明的命令不会被猜测。Node 项目服从仓库锁文件与包管理器；uv 项目使用 `uv sync` 与 `uv run ...`。

## 阶段 5：验证与交付

实际应用后依次验证：

1. Windows/WSL 组件与版本；
2. `Ubuntu-24.04`、WSL2 与 `/home` 项目路径；
3. Git、Codex CLI、`pwsh`、Node、npm、pnpm、Python、uv、fnm 等命令均为 Linux 原生路径；
4. Desktop 的 Agent environment 与 integrated terminal 由用户完成设置并重启；
5. 重启后的真实 WSL Agent 运行 `codex-env-check`；
6. 项目使用 `AGENTS.md` 中的稳定命令完成检查。

运行结果写入 `%LOCALAPPDATA%\CodexDevSetup\runs\<run-id>`。报告区分自动检测、已执行修改、人工待办、跳过项和失败项。显式运行 `Detect`、`Plan`、`Apply`、`ProjectInit` 或 `Rollback` 时，进程退出码与 `-ResultJsonPath` 写出的结构化结果保持一致：`0` 表示成功或无变更，`10` 表示需要重启，`20` 表示仍有计划阻断或人工待办，`1` 表示执行失败。计划中的 `blockingReasons` 不会被普通 warning 或“已安装”类跳过项稀释，也不会在项目初始化时被清空。

需要在现有 Windows 11 + WSL2 工作站完成发布前验收时，使用分阶段入口：

```powershell
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Preflight -RunId acceptance-01 `
  -BaselineDesktopScreenshotPath C:\evidence\desktop-before.png
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Apply -RunId acceptance-01 -ApplyChanges
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase PostRestart -RunId acceptance-01 -ApplyChanges
```

保存 WSL 工作后，`PostRestart -ApplyChanges` 会实测 `wsl --shutdown`、恢复和第二次 Apply。随后按顺序验收 `AgentWslOnly`、`TerminalWslOnly`、`BothWsl`；每次都要完全退出全部 Codex 进程、重启，并提交十分钟内生成且哈希各异的设置截图和 Agent/terminal 两份通道证据。正向通道从 WSL 项目目录用 Linux 原生 `pwsh` 运行 `tests/windows-integration/Invoke-DesktopChannelCheck.ps1`，先输出到 `$HOME`，再从 Windows 通过 `\\wsl$\Ubuntu-24.04\home\<user>\...` 提交。每次 DesktopEvidence 还必须传入 `-ConfirmManualDesktopSettings`，由操作员确认 GUI 组合与通道来源；脚本只校验证据内容与绑定关系，不声称机器证明来源。负向通道必须产生明确的非 Linux 失败记录。

初次三个 GUI 场景通过后执行真实 `Rollback`。它会先 Preview 并复核零漂移，再恢复文件/ACL、拒绝第二次回滚并运行隔离故障矩阵。之后用 `BaselineRestored -ConfirmManualDesktopSettings -ConfirmManualDesktopRollback` 记录人工 GUI 回滚，建立独立的最终重装基线，再执行 `Apply -ApplyChanges`；若返回 10，再执行 `PostRestart -ApplyChanges`。最后用 `BothWsl -ConfirmManualDesktopSettings` 提交最终双通道证据并运行 `Report`。Report 会重新 Detect，并复核受管文件、目标包和基线预装包仍满足最终状态。证据写入 `%LOCALAPPDATA%\CodexDevSetup\acceptance\<run-id>`。Preflight 固定配置、仓库工作树和主机身份，主阶段文件形成 SHA-256 前序链；证据目录和当前 Windows 用户仍是可信边界。该流程不注销发行版、不测试 WSL1、不卸载预装软件；没有缺失目标包时，WinGet 安装/卸载覆盖明确记为 `NOT_RUN`。

## 安全边界

默认使用：

```text
approval_policy = on-request
sandbox_mode = workspace-write
network_access = true
web_search = live
```

Shell 或路径错误不是权限问题。工具不会用 `danger-full-access` 或 `approval_policy = never` 修复环境歧义，也不会读取或复制 API key、访问令牌、SSH 私钥、浏览器凭据、`.env`、Codex 会话或认证缓存。

`WindowsNative` 模式默认使用 Windows 原生 `elevated` sandbox；`unelevated` 只作为显式 fallback。该模式使用 Windows 路径、PowerShell 7 和 Windows 原生工具，项目不得位于 `\\wsl$`。模式切换是完整环境选择，不是按失败命令临时换 Shell。

## 本仓库验证

在 WSL Bash 中运行：

```bash
./tests/run-wsl-tests.sh
```

若系统已经有 Linux 原生 PowerShell 7，可额外运行静态 PowerShell 契约测试：

```bash
pwsh -NoProfile -File tests/Run-All.Tests.ps1
```

WSL 测试不会调用 PowerShell、`wsl.exe` 或 Windows 可执行文件。完整 Windows 集成测试必须从 Windows PowerShell 7 单独执行，且 Desktop 设置仍需要截图、完全重启和 Agent/terminal 双通道运行时证据。

更多内容见 [需求](docs/REQUIREMENTS.md)、[设计](docs/DESIGN.md)、[官方资料](docs/SOURCES.md) 和 [验证方式](docs/VALIDATION.md)。
