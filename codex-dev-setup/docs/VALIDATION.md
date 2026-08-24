# 验证说明

记录日期：2026-08-24。

本文只列出可以从当前仓库重新执行的检查，不保留旧版本构建机、软件版本、运行号或历史通过声明。

## WSL 原生检查

在 WSL2 Ubuntu 的仓库根目录运行：

```bash
./tests/run-wsl-tests.sh
```

脚本验证：

- 当前执行环境为 Linux、`WSL_DISTRO_NAME` 非空且仓库在 `/home`；
- `wsl/setup.sh`、`wsl/verify.sh` 与所有测试 Shell 脚本通过 `bash -n`；
- `config/defaults.json` 是严格的 schema v2，默认模式和发行版正确；
- v1 策略字段、跨环境共享、项目级个人 `config.toml` 模板和双运行时包残留不存在；
- Windows/WSL 全局指令模板与项目命令模板包含必需约束；
- `wsl/verify.sh` 在当前 WSL 中可以验证 Linux、发行版、`/home` 路径和 Linux 原生命令。

该脚本不调用 PowerShell、`wsl.exe`、Git Bash 或 Windows 可执行文件。

## PowerShell 静态契约

如果环境已经安装 Linux 原生 PowerShell 7，可额外运行：

```bash
pwsh -NoProfile -File tests/Run-All.Tests.ps1
```

这组测试解析 PowerShell 源文件并检查 v2 配置、计划与 action 的静态契约。缺少 Linux 原生 `pwsh` 时应报告跳过，不得改用 Windows PowerShell。

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

Windows 验收命令通过 `\\wsl$\Ubuntu-24.04\home\<user>\codex-agent.json` 等 UNC 路径复制正向证据。负向 Windows 通道在该通道自身运行辅助脚本，保存非 Linux 结果。由于 Codex Desktop 没有公开可信的设置/通道来源 API，脚本无法机器证明 JSON 确实来自所标注通道；操作员必须核对 GUI 场景和通道来源，并显式传入 `-ConfirmManualDesktopSettings`。机器检查只覆盖 JSON 内容、绑定 nonce、时间、哈希、截图格式和进程重启。

- WinGet 包检测与实际安装；
- WSL2 更新、默认版本、精确发行版、shutdown/restart 和幂等复跑；
- Windows 文件备份与回滚；
- Desktop Settings 打开流程；
- Windows Terminal、Git for Windows 与 Desktop GUI 集成。

当前工作站验收范围禁止 `wsl --unregister`、WSL 功能禁用、WSL1 转换和预装软件重装。首次安装 WSL2 未实测；没有缺失目标包时，WinGet 安装后卸载场景必须标记 `NOT_RUN`，不得合并进通过项。

Preflight 固定验收配置哈希、仓库 commit、工作树内容哈希和 Windows 主机身份。每个主阶段证据进入不可跳步的 SHA-256 前序链；后续阶段和 Report 会重新计算。`EvidenceRoot`/`StateRoot` 及运行它的 Windows 用户是可信边界，这个链用于发现阶段文件被替换、删除或乱序，不是抵抗同一用户主动重写状态的签名系统。每张 GUI 截图必须在当前 Codex 进程启动后且十分钟内生成，并与此前场景截图哈希不同。

## Desktop 重启后验收

完成向导并在 Desktop 中分别设置 Agent environment 与 integrated terminal 后，完全重启应用，在新任务中运行：

```bash
codex-env-check --json
```

只有新 Agent 和新 integrated terminal 的两份 JSON 都确认 Linux、`Ubuntu-24.04`、Bash、`/home` 工作目录以及 Git/Codex/`pwsh`/Node/pnpm/Python/uv 等 Linux 原生路径，并且操作员明确确认 GUI 场景与证据来源后，才能签署人工 attestation。设置截图、打开 Settings 或 JSON 文件本身都不能提供 GUI 来源的机器证明。
