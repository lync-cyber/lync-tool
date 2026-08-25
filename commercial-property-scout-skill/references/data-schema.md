# Data Schema

## `search_brief.json`

推荐结构：

```json
{
  "city": "上海",
  "transaction_type": "rent",
  "asset_type": "写字楼",
  "business_use": "普通办公",
  "target_areas": ["徐汇滨江", "前滩"],
  "location_strategy": {
    "mode": "citywide_with_preferences",
    "preferred_areas": ["徐汇滨江", "前滩"],
    "hard_boundary_areas": [],
    "comparison_area_min": 2,
    "user_named_projects": []
  },
  "budget": {
    "cost_basis": "fixed_monthly_cost",
    "fixed_monthly_cost_ideal_rmb": 30000,
    "fixed_monthly_cost_max_rmb": 40000,
    "monthly_ideal_rmb": null,
    "monthly_max_rmb": null,
    "rent_sqm_day_max": null,
    "sale_total_ideal_rmb": null,
    "sale_total_max_rmb": null
  },
  "area_range": {"min_sqm": 180, "max_sqm": 300},
  "must_have": ["地铁步行10分钟内"],
  "hard_requirements": [
    {"id": "metro_walk", "field": "facts.metro_walk_minutes", "operator": "lte", "value": 10, "unknown_policy": "verify_first"}
  ],
  "nice_to_have": ["精装", "可注册"],
  "exclusions": ["商住楼"],
  "site_visit_constraints": {
    "dates": [],
    "start_location": "",
    "transport_mode": "public_transit"
  },
  "assumptions": [],
  "desired_report_maturity": "visit_ready",
  "interview": {"status": "completed", "decisions": [], "unresolved_critical": [], "completed_at": "..."}
}
```

`must_have` 最好逐步转化为结构化字段；若只能以自然语言保存，评分脚本只能判断“明确匹配”或“未知”，不能可靠判断否定语义。

`target_areas` 为兼容字段；新任务以 `location_strategy` 为准。用户仅说“重点/优先”时使用 `citywide_with_preferences`，不得把区域外候选硬排除。只有用户明确限定边界时使用 `hard_boundary` 并填写 `hard_boundary_areas`。

`budget.cost_basis` 必须由用户确认。`fixed_monthly_cost` 仅包含可确定的固定周期成本，不把水电、营业额提成等不可预测变量伪装成精确值。结构化价格下限可用 `hard_requirements` 的 `gt`，不要把“严格大于”改写成任意整数步长。

## `source_plan.json`

每个来源保存 `source_key`、名称、角色、任务级优先级、状态、URL、结果数和状态原因。`beike` 与 `lianjia` 必须分别存在，且均为 `critical` / `primary_discovery`；不得记录替代来源来抵消其中任一项。`coverage_policy.required_primary_source_keys` 保存必查键，默认是 `["beike", "lianjia"]`。

只有用户明确授权跳过时，才可在顶层 `required_source_waivers` 追加 `source_key`、`user_authorized_waiver: true` 和非空 `user_quote`。角色最低覆盖写入 `coverage_policy`，可按市场稀缺性调严；执行者不得自行调低必查源规则。

## `raw_listings.json`

每条记录代表一条具体网页广告或一份直接来源证据，而不是“一个物业”。至少保留：

- `source_id`
- `source_platform`
- `source_url`
- `captured_at`
- `listing_title`
- `transaction_type`
- `asset_type`
- `project_name`
- `address_raw`
- `district`
- `submarket`
- `area_sqm`
- `area_basis`
- `floor`
- `unit_or_room`
- `asking_price_raw`
- 可解析的标准价格字段
- `published_or_updated_at`
- `features`
- `business_constraints`
- `image_refs`
- `raw_evidence_notes`
- `verification_status`
- `red_flags`
- `property_fee_rmb_sqm_month` / `property_fee_rmb_month`
- `other_recurring_costs_rmb_month` / `aircon_fixed_rmb_month`
- `fixed_cost_components_confirmed`：仅当已确认租金、物业费以及适用于该单元的其他固定周期费用均已列明时为 `true`；缺失或 `false` 时即使能算出已知小计，`fixed_monthly_cost_status` 仍为 `partial`；
- `facts`：已由页面或人工证据支持的浅层结构化事实，例如 `metro_walk_minutes`、`public_access`；未知不填。

