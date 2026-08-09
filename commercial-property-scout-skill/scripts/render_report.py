#!/usr/bin/env python3
from __future__ import annotations
import argparse
import html
import json
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from _common import clean_text, load_json, now_iso


def esc(v): return html.escape(clean_text(v), quote=True)
def fmt_money(v):
    if v is None: return "—"
    try: return f"¥{float(v):,.0f}"
    except Exception: return esc(v)
def fmt_num(v, d=2):
    if v is None: return "—"
    try: return f"{float(v):,.{d}f}"
    except Exception: return esc(v)

STATUS_LABELS={"verify_first":"先电话/书面核验","site_visit_candidate":"可安排踩点","excluded":"已排除"}
ROLE_LABELS={"primary_discovery":"主要发现源","broad_discovery":"补充发现源","benchmark":"市场基准","verification":"反向核验源"}
PRIORITY_LABELS={"critical":"必须尝试","high":"高优先级","normal":"普通"}
SOURCE_STATUS_LABELS={"completed_with_results":"已访问并取得结果","completed_zero_results":"已访问，无结果","blocked_login":"登录受阻","blocked_captcha":"验证码待处理","access_limited":"访问受限","unavailable":"当前不可用","skipped_with_reason":"计划调整（不计覆盖）","planned":"待访问","in_progress":"访问中"}
FIELD_LABELS={"building_area":"建筑面积","complete":"租金与物业费已知","partial":"费用不完整","same_submarket_area±30%":"同商圈、面积±30%","same_district_area±30%":"同区、面积±30%","insufficient_comparables":"可比样本不足"}
ANOMALY_LABELS={"within_expected_band":"价格在样本常见区间","low_15_20pct":"低于可比中位数15%–20%","low_20_30pct":"低于可比中位数20%–30%","low_ge_30pct":"低于可比中位数30%以上","unknown":"可比样本不足"}
TOKEN_LABELS={
    "fixed_monthly_cost":"固定月总成本尚不完整","hard_requirement:metro_walk":"尚未取得地图步行时间",
    "must_have:地铁步行10分钟内":"地铁步行10分钟内尚未证实","must_have:房屋及物业规则允许办公或面向公众的共享空间/自习室用途":"物业允许公众自习室用途尚未证实",
    "must_have:公众访客可正常进出":"公众访客通行尚未证实","must_have:晚间营业时电梯、空调和门禁可用或可独立解决":"晚间门禁、电梯及空调尚未证实",
    "missing_property_fee":"缺物业费","missing_specific_unit":"缺具体房号","business_use_unknown":"公众经营用途未知","night_access_unknown":"晚间运营条件未知",
    "public_operation_unknown":"公众经营条件未知","description_area_conflict":"面积文案冲突","syndicated_ad_not_independent":"跨平台内容疑似同源转载",
    "templated_broker_copy":"经纪文案模板化","very_low_price_verify":"低价需复核","detail_body_blank":"详情正文未成功加载","missing_images":"缺少有效图片",
    "possible_duplicate_ads":"可能存在重复广告","cross_source_price_spread_ge_20pct":"同项目广告价差较大","budget_headroom_small":"预算余量较小",
    "price_lightly_below_comparables":"价格略低于可比样本","price_materially_below_comparables":"价格明显低于可比样本","price_extremely_below_comparables_requires_explanation":"价格异常偏低，需解释",
    "title_unit_scope_conflict":"标题与单元范围冲突","multi_area_marketing":"同页营销多个面积","fixed_monthly_cost_budget_exceeded":"固定月总成本超过预算",
    "fixed_monthly_cost_components":"固定月费组成尚未全部确认"
}

def human_token(value):
    text=clean_text(value)
    return TOKEN_LABELS.get(text, STATUS_LABELS.get(text, ANOMALY_LABELS.get(text, text.replace("_", " "))))

def cost_html(p):
    value=p.get("fixed_monthly_cost_rmb") if p.get("transaction_type")=="rent" else p.get("sale_total_rmb")
    if value is None:
        rent=p.get("rent_rmb_month")
        return f'<strong>{fmt_money(rent)}</strong><small>仅租金，物业及其他固定费待补</small>' if rent is not None else '<strong>待核实</strong><small>缺完整报价</small>'
    note="已知固定月成本" if p.get("fixed_monthly_cost_status")=="complete" else "部分成本"
    return f'<strong>{fmt_money(value)}</strong><small>{esc(note)}</small>'

def link(url, label="来源"):
    if not url: return "—"
    return f'<a href="{esc(url)}" target="_blank" rel="noopener noreferrer">{esc(label)}</a>'

