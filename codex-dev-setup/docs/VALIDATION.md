# 验证说明

本文列出可以从当前仓库重新执行的检查；本轮在线探测仅记录证据范围，不作为真实安装通过声明。

## WSL 原生检查

在 WSL2 Ubuntu 的仓库根目录运行：

```bash
./tests/run-wsl-tests.sh
```

脚本验证：

- 当前执行环境为 Linux、`WSL_DISTRO_NAME` 非空且仓库在 `/home`；
- `wsl/setup.sh`、`wsl/verify.sh` 与所有测试 Shell 脚本通过 `bash -n`；
- `wsl/setup.sh` 的预览、路径检查、配置写入和文件权限；
- `wsl/verify.sh` 的文本与 JSON 输出、Linux 原生命令和 uv 管理的 Python 3.12。

该脚本不调用 PowerShell、`wsl.exe`、Git Bash 或 Windows 可执行文件。

## PowerShell 测试

在 Windows 本地仓库用原生 PowerShell 7 运行，无需预装 WSL；也可在 WSL 中使用已安装的 Linux 原生 PowerShell 7：

```bash
pwsh -NoProfile -File tests/Run-All.Tests.ps1
```

这组测试解析 PowerShell 源文件，并验证配置、进程超时、计划生成、配置写入、项目命令、回滚和入口返回值。回归检查另外覆盖空数组、WSL 查询与探测协议错误、单次计划确认、非法输入、仅检查/无人值守边界、项目作用域、首次安装依赖链和待重启状态。文件写入与回滚测试使用临时目录；安装和重启分支使用模拟结果，不会安装软件或停止 WSL。

Windows 上运行此测试不代表已经验证 WSL helper。没有可用 WSL 时应单独标记 `tests/run-wsl-tests.sh` 为未运行；安装、UAC、真实系统重启和 Desktop 双通道仍需以下真实机验收。

## Ubuntu 版本选择验证

版本解析回归应使用固定元数据样本，覆盖 `latest-stable`、`latest-lts`、精确版本与命令行覆盖；确认自动选择排除预览、`Supported=0`、通用 `Ubuntu` 和当前 OS 架构不可安装的版本。网络失败、超时、缺失字段或交集为空必须产生明确错误，不回退到硬编码发行版。

同时检查：显示首页时不请求目录；进入 WslFirst 工作流后每请求最多 15 秒；解析后的重检与会话导出保持同一精确名称；新进程重新读取自动配置时才再次解析；独立 Export、Rollback、WindowsNative 不请求目录。已有其他发行版的模拟状态只能生成并行安装及默认发行版调整，不得产生升级或删除动作。

Linux 验证需分别覆盖实际 Ubuntu `VERSION_ID` 与精确目标匹配、不匹配，以及 Microsoft APT 地址按版本生成。不能只检查 WSL 注册名称，也不能把下载地址存在当作 `pwsh` 已安装。非 LTS 版本不保证 PowerShell 软件源可用；需要官方长期支持时采用 `latest-lts`，并按实际结果记录工具链兼容性。

