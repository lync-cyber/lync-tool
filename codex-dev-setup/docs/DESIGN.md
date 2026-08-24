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

## 阶段流水线

```text
Detect → Plan → Confirm → Apply → Verify
```

- Detect 只读系统、发行版、工具、项目标记与命令来源。
- Plan 根据单一模式生成结构化动作，不根据缺失工具临时切换环境。
- Confirm 对有副作用的模块给出目标、原因与边界。
- Apply 通过 Windows action 与 WSL helper 分工执行。
- Verify 区分机器可验证事实、Desktop 人工设置和重启后的真实 Agent 验收。

任何非关键失败都会被记录，依赖该结果的动作停止；不会把 unknown 当作 missing 后盲目安装。

## WslFirst 边界

Windows action 负责 Windows 11、WSL2、精确发行版 `Ubuntu-24.04`、Desktop、Terminal、UI Git/gh 与可选 Docker Desktop。WSL helper 是开发工具链唯一写入入口，负责 APT 软件、Linux 原生 PowerShell 7、fnm/Node、pnpm、uv/Python 3.12、Codex CLI、Git 基线、Bash PATH、全局指令与环境检查。

WSL helper 接收由配置解析器校验的包与命令参数，脚本内部不维护第二份发行版或 Windows 工具链策略。下载型安装器先进入临时目录，再执行官方脚本。每个受管文件在覆盖前备份，重复运行只替换具名管理区块。

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

WinGet 先用精确 package ID/source 的 `list` 退出码判断存在或缺失，再用结构化 export 为已安装项绑定版本。export 中没有某项不能证明它未安装；除明确的 `NO_APPLICATIONS_FOUND` 外，查询失败一律保持 unknown 并阻止自动安装。PATH 与 Appx 命令只用于安装后的运行能力复核。WSL 状态机只接受 WSL2；WSL1 是不受支持状态，不存在转换或兼容分支。

## 可回滚范围

回滚清单 schema v3 绑定当前主机和 Windows 用户，并由每次运行独立、DPAPI CurrentUser 保护的密钥进行 HMAC 校验。它在首次写入前记录原文件哈希、Windows ACL 和备份，写入前记录目标哈希与 ACL，并对每一项保存回滚进度。受管文件通过同目录临时文件原子替换，覆盖前再次检查原文件没有发生竞争修改。恢复前同时检查受管目标、备份、当前哈希和 ACL；软件包恢复还要求当前版本等于本次安装版本。失败项可在解除文件锁或恢复 WinGet source 后继续，已完成项不会重复破坏。

自动回滚恢复受管文件并卸载本次运行新装的 WinGet 包。WSL 发行版、APT 包、运行时、登录状态和 Desktop GUI 不进行机械删除或私有设置写入；真实机验收通过人工 GUI 恢复与最终重新 Apply 把工作站留在目标状态。
