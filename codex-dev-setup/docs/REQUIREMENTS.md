# v2 需求规格

## 目标

消除 Codex 在 Windows、WSL、Shell、路径、Git、Node、Python 和包管理器之间的环境歧义。默认把跨平台开发收敛为一套 WSL2 Ubuntu 工具链，Ubuntu 版本按配置选择并固定到本次会话；不为 v1 配置或双环境工作流提供兼容层。

## 模式契约

`environmentMode` 是唯一环境决策，允许值只有：

- `WslFirst`：默认值。所有仓库工作在本次选定的 WSL2 Ubuntu 的 `/home` 文件系统中完成。
- `WindowsNative`：仅用于必须调用 Windows API 或 Windows 原生工具链的项目。

项目探测可以给出不一致警告，但不得自动改变配置模式、迁移仓库或在失败后切换 Shell。

## 阶段 1：系统前置条件

- 支持 Windows 11 与 WSL2，不支持 WSL1。
- `wsl.distribution` 默认为 `latest-stable`，另接受 `latest-lts` 和精确名称 `Ubuntu-YY.MM`。入口 `-Distribution` 覆盖配置值；通用 `Ubuntu` 和预览名称不作为目标。
- 自动版本选择取 Canonical `meta-release` 中 `Supported=1` 的正式版本与微软 WSL 官方目录中当前 Windows OS 架构可安装版本的交集；`latest-lts` 进一步限定 LTS，再按版本选择最新项。执行前必须解析为精确发行版名，不硬编码“最新”版本。
- 仅进入 WSL 检查或设置工作流才联网解析，每个请求最多 15 秒。失败必须说明重试或指定固定版本的方式，不静默降级；独立 Export、Rollback 和 WindowsNative 不触发解析。
- 解析后在原会话配置对象中固定精确名称，供重新检查、设置和导出复用；不改写源配置。新进程读取原自动配置时重新解析，读取已导出的精确配置时保持固定。
- 选择新版不会升级、迁移或删除已有其他发行版。所选发行版缺失时可规划并行安装；安装及修改默认发行版必须显示在执行计划中。
- 检测必须区分 WSL 功能未启用、没有发行版、缺少目标发行版、目标 WSL2 就绪、WSL1 不受支持和状态未知；unknown 不得当成 missing。
- 检测并规划默认 WSL2 和发行版安装；修改后明确提示重启范围。检测到 WSL1 时停止，不执行自动转换。
- `WslFirst` 的 Windows 侧只安装 Desktop、Terminal、UI 所需 Git/gh 与可选 Docker Desktop。
- 快速检测必须只查询当前配置需要的 WinGet package ID/source，并用精确查询的官方退出码确定安装状态，不得解析表格或扫描整机应用来展示版本。安装后回滚登记和卸载前防漂移需要版本证据时才读取结构化 export；export 缺失不能当成未安装。每个只读 WinGet 子进程必须有超时上限。PATH 命令只验证可执行能力，不能代替包身份。
- WSL 生命周期检测只执行一次有超时上限的 verbose 列表查询；深度检查只启动一次目标 Ubuntu，并在同一进程中采集工具、软件包和配置状态。
- Desktop UI 状态没有可靠公开接口时，只提供人工步骤，不生成虚假自动检测结果。

## 阶段 2：唯一开发工具链

