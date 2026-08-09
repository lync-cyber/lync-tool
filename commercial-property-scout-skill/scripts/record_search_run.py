#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from _common import clean_text, load_json, now_iso, save_json, slug_hash

LANES = {"citywide_baseline", "preferred_area", "comparison_area", "project_lookup", "transit_corridor", "map_search"}
ROLES = {"primary_discovery", "broad_discovery", "lead_only"}
TERMINAL_REASONS = {"pagination_exhausted", "no_next_page", "zero_results", "saturation", "hard_cap_with_reason", "blocked"}


def main():
    ap = argparse.ArgumentParser(description="Append an auditable browser search run to collection_log.json.")
    ap.add_argument("collection_log")
    ap.add_argument("--source-key", required=True)
    ap.add_argument("--source-role", required=True, choices=sorted(ROLES))
    ap.add_argument("--lane", required=True, choices=sorted(LANES))
    ap.add_argument("--query", default="")
    ap.add_argument("--area", default="")
    ap.add_argument("--url", required=True, help="Visible browser result URL after filters were applied")
    ap.add_argument("--evidence-ref", required=True, help="Screenshot or saved-page reference proving this search state")
    ap.add_argument("--pages-examined", required=True, type=int)
    ap.add_argument("--results-seen", required=True, type=int)
    ap.add_argument("--new-unique-listings", required=True, type=int)
    ap.add_argument("--new-unique-projects", required=True, type=int)
    ap.add_argument("--consecutive-low-novelty-pages", type=int, default=0)
    ap.add_argument("--page-metrics", default="", help='JSON list with one object per examined page/batch, including result/new counts and filters_verified for primary discovery pages')
    ap.add_argument("--terminal-reason", required=True, choices=sorted(TERMINAL_REASONS))
    ap.add_argument("--notes", default="")
    args = ap.parse_args()

    if min(args.pages_examined, args.results_seen, args.new_unique_listings, args.new_unique_projects, args.consecutive_low_novelty_pages) < 0:
        raise SystemExit("counts must be non-negative")
    page_metrics = []
    if clean_text(args.page_metrics):
        try:
            page_metrics = json.loads(args.page_metrics)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid --page-metrics JSON: {exc}")
        if not isinstance(page_metrics, list) or not all(isinstance(x, dict) for x in page_metrics):
            raise SystemExit("--page-metrics must be a JSON list of objects")
        required_metric_fields = {"results_seen", "new_unique_listings", "new_unique_projects", "new_qualified_listings"}
        for index, metric in enumerate(page_metrics, start=1):
            missing = required_metric_fields.difference(metric)
            if missing:
                raise SystemExit(f"page metric {index} missing fields: {', '.join(sorted(missing))}")
            if any(not isinstance(metric[field], int) or metric[field] < 0 for field in required_metric_fields):
                raise SystemExit(f"page metric {index} counts must be non-negative integers")
            if not metric["new_unique_projects"] <= metric["new_unique_listings"] <= metric["results_seen"]:
                raise SystemExit(f"page metric {index} must satisfy projects <= listings <= results")
            if args.source_role == "primary_discovery" and args.lane != "project_lookup" and metric.get("filters_verified") is not True:
                raise SystemExit(f"page metric {index} must set filters_verified=true for primary discovery")
    path = Path(args.collection_log)
    log = load_json(path, {"version": 1, "created_at": now_iso(), "coverage_policy": {}, "search_runs": []})
    runs = log.setdefault("search_runs", [])
    stamp = now_iso()
    run = {
        "run_id": slug_hash(args.source_key, args.lane, args.query, args.area, stamp, prefix="search"),
        "source_key": clean_text(args.source_key),
        "source_role": args.source_role,
        "lane": args.lane,
        "query": clean_text(args.query),
        "area": clean_text(args.area),
        "url": clean_text(args.url),
        "evidence_ref": clean_text(args.evidence_ref),
        "started_at": stamp,
        "completed_at": stamp,
        "pages_examined": args.pages_examined,
        "results_seen": args.results_seen,
        "new_unique_listings": args.new_unique_listings,
        "new_unique_projects": args.new_unique_projects,
        "consecutive_low_novelty_pages": args.consecutive_low_novelty_pages,
        "page_metrics": page_metrics,
        "terminal_reason": args.terminal_reason,
        "notes": clean_text(args.notes),
    }
    runs.append(run)
    log["last_updated_at"] = stamp
    save_json(path, log)
    print(f"run={run['run_id']} source={run['source_key']} lane={run['lane']} pages={run['pages_examined']}")


if __name__ == "__main__":
    main()
