# Script Contracts

所有脚本仅处理用户已合法取得或浏览器 worker 已保存的数据，不负责绕过站点限制。增强依赖遵循 `dependency-policy.md`，不静默安装。除非明确处于无项目环境的诊断模式，所有脚本默认通过 `uv run python scripts/<name>.py ...` 执行；不要直接使用系统 `python` 作为主路径。

## `check_environment.py`

报告 pandas / BeautifulSoup / lxml / openpyxl 可用性和当前执行模式。

## `init_workspace.py`

创建标准工作目录、brief 模板、raw JSON 和 state，并在 source plan 中预置贝壳与链家两个 `critical` 必查主源；其他平台由 LLM 按市场填写。

## `validate_brief.py`

只检查访谈状态、核心字段、成本口径和结构化硬条件是否可执行；不替代 LLM 理解用户语义。

## `record_source_status.py`

安全更新单个来源的任务级状态，避免自由手写状态值。必查主源受限时写入人工介入等待状态，并阻止启动其他来源；同一来源恢复为 `in_progress` 或完成态时清除等待标记并保留恢复时间。替代来源参数不被接受。它不访问平台，也不自动选择来源。

## `validate_source_coverage.py`

检查贝壳与链家是否分别以 `critical` 主源完成、其他高优先级来源是否已尝试、角色最低覆盖和单平台集中度。必查主源受限或未完成是硬阻断，替代来源不能抵消；零结果是有效完成，搜索引擎无结果不是平台尝试。

## `record_search_run.py`

把一次浏览器搜索通道的查询范围、分页/滚动深度、新增房源/项目、逐页筛选完整性和停止原因追加到 `collection_log.json`。主要发现源的非项目反查页缺少 `filters_verified=true` 时拒绝写入。它不访问网页，也不根据结果数自动宣告饱和。

## `validate_collection_coverage.py`

检查是否只看首屏、主要来源分页深度、逐页筛选完整性、全市基线、区域外对照、用户点名项目反查和饱和证据。筛选条件未复核的页不计入主要来源深度；候选条数多不能抵消搜索通道缺失。

## `append_listing.py`

安全追加一条原始广告。只做 exact URL 去重，不做物理物业去重。

## `bulk_import.py`

通过 pandas（优先）或标准库回退批量导入 CSV/TSV/JSON/JSONL；pandas 增强环境支持 XLSX/XLS 和 HTML table。列名别名来自 `field-aliases.json`。未映射列写入 `import_extra`。

## `extract_saved_html.py`

使用 BeautifulSoup 解析本地 HTML，优先 lxml；提取 JSON-LD、Meta、标签字段候选、正文摘要和图片 URL。不得联网，不自动下载图片，不因结构化字段自动升级核验等级。

## `merge_raw_listings.py`

合并多 worker 输出，仍只去 exact URL/source ID 重复。

## `register_image.py`

把已取得的截图/图片复制到本地图片目录，并把来源、类型、说明挂到对应 `source_id`。

## `normalize_listings.py`

规范文本、面积和常见价格单位；无法可靠解析时保持空值并产生 warning。已知固定月费小计只有在 `fixed_cost_components_confirmed=true` 时才标为完整，否则保守标为 `partial`。

## `dataset_profile.py`

优先 pandas 生成来源分布、角色、集中度、缺失率、价格/面积分位数和区域汇总；无 pandas 时使用标准库生成核心 profile。

## `dedupe_properties.py`

保守聚类重复广告；高相似但证据不足的组合写 review 文件，不强行合并。`--engine auto` 小数据完整比较，大数据可用 pandas blocking 减少候选比较对。

## `detect_price_anomalies.py`

按同项目优先、再同商圈/同区域可比样本计算中位价偏离。`--engine auto` 在 pandas 可用时使用分组加速。输出只能叫 anomaly/warning，不能叫 fraud 判定。

## `score_candidates.py`

执行成本口径、通用结构化硬条件、fit、confidence、ranking gates、presentation tier 和 recommendation status。来源初始权重读取 registry；语义判断仍由 LLM 写入证据字段。

## `plan_visits.py`

按商圈/行政区分组；若所有候选有经纬度则做简单近邻顺序。不是实时导航替代品。

## `validate_dataset.py`

合并 brief/source/property 质量门槛并输出报告成熟度。`--strict` 有 blocker 时退出码 2。

## `render_report.py`

只从结构化 JSON 渲染报告；不要在 HTML 中手改事实和分数。主候选表直接渲染保留的 `source_url`，不拼接或改写成搜索页。

## `validate_report_html.py`

使用 BeautifulSoup 对最终 HTML 做结构 QA：未替换模板变量、重复 ID、缺失必需章节、失效内部锚点、本地图片路径，以及主候选表每行是否有 HTTP(S) 原始房源链接。该脚本不访问网络，也不验证远端链接可用性。

## `benchmark_engines.py`

维护工具。生成合成房源并比较 pandas/stdlib 的 dedupe 与 anomaly 运行时间，用于未来调整 `--pandas-threshold`。基准结果依赖机器环境，不应写成市场或真实性结论。

## `run_pipeline.py`

串联 brief/source QA → normalize → dataset profile → dedupe → anomaly → score → visits → consolidated QA → HTML，并回写 `state.json`。贝壳或链家未完成时在 source QA 后立即退出，不生成 HTML。它不负责浏览网页或选择平台。
