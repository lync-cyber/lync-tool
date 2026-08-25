#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from _optional_deps import dependency_report, get_bs4, preferred_html_parser


def run(cmd, **kwargs):
    p = subprocess.run([str(x) for x in cmd], text=True, capture_output=True, **kwargs)
    if p.returncode != 0:
        print(p.stdout)
        print(p.stderr, file=sys.stderr)
        raise SystemExit(p.returncode)
    return p


def main():
    skill = Path(__file__).resolve().parents[1]
    py = sys.executable
    deps = dependency_report()
    with tempfile.TemporaryDirectory(prefix="property-scout-test-") as td:
        root = Path(td) / "workspace"
        run([py, skill/"scripts/init_workspace.py", root, "--city", "上海", "--asset-type", "写字楼"])
        brief = json.loads((root/"data/search_brief.json").read_text(encoding="utf-8"))
        brief.update({
            "target_areas": ["浦东"],
            "location_strategy": {"mode": "citywide_with_preferences", "preferred_areas": ["浦东"], "hard_boundary_areas": [], "comparison_area_min": 2, "user_named_projects": ["测试中心"]},
            "area_range": {"min_sqm": 180, "max_sqm": 320},
            "budget": {"cost_basis": "fixed_monthly_cost", "fixed_monthly_cost_max_rmb": 50000, "fixed_monthly_cost_ideal_rmb": 38000},
            "nice_to_have": ["精装"],
            "interview": {"status": "completed", "decisions": ["固定月总成本"], "unresolved_critical": [], "completed_at": "2026-08-09T00:00:00+08:00"}
        })
        (root/"data/search_brief.json").write_text(json.dumps(brief, ensure_ascii=False, indent=2), encoding="utf-8")

        # Bulk-import test using persistent field aliases. Works with pandas or stdlib fallback.
        csv_path = root/"data/imports/listings.csv"
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["平台", "房源链接", "房源标题", "楼宇", "地址", "区域", "商圈", "面积", "报价", "物业费元/㎡/月", "楼层", "房号", "标签"])
            writer.writeheader()
            for i, daily in enumerate([4.8, 4.9, 5.0, 5.1, 5.2, 3.2, 4.7]):
                project = "测试中心" if i >= 2 else ("示例中心A" if i == 0 else "示例中心B")
                district = "浦东" if i >= 2 else "闵行"
                submarket = "测试商圈" if i >= 2 else "七宝"
                writer.writerow({
                    "平台": "安居客" if i == 6 else ("贝壳" if i % 2 == 0 else "房天下"),
                    "房源链接": f"https://example.com/{i}",
                    "房源标题": f"{project} {200+i*2}㎡ 精装",
                    "楼宇": project,
                    "地址": f"上海市{district}区测试路1号",
                    "区域": district,
                    "商圈": submarket,
                    "面积": 200+i*2,
                    "报价": f"{daily}元/㎡/天",
                    "物业费元/㎡/月": 100 if i == 4 else 10,
                    "楼层": f"{10+i}F",
                    "房号": f"{1001+i}",
                    "标签": "精装|可注册"
                })
        run([py, skill/"scripts/bulk_import.py", csv_path, "-o", root/"data/raw_listings.json", "--asset-type", "写字楼", "--transaction-type", "rent"])
        raw = json.loads((root/"data/raw_listings.json").read_text(encoding="utf-8"))
        assert len(raw) == 7, len(raw)
        assert raw[0]["project_name"] == "示例中心A"
        assert "精装" in raw[0]["features"]

        # A known cost subtotal stays partial until all applicable fixed
        # components have been affirmatively checked.
        unconfirmed_raw = root/"data/unconfirmed_cost_raw.json"
        unconfirmed_raw.write_text(json.dumps([raw[0]], ensure_ascii=False, indent=2), encoding="utf-8")
        unconfirmed_out = root/"data/unconfirmed_cost_normalized.json"
        run([py, skill/"scripts/normalize_listings.py", unconfirmed_raw, "-o", unconfirmed_out])
        unconfirmed = json.loads(unconfirmed_out.read_text(encoding="utf-8"))[0]
        assert unconfirmed["fixed_monthly_cost_rmb"] is not None
        assert unconfirmed["fixed_monthly_cost_status"] == "partial"
        for row in raw:
            row["fixed_cost_components_confirmed"] = True
        (root/"data/raw_listings.json").write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")

        # Beike and Lianjia are separate required primary sources. Other platforms
        # cannot substitute for either one, while genuine zero-result completion is valid.
        source_plan = root/"data/source_plan.json"
        state = root/"state.json"
        pre_coverage = subprocess.run([str(py), str(skill/"scripts/validate_source_coverage.py"), str(source_plan), str(root/"data/raw_listings.json"), "-o", str(root/"data/pre_source_qa.json"), "--strict"], text=True, capture_output=True)
        assert pre_coverage.returncode == 2, pre_coverage.stdout + pre_coverage.stderr
        source_rows = [
            ("beike", "贝壳", "primary_discovery", "critical", "completed_with_results", 3),
            ("lianjia", "链家", "primary_discovery", "critical", "completed_zero_results", 0),
            ("fang", "房天下", "primary_discovery", "normal", "completed_with_results", 3),
            ("official", "业主/项目官方", "verification", "normal", "completed_zero_results", 0),
            ("jll", "JLL", "benchmark", "normal", "completed_zero_results", 0),
            ("cbre", "CBRE", "benchmark", "normal", "completed_zero_results", 0),
        ]
        for key, name, role, priority, status, count in source_rows:
            run([py, skill/"scripts/record_source_status.py", source_plan, "--key", key, "--name", name, "--role", role, "--priority", priority, "--status", status, "--result-count", str(count), "--state", state])

        # A blocked required source must stop the pipeline even when Fang is complete.
        run([py, skill/"scripts/record_source_status.py", source_plan, "--key", "lianjia", "--name", "链家", "--role", "primary_discovery", "--priority", "critical", "--status", "access_limited", "--url", "https://example.com/lianjia-timeout", "--reason", "筛选页面持续超时，等待用户介入", "--state", state])
        blocked_pipeline = subprocess.run([str(py), str(skill/"scripts/run_pipeline.py"), str(root), "--skill-root", str(skill)], text=True, capture_output=True)
        assert blocked_pipeline.returncode == 2, blocked_pipeline.stdout + blocked_pipeline.stderr
        assert not list(root.glob("commercial_property_report_*.html"))
        blocked_qa = json.loads((root/"data/source_qa_report.json").read_text(encoding="utf-8"))
        assert "required_source_access_blocked" in {x["code"] for x in blocked_qa["issues"]}, blocked_qa
        blocked_state = json.loads(state.read_text(encoding="utf-8"))
        assert blocked_state["user_intervention_waiting_on"]["source_key"] == "lianjia"
        forbidden_start = subprocess.run([str(py), str(skill/"scripts/record_source_status.py"), str(source_plan), "--key", "fang", "--name", "房天下", "--role", "primary_discovery", "--priority", "normal", "--status", "in_progress", "--state", str(state)], text=True, capture_output=True)
        assert forbidden_start.returncode != 0
        run([py, skill/"scripts/record_source_status.py", source_plan, "--key", "lianjia", "--name", "链家", "--role", "primary_discovery", "--priority", "critical", "--status", "completed_zero_results", "--result-count", "0", "--state", state])
        resumed_after_lianjia = json.loads(state.read_text(encoding="utf-8"))
        assert "user_intervention_waiting_on" not in resumed_after_lianjia

        # A real CAPTCHA pause must be recoverable on the same source without
        # leaving a stale workspace-wide waiting flag.
        run([py, skill/"scripts/record_source_status.py", source_plan, "--key", "beike", "--name", "贝壳", "--role", "primary_discovery", "--priority", "critical", "--status", "blocked_captcha", "--url", "https://example.com/challenge", "--reason", "请在当前页完成验证", "--state", state])
        waiting_state = json.loads(state.read_text(encoding="utf-8"))
        assert waiting_state["captcha_waiting_on"]["source_key"] == "beike"
        run([py, skill/"scripts/record_source_status.py", source_plan, "--key", "beike", "--name", "贝壳", "--role", "primary_discovery", "--priority", "critical", "--status", "in_progress", "--url", "https://example.com/results", "--state", state])
        resumed_state = json.loads(state.read_text(encoding="utf-8"))
        assert "captcha_waiting_on" not in resumed_state
        assert resumed_state["captcha_last_resolved"]["source_key"] == "beike"
        run([py, skill/"scripts/record_source_status.py", source_plan, "--key", "beike", "--name", "贝壳", "--role", "primary_discovery", "--priority", "critical", "--status", "completed_with_results", "--result-count", "3", "--state", state])

        # Discovery coverage requires search depth, geographic counter-sampling, and project reverse searches.
        collection_log = root/"data/collection_log.json"
        search_runs = [
            ("beike", "primary_discovery", "citywide_baseline", "上海写字楼", "", 3, 60, 18, 10, 2, "saturation", "连续两页无新增合格项目"),
            ("beike", "primary_discovery", "preferred_area", "", "浦东", 2, 35, 9, 1, 2, "saturation", "偏好区域达到低新增饱和"),
            ("fang", "primary_discovery", "citywide_baseline", "上海办公室", "", 3, 45, 12, 7, 0, "no_next_page", "分页已结束"),
            ("fang", "primary_discovery", "comparison_area", "", "闵行", 2, 20, 5, 3, 0, "no_next_page", "对照区域"),
            ("fang", "primary_discovery", "comparison_area", "", "徐汇", 2, 20, 4, 3, 0, "no_next_page", "对照区域"),
            ("beike", "primary_discovery", "project_lookup", "测试中心", "浦东", 1, 4, 2, 1, 0, "no_next_page", "用户点名项目"),
            ("fang", "primary_discovery", "project_lookup", "示例中心A", "", 1, 0, 0, 0, 0, "zero_results", "高潜项目反查"),
            ("anjuke", "broad_discovery", "project_lookup", "示例中心B", "", 1, 3, 1, 1, 0, "no_next_page", "补漏项目反查"),
        ]
        for source_key, source_role, lane, query, area_name, pages, seen, new_listings, new_projects, low_pages, terminal, notes in search_runs:
            evidence_rel=f"evidence/screenshots/{source_key}_{lane}.png"
            evidence_path=root/evidence_rel
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            def distribute(total, count):
                values=[]
                remaining=total
                for index in range(count):
                    slots=count-index
                    value=remaining//slots
                    values.append(value)
                    remaining-=value
                return values
            seen_by_page=distribute(seen,pages)
            listings_by_page=distribute(new_listings,pages)
            projects_by_page=distribute(new_projects,pages)
            page_metrics=[{"results_seen":seen_by_page[i],"new_unique_listings":listings_by_page[i],"new_unique_projects":projects_by_page[i],"new_qualified_listings":0,"filters_verified":True} for i in range(pages)]
            if source_key == "beike" and lane == "citywide_baseline":
                page_metrics=[{"results_seen":20,"new_unique_listings":16,"new_unique_projects":9,"new_qualified_listings":5,"filters_verified":True},{"results_seen":20,"new_unique_listings":1,"new_unique_projects":1,"new_qualified_listings":0,"filters_verified":True},{"results_seen":20,"new_unique_listings":1,"new_unique_projects":0,"new_qualified_listings":0,"filters_verified":True}]
            if source_key == "beike" and lane == "preferred_area":
                page_metrics=[{"results_seen":18,"new_unique_listings":8,"new_unique_projects":1,"new_qualified_listings":0,"filters_verified":True},{"results_seen":17,"new_unique_listings":1,"new_unique_projects":0,"new_qualified_listings":0,"filters_verified":True}]
            cmd=[py, skill/"scripts/record_search_run.py", collection_log, "--source-key", source_key, "--source-role", source_role, "--lane", lane, "--url", f"https://example.com/{source_key}/{lane}", "--evidence-ref", evidence_rel, "--pages-examined", str(pages), "--results-seen", str(seen), "--new-unique-listings", str(new_listings), "--new-unique-projects", str(new_projects), "--consecutive-low-novelty-pages", str(low_pages), "--page-metrics", json.dumps(page_metrics, ensure_ascii=False), "--terminal-reason", terminal, "--notes", notes]
            if query: cmd += ["--query", query]
            if area_name: cmd += ["--area", area_name]
            run(cmd)
        run([py, skill/"scripts/validate_collection_coverage.py", collection_log, root/"data/raw_listings.json", root/"data/search_brief.json", "-o", root/"data/collection_qa_pre.json", "--strict"])
        collection_pre=json.loads((root/"data/collection_qa_pre.json").read_text(encoding="utf-8"))
        assert collection_pre["summary"]["coverage_ready"] is True, collection_pre
        assert collection_pre["summary"]["comparison_area_count"] == 2, collection_pre
        assert collection_pre["summary"]["project_lookup_count"] == 3, collection_pre

        # Adversarial coverage cases: shallow hard caps, fake saturation, and overlapping comparison areas must fail.
        bad_log_data=json.loads(collection_log.read_text(encoding="utf-8"))
        bad_log_data["search_runs"][0].update({"pages_examined": 1, "terminal_reason": "hard_cap_with_reason", "notes": "已有足够条数", "page_metrics": []})
        bad_log_data["search_runs"][1]["page_metrics"] = []
        bad_log_data["search_runs"][2]["page_metrics"][1]["filters_verified"] = False
        bad_log_data["search_runs"][3]["area"] = "浦东"
        bad_log=root/"data/collection_log_bad.json"
        bad_log.write_text(json.dumps(bad_log_data,ensure_ascii=False,indent=2),encoding="utf-8")
        bad_run=subprocess.run([str(py),str(skill/"scripts/validate_collection_coverage.py"),str(bad_log),str(root/"data/raw_listings.json"),str(root/"data/search_brief.json"),"-o",str(root/"data/collection_qa_bad.json"),"--source-plan",str(source_plan),"--strict"],text=True,capture_output=True)
        assert bad_run.returncode == 2, bad_run.stdout + bad_run.stderr
        bad_codes={x["code"] for x in json.loads((root/"data/collection_qa_bad.json").read_text(encoding="utf-8"))["issues"]}
        assert {"hard_cap_too_shallow","page_metrics_incomplete","page_filter_integrity_unverified","comparison_area_overlaps_preference"}.issubset(bad_codes), bad_codes

        # The audited log cannot disable its own minimums or reuse/fake evidence.
        hostile_data=json.loads(collection_log.read_text(encoding="utf-8"))
        hostile_data["coverage_policy"].update({"min_pages_per_primary_source":1,"min_project_lookups":0,"require_search_evidence":False,"require_page_metrics":False})
        hostile_data["search_runs"][0]["evidence_ref"]="https://example.invalid/fake"
        hostile_data["search_runs"][0]["page_metrics"][0].update({"results_seen":0,"new_unique_listings":16,"new_unique_projects":9})
        hostile_data["search_runs"].append(dict(hostile_data["search_runs"][0]))
        hostile_log=root/"data/collection_log_hostile.json"
        hostile_log.write_text(json.dumps(hostile_data,ensure_ascii=False,indent=2),encoding="utf-8")
        hostile_run=subprocess.run([str(py),str(skill/"scripts/validate_collection_coverage.py"),str(hostile_log),str(root/"data/raw_listings.json"),str(root/"data/search_brief.json"),"-o",str(root/"data/collection_qa_hostile.json"),"--strict"],text=True,capture_output=True)
        assert hostile_run.returncode == 2, hostile_run.stdout + hostile_run.stderr
        hostile_codes={x["code"] for x in json.loads((root/"data/collection_qa_hostile.json").read_text(encoding="utf-8"))["issues"]}
        assert {"search_run_evidence_must_be_local","page_metric_impossible_counts","duplicate_or_missing_search_run_id","duplicate_search_run"}.issubset(hostile_codes), hostile_codes

        concentrated=[dict(x, district="浦东", submarket="测试商圈", address_raw="上海市浦东新区测试路1号") for x in raw]
        concentrated_path=root/"data/raw_listings_concentrated.json"
        concentrated_path.write_text(json.dumps(concentrated,ensure_ascii=False,indent=2),encoding="utf-8")
        concentrated_run=subprocess.run([str(py),str(skill/"scripts/validate_collection_coverage.py"),str(collection_log),str(concentrated_path),str(root/"data/search_brief.json"),"-o",str(root/"data/collection_qa_concentrated.json"),"--strict"],text=True,capture_output=True)
        assert concentrated_run.returncode == 2, concentrated_run.stdout + concentrated_run.stderr
        concentrated_codes={x["code"] for x in json.loads((root/"data/collection_qa_concentrated.json").read_text(encoding="utf-8"))["issues"]}
        assert "preferred_area_sample_concentration" in concentrated_codes, concentrated_codes

        # Saved HTML extraction test when BeautifulSoup is available.
        if deps["bs4"]["available"]:
            html = root/"evidence/pages/sample.html"
            html.parent.mkdir(parents=True, exist_ok=True)
            html.write_text('''<!doctype html><html><head>
<title>测试中心 220㎡ 办公室</title>
<link rel="canonical" href="https://example.com/html-1">
<meta property="og:image" content="/img/room.jpg">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"RealEstateListing","name":"测试中心","address":{"@type":"PostalAddress","streetAddress":"上海市浦东新区测试路1号","addressLocality":"上海"},"floorSize":{"@type":"QuantitativeValue","value":220,"unitText":"sqm"}}</script>
</head><body><div>租金：4.6元/㎡/天</div><div>楼层：18F</div></body></html>''', encoding="utf-8")
            extract_out = root/"evidence/page_extracts/sample.json"
            stub_out = root/"data/html_stubs.json"
            run([py, skill/"scripts/extract_saved_html.py", html, "-o", extract_out, "--platform", "示例平台", "--asset-type", "写字楼", "--transaction-type", "rent", "--emit-listings", stub_out])
            extracts = json.loads(extract_out.read_text(encoding="utf-8"))
            assert extracts[0]["field_candidates"]["area_sqm"][0]["value"] == 220.0
            assert extracts[0]["image_candidates"][0]["url"] == "https://example.com/img/room.jpg"
            stubs = json.loads(stub_out.read_text(encoding="utf-8"))
            assert stubs[0]["project_name"] == "测试中心"
            assert stubs[0]["verification_status"] == "V0"

        # Full pipeline.
        p = run([py, skill/"scripts/run_pipeline.py", root])
        props = json.loads((root/"data/properties.json").read_text(encoding="utf-8"))
        assert len(props) == 7, len(props)
        low = [x for x in props if x.get("rent_rmb_sqm_day") == 3.2][0]
        assert low["price_anomaly"]["label"] == "low_ge_30pct", low["price_anomaly"]
        assert low["fixed_monthly_cost_status"] == "complete"
        assert low["fixed_monthly_cost_rmb"] > low["rent_rmb_month"]
        over_budget = [x for x in props if x.get("listing_versions", [{}])[0].get("source_url") == "https://example.com/4"][0]
        assert "fixed_monthly_cost_budget_exceeded" in over_budget["hard_filter"]["failures"], over_budget["hard_filter"]
        broad = [x for x in props if "安居客" in (x.get("source_platforms") or [])][0]
        assert broad["presentation_tier"] == "supplementary_lead"

        # A preferred area is a soft score unless the user explicitly declares a hard boundary.
        probe=dict(props[0]); probe.update({"district":"闵行","submarket":"七宝","address_raw":"上海市闵行区测试路2号","project_name":"对照中心"})
        probe_in=root/"data/location_probe.json"; probe_in.write_text(json.dumps([probe],ensure_ascii=False,indent=2),encoding="utf-8")
        soft_out=root/"data/location_soft.json"
        run([py,skill/"scripts/score_candidates.py",probe_in,root/"data/search_brief.json","-o",soft_out,"--source-registry",skill/"references/source-registry.json"])
        soft=json.loads(soft_out.read_text(encoding="utf-8"))[0]
        assert "outside_target_area" not in soft["hard_filter"]["failures"] and soft["fit_components"]["location"] == 62, soft
        hard_brief=dict(brief); hard_brief["location_strategy"]={"mode":"hard_boundary","preferred_areas":[],"hard_boundary_areas":["浦东"],"comparison_area_min":0,"user_named_projects":[]}
        hard_path=root/"data/hard_boundary_brief.json"; hard_path.write_text(json.dumps(hard_brief,ensure_ascii=False,indent=2),encoding="utf-8")
        hard_out=root/"data/location_hard.json"
        run([py,skill/"scripts/score_candidates.py",probe_in,hard_path,"-o",hard_out,"--source-registry",skill/"references/source-registry.json"])
        hard=json.loads(hard_out.read_text(encoding="utf-8"))[0]
        assert "outside_target_area" in hard["hard_filter"]["failures"], hard

        # Strict numeric floors are first-class; equality must fail `gt` while
        # a minimally higher value passes without integer-step workarounds.
        equal_probe = dict(props[0], property_id="rent-equal", rent_rmb_month=6000, fixed_monthly_cost_rmb=6000, fixed_monthly_cost_status="complete")
        above_probe = dict(equal_probe, property_id="rent-above", rent_rmb_month=6000.01, fixed_monthly_cost_rmb=6000.01)
        gt_input = root/"data/gt_probe.json"
        gt_input.write_text(json.dumps([equal_probe, above_probe], ensure_ascii=False, indent=2), encoding="utf-8")
        gt_brief = dict(brief)
        gt_brief["budget"] = {"cost_basis": "base_rent", "monthly_max_rmb": 50000}
        gt_brief["hard_requirements"] = [{"id": "rent_floor", "field": "rent_rmb_month", "operator": "gt", "value": 6000, "unknown_policy": "exclude"}]
        gt_brief_path = root/"data/gt_brief.json"
        gt_brief_path.write_text(json.dumps(gt_brief, ensure_ascii=False, indent=2), encoding="utf-8")
        gt_out = root/"data/gt_scored.json"
        run([py, skill/"scripts/validate_brief.py", gt_brief_path, "-o", root/"data/gt_brief_qa.json", "--strict"])
        run([py, skill/"scripts/score_candidates.py", gt_input, gt_brief_path, "-o", gt_out, "--source-registry", skill/"references/source-registry.json"])
        gt_rows = {row["property_id"]: row for row in json.loads(gt_out.read_text(encoding="utf-8"))}
        assert "hard_requirement_failed:rent_floor" in gt_rows["rent-equal"]["hard_filter"]["failures"]
        assert "hard_requirement_failed:rent_floor" not in gt_rows["rent-above"]["hard_filter"]["failures"]
        profile = json.loads((root/"data/dataset_profile.json").read_text(encoding="utf-8"))
        assert profile["row_count"] == 7
        assert profile["counts_by_platform"].get("贝壳") == 3
        source_qa = json.loads((root/"data/source_qa_report.json").read_text(encoding="utf-8"))
        assert source_qa["summary"]["coverage_ready"] is True, source_qa
        collection_qa = json.loads((root/"data/collection_qa_report.json").read_text(encoding="utf-8"))
        assert collection_qa["summary"]["coverage_ready"] is True, collection_qa
        reports = list(root.glob("commercial_property_report_*.html"))
        assert reports
        report_text = reports[0].read_text(encoding="utf-8")
        assert "数据概况" in report_text and "搜索深度与区域防偏" in report_text and "补充线索（不占主候选）" in report_text and "{{dataset_profile}}" not in report_text
        shortlist_fragment = report_text.split('<table id="shortlist"', 1)[1].split("</table>", 1)[0]
        assert 'href="https://example.com/' in shortlist_fragment
        assert "上海共享空间 / 自习室选址决策报告" not in report_text
        if deps["bs4"]["available"]:
            html_qa = json.loads((root/"data/html_qa_report.json").read_text(encoding="utf-8"))
            assert html_qa["summary"]["valid_for_delivery"] is True, html_qa
            BeautifulSoup = get_bs4(required=True)
            bad_soup = BeautifulSoup(report_text, preferred_html_parser())
            for anchor in bad_soup.select("table#shortlist tbody tr a[href]"):
                if anchor.get("href", "").startswith(("http://", "https://")):
                    anchor.unwrap()
            bad_report = root/"report_without_shortlist_links.html"
            bad_report.write_text(str(bad_soup), encoding="utf-8")
            bad_html_run = subprocess.run([str(py), str(skill/"scripts/validate_report_html.py"), str(bad_report), "-o", str(root/"data/bad_html_qa.json"), "--strict"], text=True, capture_output=True)
            assert bad_html_run.returncode == 2, bad_html_run.stdout + bad_html_run.stderr
            bad_html_codes = {x["code"] for x in json.loads((root/"data/bad_html_qa.json").read_text(encoding="utf-8"))["issues"]}
            assert "shortlist_row_missing_source_link" in bad_html_codes, bad_html_codes

        # Pandas vs stdlib anomaly semantics must match when pandas exists.
        props0 = root/"data/properties_deduped.json"
        if deps["pandas"]["available"]:
            pa = root/"data/anomaly_pandas.json"; sa = root/"data/anomaly_stdlib.json"
            run([py, skill/"scripts/detect_price_anomalies.py", props0, "-o", pa, "--engine", "pandas"])
            run([py, skill/"scripts/detect_price_anomalies.py", props0, "-o", sa, "--engine", "stdlib"])
            pj = json.loads(pa.read_text(encoding="utf-8")); sj = json.loads(sa.read_text(encoding="utf-8"))
            assert [x["price_anomaly"]["label"] for x in pj] == [x["price_anomaly"]["label"] for x in sj]

            # Force pandas blocked dedupe on a strong duplicate pair; it must merge only under existing rules.
            dup_rows = [dict(raw[0]), dict(raw[0])]
            dup_rows[1]["source_id"] = "src_dup2"; dup_rows[1]["source_url"] = "https://other.example/dup"; dup_rows[1]["source_platform"] = "房天下"
            dup_input = root/"data/dups_normalized.json"
            # Normalize duplicate pair first.
            tmp_raw = root/"data/dups_raw.json"; tmp_raw.write_text(json.dumps(dup_rows, ensure_ascii=False, indent=2), encoding="utf-8")
            run([py, skill/"scripts/normalize_listings.py", tmp_raw, "-o", dup_input])
            dup_out = root/"data/dups_props.json"
            run([py, skill/"scripts/dedupe_properties.py", dup_input, "-o", dup_out, "--engine", "pandas", "--pandas-threshold", "1"])
            merged = json.loads(dup_out.read_text(encoding="utf-8"))
            assert len(merged) == 1 and merged[0]["source_count"] == 2

        print("SELF_TEST_OK", json.dumps({
            "properties": len(props),
            "low_price_label": low["price_anomaly"]["label"],
            "source_coverage_ready": source_qa["summary"]["coverage_ready"],
            "collection_coverage_ready": collection_qa["summary"]["coverage_ready"],
            "profile_engine": profile["engine"],
            "bs4_tested": deps["bs4"]["available"],
            "pandas_diff_tested": deps["pandas"]["available"]
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