def source_links(p, limit=4):
    """Render retained listing source_url values without inventing or rewriting URLs."""
    pairs=[]
    seen=set()
    for version in p.get("listing_versions") or []:
        url=clean_text(version.get("source_url"))
        parsed=urlparse(url)
        if parsed.scheme not in {"http","https"} or not parsed.netloc or url in seen: continue
        seen.add(url)
        pairs.append((url, clean_text(version.get("source_platform")) or "原始房源"))
    platforms=p.get("source_platforms") or []
    for index, url in enumerate(p.get("source_urls") or []):
        url=clean_text(url)
        parsed=urlparse(url)
        if parsed.scheme not in {"http","https"} or not parsed.netloc or url in seen: continue
        seen.add(url)
        label=clean_text(platforms[index]) if index < len(platforms) else "原始房源"
        pairs.append((url, label or "原始房源"))
    return " · ".join(link(url,label) for url,label in pairs[:limit]) or '<span class="risk">缺原始链接</span>'

def tags(items, cls=""):
    vals = [clean_text(x) for x in (items or []) if clean_text(x)]
    return " ".join(f'<span class="tag {cls}">{esc(x)}</span>' for x in vals)

def image_html(ref, report_dir: Path):
    if isinstance(ref, str):
        src, caption, source_url, kind = ref, "", "", ""
    elif isinstance(ref, dict):
        src = ref.get("local_path") or ref.get("path") or ref.get("url") or ref.get("source_url") or ""
        caption = ref.get("caption") or ref.get("type") or ""
        source_url = ref.get("source_url") or ""
        kind = ref.get("kind") or ref.get("image_type") or ""
    else:
        return ""
    if not src: return ""
    if src.startswith(("http://", "https://")):
        img_src = src
    else:
        p = Path(src)
        if p.is_absolute():
            try: img_src = str(p.relative_to(report_dir))
            except Exception: img_src = p.as_uri() if p.exists() else str(p)
        else:
            img_src = src
    badge = f'<span class="img-kind">{esc(kind)}</span>' if kind else ""
    cap = f'<figcaption>{badge}{esc(caption)}' + (f' · {link(source_url,"原图来源")}' if source_url else "") + '</figcaption>'
    return f'<figure><a href="{esc(img_src)}" target="_blank"><img loading="lazy" src="{esc(img_src)}" alt="{esc(caption or "房源图片")}"></a>{cap}</figure>'

def report_title(brief):
    city=clean_text(brief.get("city"))
    asset=clean_text(brief.get("asset_type")) or "商业地产"
    use=clean_text(brief.get("business_use"))
    subject=use if use and len(use) <= 24 else asset
    return " ".join(x for x in (city,subject,"选址决策报告") if x)

def executive(props):
    ranked = sorted([p for p in props if p.get("rank") and p.get("presentation_tier", "primary_shortlist") == "primary_shortlist"], key=lambda p: p.get("rank"))[:3]
    if not ranked:
        return "<p>当前没有满足最终排序条件的候选；请先处理待核验项或放宽条件。</p>"
    cards=[]
    for p in ranked:
        status = p.get("recommendation_status")
        facts=p.get("facts") or {}
        metro=" / ".join(x for x in [clean_text(facts.get("metro_line")), clean_text(facts.get("metro_station"))] if x)
        if facts.get("metro_distance_meters") is not None: metro += f' · 页面约{facts.get("metro_distance_meters")}米'
        gaps=[human_token(x) for x in (p.get("hard_filter") or {}).get("unknowns",[])[:3]]
        cards.append(f'<article class="decision-card"><div class="eyebrow">#{p.get("rank")} · {esc(STATUS_LABELS.get(status,status))}</div><h3>{esc(p.get("project_name") or p.get("address_raw"))}</h3><div class="decision-cost">{cost_html(p)}</div><p>{fmt_num(p.get("area_sqm"),0)}㎡ · {esc(p.get("submarket"))}'+(f' · {esc(metro)}' if metro else '')+f'</p><p class="muted">证据 {esc(p.get("verification_level"))} · 匹配 {fmt_num(p.get("fit_score"),1)} · 可信 {fmt_num(p.get("confidence_score"),1)}</p><p class="source-action">{source_links(p,2)}</p><p class="gap"><b>先核实：</b>{esc("；".join(gaps))}</p></article>')
    return '<div class="notice risk-note"><strong>当前没有可直接踩点的房源。</strong> 以下是最值得先完成电话与书面核验的三个候选；未知项未按满足处理。</div><div class="decision-grid">'+''.join(cards)+'</div>'

