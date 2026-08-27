#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter

from _common import clean_text, load_json, platform_key, save_json

TERMINAL_ATTEMPTS = {"completed_with_results", "completed_zero_results"}
BLOCKED = {"blocked_login", "blocked_captcha", "access_limited", "unavailable"}
DEFAULT_REQUIRED_PRIMARY_SOURCES = ("beike", "lianjia")


def add(issues, severity, code, source_key=None, detail=""):
    issues.append({"severity": severity, "code": code, "source_key": source_key, "detail": detail})


def main():
    ap = argparse.ArgumentParser(description="Validate planned source attempts and listing-source concentration.")
    ap.add_argument("source_plan")
    ap.add_argument("listings")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    plan = load_json(args.source_plan, {})
    listings = [x for x in load_json(args.listings, []) if isinstance(x, dict)]
    sources = [x for x in plan.get("sources", []) if isinstance(x, dict)]
    policy = plan.get("coverage_policy") or {}
    issues = []

    by_key = {clean_text(x.get("source_key")): x for x in sources if clean_text(x.get("source_key"))}
    configured_required = policy.get("required_primary_source_keys")
    required_keys = list(dict.fromkeys(
        clean_text(x) for x in [*DEFAULT_REQUIRED_PRIMARY_SOURCES, *(configured_required or [])] if clean_text(x)
    ))
    waiver_rows = [x for x in plan.get("required_source_waivers", []) if isinstance(x, dict)]
    waivers = {
        clean_text(x.get("source_key")): x
        for x in waiver_rows
        if x.get("user_authorized_waiver") is True and clean_text(x.get("user_quote"))
    }
    required_status = {}
    for key in required_keys:
        if key in waivers:
            required_status[key] = "user_waived"
            add(issues, "warning", "required_source_user_waived", key, clean_text(waivers[key].get("user_quote")))
            continue
        source = by_key.get(key)
        if not source:
            required_status[key] = "missing"
            add(issues, "blocker", "required_source_missing", key)
            continue
        status = clean_text(source.get("status")) or "planned"
        required_status[key] = status
        if clean_text(source.get("role")) != "primary_discovery" or clean_text(source.get("priority")) != "critical":
            add(issues, "blocker", "required_source_wrong_role_or_priority", key, "must be critical primary_discovery")
        if status in BLOCKED:
            add(issues, "blocker", "required_source_access_blocked", key, status)
        elif status not in TERMINAL_ATTEMPTS:
            add(issues, "blocker", "required_source_not_completed", key, status)

    completed_by_role = Counter()
    high_priority_terminal = 0
    for source in sources:
        key = clean_text(source.get("source_key"))
        status = clean_text(source.get("status")) or "planned"
        role = clean_text(source.get("role"))
        priority = clean_text(source.get("priority")) or "normal"
        if status in TERMINAL_ATTEMPTS:
            completed_by_role[role] += 1
            if priority in {"critical", "high"}:
                high_priority_terminal += 1
        if priority in {"critical", "high"} and status not in TERMINAL_ATTEMPTS and status not in BLOCKED:
            add(issues, "blocker", "high_priority_source_not_attempted", key)
        if status in BLOCKED and key not in required_keys and priority in {"critical", "high"}:
            add(issues, "blocker", "high_priority_source_blocked_requires_user_intervention", key, status)
        if status in {"unavailable", "skipped_with_reason", "access_limited"} and not clean_text(source.get("status_reason")):
            add(issues, "warning", "source_status_missing_reason", key, status)
        if status == "completed_with_results" and source.get("result_count") in (None, 0):
            add(issues, "warning", "source_result_count_missing", key)

    minimums = policy.get("min_terminal_attempts_by_role") or {}
    for role, minimum in minimums.items():
        try:
            required = int(minimum)
        except (TypeError, ValueError):
            add(issues, "blocker", "invalid_role_minimum", detail=str(role))
            continue
        if completed_by_role[role] < required:
            add(issues, "blocker", "source_role_minimum_not_met", detail=f"{role}: {completed_by_role[role]}/{required}")
    required_high = int(policy.get("min_high_priority_terminal_attempts", 0) or 0)
    if high_priority_terminal < required_high:
        add(issues, "blocker", "high_priority_source_minimum_not_met", detail=f"{high_priority_terminal}/{required_high}")

    platform_counts = Counter(platform_key(x.get("source_platform", "")) for x in listings)
    platform_counts.pop("unknown", None)
    total = sum(platform_counts.values())
    max_share = max(platform_counts.values(), default=0) / total if total else 0.0
    threshold = float(policy.get("max_single_platform_share_warning", 0.65))
    if total and max_share > threshold:
        dominant, count = platform_counts.most_common(1)[0]
        add(issues, "warning", "single_platform_concentration", dominant, f"{count}/{total}={max_share:.1%}")
    if not listings:
        add(issues, "blocker", "no_listings_collected")

    counts = Counter(x["severity"] for x in issues)
    report = {
        "summary": {
            "planned_source_count": len(sources),
            "listing_count": len(listings),
            "terminal_attempts_by_role": dict(completed_by_role),
            "high_priority_terminal_attempts": high_priority_terminal,
            "required_primary_source_status": required_status,
            "waiting_for_user_intervention": any(x["code"] == "required_source_access_blocked" for x in issues),
            "counts_by_platform": dict(platform_counts.most_common()),
            "max_single_platform_share": round(max_share, 4),
            "blockers": counts.get("blocker", 0),
            "warnings": counts.get("warning", 0),
            "coverage_ready": counts.get("blocker", 0) == 0,
        },
        "issues": issues,
    }
    save_json(args.output, report)
    print(report["summary"])
    if args.strict and report["summary"]["blockers"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
