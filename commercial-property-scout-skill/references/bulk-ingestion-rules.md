# Bulk Ingestion Rules

## 何时使用 `bulk_import.py`

用户提供表格、CSV、历史导出、经纪清单、项目清单，或 worker 一次性得到结构化表格时，优先批量导入，不要逐行手写 JSON。

支持：CSV、TSV、JSON、JSONL/NDJSON；增强环境支持 XLSX/XLS 和 HTML table。字段别名使用 `field-aliases.json`，不要每次重新生成列名映射规则。

默认命令：

```bash
uv run python scripts/bulk_import.py input.xlsx \
  -o <workspace>/data/raw_listings.json \
  --platform "来源平台" --asset-type 写字楼 --transaction-type rent --append
```

字段名特殊时创建一次临时 mapping JSON：

```json
{
  "project_name": "项目/楼宇",
  "area_sqm": "建筑面积(㎡)",
  "asking_price_raw": "业主报价",
  "source_url": "详情页"
}
```

然后使用 `--mapping`。

## 安全规则

- 未映射列保存在 `import_extra`，不要静默丢弃；
- 映射本身不证明字段真实；
- 批量导入后必须运行 normalize / QA；
- 多个表格中的同一 URL 只 exact-dedupe，物理物业去重留给 `dedupe_properties.py`；
- Excel/HTML 表格解析失败时回退 CSV/JSON，不要为了导入绕过站点访问限制。