def brief_html(brief):
    rows=[]
    for k,label in [("city","城市"),("transaction_type","交易"),("asset_type","物业"),("business_use","用途")]:
        value=brief.get(k)
        if k=="transaction_type": value={"rent":"租赁","sale":"购买"}.get(value,value)
        rows.append(f'<tr><th>{label}</th><td>{esc(value) or "页面未显示"}</td></tr>')
    strategy=brief.get("location_strategy") or {}
    mode=clean_text(strategy.get("mode")) or "citywide_with_preferences"
    preferred=[clean_text(x) for x in (strategy.get("preferred_areas") or brief.get("target_areas") or []) if clean_text(x)]
    boundaries=[clean_text(x) for x in (strategy.get("hard_boundary_areas") or []) if clean_text(x)]
    if mode=="hard_boundary":
        location_text="硬边界："+("、".join(boundaries) or "尚未填写")
    elif mode=="citywide_with_preferences":
        location_text="全域开放"+(f"；优先：{'、'.join(preferred)}" if preferred else "")
    else:
        location_text="全域开放，无指定区域偏好"
    rows.append(f'<tr><th>区域</th><td>{esc(location_text)}</td></tr>')
    budget=brief.get("budget") or {}; area=brief.get("area_range") or {}
    rows.append(f'<tr><th>固定月成本</th><td>理想约 {fmt_money(budget.get("fixed_monthly_cost_ideal_rmb"))}；硬上限 {fmt_money(budget.get("fixed_monthly_cost_max_rmb"))}</td></tr>')
    rows.append(f'<tr><th>面积</th><td>{fmt_num(area.get("min_sqm"),0)}–{fmt_num(area.get("max_sqm"),0)}㎡</td></tr>')
    rows.append(f'<tr><th>必须满足</th><td>{tags(brief.get("must_have"),"good") or "—"}</td></tr>')
    rows.append(f'<tr><th>偏好</th><td>{tags(brief.get("nice_to_have")) or "—"}</td></tr>')
    rows.append(f'<tr><th>排除</th><td>{tags(brief.get("exclusions"),"risk") or "—"}</td></tr>')
    if brief.get("assumptions"):
        rows.append(f'<tr><th>执行假设</th><td>{tags(brief.get("assumptions"),"warn")}</td></tr>')
    return '<table class="kv">'+''.join(rows)+'</table>'

def dataset_profile_html(profile):
    if not profile:
        return '<p class="muted">未生成数据 profile。</p>'
    rows = []
    rows.append(f'<tr><th>原始/规范化记录</th><td>{esc(profile.get("row_count"))}</td></tr>')
    rows.append(f'<tr><th>分析引擎</th><td>{esc(profile.get("engine"))}</td></tr>')
    platforms = profile.get("counts_by_platform") or {}
    ptxt = "；".join(f"{clean_text(k)} {v}" for k, v in list(platforms.items())[:10])
    rows.append(f'<tr><th>来源覆盖</th><td>{esc(ptxt) or "—"}</td></tr>')
    roles = profile.get("counts_by_source_role") or {}
    rows.append(f'<tr><th>来源角色</th><td>{esc("；".join(f"{ROLE_LABELS.get(k,k)} {v}" for k,v in roles.items())) or "页面未显示"}</td></tr>')
    concentration = profile.get("source_concentration") or {}
    if concentration:
        rows.append(f'<tr><th>来源集中度</th><td>{esc(concentration.get("dominant_platform"))} {float(concentration.get("dominant_share") or 0):.0%}</td></tr>')
    miss = profile.get("missingness") or {}
    critical = []
    for key, label in (("source_url","来源链接"),("project_name","项目名"),("area_sqm","面积"),("asking_price_raw","原始报价")):
        item = miss.get(key) or {}
        ratio = item.get("ratio")
        if ratio is not None:
            critical.append(f"{label} {float(ratio):.0%}")
    rows.append(f'<tr><th>关键字段缺失率</th><td>{esc("；".join(critical)) or "—"}</td></tr>')
    numeric = profile.get("numeric_summary") or {}
    rent = numeric.get("rent_rmb_sqm_day") or {}
    if rent.get("count"):
        rows.append(f'<tr><th>租金样本</th><td>n={esc(rent.get("count"))}；P25 {fmt_num(rent.get("p25"),2)}；中位 {fmt_num(rent.get("median"),2)}；P75 {fmt_num(rent.get("p75"),2)} 元/㎡/天</td></tr>')
    return '<table class="kv">'+''.join(rows)+'</table>'

def calibration_html(cal):
    if not cal: return '<p class="muted">未提供结构化市场校准数据；报告中的价格异常仅基于候选集合的可比样本。</p>'
    if isinstance(cal, dict) and "benchmarks" in cal: items=cal["benchmarks"]
    else: items=cal if isinstance(cal,list) else [cal]
    cards=[]
    for x in items:
        if not isinstance(x,dict): continue
        cards.append(f'<div class="mini"><strong>{esc(x.get("name") or x.get("source") or "基准")}</strong><br>{esc(x.get("price_band") or x.get("summary") or "")}<br><span class="muted">{esc(x.get("scope") or "")}</span> {link(x.get("url"),"来源")}</div>')
    return '<div class="grid">'+''.join(cards)+'</div>' if cards else '<p>—</p>'

