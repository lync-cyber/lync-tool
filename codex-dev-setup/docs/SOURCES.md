# 2026 年官方资料核对

核对日期：2026-08-02。实现只依赖公开、当前的 OpenAI、Microsoft、Node.js、fnm 与 uv 官方资料；未使用第三方教程推断配置 key。

## OpenAI / Codex

- [ChatGPT desktop app for Windows](https://learn.chatgpt.com/docs/windows/windows-app)：Windows native/WSL Agent、独立 integrated terminal、Desktop WinGet ID、Windows Git/gh 依赖、`CODEX_HOME` 共享和重启要求。
- [WSL](https://learn.chatgpt.com/docs/windows/wsl)：WSL2、Codex 0.115 起不支持 WSL1、仓库放 `~/code`、避免 `/mnt/c` 高 I/O。
- [Windows sandbox](https://learn.chatgpt.com/docs/windows/windows-sandbox)：`[windows] sandbox = "elevated" | "unelevated"`、private desktop、Windows 11 基线和权限边界。
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)：用户/项目 `config.toml`、`approval_policy`、`sandbox_mode`、`web_search`、`sandbox_workspace_write.network_access`、Windows sandbox 等当前 key。
- [Configuration](https://learn.chatgpt.com/docs/configuration)：用户级和项目级配置层级、项目 trust 要求。
- [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)：全局/项目/嵌套指令发现与覆盖规则。
- [Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)：Desktop managed worktree、Git 前置条件、环境可重建和 `$CODEX_HOME/worktrees`。
- [Local environments](https://learn.chatgpt.com/docs/environments/local-environment#setup-scripts)：Desktop worktree setup script 的运行时机与平台专用脚本。

## Microsoft

- [Install WSL](https://learn.microsoft.com/windows/wsl/install) 与 [WSL basic commands](https://learn.microsoft.com/windows/wsl/basic-commands)：`wsl --install`、`--distribution`、`--list --verbose`、WSL2 转换。
- [Set up a WSL development environment](https://learn.microsoft.com/windows/wsl/setup/environment)：Linux home 文件存储、Terminal、Git 和编辑器边界。
- [Accessing network applications with WSL](https://learn.microsoft.com/windows/wsl/networking)：mirrored 模式下 WSL 通过 IPv4 `127.0.0.1` 访问 Windows 服务，以及 VPN、DNS 和 LAN 边界。
- [Advanced settings configuration in WSL](https://learn.microsoft.com/windows/wsl/wsl-config)：`.wslconfig` 位置、重启规则、`networkingMode`、`dnsTunneling`、`autoProxy`、`firewall` 与 `initialAutoProxyTimeout`。
- [Use WinGet](https://learn.microsoft.com/windows/package-manager/winget/) 与 [install command](https://learn.microsoft.com/windows/package-manager/winget/install)：exact ID/source、agreement flags、安装和更新行为。
- [Install PowerShell 7 on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)：PowerShell 7 与 5.1 side-by-side，WinGet 为 Windows client 推荐安装方式。
- [Windows Terminal installation](https://learn.microsoft.com/windows/terminal/install)、[startup settings](https://learn.microsoft.com/windows/terminal/customize-settings/startup) 与 [JSON fragment extensions](https://learn.microsoft.com/windows/terminal/json-fragment-extensions)：profile、默认终端和 fragment 机制。

## Node.js / Python

- [Node.js releases](https://nodejs.org/en/about/previous-releases)：生产项目使用 Active/Maintenance LTS；核对时 Node 24 为 LTS。
- [fnm official repository](https://github.com/Schniz/fnm)：WinGet ID、PowerShell/Bash shell setup、`--use-on-cd` 与 LTS 管理。
- [uv installation](https://docs.astral.sh/uv/getting-started/installation/) 与 [Python versions](https://docs.astral.sh/uv/concepts/python-versions/)：WinGet ID、跨平台安装、解释器自动管理、`.python-version` 与项目环境。

## GitHub / Shell

- [GitHub CLI manual](https://cli.github.com/manual/) 与 [Linux installation](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)：Linux 原生 CLI、`gh auth login`、`gh auth status` 与包管理安装方式。
- [ShellCheck](https://github.com/koalaman/shellcheck) 与 [shfmt](https://github.com/mvdan/sh)：Ubuntu 包安装和 Shell 脚本检查/格式化用途；作为默认关闭的软件包组提供。

## 避免的过时或不准确写法

- 不支持 WSL1。
- 不使用已弃用的 `approval_policy = "on-failure"`。
- Windows sandbox 使用当前 `[windows] sandbox`，不把 Windows Sandbox optional feature 当作 Codex sandbox。
- Desktop 产品当前官方名称与安装包是 ChatGPT desktop app，但界面内使用 Codex 工作流；检测同时匹配 ChatGPT/OpenAI 包名。
- 不假设 integrated terminal 会随 Agent 自动改变；脚本只推荐匹配值，因为两项在 Desktop 中独立设置。
