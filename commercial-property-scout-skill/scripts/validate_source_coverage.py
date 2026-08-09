#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter

from _common import clean_text, load_json, platform_key, save_json

TERMINAL_ATTEMPTS = {"completed_with_results", "completed_zero_results", "access_limited", "unavailable"}
BLOCKED = {"blocked_login", "blocked_captcha"}


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
        if status in BLOCKED:
            substitute = clean_text(source.get("substitute_key"))
            replacement = by_key.get(substitute)
            if not substitute or not replacement or clean_text(replacement.get("status")) not in TERMINAL_ATTEMPTS:
                add(issues, "blocker", "blocked_source_without_completed_substitute", key, status)
            else:
                add(issues, "warning", "source_blocked_but_substituted", key, status)
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