def source_plan_html(plan):
    sources = (plan or {}).get("sources") or []
    if not sources:
        return '<p class="muted">未提供来源访问登记。</p>'
    rows = []
    for s in sources:
        priority = clean_text(s.get("priority"))
        cls = "good" if s.get("status") == "completed_with_results" else "warn"
        rows.append('<tr>'+''.join([
            f'<td>{link(s.get("url"), s.get("display_name") or s.get("source_key") or "来源")}</td>',
            f'<td>{esc(ROLE_LABELS.get(s.get("role"),s.get("role")))}</td>',
            f'<td>{tags([PRIORITY_LABELS.get(priority,priority)], "warn" if priority in ("critical", "high") else "")}</td>',
            f'<td>{tags([SOURCE_STATUS_LABELS.get(s.get("status"),s.get("status"))], cls)}</td>',
            f'<td>{esc(s.get("result_count"))}</td>',
            f'<td class="wrap-cell">{esc(s.get("status_reason"))}</td>',
            f'<td>{esc(s.get("updated_at"))}</td>'
        ])+'</tr>')
    head='<thead><tr><th>来源/入口</th><th>角色</th><th>优先级</th><th>访问状态</th><th>结果数</th><th>实际访问结果</th><th>记录时间</th></tr></thead>'
    return '<div class="table-wrap"><table>'+head+'<tbody>'+''.join(rows)+'</tbody></table></div>'

def collection_coverage_html(log, qa):
    runs=(log or {}).get("search_runs") or []
    summary=(qa or {}).get("summary") or {}
    if not runs:
        return '<div class="notice risk-note"><strong>没有搜索深度记录。</strong> 无法证明已翻页、覆盖对照区域或执行项目反查；当前结果不得视为覆盖充分。</div>'
    lane_labels={"citywide_baseline":"全市基线","preferred_area":"偏好区域","comparison_area":"对照区域","project_lookup":"项目反查","transit_corridor":"地铁走廊","map_search":"地图补漏"}
    terminal_labels={"pagination_exhausted":"分页耗尽","no_next_page":"无下一页","zero_results":"零结果","saturation":"连续低新增，达到饱和","hard_cap_with_reason":"达到有理由的任务上限","blocked":"访问受阻"}
    rows=[]
    for x in runs:
        scope=clean_text(x.get("query")) or clean_text(x.get("area")) or "无关键词"
        rows.append(f'<tr><td>{esc(x.get("source_key"))}</td><td>{esc(lane_labels.get(x.get("lane"),x.get("lane")))}</td><td class="wrap-cell">{esc(scope)}</td><td>{esc(x.get("pages_examined"))}</td><td>{esc(x.get("results_seen"))}</td><td>{esc(x.get("new_unique_listings"))} / {esc(x.get("new_unique_projects"))}</td><td class="wrap-cell">{esc(terminal_labels.get(x.get("terminal_reason"),x.get("terminal_reason")))}</td></tr>')
    status='覆盖闸门已通过' if summary.get("coverage_ready") else f'覆盖闸门未通过：{summary.get("blockers",0)} 个阻断项'
    cls='good' if summary.get("coverage_ready") else 'risk'
    head='<thead><tr><th>来源</th><th>搜索通道</th><th>查询/区域</th><th>页/批次</th><th>浏览结果</th><th>新增房源/项目</th><th>停止原因</th></tr></thead>'
    return f'<p><span class="tag {cls}">{esc(status)}</span> 对照区域 {esc(summary.get("comparison_area_count"))} 个；项目反查 {esc(summary.get("project_lookup_count"))} 次。</p><div class="table-wrap"><table>{head}<tbody>{"".join(rows)}</tbody></table></div>'