- 项目根目录位于 `~/code`，实际路径必须以 `/home/` 开头。
- WSL 内安装 Linux 原生 Git、curl、构建工具、ripgrep、jq、fd、ShellCheck、shfmt、gh、PowerShell 7、Codex CLI、fnm、Node LTS、npm、pnpm、uv 与由 uv 管理的 Python 3.12。
- Linux helper 必须核对 Ubuntu `VERSION_ID` 与精确目标版本一致，并按实际版本使用 Microsoft APT 软件源，不得沿用固定的 24.04 地址。Ubuntu 非 LTS 版本不在 Microsoft PowerShell 官方测试及支持范围内，软件源可用性不作保证；需要长期支持时推荐 `latest-lts`。
- 交互式运行由 `sudo` 直接读取密码；工具不读取或保存 sudo 密码。无人值守运行只接受 passwordless sudo，否则停止。
- Git 基线为 `core.autocrlf=input`、`core.safecrlf=warn`、`init.defaultBranch=main`、`fetch.prune=true`、`pull.ff=only`。
- 不安装 Windows Node/Python/fnm/pnpm/uv，不共享 `node_modules`、`.venv`、缓存或 `CODEX_HOME`。
- 所有安装和 shell 配置必须幂等；失败后先诊断环境与命令路径。
- 可管理 `.wslconfig` 的 mirrored networking、DNS tunneling、auto proxy 与 firewall；保留不属于本工具的 WSL 设置。
- 不推测代理端口，不写 Git/Shell proxy，不创建代理软件或 LAN 防火墙规则；网络配置变化后要求 `wsl --shutdown`。

## 阶段 3：Desktop 设置

- `Agent environment` 与 `Integrated terminal shell` 是两个独立检查项。
- `WslFirst` 两项都设为 WSL；`WindowsNative` 两项分别为 Windows native 与 PowerShell。
- 修改 Agent environment 后必须完全重启 Desktop。
- 工具只能打开 Settings 和生成清单，不能声称已自动写入或验证不可读的 GUI 状态。

## 阶段 4：指令与项目入口

- Windows 与 WSL 分别管理全局 `AGENTS.md`，两者不能通过共享 Codex 主目录合并。
- WSL 全局指令规定 Bash、Linux 路径、`~/code` 与第一次失败诊断流程。
- 项目模板只生成仓库协作文件，不生成项目级个人 `config.toml`。
- 项目命令只能来自可证明的项目元数据与已有 scripts；不得猜测包管理器、依赖管理器或测试工具。
- Node 项目服从 lockfile/packageManager；uv 项目使用 `uv sync` 与 `uv run`。

## 阶段 5：验证与报告

- 提供可独立运行的 WSL 环境检查，验证内核、发行版、路径与命令来源。
- Windows 计划执行完成不等于 Desktop 设置完成；报告必须单列“人工待办”和“重启后 Agent 验收”。
- 每个设置动作必须在成功返回前验证自己的结果；Apply 结束后不得重复整套环境检测。
- 检测、计划、执行与项目模板结果保存为结构化输出，失败与跳过不可伪装为成功。
- Windows 真实机验收分阶段保存基线、动作结果、重启后复核、Desktop 人工证据、回滚结果和最终 verdict。
- 测试覆盖 Bash 语法、严格配置、计划生成、受管文件写入、回滚和 WSL 环境检查。

## 安全与秘密

- 默认 `approval_policy=on-request`、`sandbox_mode=workspace-write`、允许 workspace 网络与 live web search。
- `danger-full-access` 不得作为 Shell、路径或权限诊断的默认修复。
- `WindowsNative` 默认使用 `elevated` Windows sandbox；`unelevated` 仅为显式 fallback。
- 不读取、写入、输出或跨环境复制 token、API key、SSH 私钥、浏览器凭据、`.env`、Codex 认证、历史和会话。
- GitHub 与 Codex 登录保持人工交互，工具只检测非秘密状态。
- 回滚清单使用 schema v3，不读取旧清单；清单必须绑定当前主机和 Windows 用户并校验 HMAC。文件恢复校验应用前、应用后和备份哈希以及 Windows ACL，软件包卸载校验本次安装版本，部分失败必须可重试收敛。
- 自动回滚只恢复受管文件并卸载本次新装的 WinGet 包，不注销发行版、不删除 Linux 工具链，也不推断 Desktop GUI 已恢复。

## 明确不做

- 不迁移 v1 配置。
- 不支持 WSL1、泛化的 Ubuntu 发行版名或 `/mnt` 项目。
- 不为同一项目配置 Windows/WSL 双运行时。
- 不从 PowerShell、`wsl.exe` 或 Git Bash 套壳执行仓库命令。
- 不自动修改 Desktop 私有设置、Git remote、认证状态或已有仓库位置。
