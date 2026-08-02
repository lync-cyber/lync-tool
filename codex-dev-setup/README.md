# Codex Desktop Windows 11 开发环境向导

这是一个面向个人多台 Windows 11 设备、以 Codex Desktop 为中心的可重复环境配置工具。入口是 PowerShell 7 菜单向导；首次默认执行快速 WhatIf 演练，不会启动 WSL 发行版、安装软件或修改配置。

## 快速开始

最方便的方式是双击 `Launch-CodexSetup.cmd`。如果尚未安装 PowerShell 7，引导程序会先解释并询问是否通过 WinGet 安装。菜单操作完成后会保留结果并返回主菜单，只有选择 `[0]` 才关闭窗口。

也可以从 PowerShell 7 启动：

```powershell
Set-Location <解压目录>
./Start-CodexSetup.ps1
```

常用的非菜单命令：

```powershell
# 只检测
./Start-CodexSetup.ps1 -Mode Detect

# 完整检测（包含启动 WSL 并检查 Linux 工具链）
./Start-CodexSetup.ps1 -Mode Detect -DeepDetection

# 生成计划并 WhatIf 演练
./Start-CodexSetup.ps1 -Mode Plan -ProjectPath C:\path\to\repo

# 忽略当前会话的检测缓存并刷新
./Start-CodexSetup.ps1 -Mode Plan -ForceRefresh

# 真实应用；仍会按模块确认
./Start-CodexSetup.ps1 -Mode Apply -ApplyChanges -ProjectPath C:\path\to\repo

# 项目模板演练 / 真实写入
./Start-CodexSetup.ps1 -Mode ProjectInit -ProjectPath C:\path\to\repo
./Start-CodexSetup.ps1 -Mode ProjectInit -ProjectPath C:\path\to\repo -ApplyChanges

# 导出可在另一台设备重放的 JSON
./Start-CodexSetup.ps1 -Mode Export -ExportPath .\my-codex-setup.json

# 导入配置并演练
./Start-CodexSetup.ps1 -Mode Plan -ConfigPath .\my-codex-setup.json

# 明确授权后的无人值守重放（没有 -ApplyChanges 时仍只演练）
./Start-CodexSetup.ps1 -Mode Apply -ConfigPath .\my-codex-setup.json -NonInteractive -ApplyChanges

# 回滚先演练，再真实执行
./Start-CodexSetup.ps1 -Mode Rollback -RollbackManifest <manifest.json>
./Start-CodexSetup.ps1 -Mode Rollback -RollbackManifest <manifest.json> -ApplyChanges
```

## 检测模式与完成页

- 菜单 `[1]` 是快速检测：显示 6 个检测阶段和耗时，但不启动 WSL 发行版。
- 菜单 `[7]` 是完整检测：额外检查 WSL 内的 Git、Node、Python、uv、fnm 和 Codex。
- 同一项目的检测结果在当前菜单会话内缓存 5 分钟；完整结果也可满足后续快速请求。菜单 `[R]` 可强制刷新。
- 真实应用始终使用完整检测，写入完成后会清空缓存。
- 完成页汇总健康状态、缺失工具、检测异常和真实 PATH 冲突，并可打开报告、打开目录或复制路径。
- 单个非关键检测失败不会中断其他阶段；状态未知的组件不会生成自动安装动作，失败原因会写入报告。

## 它会做什么

- 分阶段检测 Windows、Codex Desktop、Terminal、开发工具、WSL、项目类型和 PATH；区分真实安装冲突、同安装重复入口与 Windows 应用别名。
- 检测 `%USERPROFILE%\.wslconfig`、Windows 系统代理和常见 localhost 代理端口；真实应用时可选配置 mirrored networking 与 v2rayN 持久代理。
- 扫描项目标记，为 Windows 专属 .NET/PowerShell 项目建议 Windows native Agent，为 Web/Python/跨平台项目建议 WSL Agent，并自动匹配 PowerShell 7 或 WSL terminal。
- 用 WinGet 生成安装/更新检查计划，真实应用时按功能模块确认。
- 配置 Git 的非秘密基础选项；GitHub CLI 与 SSH 只显示官方交互命令。
- 为 Node.js 推荐 fnm + 当前 LTS，为 Python 推荐 uv + 项目级 Python 版本与虚拟环境。
- 以幂等方式写入 Codex 用户级 `config.toml`、PowerShell profile、Windows Terminal JSON fragment 和 WSL `.bashrc` 管理区块。
- 生成 `AGENTS.md`、`.codex/config.toml`、`.editorconfig`、`.gitattributes`、`.gitignore`。
- 为每次运行保存详细 JSONL 日志、检测/计划/结果 JSON、中文摘要报告、文件备份和回滚清单。