def verification_context_html(context):
    if not context:
        return '<p class="muted">未提供专项用途与合规核验记录。</p>'
    method = esc(context.get("screening_method"))
    reviews = []
    for x in context.get("priority_candidate_reviews") or []:
        reviews.append('<tr>'+''.join([
            f'<td><strong>{esc(x.get("project"))}</strong></td>',
            f'<td class="wrap-cell">{esc(x.get("known_cost"))}</td>',
            f'<td class="wrap-cell">{esc(x.get("transport"))}</td>',
            f'<td class="wrap-cell">{esc(x.get("registration"))}</td>',
            f'<td class="wrap-cell">{esc(x.get("public_and_night_use"))}</td>',
            f'<td class="wrap-cell">{esc(x.get("space_and_fitout"))}</td>',
            f'<td class="wrap-cell">{esc(x.get("decision"))}</td>'
        ])+'</tr>')
    review_head='<thead><tr><th>候选</th><th>固定成本</th><th>交通</th><th>登记</th><th>公众/晚间运营</th><th>空间与改造</th><th>动作</th></tr></thead>'
    review_table='<div class="table-wrap"><table>'+review_head+'<tbody>'+''.join(reviews)+'</tbody></table></div>' if reviews else '<p>—</p>'
    compliance=[]
    for x in context.get("compliance_findings") or []:
        compliance.append(f'<div class="mini"><strong>{esc(x.get("topic"))}</strong><p>{esc(x.get("finding"))}</p><p><b>对本次决策的影响：</b>{esc(x.get("impact"))}</p><p>{link(x.get("url"), x.get("source_label") or "官方依据")}</p></div>')
    return (f'<p>{method}</p>' if method else '') + '<h3>重点候选专项复核</h3>' + review_table + '<h3>登记、消防与经营合规</h3><div class="grid">'+''.join(compliance)+'</div>'

def shortlist_table(props):
    ranked=sorted([p for p in props if p.get("presentation_tier", "primary_shortlist") == "primary_shortlist"],key=lambda p:(p.get("rank") is None,p.get("rank") or 9999))
    rows=[]
    for p in ranked:
        if p.get("recommendation_status")=="excluded" and not p.get("rank"): continue
        anomaly=(p.get("price_anomaly") or {}).get("label","unknown")
        facts=p.get("facts") or {}
        metro=" ".join(x for x in [clean_text(facts.get("metro_line")), clean_text(facts.get("metro_station"))] if x)
        if facts.get("metro_distance_meters") is not None: metro += f'（页面约{facts.get("metro_distance_meters")}米）'
        cost=p.get("fixed_monthly_cost_rmb")
        cost_text=fmt_money(cost) if cost is not None else f'{fmt_money(p.get("rent_rmb_month"))}租金；总成本待补'
        project_label=esc(p.get("project_name") or p.get("address_raw"))
        project_cell=f'<a href="#{esc(p.get("property_id"))}">{project_label}</a>' if p.get("rank") and p.get("rank") <= 5 else project_label
        rows.append('<tr>'+''.join([
            f'<td>{p.get("rank") or "—"}</td>', f'<td>{project_cell}</td>',
            f'<td class="source-link">{source_links(p,3)}</td>',
            f'<td>{esc(p.get("district"))} / {esc(p.get("submarket"))}</td>', f'<td>{fmt_num(p.get("area_sqm"),0)}㎡</td>',
            f'<td class="wrap-cell">{cost_text}</td>', f'<td>{fmt_num(p.get("rent_rmb_sqm_day"),2)}</td>', f'<td class="wrap-cell">{esc(metro) or "距离待核实"}</td>',
            f'<td>{fmt_num(p.get("fit_score"),1)} / {fmt_num(p.get("confidence_score"),1)}</td>', f'<td>{esc(p.get("verification_level"))}</td>',
            f'<td class="wrap-cell">{esc(ANOMALY_LABELS.get(anomaly,anomaly))}</td>', f'<td>{esc(STATUS_LABELS.get(p.get("recommendation_status"),p.get("recommendation_status")))}</td>'
        ])+'</tr>')
    head='<thead><tr><th>#</th><th>项目</th><th>原始房源</th><th>区域</th><th>面积</th><th>月成本</th><th>元/㎡/天</th><th>地铁证据</th><th>匹配/可信</th><th>证据</th><th>价格判断</th><th>动作</th></tr></thead>'
    primary=''.join(rows[:10]); rest=''.join(rows[10:])
    table='<div class="table-wrap"><table id="shortlist">'+head+'<tbody>'+primary+'</tbody></table></div>'
    if rest:
        table+=f'<details class="audit-fold"><summary>查看其余 {len(rows)-10} 个初筛候选（审计附录）</summary><div class="table-wrap"><table>{head}<tbody>{rest}</tbody></table></div></details>'
    return table

