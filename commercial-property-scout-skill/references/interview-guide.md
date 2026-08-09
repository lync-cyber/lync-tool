# Requirement Interview

在开始浏览房源前完成一次短访谈。目标是确认会改变搜索结果的决策，不是穷举用户偏好。

## 提问方式

- 优先使用宿主环境的选择题工具；每轮只问 1–3 题，每题提供 2–3 个互斥选项，并允许用户自由补充。
- 把建议选项放在第一位并说明取舍。已有答案不要重复询问。
- 第一轮只问会改变搜索边界的问题；第二轮仅补齐仍会影响硬筛选或交付深度的缺口。
- 用户明确要求立即搜索时，可以把访谈标记为 `skipped_by_user`，但必须列出假设，并把未确认硬条件保持为 `unknown`。

## 第一轮：搜索边界

根据上下文生成选项，优先确认：

1. **交易与用途**：租赁/购买，以及实际经营或使用方式。
2. **成本口径**：固定月总成本上限、仅租金上限，或暂不设上限。租赁任务默认建议“固定月总成本”，包括租金、物业费和已知固定周期费用。
3. **位置约束**：指定区域、交通走廊/站点、通勤半径，或全城择优。

## 第二轮：硬条件与交付深度

只在尚未明确时询问：

- 面积范围及可接受弹性；
- 哪些经营/使用条件属于“一票否决”；
- 时间、租期、装修、楼层等执行约束；
- 交付目标：`research_shortlist`（线上研究候选）、`visit_ready`（可安排踩点）、`unit_confirmed`（具体单元已确认）。

## 写入 brief

把结果写入 `data/search_brief.json`：

- `interview.status`：`completed` 或 `skipped_by_user`；
- `interview.decisions`：用户已确认的关键选择；
- `interview.unresolved_critical`：仍会改变硬筛选的未知项；
- `budget.cost_basis`：租赁优先使用 `fixed_monthly_cost`，只有用户明确表示时才用 `base_rent`；
- 可结构化的一票否决条件写入 `hard_requirements`，不要只放进自然语言 `must_have`。

`hard_requirements` 使用通用规则，不绑定具体物业类型：

```json
{
  "id": "metro_walk",
  "label": "地铁步行不超过10分钟",
  "field": "facts.metro_walk_minutes",
  "operator": "lte",
  "value": 10,
  "unknown_policy": "verify_first"
}
```

允许的 `operator`：`eq`、`neq`、`lt`、`lte`、`gt`、`gte`、`in`、`contains_any`、`truthy`。严格大于/小于必须使用 `gt`/`lt`，不要用人为加减 1 的方式近似。未知值默认进入 `verify_first`，不得推定满足。
