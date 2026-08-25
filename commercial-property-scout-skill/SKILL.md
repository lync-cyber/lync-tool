---
name: commercial-property-scout
description: 通过简短选择题访谈明确商铺、办公室、写字楼、园区、仓储等商业或经营性房产的预算、面积、位置、用途、交通与硬条件，再执行按可靠度分层的跨来源检索、语义核验、成本校准、去重、候选筛选和踩点规划，并生成可审计的 HTML 决策报告。用于租赁或购买房源、比较候选和复核来源覆盖；不用于纯住宅找房、替代法律/产权尽调，或未经授权的联系、预约、议价和签约。
---

# Commercial Property Scout

## 目标与边界

把找房任务转化为“需求已确认、来源有计划、证据可追溯、成本口径一致”的决策过程。始终分开维护：

- `fit_score`：是否适合用户；
- `confidence_score`：证据是否足够可信；
- `report_maturity`：报告目前能支持什么动作。

让 LLM 负责语义工作：理解用途、生成访谈选项、选择适用来源、阅读页面、识别软文和冲突、判断经营条件、提出核验问题。只用脚本处理容易出错的机械工作：JSON 结构、金额换算、保守去重、来源覆盖/数据 QA 和 HTML 渲染。不要建立自动爬虫编排或用脚本替代页面语义判断。

## 开始前必须读取

按任务读取，不要把全部 reference 复述给用户：

- 开始：`references/interview-guide.md`、`references/workflow-contract.md`、`references/source-policy.md`、`references/data-schema.md`、`references/browser-collection-protocol.md`、`references/discovery-coverage-rules.md`、`references/dependency-policy.md`；
- 分析：`references/price-dedupe-rules.md`、`references/scoring-rules.md`、`references/verification-rules.md`；
- 报告/踩点：`references/report-spec.md`、`references/site-visit-rules.md`、`references/script-contracts.md`；
- 批量表格或已保存 HTML：仅在需要时读取对应 ingestion/extraction reference。

`references/source-registry.json` 是可配置的来源目录和初始先验。贝壳与链家是本技能的必查主源；只有用户明确授权豁免时才可跳过其中之一。

## 工作流

### 1. 先做选择题访谈

在搜索前按照 `interview-guide.md` 提问。每轮只问 1–3 题，优先确认成本口径、位置边界、面积弹性、一票否决条件和期望交付深度。已有答案直接复用。

用户明确跳过时，把 `interview.status` 设为 `skipped_by_user`，写明假设，并保持未确认硬条件为 `unknown`。

### 2. 初始化并验证 brief

```bash
uv run python scripts/init_workspace.py <workspace> --city <城市> --asset-type <类型> --transaction-type rent
uv run python scripts/validate_brief.py <workspace>/data/search_brief.json -o <workspace>/data/brief_qa_report.json --strict
```

租赁预算必须明确是：

- `fixed_monthly_cost`：租金 + 物业费 + 已知固定周期费用；或
- `base_rent`：仅租金。

默认建议前者。不要把“租金约 1 万”和“含物业总成本约 1 万”当成同一要求。

### 3. 由 LLM 制定来源计划

根据城市、物业类型、交易类型和当前可用性选择来源，写入 `data/source_plan.json`。按 `source-policy.md` 分成：

1. `primary_discovery`：高优先级结构化发现源；
2. `broad_discovery`：补漏源；
3. `verification`：项目、业主、物业、政府等核验源；
4. `benchmark`：独立市场基准；
5. `lead_only`：只能提供线索的来源。

把贝壳与链家分别列为 `critical` 的 `primary_discovery`，并在任何其他房源平台之前逐一直接尝试。不得把贝壳和链家合并成一个来源，也不得用其中一个或房天下、安居客、58 等替代另一个。搜索引擎没有结果不等于已经访问过平台。每个来源都必须记录明确状态；可以使用：

```bash
uv run python scripts/record_source_status.py <workspace>/data/source_plan.json \
  --key <key> --name <名称> --role <角色> --priority critical \
  --status <状态> --reason <说明> --result-count <数量>
```

贝壳与链家允许在完成计划内搜索后得到零结果；不得因此伪造房源。两者只有 `completed_with_results` 或 `completed_zero_results` 才算完成。若任一必查主源出现登录、验证码、访问限制、超时、空白页、入口失效、筛选失灵或浏览器不可用，立即保持当前页面和状态，停止访问其他房源平台、停止采集和停止生成报告，明确告诉用户平台、URL、故障表现及需要用户执行的动作，等待用户介入。用户确认恢复后才从同一来源继续。替代来源不能解除此闸门。

只有用户明确说可以跳过某个必查主源时，才在 `source_plan.json` 中记录 `user_authorized_waiver: true`、被豁免的 `source_key` 和用户原话；执行者不得自行推断豁免。

房源平台的实际访问、筛选和详情核验必须在用户可见且可人工接管的浏览器标签页中完成。开始访问第一个房源平台前先把该浏览器页面显示给用户，并在采集期间保留正在操作的标签页。后台网页抓取、搜索索引或 HTTP 响应只能用于市场基准、辅助发现和交叉核验，不能替代高优先级平台的浏览器直访，也不能单独据此判定平台出现验证码、登录墙或访问限制。

### 4. 先校准市场，再采集房源

