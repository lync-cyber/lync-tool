# Discovery Coverage Rules

## 目的

防止“首屏即完成”、偏好区域确认偏差和同质广告堆量。覆盖充分必须同时满足来源、深度、地理和项目四个维度；候选条数本身不能证明覆盖充分。

## 位置语义

在 `search_brief.location_strategy.mode` 中明确记录：

- `hard_boundary`：区域外是硬排除；仅在用户明确说“只要/仅限/区域外不考虑”时使用。
- `citywide_with_preferences`：全市可选，指定区域只影响搜索配额和软评分。
- `citywide`：全市基线搜索，不给指定区域加分。

用户说“重点、优先、最好、沿线”时默认 `citywide_with_preferences`，不得自动升级为 `hard_boundary`。

## 必须执行的搜索通道

除 `hard_boundary` 外，发现阶段至少包括：

1. `citywide_baseline`：不带偏好区域词的全市场基线筛选；
2. `preferred_area`：逐个或分组覆盖用户偏好区域/线路；
3. `comparison_area`：至少两个偏好区域之外、满足交通与成本逻辑的对照商圈；
4. `project_lookup`：对用户点名项目和初筛中高潜/高频/异常项目做楼盘名反查；
5. 可选 `transit_corridor` / `map_search`：线路或地图补漏。

`hard_boundary` 可不做区域外对照，但仍需全边界覆盖和项目反查。

## 初筛与噪声控制

- `citywide_baseline` 优先组合面积与总价/总成本等稳定数值条件；不要先限定软偏好商圈而缩窄候选池。
- 用户明确的价格下限、用途排除、距离边界等应写入结构化硬条件或排除项。命中者保留来源、原始值和排除原因，但不进入详情核验、项目反查或异常低价复核队列。
- 软偏好只影响后续覆盖与排序。不得用大量明显不满足需求的廉价远端库存制造样本量或消耗复核配额。

## 翻页与滚动

- 主要发现源不得只看第一页就标记完成，除非页面明确零结果、无下一页、列表不足一页或真实访问受限。
- 默认每个主要发现源至少检查 3 个结果页/等价滚动批次；每个搜索通道至少检查 2 页/批次，或记录合法提前终止原因。
- 无限滚动按一次完整新增卡片加载记为一个批次。
- 每页/批次必须逐页记录 `results_seen`、`new_unique_listings`、`new_unique_projects`、`new_qualified_listings`；逐页合计必须与搜索运行总数一致，不能只记平台显示的总结果数或事后填写一个总数。
- 翻页后必须确认交易类型、面积、价格等已选筛选条件仍有效。筛选状态丢失的页面不计入覆盖；无法恢复时使用 `blocked` 终态并在 `notes` 与本地证据中说明。

## 饱和停止条件

满足任一条件才可停止某搜索通道：

- `pagination_exhausted` / `no_next_page` / `zero_results`；
- 连续至少 2 页/批次的新增项目率低于 10%，且没有新增合格候选；
- `blocked`：用户可见浏览器出现真实访问限制。若来源是贝壳、链家或其他 `critical` 来源，必须按来源政策停止并等待用户介入，不能转入替代来源；
- `hard_cap_with_reason`：达到任务级明确上限，并写明为何继续搜索的边际价值不足。不能只写“已有足够条数”。

## 项目反查

- 每个用户明确点名的项目必须有一条 `project_lookup` 记录，即使结果为零。
- 对初筛出现频率高、排名靠前、异常低价或具有特殊运营优势的项目，至少反查 3 个。
- 项目别名、旧名、开发商/园区名可能不同；记录使用过的查询词，不把单一名称零结果写成项目无房。

## 地理防偏

- `citywide_with_preferences` 默认至少选择 2 个对照区域；选择依据应是交通、成本、供给和用途适配，而不是随机凑数。
- 偏好区域广告占原始样本 80% 以上时为 blocker；仅创建零结果对照搜索不能掩盖样本集中。
- 报告应比较“偏好区域是否真的更优”，而不是预设其胜出。

## 结构化记录

使用 `scripts/record_search_run.py` 写入 `data/collection_log.json`。运行：

```bash
uv run python scripts/validate_collection_coverage.py \
  <workspace>/data/collection_log.json \
  <workspace>/data/raw_listings.json \
  <workspace>/data/search_brief.json \
  --source-plan <workspace>/data/source_plan.json \
  -o <workspace>/data/collection_qa_report.json --strict
```

最低页数、对照区域数、项目反查数、逐页指标和本地证据要求是 Skill 的审计下限；工作区配置只能调严，不能关闭。证据必须是非空本地截图或保存页，不能用一个远程 URL 充当证据。未记录搜索深度等同于未证明覆盖，不能依赖口头说明升级报告成熟度。
