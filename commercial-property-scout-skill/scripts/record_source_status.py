#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from _common import clean_text, load_json, now_iso, save_json

ROLES = {"primary_discovery", "broad_discovery", "verification", "benchmark", "lead_only"}
STATUSES = {
    "planned", "in_progress", "completed_with_results", "completed_zero_results",
    "blocked_login", "blocked_captcha", "access_limited", "unavailable", "skipped_with_reason",
}


def main():
    ap = argparse.ArgumentParser(description="Add or update a structured source-attempt record.")
    ap.add_argument("source_plan")
    ap.add_argument("--key", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--role", required=True, choices=sorted(ROLES))
    ap.add_argument("--priority", choices=["critical", "high", "normal", "low"], default="normal")
    ap.add_argument("--status", required=True, choices=sorted(STATUSES))
    ap.add_argument("--url", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--result-count", type=int)
    ap.add_argument("--substitute-key", default="")
    ap.add_argument("--state", help="Optional workspace state.json to keep in sync")
    args = ap.parse_args()

    path = Path(args.source_plan)
    plan = load_json(path, {})
    sources = plan.setdefault("sources", [])
    key = clean_text(args.key)
    record = next((x for x in sources if clean_text(x.get("source_key")) == key), None)
    if record is None:
        record = {"source_key": key, "created_at": now_iso()}
        sources.append(record)
    record.update({
        "display_name": clean_text(args.name),
        "role": args.role,
        "priority": args.priority,
        "status": args.status,
        "url": clean_text(args.url),
        "status_reason": clean_text(args.reason),
        "result_count": args.result_count,
        "substitute_key": clean_text(args.substitute_key),
        "updated_at": now_iso(),
    })
    plan["last_updated_at"] = now_iso()
    save_json(path, plan)

    if args.state:
        state_path = Path(args.state)
        state = load_json(state_path, {})
        state["last_updated_at"] = now_iso()
        state["source_plan_path"] = str(path)
        if args.status == "blocked_captcha":
            state["captcha_waiting_on"] = {"source_key": key, "url": args.url, "action": args.reason or "Complete the site challenge manually"}
        elif args.status in {"in_progress", "completed_with_results", "completed_zero_results"}:
            waiting = state.get("captcha_waiting_on") or {}
            if clean_text(waiting.get("source_key")) == key:
                state.pop("captcha_waiting_on", None)
                state["captcha_last_resolved"] = {"source_key": key, "resolved_at": now_iso(), "resumed_status": args.status}
        save_json(state_path, state)
    print(f"source={key} status={args.status}")


if __name__ == "__main__":
    main()
