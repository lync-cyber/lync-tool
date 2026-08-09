# Saved HTML Extraction Rules

## 目标

`scripts/extract_saved_html.py` 用于把浏览器 worker 已保存的详情页 HTML 转成可复查的结构化“页面提取结果”，减少重复抄录。它不是通用爬虫，不访问网络。

## 提取层级

1. `application/ld+json`：保留所有可解析对象，同时尝试识别 `Offer`、`Product`、`Place`、`Apartment`、`RealEstateListing` 等常见结构。
2. canonical / OpenGraph / Twitter meta：标题、描述、canonical URL、图片。
3. 页面正文：删除 script/style/noscript/template/svg 等非正文节点后生成压缩可见文本。
4. DOM 图片：记录 `src`、`data-src`、`data-original`、`srcset` 等候选，使用 base URL 解析相对路径。
5. 保守字段候选：面积、元/㎡/天、月租、总价、项目名/地址只在有清晰标签或结构化字段时填入。

## 输出原则

每个字段候选保存：

- `value`
- `source`（jsonld/meta/labelled_text/regex）
- `confidence`（high/medium/low）
- `evidence`（短证据片段）

只有 high/medium 且无冲突的字段才允许通过 `--emit-listing` 写入 raw listing stub。低置信字段保留在 `page_extract` 中供 worker 判断。

## 冲突处理

同一页面存在多个价格或面积时不要“选最低价”。输出全部候选，并把冲突加入 `extraction_warnings`。worker 根据具体单元、标签和页面上下文确认后再写回 raw 数据。

## 图片

HTML 解析只登记图片 URL，不自动下载。需要进入最终报告的图片由浏览器或合法下载步骤取得本地文件，再使用 `register_image.py` 写入 provenance。