先取得至少两个真正独立的市场基准，写入 `data/market_calibration.json`。不要混合不同资产等级或价格口径。

随后采集原始广告到 `data/raw_listings.json`，并把每次搜索的范围、查询词、页数/滚动批次、新增房源与停止原因记录到 `data/collection_log.json`。保留 URL、平台、抓取时间、原始报价、面积和页面证据。

初筛顺序应先宽后窄：先在全市/全边界范围组合使用平台稳定支持的面积与总价/总成本条件，再应用用户明确给出的价格下限、排除项等噪声规则，最后才按软偏好区域、线路或商圈分通道补充和比较。被硬条件或明确噪声规则排除的记录仍保留排除原因与来源证据，但不消耗详情核验、项目反查和异常低价复核配额；不得为了补数量反复复核明显不合需求的低价远端库存。

20–50 条只是候选池规模参考，不是停止条件。单个来源看到足够多首屏卡片也不算完成。除非第一页已经明确无下一页、零结果或发生真实访问限制，否则主要发现源必须翻页/继续滚动；按 `discovery-coverage-rules.md` 同时覆盖全市基线、用户偏好区域、偏好区域之外的对照区域和重点项目反查。只有分页耗尽或连续低新增达到饱和条件时才能停止。

位置条件必须区分：

- `hard_boundary`：用户明确表示区域外完全不考虑；
- `citywide_with_preferences`：用户只表达重点/优先区域，区域外仍可进入候选并用于比较；
- `citywide`：全市开放，无区域偏好。

不要把“重点覆盖某区域”解释成结果必须集中在该区域。偏好区域可能价格、供给、运营条件或综合适配度较差；报告必须允许对照区域胜出。

低可靠度聚合平台只用于补漏。仅由 `broad_discovery`/`lead_only` 支撑且没有独立交叉证据的候选，保留为 `supplementary_lead`，不占主候选表。不要用大量同质广告制造“覆盖充分”的错觉。

### 5. 遵守访问限制

只有用户可见、当前正在操作的浏览器标签页真实出现 CAPTCHA、滑块、短信、二维码登录或二次验证时，才写入对应验证状态。必查主源出现验证或其他网站故障时都必须立即暂停并记录平台、当前 URL、故障表现和用户动作；保持同一标签页可见且不刷新，请用户本人处理后从该页继续。用户确认完成后，在同一来源第一次恢复为 `in_progress` 或完成态时清除等待标记，并继续原搜索通道。后台抓取工具返回的验证码页只记为辅助访问异常；必须先在可见浏览器中复现，才能写入 `blocked_captcha` 或请求人工接管。不得自动破解、绕过或对抗访问控制。

### 6. 运行确定性流水线

```bash
uv run python scripts/run_pipeline.py <workspace>
```

该入口只执行：brief/source/collection QA → 规范化 → profile → 保守去重 → 价格预警 → 成本与匹配评分 → 踩点分组 → 数据 QA → HTML。任一必查主源未完成或正在等待用户介入时，流水线必须在 source QA 后直接退出，不得生成工作稿或 HTML；其他 collection QA blocker 才允许按成熟度规则保留发现阶段工作稿。

脚本不是事实裁判：

- HTML 自动提取只能产生字段候选/V0；
- 多广告不等于多份独立证据；
- 价格异常只能叫预警，不能叫虚假；
- 经营条件缺证据时保持未知；
- V2/V3 必须有明确核验证据。

### 7. 反向核验高潜候选

优先核验排名靠前但低置信、固定月总成本不完整、价格异常、来源冲突、缺具体单元、仅补漏源支撑或硬条件未知的候选。围绕项目、地址、面积、楼层/房号、图片和报价反向搜索。

根据物业用途语义判断需要核实的条件。例如商铺关注上下水、排烟、门头和业态；办公关注公共访问、空调时段、电梯、注册和综合成本。不要把这些差异扩展成复杂脚本规则。

发现新证据后修改原始数据或 brief，再重新运行流水线；不要手改最终 HTML 的事实或分数。

### 8. 按成熟度交付

- `discovery_draft`：需求、来源或证据仍有 blocker；只能作为工作稿；
- `research_shortlist`：线上研究完成，但关键条件仍需核验；
- `visit_ready`：来源与硬条件证据足以安排踩点；
- `unit_confirmed`：至少一个具体单元达到明确确认级别。

报告必须说明高优先级来源的尝试结果、来源集中度、固定月总成本是否完整，以及补充线索为何没有进入主表。主候选表每行必须直接提供从保留的 `source_url` 渲染出的可点击原始房源链接；内部详情锚点不能替代它，缺链接时 HTML 自检必须阻止交付。

未经用户明确授权，不代表用户联系、提交手机号、预约、议价、出价或签署。

## 依赖与恢复

先运行：

```bash
uv --version
uv run --no-sync python scripts/check_environment.py
```

核心 JSON 流程必须有标准库降级路径。不要静默安装依赖。`state.json` 记录恢复点、QA 路径、报告成熟度和下一步动作；中断后先读取它，不要从零重搜。

## 修改后自检

```bash
uv run python scripts/self_test.py
python <skill-creator>/scripts/quick_validate.py <skill-root>
```

自检至少覆盖：访谈/brief 闸门、高优先级来源尝试、来源集中度、固定月总成本、补充来源降级、去重、价格预警、QA 和 HTML 渲染。
