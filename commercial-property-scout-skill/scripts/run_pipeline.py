#!/usr/bin/env python3
from __future__ import annotations
import argparse
import subprocess
import sys
from pathlib import Path
from _common import load_json, now_iso, save_json
from _optional_deps import dependency_report


def run(cmd, allow_nonzero=False):
    print("+", " ".join(str(x) for x in cmd))
    p = subprocess.run(cmd)
    if p.returncode and not allow_nonzero:
        raise SystemExit(p.returncode)
    return p.returncode


def main():
    ap = argparse.ArgumentParser(description="Run deterministic normalize→profile→dedupe→anomaly→score→visit→QA→HTML pipeline for a workspace.")
    ap.add_argument("workspace")
    ap.add_argument("--skill-root", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--report-name", default="")
    ap.add_argument("--engine", choices=["auto", "pandas", "stdlib"], default="auto", help="Shared engine preference for profile/dedupe/anomaly")
    ap.add_argument("--dedupe-pandas-threshold", type=int, default=250)
    args = ap.parse_args()
    root = Path(args.workspace); skill = Path(args.skill_root); scripts = skill / "scripts"
    data = root / "data"; data.mkdir(parents=True, exist_ok=True)
    raw = data / "raw_listings.json"; brief = data / "search_brief.json"; source_plan = data / "source_plan.json"; collection_log = data / "collection_log.json"
    normalized = data / "normalized_listings.json"; profile = data / "dataset_profile.json"; review = data / "possible_duplicates.json"
    props0 = data / "properties_deduped.json"; props1 = data / "properties_anomaly.json"; props = data / "properties.json"
    visits = data / "visit_plan.json"; qa = data / "qa_report.json"; html_qa = data / "html_qa_report.json"
    brief_qa = data / "brief_qa_report.json"; source_qa = data / "source_qa_report.json"; collection_qa = data / "collection_qa_report.json"
    state_path = root / "state.json"
    if not raw.exists() or not brief.exists(): raise SystemExit("workspace missing raw_listings.json or search_brief.json; run init_workspace.py first")
    if not source_plan.exists():
        save_json(source_plan, {"version": 1, "coverage_policy": {"min_terminal_attempts_by_role": {"primary_discovery": 2, "verification": 1, "benchmark": 2}, "min_high_priority_terminal_attempts": 1, "required_primary_source_keys": ["beike", "lianjia"], "stop_on_required_source_problem": True, "max_single_platform_share_warning": 0.65}, "sources": [], "migration_note": "Created by run_pipeline; complete Beike and Lianjia separately before continuing."})
    if not collection_log.exists():
        save_json(collection_log, {"version": 1, "created_at": now_iso(), "last_updated_at": now_iso(), "coverage_policy": {"min_pages_per_nonterminal_run": 2, "min_pages_per_primary_source": 3, "min_comparison_areas": 2, "min_project_lookups": 3, "saturation_low_novelty_pages": 2, "saturation_novelty_threshold": 0.10, "hard_cap_min_pages": 5, "require_search_evidence": True, "preferred_area_share_warning": 0.80}, "search_runs": [], "migration_note": "Created by run_pipeline; record browser search depth before final delivery."})
    py = sys.executable
    brief_qa_code = run([py, scripts/"validate_brief.py", brief, "-o", brief_qa, "--strict"], allow_nonzero=True)
    source_qa_code = run([py, scripts/"validate_source_coverage.py", source_plan, raw, "-o", source_qa, "--strict"], allow_nonzero=True)
    source_report = load_json(source_qa, {}) or {}
    required_gate_codes = {
        "required_source_missing", "required_source_wrong_role_or_priority",
        "required_source_access_blocked", "required_source_not_completed",
    }
    required_gate_issues = [x for x in source_report.get("issues", []) if x.get("code") in required_gate_codes]
    if required_gate_issues:
        state = load_json(state_path, {})
        waiting = [x for x in required_gate_issues if x.get("code") == "required_source_access_blocked"]
        state.update({
            "last_updated_at": now_iso(),
            "workflow_status": "waiting_for_user_intervention" if waiting else "required_sources_incomplete",
            "source_qa_path": str(source_qa),
            "report_maturity": "discovery_draft",
            "next_actions": ["Complete Beike and Lianjia separately in the visible browser; do not collect from substitute platforms or generate a report."],
        })
        save_json(state_path, state)
        print("required_source_gate=blocked; pipeline stopped before collection QA, scoring, and HTML generation")
        raise SystemExit(2)
    collection_qa_code = run([py, scripts/"validate_collection_coverage.py", collection_log, raw, brief, "-o", collection_qa, "--source-plan", source_plan, "--strict"], allow_nonzero=True)
    run([py, scripts/"normalize_listings.py", raw, "-o", normalized])
    run([py, scripts/"dataset_profile.py", normalized, "-o", profile, "--engine", args.engine, "--source-registry", skill/"references/source-registry.json"])
    run([py, scripts/"dedupe_properties.py", normalized, "-o", props0, "--review-output", review, "--engine", args.engine, "--pandas-threshold", str(args.dedupe_pandas_threshold)])
    run([py, scripts/"detect_price_anomalies.py", props0, "-o", props1, "--engine", args.engine])
    run([py, scripts/"score_candidates.py", props1, brief, "-o", props, "--source-registry", skill/"references/source-registry.json"])
    run([py, scripts/"plan_visits.py", props, brief, "-o", visits])
    qa_code = run([py, scripts/"validate_dataset.py", props, "-o", qa, "--brief-qa", brief_qa, "--source-qa", source_qa, "--collection-qa", collection_qa, "--strict"], allow_nonzero=True)
    today = now_iso()[:10]
    report = root / (args.report_name or f"commercial_property_report_{today}.html")
    render_cmd=[py, scripts/"render_report.py", "--brief", brief, "--properties", props, "--template", skill/"assets/report-template.html", "--visits", visits, "--qa", qa, "--state", state_path, "--profile", profile, "--source-plan", source_plan, "--collection-log", collection_log, "--collection-qa", collection_qa, "-o", report]
    cal = data / "market_calibration.json"
    if cal.exists(): render_cmd += ["--calibration", cal]
    verification_context = data / "verification_context.json"
    if verification_context.exists(): render_cmd += ["--verification-context", verification_context]
    run(render_cmd)
    deps = dependency_report()
    html_qa_code = None
    if deps.get("bs4", {}).get("available"):
        html_qa_code = run([py, scripts/"validate_report_html.py", report, "-o", html_qa, "--strict"], allow_nonzero=True)
    state = load_json(state_path, {})
    qa_summary = (load_json(qa, {}) or {}).get("summary", {})
    state.update({
        "last_updated_at": now_iso(),
        "raw_listing_count": len(load_json(raw, [])),
        "deduped_property_count": len(load_json(props, [])),
        "verified_property_count": sum(1 for p in load_json(props, []) if str(p.get("verification_level","")).upper() in ("V2","V3")),
        "report_path": str(report),
        "execution_dependencies": deps,
        "dataset_profile_path": str(profile),
        "analysis_engine_requested": args.engine,
        "dedupe_pandas_threshold": args.dedupe_pandas_threshold,
        "html_qa_path": str(html_qa) if html_qa_code is not None else "",
        "brief_qa_path": str(brief_qa),
        "source_qa_path": str(source_qa),
        "collection_log_path": str(collection_log),
        "collection_qa_path": str(collection_qa),
        "brief_complete": brief_qa_code == 0,
        "interview_status": (load_json(brief, {}) or {}).get("interview", {}).get("status", "pending"),
        "report_maturity": qa_summary.get("report_maturity", "discovery_draft"),
        "next_actions": (["Resolve brief/source/evidence QA blockers before treating report as final"] if qa_code or html_qa_code not in (None, 0) else ["Review shortlist and proceed at the stated report maturity"])
    })
    save_json(state_path, state)
    print(f"report={report.resolve()} brief_qa_exit={brief_qa_code} source_qa_exit={source_qa_code} collection_qa_exit={collection_qa_code} qa_exit={qa_code} html_qa_exit={html_qa_code}")

if __name__ == "__main__": main()
