#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import sys
from pathlib import Path
from _common import load_json, save_json, now_iso, slug_hash


def main():
    ap = argparse.ArgumentParser(description="Append one listing JSON record safely to raw_listings.json")
    ap.add_argument("raw_file")
    ap.add_argument("--json", dest="json_text", help="Listing JSON object. If omitted, read stdin.")
    args = ap.parse_args()
    payload = json.loads(args.json_text if args.json_text is not None else sys.stdin.read())
    if not isinstance(payload, dict):
        raise SystemExit("Listing must be one JSON object")
    payload.setdefault("captured_at", now_iso())
    payload.setdefault("verification_status", "unverified")
    payload.setdefault("red_flags", [])
    payload.setdefault("image_refs", [])
    payload.setdefault("features", [])
    payload.setdefault("business_constraints", [])
    payload.setdefault("source_id", slug_hash(payload.get("source_url"), payload.get("listing_title"), prefix="src"))
    rows = load_json(args.raw_file, [])
    if not isinstance(rows, list):
        raise SystemExit("raw file must contain a JSON array")
    # Exact-source dedupe only. Never silently dedupe likely same physical units here.
    if payload.get("source_url") and any(r.get("source_url") == payload.get("source_url") for r in rows if isinstance(r, dict)):
        print("duplicate_source_url: not appended")
        return
    rows.append(payload)
    save_json(args.raw_file, rows)
    print(payload["source_id"])

if __name__ == "__main__":
    main()
