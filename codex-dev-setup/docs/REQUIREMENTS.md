# 需求规格摘要

## 用户与设备

- 面向个人多台 Windows 11 设备；系统 edition 由脚本检测。
- 用户日常账户有管理员权限；个人设备，无集中管理。
- 普通网络与 VPN 场景；界面中文为主，保留英文技术名词。

## Codex Desktop 工作方式

- Desktop 为主要入口；检测安装和版本更新，不触碰登录秘密。
- 根据项目标记建议 Windows native 或 WSL2 Agent，由用户确认；终端与 Agent 自动匹配，但保留 Desktop 内独立选择。
- 检查 Agent、terminal、sandbox、项目目录、Windows Git 等 Desktop 前置条件。
- 无稳定公开配置接口的 Desktop UI 设置采用“逐步说明 + 打开 Settings”，切换 Agent 后明确提示重启。
- 支持 Git worktree 所需环境、项目初始化和可重建依赖约定。

## Windows / WSL 边界

- 主要项目类型是 Node.js 前端与 Python；当前仓库多在 Windows 用户目录。
- 新项目按类型建议：Windows 专属项目留在 Windows 文件系统；Web/Python/跨平台项目放 WSL `~/code`。
- 完整检测并配置 WSL2 Ubuntu，提供可重复 Bash helper；不迁移已有仓库。
- WSL APT 软件通过统一的可扩展包组配置定义；默认包含 Linux 原生 gh，可选 ShellCheck/shfmt，不在 Bash、检测和计划模块重复维护清单。
- 可选配置 WSL mirrored networking；检测 Windows 系统代理与 loopback 端口，不自动开启 v2rayN LAN 监听或创建 LAN 入站规则。
- 可选把代理环境持久写入 WSL 用户级 `~/.config/codex/proxy.sh`，并从 `~/.profile`、`~/.bashrc` 加载，使 Codex 独立启动的 WSL 进程可继承。
- 检测 Windows/WSL Git、Node、Python、依赖目录、`/mnt/c` 高 I/O 和 PATH 冲突等混用风险。

## Git、终端与工具

- GitHub 为主要服务，当前认证方式混用。
- 安装 Windows 与 WSL/Linux 各自原生的 GitHub CLI；检测版本和登录状态，但不自动登录、复制凭据、修改 remote 或读取/保存令牌与私钥。
- Windows Terminal 支持 PowerShell 7 和 WSL profiles；使用 JSON fragment，避免覆盖用户 settings.json。
- WinGet 安装计划按开发栈生成，逐模块确认；包括 PowerShell 7、Terminal、Git、gh、ripgrep、fd、jq、fnm、uv 和 Desktop。

## 运行时与项目模板

- 统一版本管理规则：Node.js 使用 fnm 与 LTS；Python 使用 uv、`pyproject.toml`/`.python-version` 和项目虚拟环境。
- 生成项目类型模板：`AGENTS.md`、`.codex/config.toml`、`.editorconfig`、`.gitattributes`、`.gitignore`。
- 已有文件内容不同则逐个确认；拒绝替换时生成 `.codex-setup.candidate`。

## Codex 安全配置

- 默认选择 `workspace-write`、Windows `unelevated` sandbox、默认联网和 live web search；完全访问与 Windows/WSL 配置共享必须由用户显式开启。
- 默认 `approval_policy = "on-request"`，模型留空以跟随当前 Codex 默认，推理强度 high，personality pragmatic。
- 可选共享 Windows `%USERPROFILE%\.codex` 到 WSL `CODEX_HOME`；默认关闭，脚本不读取其中的配置、认证和历史内容。
- 第一版明确不管理 MCP、插件和技能。

## 交互、日志和回滚

- PowerShell 7 菜单向导；用户定位为能使用基本命令、但不熟悉环境配置。
- 首次默认 WhatIf；真实应用按功能模块确认；无人值守用导出的 JSON 重放，但真实应用仍需显式 `-ApplyChanges`。
- 执行计划列出安装、修改、跳过和警告；摘要报告 + 详细 JSONL 日志。
- 文件修改前备份；记录 WinGet 安装；支持按次运行回滚。
- 错误区分关键/非关键：单项失败被记录，后续不依赖模块继续检测/执行。
- 最终报告包含健康评分、变更、未解决问题、重启事项、Desktop 手动设置、打开方式与项目目录建议。