def property_cards(props, report_dir):
    cards=[]
    ranked=sorted(props,key=lambda p:(p.get("rank") is None,p.get("rank") or 9999,-float(p.get("decision_score") or 0)))
    for p in ranked:
        if p.get("presentation_tier", "primary_shortlist") != "primary_shortlist": continue
        if p.get("recommendation_status")=="excluded" and not p.get("rank"): continue
        if not p.get("rank") or p.get("rank") > 5: continue
        flags=p.get("red_flags") or []
        imgs=''.join(image_html(x,report_dir) for x in (p.get("image_refs") or [])[:6]) or '<p class="muted">暂无本地或可引用图片。</p>'
        versions=p.get("listing_versions") or []
        primary=versions[0] if versions else {}
        sources=source_links(p,8)
        anomaly=p.get("price_anomaly") or {}
        hard=p.get("hard_filter") or {}
        cards.append(f'''<article class="card property" id="{esc(p.get("property_id"))}">
<div class="property-head"><div><h3>{('#'+str(p.get('rank'))+' ') if p.get('rank') else ''}{esc(p.get('project_name') or p.get('address_raw'))}</h3><p class="muted">{esc(p.get('address_raw'))} · {esc(p.get('floor'))} {esc(p.get('unit_or_room'))}</p></div><div>{tags([STATUS_LABELS.get(p.get('recommendation_status'),p.get('recommendation_status')),p.get('verification_level')],'good' if p.get('recommendation_status')=='site_visit_candidate' else 'warn')}</div></div>
<div class="metrics"><div><b>{fmt_num(p.get('area_sqm'),0)}㎡</b><span>面积</span></div><div><b>{fmt_money(p.get('fixed_monthly_cost_rmb') if p.get('transaction_type')=='rent' else p.get('sale_total_rmb'))}</b><span>固定月总成本 / 总价</span></div><div><b>{fmt_num(p.get('rent_rmb_sqm_day'),2)}</b><span>元/㎡/天</span></div><div><b>{fmt_num(p.get('fit_score'),1)}</b><span>Fit</span></div><div><b>{fmt_num(p.get('confidence_score'),1)}</b><span>Confidence</span></div></div>
<div class="gallery">{imgs}</div>
<div class="grid"><div><h4>证据与价格</h4><p>来源：{sources}</p><p>抓取：{esc(primary.get('captured_at')) or '页面未显示'}；发布/更新：{esc(primary.get('published_or_updated_at')) or '页面未显示'}</p><p>原始报价：{esc(primary.get('asking_price_raw')) or '页面未显示'}</p><p>资产/面积口径：{esc(p.get('asset_type')) or '页面未显示'} / {esc(FIELD_LABELS.get(p.get('area_basis'),p.get('area_basis'))) or '页面未显示'}；室号：{esc(p.get('unit_or_room')) or '未提供'}</p><p>物业费：{(fmt_num(p.get('property_fee_rmb_sqm_month'),2)+' 元/㎡/月') if p.get('property_fee_rmb_sqm_month') is not None else '页面未显示'}；费用完整性：{esc(FIELD_LABELS.get(p.get('fixed_monthly_cost_status'),p.get('fixed_monthly_cost_status'))) or '未知'}</p><p>独立来源：{p.get('independent_source_count',0)}；报价区间：{fmt_num(p.get('rent_rmb_sqm_day_min'),2)}–{fmt_num(p.get('rent_rmb_sqm_day_max'),2)} 元/㎡/天</p><p>可比范围：{esc(FIELD_LABELS.get(anomaly.get('comparable_scope'),anomaly.get('comparable_scope')))}；中位数：{fmt_num(anomaly.get('comparable_median'),2)}；偏离：{(fmt_num((anomaly.get('delta_vs_median') or 0)*100,1)+'%') if anomaly.get('delta_vs_median') is not None else '无可比值'}</p><p>适配线索：{tags(p.get('features')) or '页面未显示'}</p></div>
<div><h4>风险与待核验</h4>{tags([human_token(x) for x in flags],'risk') or '<span class="muted">无已记录红旗</span>'}<p><b>签约前必须确认：</b>{esc('；'.join(human_token(x) for x in (hard.get('unknowns') or []))) or '无'}</p><p><b>已触发排除：</b>{esc('；'.join(human_token(x) for x in (hard.get('failures') or []))) or '无'}</p><p><b>页面证据备注：</b>{esc(primary.get('raw_evidence_notes')) or '无补充说明'}</p></div></div>
</article>''')
    return ''.join(cards)

def verification_matrix(props):
    rows=[]
    for p in sorted(props,key=lambda x:x.get("rank") or 9999):
        if not p.get("rank"): continue
        versions=p.get("listing_versions") or []
        price_bits=[]
        for v in versions:
            price=v.get("rent_rmb_sqm_day") if p.get("transaction_type")=="rent" else v.get("sale_rmb_sqm")
            price_bits.append(f'{esc(v.get("source_platform"))}: {fmt_num(price,2)}')
        rows.append(f'<tr><td>{p.get("rank")}</td><td>{esc(p.get("project_name"))}</td><td>{source_links(p,4)}</td><td>{esc("；".join(price_bits))}</td><td>{esc(p.get("verification_level"))}</td></tr>')
    head='<thead><tr><th>#</th><th>项目</th><th>来源</th><th>各来源报价</th><th>证据等级</th></tr></thead>'
    main='<div class="table-wrap"><table>'+head+'<tbody>'+''.join(rows[:10])+'</tbody></table></div>'
    if len(rows)>10:
        main+=f'<details class="audit-fold"><summary>查看其余 {len(rows)-10} 个候选的来源矩阵</summary><div class="table-wrap"><table>{head}<tbody>{"".join(rows[10:])}</tbody></table></div></details>'
    return main

