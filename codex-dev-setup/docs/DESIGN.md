# v2 设计说明

## 单一决策模型

配置从 `schemaVersion = 2` 开始，必须完整满足当前结构。读取器拒绝未知 schema 和缺少的必需字段，不执行 v1 字段别名、默认值合并或自动迁移。程序版本只读取仓库根目录的 `VERSION`，不在 JSON 或源文件中保存第二份版本常量。

`environmentMode` 决定全部下游行为：

| 维度 | WslFirst | WindowsNative |
|---|---|---|
| 仓库 | WSL `/home/...` | Windows 本地路径 |
| Agent | WSL | Windows native |
| Terminal | WSL | PowerShell 7 |
| Git/运行时/测试 | Linux 原生 | Windows 原生 |
| Windows sandbox | 不适用 | `elevated` 默认 |

项目探测只提供证据与冲突警告，不成为第二套隐式策略。

## Ubuntu 版本选择

`wsl.distribution` 是版本策略的唯一配置入口：默认 `latest-stable`，可改为 `latest-lts` 或精确的 `Ubuntu-YY.MM`。命令行 `-Distribution` 先覆盖该字段。配置读取只校验形式；进入 WslFirst 工作流才解析自动选项，独立 Export、Rollback 和 WindowsNative 不访问版本目录。

