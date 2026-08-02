# 主要设计说明

## 1. 两阶段执行模型

向导把“发现和决定”与“修改”分离：Detection 只读取环境，Planning 生成结构化 action 列表，Actions 才执行变更。`-Mode Apply` 没有 `-ApplyChanges` 时仍是 WhatIf，避免脚本被复制到另一台机器后误执行。

## 2. Agent 推荐规则

推荐器给项目标记打分：WPF、WinUI、`-windows` TargetFramework、Visual C++ 和 PowerShell module 强烈偏向 Windows native；`package.json`、`pyproject.toml`、Docker、Go、Rust 和 Makefile 偏向 WSL。文件系统位置也参与评分。推荐只生成结论与原因，不在未确认时迁移仓库或切换 Desktop。

检测分为快速和完整两种。快速检测确认 WSL 与发行版状态但不启动 Linux；完整检测才进入 Ubuntu 检查工具链。菜单会话按“项目路径 + 检测范围”缓存 5 分钟，完整结果可满足快速请求，真实写入后立即失效。

检测使用 6 个可见阶段。非关键阶段失败时返回结构一致的 fallback 数据并继续生成部分报告；Planning 对“确认缺失”和“检测失败”分别处理，后者不会被误转成自动安装动作。

## 3. 可重复与低侵入配置

- `config/defaults.json` 是 WSL 软件包的唯一配置入口。包组包含启用状态、用途、APT 包、探测命令和兼容别名；公共解析器统一校验、去重并生成 Detection/Planning/Actions 使用的结构。Bash helper 不内置软件清单，只消费逐项参数并再次校验。
- Codex TOML 只更新已管理的 key，保留其他用户配置和注释；现有 `[windows]` section 被复用，不追加重复 section。
- PowerShell 与 WSL shell 配置使用具名 marker block，重复运行会替换该区块。
- Windows Terminal 用官方 JSON fragment 添加两个 profile，不解析或覆盖可能含 JSONC 注释的用户 `settings.json`。
- 项目模板从 `templates/project` 渲染；内容不同时逐文件确认，拒绝时写候选文件。

## 4. 权限与网络含义

`windows.sandbox = "elevated"` 选择 Windows 原生 sandbox 实现；`sandbox_mode = "danger-full-access"` 决定命令不受工作区边界限制。二者是不同维度。完全访问下网络不受 workspace sandbox 的 `network_access` 开关约束，因此脚本不写一个会造成虚假安全感的 `[sandbox_workspace_write]` 区块；只有选择 `workspace-write` 时才写该区块。

默认配置选择 `workspace-write`、`unelevated` 与不共享 `CODEX_HOME`。`danger-full-access`、`elevated` 和跨 Windows/WSL 的 Codex 主目录共享均属于可信项目的显式 opt-in，而非首次运行默认值。

## 5. Node 与 Python

Node 使用 fnm，项目以 `.node-version` 或 package manager metadata 锁定版本；默认安装当前 LTS，不把全局 Node 目录跨 Windows/WSL 共用。Python 使用 uv 管理解释器、虚拟环境、锁文件和运行命令，不把 `.venv` 跨操作系统共用。

## 6. 日志与秘密

日志仅记录 action、命令名、非秘密参数、结果、软件版本和路径；常见 token/key 形态再次经过 redaction。脚本只以收起输出的 `gh auth status` 判断 WSL 登录状态，不执行 `--show-token`、不自动登录、不修改 remote、不枚举 `.ssh` 内容、不读取 `.env`、不复制 auth 文件。共享 `CODEX_HOME` 只是写入 WSL 环境变量指针。

PATH 诊断按安装根目录归类候选：不同安装来源才作为冲突影响健康评分；同一安装的多个入口、应用执行别名和重复 PATH 目录只作为信息展示，不自动清理。

## 7. 回滚边界

第一次修改文件时保存一次原始副本；同次幂等重写不会制造多级备份。回滚按相反方向恢复文件，并可选择卸载本次 WinGet 软件。WSL 发行版、版本转换、Linux 包和认证状态不自动逆转，因为机械逆转可能删除用户数据；这些成为回滚清单中的人工复核项。

## 8. Desktop UI 边界

官方公开文档说明 Agent 和 integrated terminal 是独立设置，但没有承诺稳定、可脚本化的本地设置文件。因此本工具不会猜测或修改 Desktop 私有状态；它生成建议、打开 `codex://settings` 并在报告中给出准确步骤。