def anomalies_html(props):
    xs=[p for p in props if (p.get("price_anomaly") or {}).get("label") in ("low_15_20pct","low_20_30pct","low_ge_30pct")]
    if not xs: return '<p>未发现达到默认低价预警阈值的候选。</p>'
    return '<ul>'+''.join(f'<li><strong>{esc(p.get("project_name"))}</strong>：{esc(ANOMALY_LABELS.get((p.get("price_anomaly") or {}).get("label"),(p.get("price_anomaly") or {}).get("label")))}；仅为预警，不等于虚假。应核实具体单元、优惠条件、税费、免租、补贴与可看状态。</li>' for p in xs)+'</ul>'

def near_misses(props):
    xs=[p for p in props if p.get("recommendation_status")=="excluded"]
    if not xs: return '<p>无明确近似但被硬条件排除的房源。</p>'
    return '<ul>'+''.join(f'<li>{esc(p.get("project_name") or p.get("address_raw"))}：{esc("；".join(human_token(x) for x in ((p.get("hard_filter") or {}).get("failures") or [])))}</li>' for p in xs[:20])+'</ul>'

def supplementary_leads(props):
    xs=sorted([p for p in props if p.get("presentation_tier")=="supplementary_lead" and p.get("recommendation_status")!="excluded"],key=lambda p:float(p.get("decision_score") or 0),reverse=True)
    if not xs: return '<p>无仅由低证据发现源支撑的补充线索。</p>'
    shown=xs[:10]
    rows=''.join(f'<tr><td>{esc(p.get("project_name") or p.get("address_raw"))}</td><td>{source_links(p,3)}</td><td>{fmt_num(p.get("area_sqm"),0)}㎡</td><td>{fmt_money(p.get("fixed_monthly_cost_rmb") or p.get("rent_rmb_month") or p.get("sale_total_rmb"))}</td><td>需独立交叉核验后才能升级</td></tr>' for p in shown)
    note=f'<p class="muted">共 {len(xs)} 条，仅展示匹配度最高的 {len(shown)} 条；它们不占主候选表。</p>'
    return note+'<div class="table-wrap"><table><thead><tr><th>项目</th><th>来源</th><th>面积</th><th>已知成本</th><th>动作</th></tr></thead><tbody>'+rows+'</tbody></table></div>'

def visit_html(plan):
    if not plan or not plan.get("sessions"): return '<p>尚未生成踩点计划。</p>'
    all_stops=[x for s in plan.get("sessions") or [] for x in s.get("stops") or []]
    if not any(x.get("recommendation_status")=="site_visit_candidate" for x in all_stops):
        return '<div class="notice"><strong>暂不建议直接踩点。</strong> 当前所有候选仍有硬条件未知。先按“物业用途书面许可 → 具体房号与费用单 → 晚间设施 → 登记与消防 → 地图步行时间”的顺序完成远程核验，再生成实际路线。</div>'
    out=[]
    for s in plan["sessions"]:
        lis=''.join(f'<li><strong>{x.get("order")}. {esc(x.get("project_name"))}</strong> — {esc(x.get("address"))}；核验 {esc(x.get("verification_level"))}；{esc(x.get("recommendation_status"))}</li>' for x in s.get("stops") or [])
        out.append(f'<div class="mini"><h3>半天 {s.get("session")} · {esc(s.get("area"))}</h3><ol>{lis}</ol><p class="muted">{esc(s.get("routing_note"))}</p></div>')
    return ''.join(out)

def checklist(asset_type):
    shop=["真实门头宽度/展示面","工作日与周末人行动线","上下水、排烟、燃气/明火、电量","外摆、垃圾清运、装卸","物业业态限制、营业时间、招牌权限","转让费/进场费/其他一次性费用","邻铺与空置率"]
    office=["地铁步行实测","大堂、访客与电梯高峰","采光、噪音、柱网、层高与实际使用效率","空调时段及加班费用","停车、快递外卖、午餐配套","装修交付状态与恢复义务","注册、网络、物业及税费"]
    items=shop if "商铺" in clean_text(asset_type) else office
    return '<div class="checklist">'+''.join(f'<label><input type="checkbox"> {esc(x)}</label>' for x in items)+'</div>'