缺失字段写 `null`、空字符串或 `unknown`，不得编造。批量导入产生的未映射列保存到 `import_extra`；导入文件和映射保存在 `import_provenance`。

## `collection_log.json`

每条 `search_runs` 记录一次可审计的搜索通道，至少包含：

- `source_key` / `lane` / `query` / `area`
- `url`：实际完成筛选后的可见结果页 URL；`evidence_ref`：非空本地截图、保存页或页面提取证据，不能直接填远程 URL；
- `started_at` / `completed_at`
- `pages_examined`：分页数或等价滚动批次；
- `results_seen` / `new_unique_listings` / `new_unique_projects`
- `page_metrics`：每一页/批次一项，包含 `results_seen`、`new_unique_listings`、`new_unique_projects`、`new_qualified_listings`；主要发现源的非项目反查页还必须记录 `filters_verified: true`，表示翻页后已复核交易类型、面积和价格等筛选仍生效；项目数与房源数不可混用，逐页合计必须与运行总数一致；
- `consecutive_low_novelty_pages`
- `terminal_reason`：`pagination_exhausted`、`no_next_page`、`zero_results`、`saturation`、`hard_cap_with_reason` 或 `blocked`
- `notes`：特别是提前停止、项目别名和硬上限理由。

`lane` 可取 `citywide_baseline`、`preferred_area`、`comparison_area`、`project_lookup`、`transit_corridor`、`map_search`。平台显示的总结果数不能替代实际检查页数。

`project_lookup` 按规范化后的不同项目查询词计数；重复运行、重复 `run_id` 或复用同一 URL 与证据的完全相同搜索不能增加覆盖计数。`coverage_policy` 只能把 Skill 默认下限调严，不能调低或关闭证据检查。

## `page_extract`

`extract_saved_html.py` 的输出代表“页面解析证据”，不是房源事实。至少包含：

- `html_file` / `parsed_at` / `parser`
- `source_url` / `canonical_url`
- `title` / `description`
- `field_candidates`：每个候选带 `value/source/confidence/evidence`
- `image_candidates`：只登记 URL，不自动下载
- `visible_text_excerpt`
- `jsonld`
- `extraction_warnings`

字段冲突必须保留，不要只保留最低价格或最大面积。

## `dataset_profile.json`

由 `dataset_profile.py` 生成，持久保存：记录数、来源分布、区域分布、关键字段缺失率、面积/租金/售价的分位数和可用时的区域价格汇总。它用于描述“当前采集数据是什么样”，不能替代市场基准。

## 图片 `image_refs`

推荐使用对象，不推荐只存字符串：

```json
{
  "local_path": "assets/images/src_xxx_interior_01.jpg",
  "source_url": "https://example.com/listing/123",
  "caption": "室内主空间，页面截图",
  "kind": "interior"
}
```

`kind` 建议值：`listing_page`、`interior`、`exterior`、`street`、`public_area`、`map`、`floorplan`、`rendering`、`user_photo`、`other`。

效果图必须标 `rendering`；用户现场照片标 `user_photo`；来源页面图片未现场核验时不能写成“现场实拍”。

## `market_calibration.json`

```json
{
  "benchmarks": [
    {
      "name": "某机构 2026Q2 上海办公市场",
      "source": "JLL",
      "url": "https://...",
      "captured_at": "...",
      "scope": "上海甲级办公，CBD",
      "price_band": "...",
      "price_basis": "名义/净有效/未知",
      "notes": "不能直接套用到乙级写字楼"
    }
  ]
}
```

## `properties.json`

由脚本聚合生成。一个对象应代表一个物理物业/单元候选，并保留：

- `property_id`
- 聚合后的地址、面积、楼层、单元
- 聚合价格及最小/最大值
- `source_ids` / `source_urls` / `source_platforms`
- `listing_versions`
- `verification_level`
- `price_anomaly`
- `fixed_monthly_cost_rmb` / `fixed_monthly_cost_status`
- `source_roles` / `presentation_tier`
- `hard_filter`
- `fit_score`
- `confidence_score`
- `decision_score`
- `ranking_gates`
- `recommendation_status`

不要直接手写最终分数；应尽量修改证据或 brief 后重新运行脚本。
