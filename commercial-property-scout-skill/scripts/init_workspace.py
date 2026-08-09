#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path
from _common import now_iso, save_json


def main():
    ap = argparse.ArgumentParser(description="Initialize a commercial property search workspace.")
    ap.add_argument("workspace", help="Target workspace directory")
    ap.add_argument("--city", default="")
    ap.add_argument("--asset-type", default="")
    ap.add_argument("--transaction-type", default="rent", choices=["rent", "sale"])
    args = ap.parse_args()

    root = Path(args.workspace)
    for rel in ["data", "data/imports", "assets/images", "evidence/screenshots", "evidence/pages", "evidence/page_extracts", "notes"]:
        (root / rel).mkdir(parents=True, exist_ok=True)

    brief = {
        "city": args.city,
        "transaction_type": args.transaction_type,
        "asset_type": args.asset_type,
        "business_use": "",
        "target_areas": [],
        "location_strategy": {
            "mode": "citywide",
            "preferred_areas": [],
            "hard_boundary_areas": [],
            "comparison_area_min": 2,
            "user_named_projects": []
        },
        "budget": {
            "cost_basis": "unknown",
            "fixed_monthly_cost_ideal_rmb": None,
            "fixed_monthly_cost_max_rmb": None,
            "monthly_ideal_rmb": None,
            "monthly_max_rmb": None
        },
        "area_range": {"min_sqm": None, "max_sqm": None},
        "move_in_date": "",
        "lease_term": "",
        "must_have": [],
        "hard_requirements": [],
        "nice_to_have": [],
        "exclusions": [],
        "site_visit_constraints": {"dates": [], "start_location": "", "transport_mode": "public_transit"},
        "assumptions": [],
        "desired_report_maturity": "research_shortlist",
        "interview": {
            "status": "pending",
            "decisions": [],
            "unresolved_critical": [],
            "completed_at": ""
        }
    }
    source_plan = {
        "version": 1,
        "created_at": now_iso(),
        "last_updated_at": now_iso(),
        "market_context": {"city": args.city, "asset_type": args.asset_type, "transaction_type": args.transaction_type},
        "coverage_policy": {
            "min_terminal_attempts_by_role": {"primary_discovery": 2, "verification": 1, "benchmark": 2},
            "min_high_priority_terminal_attempts": 1,
            "max_single_platform_share_warning": 0.65
        },
        "sources": [],
        "selection_notes": ["Choose sources for this market from the registry and current public availability; no platform is globally mandatory."]
    }
    collection_log = {
        "version": 1,
        "created_at": now_iso(),
        "last_updated_at": now_iso(),
        "coverage_policy": {
            "min_pages_per_nonterminal_run": 2,
            "min_pages_per_primary_source": 3,
            "min_comparison_areas": 2,
            "min_project_lookups": 3,
            "saturation_low_novelty_pages": 2,
            "saturation_novelty_threshold": 0.10,
            "hard_cap_min_pages": 5,
            "require_search_evidence": True,
            "require_page_metrics": True,
            "preferred_area_share_warning": 0.80
        },
        "search_runs": []
    }
    state = {
        "started_at": now_iso(),
        "last_updated_at": now_iso(),
        "interview_status": "pending",
        "brief_complete": False,
        "source_plan_path": str(root / "data/source_plan.json"),
        "captcha_waiting_on": None,
        "raw_listing_count": 0,
        "deduped_property_count": 0,
        "verified_property_count": 0,
        "report_path": "",
        "report_maturity": "discovery_draft",
        "next_actions": ["Complete the requirement interview", "Validate the brief", "Create and execute the source plan"]
    }
    save_json(root / "data/search_brief.json", brief)
    save_json(root / "data/raw_listings.json", [])
    save_json(root / "data/source_plan.json", source_plan)
    save_json(root / "data/collection_log.json", collection_log)
    save_json(root / "data/normalized_listings.json", [])
    save_json(root / "data/properties.json", [])
    save_json(root / "state.json", state)
    print(root.resolve())

if __name__ == "__main__":
    main()