def methodology(qa,state):
    bits=["房源广告仅作为线索和证据来源，不视为事实数据库。", "价格异常标签只触发核验，不自动判定虚假。", "跨平台重复广告先按实际物业/单元聚合，再排序。", "未知字段保持未知，不推断为满足。"]
    if qa: bits.append(f"数据证据检查：{qa.get('summary',{}).get('blockers',0)} 个阻断项，{qa.get('summary',{}).get('warnings',0)} 个警告；阻断项均保留，未强行升级报告成熟度。")
    if state and state.get("captcha_waiting_on"): bits.append("当前仍有验证码/人工登录步骤待用户完成。")
    deps=(state or {}).get("execution_dependencies") or {}
    if deps and not (deps.get("bs4") or {}).get("available"): bits.append("BeautifulSoup 增强依赖缺失，未运行自动 HTML 结构 QA；已完成基础文件完整性与占位符检查，但不等同于自动 HTML QA 通过。")
    return '<ul>'+''.join(f'<li>{esc(x)}</li>' for x in bits)+'</ul>'

def report_status(qa):
    summary=(qa or {}).get("summary",{})
    maturity=summary.get("report_maturity","discovery_draft")
    ready=summary.get("ready_for_final_report",False)
    label={"discovery_draft":"发现阶段工作稿","research_shortlist":"线上研究候选","visit_ready":"可安排踩点","unit_confirmed":"具体单元已确认"}.get(maturity,maturity)
    cls="good" if ready else "warn"
    coverage="已完成" if summary.get("source_coverage_ready") else "未完成"
    collection="已证明" if summary.get("collection_coverage_ready") else "未证明"
    brief="已确认" if summary.get("brief_ready") else "未完成"
    return f'<span class="tag {cls}">{esc(label)}</span> <span class="muted">来源覆盖：{coverage}；搜索深度：{collection}；需求：{brief}</span>'

def main():
    ap=argparse.ArgumentParser(description="Render a self-contained-style local HTML report from structured scouting data.")
    ap.add_argument("--brief",required=True); ap.add_argument("--properties",required=True); ap.add_argument("--template",required=True); ap.add_argument("-o","--output",required=True)
    ap.add_argument("--visits"); ap.add_argument("--qa"); ap.add_argument("--state"); ap.add_argument("--calibration"); ap.add_argument("--profile"); ap.add_argument("--source-plan"); ap.add_argument("--collection-log"); ap.add_argument("--collection-qa"); ap.add_argument("--verification-context")
    args=ap.parse_args()
    brief=load_json(args.brief,{}); props=load_json(args.properties,[]); template=Path(args.template).read_text(encoding="utf-8")
    visits=load_json(args.visits,{}) if args.visits else {}; qa=load_json(args.qa,{}) if args.qa else {}; state=load_json(args.state,{}) if args.state else {}; cal=load_json(args.calibration,{}) if args.calibration else {}; profile=load_json(args.profile,{}) if args.profile else {}; source_plan=load_json(args.source_plan,{}) if args.source_plan else {}; collection_log=load_json(args.collection_log,{}) if args.collection_log else {}; collection_qa=load_json(args.collection_qa,{}) if args.collection_qa else {}; verification_context=load_json(args.verification_context,{}) if args.verification_context else {}
    out_path=Path(args.output); out_path.parent.mkdir(parents=True,exist_ok=True)
    captured=[]
    for p in props:
        for v in p.get("listing_versions") or []:
            if v.get("captured_at"): captured.append(v["captured_at"])
    replacements={
        "{{report_title}}":esc(report_title(brief)), "{{generated_at}}":esc(now_iso()), "{{data_cutoff}}":esc(max(captured) if captured else state.get("last_updated_at") or "unknown"), "{{report_status}}":report_status(qa),
        "{{executive_summary}}":executive(props), "{{search_brief}}":brief_html(brief), "{{dataset_profile}}":dataset_profile_html(profile), "{{source_plan}}":source_plan_html(source_plan), "{{collection_coverage}}":collection_coverage_html(collection_log,collection_qa), "{{market_calibration}}":calibration_html(cal), "{{verification_context}}":verification_context_html(verification_context),
        "{{shortlist_table}}":shortlist_table(props), "{{property_cards}}":property_cards(props,out_path.parent),
        "{{verification_matrix}}":verification_matrix(props), "{{price_anomalies}}":anomalies_html(props), "{{near_misses}}":near_misses(props), "{{supplementary_leads}}":supplementary_leads(props),
        "{{site_visit_plan}}":visit_html(visits), "{{field_checklist}}":checklist(brief.get("asset_type")), "{{methodology}}":methodology(qa,state)
    }
    for k,v in replacements.items(): template=template.replace(k,v)
    out_path.write_text(template,encoding="utf-8")
    print(out_path.resolve())

if __name__=="__main__": main()