## 重要安全提示

默认值使用 `sandbox_mode = "workspace-write"`、`windows.sandbox = "unelevated"`、`web_search = "live"`，且不共享 Windows `%USERPROFILE%\.codex` 给 WSL CLI。这适合日常项目：命令被限制在工作区边界内，WSL 也不会自动访问 Windows 侧的 Codex 认证缓存与会话历史。

对确实需要完全访问的可信个人项目，可在 `config/defaults.json` 中显式改用 `sandboxMode = "danger-full-access"`，并按需启用 `shareWindowsHomeToWsl` 或 `windowsSandbox = "elevated"`。Windows elevated sandbox 与 Windows 的“Windows Sandbox”可选功能不是同一个机制。

脚本不会读取或记录 API Key、访问令牌、SSH 私钥、浏览器凭据或 `.env`；不会自动迁移已有仓库；不会绕过 UAC、企业策略或安全软件；第一版不管理 MCP、插件和技能。

## WSL mirrored 网络与 v2rayN

“开始设置”完成 WSL 检测后会提供一个可跳过的网络环节：

- 推荐项写入 `networkingMode=mirrored`、`dnsTunneling=true`、`autoProxy=true`、`firewall=true` 和 `initialAutoProxyTimeout=5000`，保留原有 `.wslconfig` 中的内存、CPU、swap 等设置。
- v2rayN 只需监听 Windows `127.0.0.1`，不需要启用“允许来自局域网的连接”，也不会由本工具创建 LAN 防火墙入站规则。
- 选择持久代理时会生成 WSL `~/.config/codex/proxy.sh`，并通过受管区块从 `~/.profile` 和 `~/.bashrc` 加载。这样新启动的 Codex WSL 进程不依赖另一个终端中临时执行过的 `export`。
- 工具只把 localhost 监听识别为候选端口，无法仅凭监听状态判断 HTTP/SOCKS 协议；最终必须按 v2rayN 界面确认，不会假设所有版本都使用 10808。
- 持久代理要求先启动 v2rayN 再启动 Codex。端口改变时重新运行网络环节，或编辑代理文件后执行 `wsl --shutdown`。
- 再次运行网络环节并选择“mirrored + 关闭本工具持久代理”会移除本工具在 `proxy.sh`、`.profile` 和 `.bashrc` 中管理的代理加载区块，不会修改 v2rayN。
- 若工具无法确认 WSL 包版本，会提示先在 PowerShell 运行 `wsl --update`；旧版 WSL 不应直接应用 mirrored 配置。

应用后先保存所有 WSL 工作，再从 PowerShell 运行：

```powershell
wsl --shutdown
```

重新打开 Codex 后，可让 WSL Agent 运行以下命令验证：

```bash
uname -a
echo "$WSL_DISTRO_NAME"
env | grep -i proxy
curl -I --connect-timeout 10 https://github.com
git ls-remote https://github.com/openai/codex.git HEAD
```

Codex Desktop 的 Linux setup script 是项目/工作树级补充：官方文档说明它在创建新 worktree 时自动运行。需要显式初始化依赖时，可在 Desktop 的 local environment 中加入 `. "$HOME/.config/codex/proxy.sh"`；它不替代上述用户级持久加载。

## 运行数据与回滚

运行数据默认写入：

```text
%LOCALAPPDATA%\CodexDevSetup\
├── logs\<run-id>.jsonl
└── runs\<run-id>\
    ├── summary.md
    ├── detection.json
    ├── plan.json
    ├── results.json
    ├── rollback-manifest.json
    └── backups\
```

回滚会恢复本次修改前备份的文件，并可选择卸载本次由 WinGet 安装的软件。为了避免数据丢失，它不会自动注销 Ubuntu、把 WSL2 降回 WSL1、删除登录状态或强行卸载 WSL 内的 apt/fnm/uv 包；报告会列出这些人工复核项。

## 目录

```text
codex-dev-setup/
├── Launch-CodexSetup.cmd
├── Bootstrap-CodexSetup.ps1
├── Start-CodexSetup.ps1
├── config/defaults.json
├── modules/
│   ├── CodexSetup.Common.psm1
│   ├── CodexSetup.Detection.psm1
│   ├── CodexSetup.Planning.psm1
│   ├── CodexSetup.Actions.psm1
│   └── CodexSetup.Reporting.psm1
├── templates/project/
├── wsl/setup.sh
├── tests/Smoke.Tests.ps1
└── docs/
```

更详细内容见 [需求摘要](docs/REQUIREMENTS.md)、[设计说明](docs/DESIGN.md)、[官方资料](docs/SOURCES.md) 和 [验证结果](docs/VALIDATION.md)。
