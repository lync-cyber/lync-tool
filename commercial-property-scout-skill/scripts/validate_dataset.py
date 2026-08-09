#!/usr/bin/env python3
from __future__ import annotations
import argparse
from collections import Counter
from _common import clean_text, load_json, save_json


def add_issue(issues, severity, code, property_id=None, detail=""):
    issues.append({"severity": severity, "code": code, "property_id": property_id, "detail": detail})


def main():
    ap = argparse.ArgumentParser(description="Validate evidence quality and final-report readiness.")
    ap.add_argument("properties")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--strict", action="store_true", help="Exit non-zero if blocking issues exist")
    ap.add_argument("--brief-qa")
    ap.add_argument("--source-qa")
    ap.add_argument("--collection-qa")
    args = ap.parse_args()
    props = load_json(args.properties, [])
    issues = []
    brief_qa = load_json(args.brief_qa, {}) if args.brief_qa else {}
    source_qa = load_json(args.source_qa, {}) if args.source_qa else {}
    collection_qa = load_json(args.collection_qa, {}) if args.collection_qa else {}
    for prefix, external in (("brief", brief_qa), ("source", source_qa), ("collection", collection_qa)):
        for item in external.get("issues", []):
            copied = dict(item)
            copied["code"] = f"{prefix}:{item.get('code')}"
            issues.append(copied)
    for p in props:
        pid = p.get("property_id")
        if not p.get("source_urls"):
            add_issue(issues, "blocker", "missing_source_url", pid)
        if p.get("area_sqm") is None:
            add_issue(issues, "warning", "missing_area", pid)
        if p.get("transaction_type") == "rent" and p.get("rent_rmb_sqm_day") is None and p.get("rent_rmb_month") is None:
            add_issue(issues, "blocker", "missing_rent_price", pid)
        if p.get("transaction_type") == "rent" and p.get("rank") and int(p.get("rank")) <= 5 and p.get("fixed_monthly_cost_status") != "complete":
            add_issue(issues, "warning", "top5_fixed_monthly_cost_incomplete", pid)
        if p.get("transaction_type") == "sale" and p.get("sale_total_rmb") is None and p.get("sale_rmb_sqm") is None:
            add_issue(issues, "blocker", "missing_sale_price", pid)
        if clean_text(p.get("verification_level")).upper() == "V0" and p.get("rank") and int(p.get("rank")) <= 5:
            add_issue(issues, "blocker", "top5_single_source_v0", pid)
        if p.get("confidence_score") is not None and float(p.get("confidence_score")) < 45 and p.get("recommendation_status") == "site_visit_candidate":
            add_issue(issues, "blocker", "low_confidence_marked_for_visit", pid)
        anomaly = (p.get("price_anomaly") or {}).get("label")
        if anomaly in ("low_20_30pct", "low_ge_30pct") and not p.get("red_flags"):
            add_issue(issues, "warning", "price_anomaly_without_red_flag", pid)
        if p.get("source_count", 0) > 1 and p.get("independent_source_count", 0) == 1:
            add_issue(issues, "info", "multiple_ads_but_single_independent_platform", pid)
        if not p.get("image_refs") and p.get("rank") and int(p.get("rank")) <= 5:
            add_issue(issues, "warning", "top5_missing_images", pid)
        # V3 must not be inferred merely from multiple sources.
        if clean_text(p.get("verification_level")).upper() == "V3":
            versions = p.get("listing_versions") or []
            has_explicit = any(clean_text(v.get("verification_status")).upper() == "V3" or clean_text(v.get("verification_level")).upper() == "V3" for v in versions)
            if not has_explicit:
                add_issue(issues, "blocker", "v3_without_explicit_unit_confirmation_evidence", pid)

    counts = Counter(i["severity"] for i in issues)
    top = [p for p in props if p.get("rank") and int(p.get("rank")) <= 5]
    ready = counts.get("blocker", 0) == 0
    rankable = sorted([p for p in props if p.get("rank")], key=lambda p: int(p.get("rank") or 999999))
    if not ready:
        maturity = "discovery_draft"
    elif any(clean_text(p.get("verification_level")).upper() == "V3" for p in rankable[:5]):
        maturity = "unit_confirmed"
    elif any(p.get("recommendation_status") == "site_visit_candidate" for p in rankable):
        maturity = "visit_ready"
    else:
        maturity = "research_shortlist"
    report = {
        "summary": {
            "property_count": len(props),
            "top5_count": len(top),
            "blockers": counts.get("blocker", 0),
            "warnings": counts.get("warning", 0),
            "info": counts.get("info", 0),
            "ready_for_final_report": ready,
            "report_maturity": maturity,
            "brief_ready": (brief_qa.get("summary") or {}).get("brief_ready") if brief_qa else None,
            "source_coverage_ready": (source_qa.get("summary") or {}).get("coverage_ready") if source_qa else None,
            "collection_coverage_ready": (collection_qa.get("summary") or {}).get("coverage_ready") if collection_qa else None
        },
        "issues": issues
    }
    save_json(args.output, report)
    print(report["summary"])
    if args.strict and counts.get("blocker", 0):
        raise SystemExit(2)

if __name__ == "__main__":
    main()
