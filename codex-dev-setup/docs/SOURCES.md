# 官方资料

核对日期：2026-08-24。实现只依据 OpenAI、Microsoft、pnpm、Node.js、fnm、uv 与 GitHub 的官方资料。

## OpenAI / Codex

- [ChatGPT desktop app for Windows](https://learn.chatgpt.com/docs/windows/windows-app)：Windows native 与 WSL2 Agent、独立的 integrated terminal、Windows Git 前置条件，以及修改 Agent environment 后重启应用。
- [WSL](https://learn.chatgpt.com/docs/windows/wsl)：WSL2 要求、Linux 文件系统中的项目路径，以及在 WSL 内安装 Linux 版 Codex CLI。
- [Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)：全局、项目和嵌套指令的发现与覆盖层级。
- [Configuration reference](https://developers.openai.com/codex/config-reference)：`approval_policy`、`sandbox_mode`、`web_search`、workspace network access 与 Windows sandbox 配置。
- [Windows sandbox](https://developers.openai.com/codex/windows)：Windows native `elevated` 与 `unelevated` sandbox 的边界。

## Microsoft

- [Install WSL](https://learn.microsoft.com/windows/wsl/install)：`wsl --install` 和发行版安装前置条件。
- [Basic commands for WSL](https://learn.microsoft.com/windows/wsl/basic-commands)：更新 WSL、列出发行版、设置默认版本和选择发行版。
- [Set up a WSL development environment](https://learn.microsoft.com/windows/wsl/setup/environment)：在 Linux 文件系统中保存 WSL 项目以及 Linux Git 的使用方式。
- [Accessing network applications with WSL](https://learn.microsoft.com/windows/wsl/networking)：NAT 与 mirrored 网络模式、localhost 和防火墙边界。
- [Advanced settings configuration in WSL](https://learn.microsoft.com/windows/wsl/wsl-config)：`.wslconfig` 的作用域、配置项和重启规则。
- [WinGet](https://learn.microsoft.com/windows/package-manager/winget/)：Windows 软件包安装与更新。
- [WinGet export](https://learn.microsoft.com/windows/package-manager/winget/export)：结构化清单、版本字段，以及无法匹配本机应用时只产生警告的非完整性边界。
- [WinGet HRESULT codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md)：精确查询的 `APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND` 退出码。
- [Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)：PowerShell 7 安装与 side-by-side 模型。
- [Install PowerShell on Ubuntu](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu)：Microsoft Ubuntu 软件源、支持版本与 Linux 原生 `pwsh` 安装方式。
- [Windows Terminal installation](https://learn.microsoft.com/windows/terminal/install)：Windows Terminal 安装与系统要求。

## Node / Python / GitHub

- [pnpm installation](https://pnpm.io/installation)：POSIX standalone installer 与当前支持的 Node 版本。
- [Node.js releases](https://nodejs.org/en/about/previous-releases)：生产工作负载使用 Active LTS 或 Maintenance LTS。
- [fnm](https://github.com/Schniz/fnm)：Bash 环境初始化与 Node 版本管理。
- [uv installation](https://docs.astral.sh/uv/getting-started/installation/)：Linux 安装方式。
- [uv projects](https://docs.astral.sh/uv/guides/projects/)：`uv sync`、锁文件和项目命令。
- [GitHub CLI Linux installation](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)：Linux 原生 gh 安装。
- [GitHub CLI manual](https://cli.github.com/manual/)：`gh auth status` 与交互式登录。
- [ShellCheck](https://github.com/koalaman/shellcheck) 与 [shfmt](https://github.com/mvdan/sh)：Shell 静态检查与格式化工具的官方项目。

## 已排除的旧模式

- 不支持 WSL1、`/mnt/c` 仓库或泛化的 Ubuntu 目标。
- 不假设 integrated terminal 会随 Agent 自动改变。
- 不共享 Windows 与 WSL 的 `CODEX_HOME`、依赖目录或运行时。
- 不生成项目级个人 Codex 安全配置。
- 不用 `danger-full-access` 或 `approval_policy=never` 解决环境错误。
