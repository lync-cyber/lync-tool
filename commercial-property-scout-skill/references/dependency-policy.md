# Dependency & Execution Policy

## 包管理器

本 Skill 统一使用 `uv` 管理 Python 解释器环境、依赖解析、锁文件和脚本执行。`pyproject.toml` 是唯一主依赖声明；`uv.lock` 是可复现执行的锁文件。不维护 `requirements.txt`，避免形成第二套依赖真源。确有外部兼容需求时，可临时用 `uv export` 生成，但不要提交为主依赖声明。

标准初始化流程：

```bash
uv --version
uv lock                 # 仅首次或依赖发生变化时
uv sync --frozen        # 已有 uv.lock 时的默认同步方式
uv run python scripts/check_environment.py
```

如果当前环境无法访问包索引，禁止伪造 `uv.lock`，也不要静默改用 pip。可运行 `uv run --no-sync python scripts/check_environment.py` 检查已有环境；核心 JSON 流水线如果依赖可降级，则允许标准库路径继续。需要增强依赖而环境缺失时，应明确报告阻塞点，由用户/运行环境恢复网络或提供缓存后执行 `uv lock` / `uv sync`。

## 依赖维护

新增、升级或移除依赖时，使用 uv 维护项目元数据：

```bash
uv add <package>
uv remove <package>
uv lock
uv sync --frozen
```

任何自动房源任务都不得自行运行 `uv add`、`uv remove`、`uv lock` 或安装新包；这些属于 Skill 维护动作，不属于搜索任务。

## 增强依赖与降级

核心 JSON 工作流必须可以在 Python 标准库下运行。`pandas`、`beautifulsoup4`、`lxml`、`openpyxl` 属于增强依赖：存在时优先使用，提高批量数据处理、网页解析和表格导入能力；缺失时不得让已有 JSON 流水线完全失效。

### pandas 适用场景

优先用于 CSV / XLSX / JSONL / HTML table 批量导入，大量房源字段的类型转换和缺失值处理，来源/区域/项目分组统计，价格中位数和分位数、异常检测，数据质量 profile，以及大数据量去重候选 blocking。不要为了 pandas 改变证据语义；`NaN` 写回 JSON 前必须转换为 `null`。

### BeautifulSoup / lxml 适用场景

只解析 worker 已经合法保存到本地的 HTML，或明确传入的 HTML 内容。默认优先 `lxml` parser；没有 `lxml` 时回退 `html.parser`。提取顺序为 JSON-LD → canonical/meta → DOM 可见字段/文本 → 图片候选。机器可读不等于真实，解析结果仍按来源策略核验。

## 禁止行为

- 不利用 BeautifulSoup 绕过验证码、登录、反爬或付费墙；
- 不在搜索任务中静默安装或升级依赖；
- 不因 JSON-LD/Meta 中存在价格就自动提升 V2/V3；
- 不把页面中任意数字错误绑定为面积或价格；
- 不静默覆盖 worker 人工确认过的高置信字段。
