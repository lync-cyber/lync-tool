# Workflow Contract

本文件定义技能执行时必须遵循的固定阶段、输入、输出和停止条件。不要在每次任务中重新发明流程。

## 固定阶段

0. `interview`：用 1–2 轮选择题确认会改变搜索边界的需求；写入 `search_brief.interview`。
1. `environment`：运行 `scripts/check_environment.py`，记录增强依赖可用性；缺少增强依赖时核心 JSON 流程仍可继续。
2. `brief`：写入并运行 `validate_brief.py`；有 blocker 时不得开始大规模采集。
3. `source_plan`：先把贝壳与链家分别写成 `critical` 必查主源，再由 LLM 根据本地市场选择其他来源。必须先在用户可见、可人工接管的浏览器中完成贝壳和链家；任一出现网站问题时立即停止并等待用户介入。
4. `market_calibration`：写入 `data/market_calibration.json`，至少记录两个独立市场基准或说明为何无法取得。
5. `collection`：浏览器将原始广告写入 `data/raw_listings.json`，并将每个搜索通道的页数、滚动批次、新增项目和停止原因写入 `data/collection_log.json`；不在采集阶段做激进去重。
6. `coverage`：运行 `validate_source_coverage.py` 和 `validate_collection_coverage.py`；贝壳或链家未完成时在 source QA 后硬停止且不生成报告。搜索引擎无结果不算平台尝试，首屏有足够广告也不算发现阶段完成。
7. `normalization`：运行 `normalize_listings.py`，统一成本口径。
8. `dataset_profile`：运行 `dataset_profile.py`，保存来源角色、集中度、缺失率和价格分布。
9. `dedupe`：运行 `dedupe_properties.py`，只自动合并强证据重复；疑似重复进入 review。
10. `price_anomaly`：运行 `detect_price_anomalies.py`。
11. `scoring`：运行 `score_candidates.py`，分开 fit/confidence，并把低证据单源候选降为补充线索。
12. `verification`：由 LLM 回看页面和交叉来源，更新原始证据后重跑。
13. `site_visit`：运行 `plan_visits.py` 后用地图核对；无实时数据时不得伪装精确分钟数。
14. `quality_gate`：合并 brief/source/dataset QA，确定报告成熟度。
15. `report`：生成 HTML；结构 blocker 未解决前只能交付工作稿。

## 强制不变量

- 原始广告必须保留 `source_url`、`captured_at`、原始报价、面积和来源平台。
- 自动 HTML 提取必须保留原始 HTML 路径、parser、字段候选来源和冲突 warning。
- pandas/BeautifulSoup 只提供确定性处理与输入兼容，不提升证据等级。
- 不允许把“没有找到证据”写成“不存在”。
- 价格低只触发核验，不直接判定虚假，也不直接提高推荐度。
- 多个平台出现同一广告，不等于多份独立证据。
- V2/V3 只能由明确的项目级/单元级核验证据提升，不能由脚本因广告数量自动推断。
- 关键硬条件为未知时必须保留 `unknown`，不得默认满足。
- 最终候选按物理物业/单元排名，不按广告条数排名。
- 贝壳和链家必须作为两个独立主源记录完成态；零结果可以接受，未尝试、受限或自行替代不可以。
- 必查主源出现登录、验证码、限流、超时、空白页、入口失效、筛选失灵或浏览器故障时，必须停止其他房源采集与报告生成并等待用户介入。
- 后台抓取、搜索索引或 HTTP 响应不计为高优先级房源平台的直接尝试，也不能单独确认验证码或登录墙；平台终态必须来自用户可见浏览器中的实际访问结果。
- 仅由低证据发现源支撑的候选不得大量占据主候选表。
- 用户选择综合成本时，预算硬筛选必须使用固定月总成本而不是裸租金。
- 用户的重点/优先区域默认是软偏好，不是硬边界；只有 `location_strategy.mode=hard_boundary` 才能排除区域外房源。
- 主要发现源不得以“首屏已取得20–50条”为停止理由；必须证明分页耗尽、访问受限或达到连续低新增饱和条件。
- 非硬边界任务必须完成全市基线和至少两个有逻辑的区域外对照搜索；用户点名项目必须逐一执行项目级反查。

## 推荐命令

初始化：

```bash
uv run python scripts/init_workspace.py <workspace> --city 上海 --asset-type 写字楼 --transaction-type rent
```

完成采集后运行整条确定性流水线：

```bash
uv run python scripts/run_pipeline.py <workspace>
```

若 QA 有 blocker，继续核验和修正 `raw_listings.json`，再重新运行，不要手工在 HTML 中修补结论。