自动解析合并 [Canonical 正式发布元数据](https://changelogs.ubuntu.com/meta-release) 与 [微软 WSL 发行版目录](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json)：只保留 `Supported=1` 的正式 Ubuntu 版本，以及当前 Windows OS 架构存在下载项的精确发行版。`latest-lts` 再筛选 LTS，最后按版本排序。通用 `Ubuntu`、预览版和已停止支持的发布不参与自动选择；精确版本输入直接成为目标，不需要联网决定版本。

每个目录请求最多 15 秒。下载或解析失败不使用猜测的默认值，而是提示重试或指定精确版本。成功后原配置对象的 `wsl.distribution` 被固定为精确名，后续检测缓存键、动作、环境验证与会话导出共用此值。源 JSON 不被改写，新进程读取原自动配置时重新解析；不额外维护跨进程缓存或另一套版本状态。

现有发行版是独立安装。选定新版本可能产生安装及设置默认发行版的动作，均在计划内展示；不创建发行版升级、注销或迁移逻辑。Windows 真实机验收在 Preflight 解析并保存精确的验收配置，后续阶段和通道证据使用该版本，避免跨重启追随“最新”变化。

## 阶段流水线

```text
Detect → Plan → Confirm → Apply
```

- Detect 只读系统、发行版、工具、项目标记与命令来源。
- Plan 根据单一模式生成结构化动作，不根据缺失工具临时切换环境。
- Confirm 在完整计划中给出目标、原因、前置依赖和配置变更，交互执行仅统一确认一次；已有项目文件批量覆盖和全局高风险权限单独确认。
- Apply 通过 Windows action 与 WSL helper 分工执行，每个动作在返回成功前验证自己的结果。
- 首页仅保留开始或修复、仅检查、项目配置和更多入口，检查深度由任务选择。Apply 有实际变更后在本次运行完成一次完整验证；各模块之间不重复全量查询。结果页可继续修复、重新检查或显式停止 WSL 后验证，无需退出工具。
- Desktop 人工设置和重启后的真实 Agent 由独立验收步骤确认。

任何非关键失败都会被记录，依赖该结果的动作停止；不会把 unknown 当作 missing 后盲目安装。

首次安装计划同时包含发行版准备和依赖它的工具链配置。安装返回后根据真实退出码和发行版状态继续；不再无条件报告需要重启。WSL 网络重启要求在当前结果会话中保留，普通复检不清除。退出工具后的新会话重新检查真实配置，网络运行时生效仍需按指南验证，不用配置文件匹配冒充 VM 或 Desktop 验收。

健康分数不参与决策，已移除任意权重评分；旧 JSON `healthScore` 字段固定为 null。界面分别显示检查是否完整、具体变更和待处理问题，避免缺工具或配置未就绪时仍给出 100 分。旧 v2 `preferences` 两个字段仅为读取既有导出文件保留，不再形成第二套确认流程；默认配置不再写入它们。

## WslFirst 边界

Windows action 负责 Windows 11、WSL2、解析后的精确 Ubuntu 发行版、Desktop、Terminal、UI Git/gh 与可选 Docker Desktop。WSL helper 是开发工具链唯一写入入口，负责 APT 软件、Linux 原生 PowerShell 7、fnm/Node、pnpm、uv/Python 3.12、Codex CLI、Git 基线、Bash PATH、全局指令与环境检查。

WSL helper 接收由配置解析器校验的包与命令参数，脚本内部不维护第二份发行版或 Windows 工具链策略。下载型安装器先进入临时目录，再执行官方脚本。每个受管文件在覆盖前备份，重复运行只替换具名管理区块。

`setup.sh` 对照精确目标核验 `/etc/os-release` 的 Ubuntu 身份与 `VERSION_ID`，Microsoft 软件源地址由该实际版本生成：`https://packages.microsoft.com/config/ubuntu/<VERSION_ID>/packages-microsoft-prod.deb`。WSL 目录可安装性不等于 PowerShell 软件源可用性；Microsoft 不测试或支持 Ubuntu interim 版本，长期维护场景推荐 `latest-lts`。软件源失败按实际错误报告，不借用其他 Ubuntu 版本的仓库，也不增加自动跨版本回退。[Microsoft 安装说明](https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu)

`CODEX_HOME` 不跨系统共享。Windows Desktop 和 Linux Codex CLI 拥有独立配置、认证、历史、缓存与全局 `AGENTS.md`。

网络 action 只更新 `.wslconfig` 中明确受管的 WSL2 键，并保留 CPU、内存、swap 等其他配置。代理发现和代理环境注入不属于 v2；`autoProxy` 交给 WSL 自身处理，避免形成第二套代理状态。

## 项目命令生成

项目初始化使用证据优先的命令映射：

1. 读取 lockfile 与 `package.json.packageManager` 确定 Node 包管理器。
2. 仅把 `package.json.scripts` 中实际存在的 dev、test、lint、format、typecheck、check、build 写入说明。
3. `uv.lock` 或 uv 配置存在时使用 `uv sync`；只在 `pyproject.toml` 声明对应工具时生成 pytest/ruff 命令。
4. 无证据的命令标记为未声明，不创建推测性入口。

模板写入 `AGENTS.md`、`.editorconfig`、`.gitattributes` 与 `.gitignore`。个人 approval、sandbox、model、web search 等策略属于用户级配置，不进入仓库模板。

## Desktop 人工验收

公开文档确认 Agent environment 与 integrated terminal 独立，但没有提供稳定的本地设置写入接口。报告因此明确区分：

- 通过公开接口自动检测的系统事实；
- 必须由用户在 Desktop Settings 完成的人工待办；
- 重启后在新 Agent 内运行环境检查才能确认的事实。

打开 Settings 或打印说明不会把状态提升为已验证。

## 安全设计

工作区 sandbox、approval policy、网络访问与 Windows sandbox 是不同维度。v2 默认保持 `workspace-write` 和 `on-request`；环境错误通过修正 Shell、路径和命令来源解决，不通过放宽权限解决。

Windows 专属项目使用 Windows native `elevated` sandbox 默认值。它与 `danger-full-access` 不等价；后者仍是高风险显式选择。

日志只记录组件、动作、非秘密参数、版本、路径和状态。认证命令不显示令牌，文件扫描不读取 `.env`、SSH 私钥或 Codex 身份数据。

## Windows 真实机证据

真实机验收使用可续跑的阶段状态，而不是一条跨重启的长命令。Preflight 记录 Windows、WinGet、WSL、受管文件和 Desktop 进程基线；Apply 与 PostRestart 保存结构化工作流结果；DesktopEvidence 依次验证两个负向组合和最终 WSL/WSL 组合，只接受人工设置截图、完整进程替换以及绑定 RunId、通道和本轮 nonce 的独立 JSON 环境检查。真实回滚后必须先记录人工 GUI 基线恢复，再重新 Apply；需要时再次完成 WSL shutdown/restart，最后重新提交 WSL/WSL 双通道证据。

快速检测只对当前配置需要的 Windows 应用执行精确 package ID/source `list`，仅使用官方退出码判断已安装、未安装或 unknown，不解析面向人的表格，也不为展示版本而扫描整机应用。安装后回滚登记和卸载前防漂移需要版本证据时，才读取结构化 export；export 缺失不能证明未安装，仍由精确查询退出码复核。所有只读 WinGet 子进程都有超时上限，某个软件源超时后跳过本轮同源后续查询。PATH 与 Appx 命令只用于安装后的运行能力复核。WSL 生命周期只执行一次有界的 verbose 列表查询；深度工具链状态通过一次 Ubuntu 进程采集。WSL1 是不受支持状态，不存在转换或兼容分支。

## 可回滚范围

回滚清单 schema v3 绑定当前主机和 Windows 用户，并由每次运行独立、DPAPI CurrentUser 保护的密钥进行 HMAC 校验。它在首次写入前记录原文件哈希、Windows ACL 和备份，写入前记录目标哈希与 ACL，并对每一项保存回滚进度。受管文件通过同目录临时文件原子替换，覆盖前再次检查原文件没有发生竞争修改。恢复前同时检查受管目标、备份、当前哈希和 ACL；软件包恢复还要求当前版本等于本次安装版本。失败项可在解除文件锁或恢复 WinGet source 后继续，已完成项不会重复破坏。

自动回滚恢复受管文件并卸载本次运行新装的 WinGet 包。WSL 发行版、APT 包、运行时、登录状态和 Desktop GUI 不进行机械删除或私有设置写入；真实机验收通过人工 GUI 恢复与最终重新 Apply 把工作站留在目标状态。
