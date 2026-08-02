# 验证结果

构建时验证日期：2026-08-02。

## 已执行结果

| 检查 | 结果 | 详情 |
|---|---:|---|
| PowerShell 7 AST 语法 | 通过 | 5 个模块、2 个入口、2 个测试脚本全部无 parser error |
| 默认 JSON | 通过 | `schemaVersion = 1`，PowerShell `ConvertFrom-Json` 成功 |
| PowerShell 7 smoke tests | 通过 | 30/30；新增覆盖安全默认值、Codex Desktop 同产品入口归并、阶段失败 fallback、检测失败不生成安装动作、快速 WSL 跳过、健康标签与 WindowsApps alias 安全检测 |
| 快速/完整真实环境 WhatIf | 通过 | 快速模式不启动 WSL；`-DeepDetection` 完整模式解析 8 个 WSL 工具项；两者均 exit 0 且未修改项目/系统配置 |
| 菜单启动链路与缓存 | 通过 | 自动输入 `1 → Enter → 1 → Enter → 0`，生成两个唯一毫秒级运行号；第二次命中缓存且命令探测数为 0 |
| WSL Bash 语法 | 通过 | Ubuntu-24.04 `bash -n` exit 0 |
| WSL helper WhatIf | 通过 | 正确展示 apt、`~/code`、fnm、uv、`CODEX_HOME` 和 managed `.bashrc` block；未应用 |
| WinGet/MS Store ID | 通过 | 10/10：PowerShell、Terminal、Git、gh、ripgrep、fd、jq、fnm、uv、ChatGPT Desktop |

## 构建机演练摘要

- PowerShell：7.6.4。
- WSL：Ubuntu-24.04 / WSL2。
- 环境健康评分：97/100（状态良好）；重复入口与应用别名不再造成虚假扣分。
- PATH：不同安装来源保留为警告；同安装入口、应用别名和重复目录降为信息；所有项目均只报告，不自动删除。
- 快速 WhatIf 报告运行号：`20260802-170001`；完整 WhatIf：`20260802-170006`。
- Codex Desktop 与 Windows Terminal 使用 Appx package metadata 获取版本，不再执行可能显示 GUI helper 的程序。
- `wsl.exe` 自身的 UTF-16 输出与 Linux 命令的 UTF-8 输出分别解码；Bash 探测脚本经标准输入传递，版本、发行版和工具链条目均可正常解析。
- PATH 清理后，旧的 `.local\\bin` uv 入口已移入可恢复备份，损坏的全局 npm Codex 包已卸载；默认配置已实际写入 `workspace-write`、`unelevated` 与不共享 `CODEX_HOME`。

## 未在构建机上执行的破坏性/外部状态测试

- 没有真实应用整套环境计划，因此没有安装 fd/jq/fnm、没有修改 Git/Codex/Terminal/profile，也没有执行 WSL apt/fnm/uv 安装。
- 没有执行 GitHub/SSH/Codex 登录；秘密边界由代码路径和 smoke redaction 测试验证。
- WinGet 软件卸载回滚未在真实系统执行；临时目录中的文件创建/恢复/删除回滚已通过。

ZIP 的解压清单和 SHA-256 在交付打包时另行生成。
