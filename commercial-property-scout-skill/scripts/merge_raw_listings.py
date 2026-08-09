#!/usr/bin/env python3
from __future__ import annotations
import argparse
from _common import load_json, save_json, slug_hash


def main():
    ap = argparse.ArgumentParser(description="Merge worker raw listing arrays, removing only exact duplicate source URLs/IDs.")
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()
    out, seen = [], set()
    for path in args.inputs:
        rows = load_json(path, [])
        if not isinstance(rows, list):
            raise SystemExit(f"{path}: expected JSON array")
        for row in rows:
            if not isinstance(row, dict):
                continue
            row.setdefault("source_id", slug_hash(row.get("source_url"), row.get("listing_title"), prefix="src"))
            key = row.get("source_url") or row.get("source_id")
            if key in seen:
                continue
            seen.add(key)
            out.append(row)
    save_json(args.output, out)
    print(f"merged={len(out)}")

if __name__ == "__main__":
    main()