本轮在线探测（2026-09-13）得到最新正式发行系列为 Ubuntu 26.04.1 LTS，微软 WSL 目录中的对应精确名称为 `Ubuntu-26.04`；`https://packages.microsoft.com/config/ubuntu/26.04/packages-microsoft-prod.deb` 的 HEAD 响应为 200。补丁版本 `.1` 不进入发行版注册名称。这些证据只说明当时的目录匹配与仓库引导包端点可达，未验证 WSL 安装、APT 中 PowerShell 包的实际安装或完整 Linux 工具链；真实 Linux/WSL 安装本轮仍未运行。重新验收时应重新查询 [Canonical 元数据](https://changelogs.ubuntu.com/meta-release)、[WSL 目录](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json) 和对应软件源，不依赖上述日期的结果。

## Windows 集成验收

以下检查只能在 Windows 11 测试机上完成，WSL 测试不得声称覆盖。入口为：

```powershell
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Preflight -RunId <id> -BaselineDesktopScreenshotPath C:\evidence\before.png
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Apply -RunId <id> -ApplyChanges
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase PostRestart -RunId <id> -ApplyChanges
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase DesktopEvidence -RunId <id> -DesktopScenario AgentWslOnly -DesktopScreenshotPath C:\evidence\agent-only.png -AgentEvidenceJsonPath C:\evidence\agent.json -TerminalEvidenceJsonPath C:\evidence\terminal-fail.json -ConfirmManualDesktopSettings
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase DesktopEvidence -RunId <id> -DesktopScenario TerminalWslOnly -DesktopScreenshotPath C:\evidence\terminal-only.png -AgentEvidenceJsonPath C:\evidence\agent-fail.json -TerminalEvidenceJsonPath C:\evidence\terminal.json -ConfirmManualDesktopSettings
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase DesktopEvidence -RunId <id> -DesktopScenario BothWsl -DesktopScreenshotPath C:\evidence\both.png -AgentEvidenceJsonPath C:\evidence\agent.json -TerminalEvidenceJsonPath C:\evidence\terminal.json -ConfirmManualDesktopSettings
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Rollback -RunId <id> -ApplyChanges
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase DesktopEvidence -RunId <id> -DesktopScenario BaselineRestored -DesktopScreenshotPath C:\evidence\restored.png -ConfirmManualDesktopSettings -ConfirmManualDesktopRollback
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Apply -RunId <id> -ApplyChanges
# 仅当上一步返回 10 时执行：
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase PostRestart -RunId <id> -ApplyChanges
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase DesktopEvidence -RunId <id> -DesktopScenario BothWsl -DesktopScreenshotPath C:\evidence\final.png -AgentEvidenceJsonPath C:\evidence\agent-final.json -TerminalEvidenceJsonPath C:\evidence\terminal-final.json -ConfirmManualDesktopSettings
./tests/windows-integration/Invoke-Windows11Acceptance.ps1 -Phase Report -RunId <id>
```

证据写入 `%LOCALAPPDATA%\CodexDevSetup\acceptance\<run-id>`。每一阶段可以单独恢复，不跨重启持有进程状态。验收包括：

在每个新 Agent 或新 integrated terminal 中分别运行辅助脚本。正向 WSL 通道必须从 Linux 项目目录执行 Linux 原生 `pwsh`，并把 JSON 先写入 Linux 文件系统：

```bash
cd ~/code/codex-dev-setup
pwsh -NoProfile -File ./tests/windows-integration/Invoke-DesktopChannelCheck.ps1 \
  -Channel Agent -RunId <id> -Nonce <Preflight 输出的 nonce> -OutputPath "$HOME/codex-agent.json"
# 在新的 integrated terminal 中另行执行，并把 Channel 和输出文件改为 Terminal/codex-terminal.json。
```

Windows 验收命令通过 `\\wsl$\<发行版>\home\<user>\codex-agent.json` 等 UNC 路径复制正向证据，`<发行版>` 必须替换为 Preflight 解析并固定的精确名称，例如 `Ubuntu-26.04`。负向 Windows 通道在该通道自身运行辅助脚本，保存非 Linux 结果。由于 Codex Desktop 没有公开可信的设置/通道来源 API，脚本无法机器证明 JSON 确实来自所标注通道；操作员必须核对 GUI 场景和通道来源，并显式传入 `-ConfirmManualDesktopSettings`。机器检查只覆盖 JSON 内容、绑定 nonce、时间、哈希、截图格式和进程重启。

- WinGet 包检测与实际安装；
- WSL2 生命周期、默认版本、精确发行版、shutdown/restart 和幂等复跑；
- Windows 文件备份与回滚；
- Desktop Settings 打开流程；
- Windows Terminal、Git for Windows 与 Desktop GUI 集成。

当前工作站验收范围禁止 `wsl --unregister`、WSL 功能禁用、WSL1 转换和预装软件重装。首次安装 WSL2 未实测；没有缺失目标包时，WinGet 安装后卸载场景必须标记 `NOT_RUN`，不得合并进通过项。

Preflight 先把自动版本配置解析为精确名称，再保存验收配置及哈希、仓库 commit、工作树内容哈希和 Windows 主机身份；后续阶段复用该精确版本，不在每次重启后重新追随最新版。每个主阶段证据进入不可跳步的 SHA-256 前序链；后续阶段和 Report 会重新计算。`EvidenceRoot`/`StateRoot` 及运行它的 Windows 用户是可信边界，这个链用于发现阶段文件被替换、删除或乱序，不是抵抗同一用户主动重写状态的签名系统。每张 GUI 截图必须在当前 Codex 进程启动后且十分钟内生成，并与此前场景截图哈希不同。

## Desktop 重启后验收

完成向导并在 Desktop 中分别设置 Agent environment 与 integrated terminal 后，完全重启应用，在新任务中运行：

```bash
codex-env-check --json
```

只有新 Agent 和新 integrated terminal 的两份 JSON 都确认 Linux、验收配置固定的精确 Ubuntu 发行版、Bash、`/home` 工作目录，Git/Codex/`pwsh`/Node/pnpm/Python/uv/`rg` 等命令均为 Linux 原生路径，并且 `uv python find --managed-python --no-project 3.12` 返回 `uv python dir` 下的真实 3.12 解释器，操作员再明确确认 GUI 场景与证据来源后，才能签署人工 attestation。设置截图、打开 Settings 或 JSON 文件本身都不能提供 GUI 来源的机器证明。
