#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter

from _common import clean_text, ensure_list, load_json, save_json

VALID_OPERATORS = {"eq", "neq", "lt", "lte", "gt", "gte", "in", "contains_any", "truthy"}


def issue(items, severity, code, detail=""):
    items.append({"severity": severity, "code": code, "detail": detail})


def main():
    ap = argparse.ArgumentParser(description="Validate that a property-search brief is decision-ready.")
    ap.add_argument("brief")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    brief = load_json(args.brief, {})
    issues = []
    for field in ("city", "transaction_type", "asset_type"):
        if not clean_text(brief.get(field)):
            issue(issues, "blocker", f"missing_{field}")

    interview = brief.get("interview") or {}
    if interview.get("status") not in {"completed", "skipped_by_user"}:
        issue(issues, "blocker", "interview_not_completed")
    for item in ensure_list(interview.get("unresolved_critical")):
        if clean_text(item):
            issue(issues, "warning", "unresolved_critical_requirement", clean_text(item))

    area = brief.get("area_range") or {}
    if area.get("min_sqm") is None and area.get("max_sqm") is None:
        issue(issues, "warning", "area_range_not_set")
    if area.get("min_sqm") is not None and area.get("max_sqm") is not None:
        try:
            if float(area["min_sqm"]) > float(area["max_sqm"]):
                issue(issues, "blocker", "invalid_area_range")
        except (TypeError, ValueError):
            issue(issues, "blocker", "invalid_area_range")

    transaction = clean_text(brief.get("transaction_type")).lower()
    location = brief.get("location_strategy") or {}
    mode = clean_text(location.get("mode"))
    if mode and mode not in {"citywide", "citywide_with_preferences", "hard_boundary"}:
        issue(issues, "blocker", "invalid_location_strategy_mode", mode)
    if not mode and ensure_list(brief.get("target_areas")):
        issue(issues, "warning", "legacy_target_areas_without_location_strategy", "target_areas will be treated as preferences, not a hard boundary")
    if mode == "hard_boundary" and not ensure_list(location.get("hard_boundary_areas") or brief.get("target_areas")):
        issue(issues, "blocker", "hard_boundary_without_areas")
    if mode == "citywide_with_preferences" and not ensure_list(location.get("preferred_areas") or brief.get("target_areas")):
        issue(issues, "warning", "preference_mode_without_preferred_areas")
    budget = brief.get("budget") or {}
    if transaction == "rent":
        basis = budget.get("cost_basis")
        if basis not in {"fixed_monthly_cost", "base_rent", "none"}:
            issue(issues, "blocker", "rent_cost_basis_not_confirmed")
        if basis == "fixed_monthly_cost" and budget.get("fixed_monthly_cost_max_rmb") is None:
            issue(issues, "blocker", "missing_fixed_monthly_cost_max")
        if basis == "base_rent" and budget.get("monthly_max_rmb") is None:
            issue(issues, "blocker", "missing_base_rent_max")
    elif transaction == "sale" and budget.get("sale_total_max_rmb") is None:
        issue(issues, "warning", "sale_budget_not_set")

    seen = set()
    for req in ensure_list(brief.get("hard_requirements")):
        if not isinstance(req, dict):
            issue(issues, "blocker", "invalid_hard_requirement", "requirement must be an object")
            continue
        rid = clean_text(req.get("id"))
        if not rid or rid in seen:
            issue(issues, "blocker", "invalid_hard_requirement_id", rid or "missing")
        seen.add(rid)
        if not clean_text(req.get("field")):
            issue(issues, "blocker", "hard_requirement_missing_field", rid)
        if req.get("operator") not in VALID_OPERATORS:
            issue(issues, "blocker", "hard_requirement_invalid_operator", rid)
        if req.get("unknown_policy", "verify_first") not in {"verify_first", "exclude"}:
            issue(issues, "blocker", "hard_requirement_invalid_unknown_policy", rid)

    counts = Counter(x["severity"] for x in issues)
    report = {
        "summary": {
            "blockers": counts.get("blocker", 0),
            "warnings": counts.get("warning", 0),
            "brief_ready": counts.get("blocker", 0) == 0,
        },
        "issues": issues,
    }
    save_json(args.output, report)
    print(report["summary"])
    if args.strict and report["summary"]["blockers"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
