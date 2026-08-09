# HTML Report Spec

## 目标

HTML 是决策报告，不是网页广告目录。用户应能在 5–10 分钟内完成第一轮初筛，并知道哪些房源需要电话核验、哪些值得踩点。

## Property card required fields

- 项目/楼宇名
- 地址/商圈
- 资产类型
- 面积与面积口径
- 楼层/室号（可见时）
- 原始报价与标准化价格
- 物业/税费/其他成本
- 固定月总成本及完整性（信息足够时）
- 来源平台与 URL
- 抓取时间
- 更新/发布时间（可见时）
- 核验级别 V0–V3
- `fit_score`
- `confidence_score`
- `recommendation_status`
- 优点/适配点
- 缺点/风险
- 红旗
- 待核验问题
- 2–6 张有决策价值的图片（Top 候选尽量满足）

## 图片 provenance

每张图尽量保存：

- `local_path`
- `source_url`
- `caption`
- `kind`

`rendering` 必须标成效果图；`user_photo` 才能表述为用户现场照片。房源页面图片默认表述为“来源页面图片，未现场核验”。

不要为了填满版面添加与候选无关的库存图。

## Candidate table columns

排名、项目、可点击的原始房源链接、区域、面积、月总成本/总价、元/㎡/天、Fit、Confidence、核验等级、价格异常、推荐动作。

主候选表的每一行必须至少提供一个可点击的 HTTP(S) 原始房源链接。链接只能直接取自已保留的 `listing_versions[].source_url` 或聚合后的 `source_urls`；不得按平台域名或项目名拼接 URL，不得把详情页静默替换成搜索页、城市入口页或内部详情卡锚点。内部锚点可以保留，但不能代替原始房源链接。候选没有可审计的 `source_url` 时，应显示“缺原始链接”，并由 HTML 自检阻止交付。

## Required sections

1. Executive summary
2. Search brief / assumptions
3. Dataset profile（来源覆盖、缺失率、基础分布）
4. Search depth / geographic counter-sampling（通道、页数、停止原因、项目反查）
5. Market calibration
6. Shortlist
7. Property cards
8. Cross-source verification matrix
9. Price anomalies
10. Near misses / excluded
11. Site visit plan
12. Field checklist
13. Methodology / data quality / limitations

主候选表不得被仅由低证据补漏源支撑的广告淹没。此类候选进入数量受控的“补充线索”区，并说明需要何种独立证据才能升级。报告必须展示高优先级来源的尝试状态、单平台集中度、实际检查页数/滚动批次、区域外对照和项目反查。只有条数而没有搜索深度记录时，必须明确标成覆盖未证明。

## Executive summary

只总结 Top 3–5，并明确动作：

- `site_visit_candidate`：可以进入踩点候选；
- `verify_first`：先完成指定核验；
- 不要把 `excluded` 放入推荐摘要。

## Visual language

- 推荐：清晰但不过度强调；
- 待核验：警示标签；
- 高风险：显著标记；
- 已排除：弱化显示；
- 不使用“100%真实”“绝对最低价”等不可证实表述。

## 技术要求

- 桌面/移动端可读；
- 可打印；
- 所有外部来源链接可点击；
- 默认本地图片使用相对路径；
- 不依赖必须联网加载的前端框架；
- JS 只用于排序、筛选、折叠等轻交互；
- 数据和结论从 JSON 渲染，不应在 HTML 中手工修正事实。
- `dataset_profile.json` 可以展示数据覆盖和缺失，但不得把候选广告分布误称为“上海市场总体分布”。

## 工作稿与最终稿

如果 `qa_report.json.summary.ready_for_final_report=false`，报告仍可生成供内部核验，但必须标为 `discovery_draft`。其他成熟度为 `research_shortlist`、`visit_ready`、`unit_confirmed`。BeautifulSoup 可用时还应满足 HTML QA。先修数据/证据或模板并重新运行流水线，再升级成熟度。
