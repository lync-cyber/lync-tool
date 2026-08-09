#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import urlparse

from _common import clean_text, ensure_list, load_json, norm_text, save_json

VALID_LANES = {"citywide_baseline", "preferred_area", "comparison_area", "project_lookup", "transit_corridor", "map_search"}
VALID_TERMINALS = {"pagination_exhausted", "no_next_page", "zero_results", "saturation", "hard_cap_with_reason", "blocked"}
EARLY_TERMINALS = {"pagination_exhausted", "no_next_page", "zero_results", "blocked"}


def add(issues, severity, code, run_id=None, detail=""):
    issues.append({"severity": severity, "code": code, "run_id": run_id, "detail": detail})


def location_text(listing):
    return " ".join(clean_text(listing.get(k)) for k in ("district", "submarket", "address_raw", "project_name"))


def main():
    ap = argparse.ArgumentParser(description="Validate pagination depth, geographic counter-sampling, project lookups, and saturation evidence.")
    ap.add_argument("collection_log")
    ap.add_argument("listings")
    ap.add_argument("brief")
    ap.add_argument("--source-plan")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    log = load_json(args.collection_log, {})
    listings = [x for x in load_json(args.listings, []) if isinstance(x, dict)]
    brief = load_json(args.brief, {})
    source_plan = load_json(args.source_plan, {}) if args.source_plan else {}
    policy = log.get("coverage_policy") or {}
    runs = [x for x in log.get("search_runs", []) if isinstance(x, dict)]
    issues = []
    # Workspace policy may tighten these floors, but the artifact being audited
    # must not be able to disable its own audit gates.
    min_run_pages = max(2, int(policy.get("min_pages_per_nonterminal_run", 2) or 2))
    min_primary_pages = max(3, int(policy.get("min_pages_per_primary_source", 3) or 3))
    min_project_lookups = max(3, int(policy.get("min_project_lookups", 3) or 3))
    required_low_novelty = max(2, int(policy.get("saturation_low_novelty_pages", 2) or 2))
    novelty_threshold = min(0.10, max(0.0, float(policy.get("saturation_novelty_threshold", 0.10))))
    hard_cap_min_pages = max(5, int(policy.get("hard_cap_min_pages", 5) or 5))
    require_evidence = True
    require_page_metrics = True

    lanes = Counter()
    primary_pages = defaultdict(int)
    comparison_areas = set()
    project_lookups = set()
    seen_run_ids = set()
    seen_run_fingerprints = set()
    for run in runs:
        rid = clean_text(run.get("run_id"))
        lane = clean_text(run.get("lane"))
        terminal = clean_text(run.get("terminal_reason"))
        pages = int(run.get("pages_examined") or 0)
        metrics = run.get("page_metrics") or []
        fingerprint = tuple(norm_text(run.get(k)) for k in ("source_key", "lane", "query", "area", "url", "evidence_ref"))
        if not rid or rid in seen_run_ids:
            add(issues, "blocker", "duplicate_or_missing_search_run_id", rid)
        else:
            seen_run_ids.add(rid)
        if fingerprint in seen_run_fingerprints:
            add(issues, "blocker", "duplicate_search_run", rid)
        else:
            seen_run_fingerprints.add(fingerprint)
        if require_evidence and (not clean_text(run.get("url")) or not clean_text(run.get("evidence_ref"))):
            add(issues, "blocker", "search_run_missing_browser_evidence", rid)
        elif require_evidence:
            ref = clean_text(run.get("evidence_ref"))
            parsed = urlparse(ref)
            if parsed.scheme:
                add(issues, "blocker", "search_run_evidence_must_be_local", rid, ref)
            else:
                candidate = Path(ref)
                if not candidate.is_absolute():
                    candidate = Path(args.collection_log).resolve().parent.parent / candidate
                if not candidate.exists():
                    add(issues, "blocker", "search_run_evidence_not_found", rid, ref)
                elif not candidate.is_file() or candidate.stat().st_size == 0:
                    add(issues, "blocker", "search_run_evidence_empty", rid, ref)
        if lane not in VALID_LANES:
            add(issues, "blocker", "invalid_search_lane", rid, lane)
            continue
        lanes[lane] += 1
        if terminal not in VALID_TERMINALS:
            add(issues, "blocker", "search_run_without_terminal_reason", rid, terminal)
        if pages <= 0 and terminal not in {"zero_results", "blocked"}:
            add(issues, "blocker", "search_run_without_examined_page", rid)
        if pages < min_run_pages and terminal not in EARLY_TERMINALS:
            add(issues, "blocker", "shallow_search_without_valid_early_stop", rid, f"{pages}/{min_run_pages}; {terminal}")
        if pages < min_run_pages and terminal in EARLY_TERMINALS and not clean_text(run.get("notes")):
            add(issues, "blocker", "early_stop_missing_explanation", rid, terminal)
        if require_page_metrics and pages > 0 and len(metrics) != pages:
            add(issues, "blocker", "page_metrics_incomplete", rid, f"{len(metrics)}/{pages}")
        metric_fields = ("results_seen", "new_unique_listings", "new_unique_projects", "new_qualified_listings")
        invalid_metric = False
        verified_filter_pages = 0
        for page_index, metric in enumerate(metrics, start=1):
            if not isinstance(metric, dict):
                invalid_metric = True
                add(issues, "blocker", "page_metric_invalid", rid, f"page {page_index}: not an object")
                continue
            for field in metric_fields:
                value = metric.get(field)
                if not isinstance(value, int) or value < 0:
                    invalid_metric = True
                    add(issues, "blocker", "page_metric_invalid", rid, f"page {page_index}: {field}")
            if not invalid_metric and not (
                metric["new_unique_projects"] <= metric["new_unique_listings"] <= metric["results_seen"]
            ):
                invalid_metric = True
                add(issues, "blocker", "page_metric_impossible_counts", rid, f"page {page_index}")
            if clean_text(run.get("source_role")) == "primary_discovery" and lane != "project_lookup":
                if metric.get("filters_verified") is not True:
                    add(issues, "blocker", "page_filter_integrity_unverified", rid, f"page {page_index}")
                else:
                    verified_filter_pages += 1
        if metrics and not invalid_metric:
            metric_totals = {field: sum(metric[field] for metric in metrics) for field in metric_fields}
            run_totals = {
                "results_seen": int(run.get("results_seen") or 0),
                "new_unique_listings": int(run.get("new_unique_listings") or 0),
                "new_unique_projects": int(run.get("new_unique_projects") or 0),
            }
            mismatches = [f"{field} {metric_totals[field]}/{run_totals[field]}" for field in run_totals if metric_totals[field] != run_totals[field]]
            if mismatches:
                add(issues, "blocker", "page_metrics_do_not_match_run_totals", rid, "; ".join(mismatches))
        if terminal == "saturation":
            declared = int(run.get("consecutive_low_novelty_pages") or 0)
            demonstrated = 0
            for metric in reversed(metrics):
                if not isinstance(metric, dict):
                    break
                seen = int(metric.get("results_seen") or 0)
                new_projects = int(metric.get("new_unique_projects") or 0)
                new_qualified = int(metric.get("new_qualified_listings") or 0)
                novelty = (new_projects / seen) if seen else 0.0
                if seen > 0 and novelty < novelty_threshold and new_qualified == 0:
                    demonstrated += 1
                else:
                    break
            if declared < required_low_novelty or demonstrated < required_low_novelty:
                add(issues, "blocker", "saturation_not_demonstrated", rid, f"declared={declared}; calculated={demonstrated}; required={required_low_novelty}")
        if terminal == "hard_cap_with_reason":
            if not clean_text(run.get("notes")):
                add(issues, "blocker", "hard_cap_missing_reason", rid)
            if pages < hard_cap_min_pages:
                add(issues, "blocker", "hard_cap_too_shallow", rid, f"{pages}/{hard_cap_min_pages}")
        if clean_text(run.get("source_role")) == "primary_discovery" and lane != "project_lookup":
            primary_pages[clean_text(run.get("source_key"))] += verified_filter_pages
        if lane == "comparison_area" and clean_text(run.get("area")):
            comparison_areas.add(norm_text(run.get("area")))
        if lane == "project_lookup":
            project_key = norm_text(run.get("query"))
            if not project_key:
                add(issues, "blocker", "project_lookup_missing_project_query", rid)
            else:
                project_lookups.add(project_key)

    location = brief.get("location_strategy") or {}
    mode = clean_text(location.get("mode")) or "citywide_with_preferences"
    preferred = ensure_list(location.get("preferred_areas") or brief.get("target_areas"))
    preferred_norm = [norm_text(x) for x in preferred if norm_text(x)]
    for run in runs:
        if run.get("lane") == "citywide_baseline":
            scope = norm_text(clean_text(run.get("query")) + clean_text(run.get("area")))
            if clean_text(run.get("area")) or any(x and x in scope for x in preferred_norm):
                add(issues, "blocker", "citywide_baseline_contains_preference_constraint", run.get("run_id"), clean_text(run.get("area")) or clean_text(run.get("query")))
        if run.get("lane") == "comparison_area":
            area_norm = norm_text(run.get("area"))
            if any(x and (x in area_norm or area_norm in x) for x in preferred_norm):
                add(issues, "blocker", "comparison_area_overlaps_preference", run.get("run_id"), clean_text(run.get("area")))
                comparison_areas.discard(area_norm)
    if mode != "hard_boundary" and not lanes["citywide_baseline"]:
        add(issues, "blocker", "missing_citywide_baseline")
    if mode == "citywide_with_preferences" and preferred and not lanes["preferred_area"]:
        add(issues, "blocker", "missing_preferred_area_search")
    preferred_run_text = norm_text(" ".join(clean_text(x.get("query")) + " " + clean_text(x.get("area")) for x in runs if x.get("lane") in {"preferred_area", "transit_corridor"}))
    if mode == "citywide_with_preferences":
        for area in preferred:
            if norm_text(area) and norm_text(area) not in preferred_run_text:
                add(issues, "blocker", "preferred_area_not_searched", detail=clean_text(area))
    required_comparisons = 0 if mode == "hard_boundary" else max(2, int(location.get("comparison_area_min", policy.get("min_comparison_areas", 2)) or 2))
    if len(comparison_areas) < required_comparisons:
        add(issues, "blocker", "comparison_area_minimum_not_met", detail=f"{len(comparison_areas)}/{required_comparisons}")
    if len(project_lookups) < min_project_lookups:
        add(issues, "blocker", "project_lookup_minimum_not_met", detail=f"{len(project_lookups)}/{min_project_lookups}")

    lookup_text = " ".join(clean_text(x.get("query")) + " " + clean_text(x.get("area")) + " " + clean_text(x.get("notes")) for x in runs if x.get("lane") == "project_lookup")
    for project in ensure_list(location.get("user_named_projects")):
        if clean_text(project) and norm_text(project) not in norm_text(lookup_text):
            add(issues, "blocker", "user_named_project_not_searched", detail=clean_text(project))

    project_counts = Counter(clean_text(x.get("project_name")) for x in listings if clean_text(x.get("project_name")))
    for project, _ in project_counts.most_common(min(min_project_lookups, len(project_counts))):
        if norm_text(project) not in norm_text(lookup_text):
            add(issues, "blocker", "high_frequency_project_not_reverse_searched", detail=project)

    if not primary_pages:
        add(issues, "blocker", "no_primary_discovery_depth_recorded")
    for source_key, pages in primary_pages.items():
        if pages < min_primary_pages:
            add(issues, "blocker", "primary_source_page_minimum_not_met", detail=f"{source_key}: {pages}/{min_primary_pages}")
    planned_primary = [x for x in source_plan.get("sources", []) if clean_text(x.get("role")) == "primary_discovery" and clean_text(x.get("status")) == "completed_with_results"]
    for source in planned_primary:
        key = clean_text(source.get("source_key"))
        if key and key not in primary_pages:
            add(issues, "blocker", "completed_primary_source_without_depth_record", detail=key)

    preferred_share = None
    if preferred and listings:
        hits = sum(1 for x in listings if any(norm_text(a) and norm_text(a) in norm_text(location_text(x)) for a in preferred))
        preferred_share = hits / len(listings)
        threshold = min(0.80, float(policy.get("preferred_area_share_warning", 0.80)))
        if mode != "hard_boundary" and preferred_share > threshold:
            add(issues, "blocker", "preferred_area_sample_concentration", detail=f"{hits}/{len(listings)}={preferred_share:.1%}")

    counts = Counter(x["severity"] for x in issues)
    report = {
        "summary": {
            "search_run_count": len(runs),
            "counts_by_lane": dict(lanes),
            "primary_pages_by_source": dict(primary_pages),
            "comparison_area_count": len(comparison_areas),
            "project_lookup_count": len(project_lookups),
            "preferred_area_listing_share": round(preferred_share, 4) if preferred_share is not None else None,
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
