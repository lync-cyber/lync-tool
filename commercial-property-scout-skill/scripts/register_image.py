#!/usr/bin/env python3
from __future__ import annotations
import argparse
import shutil
from pathlib import Path
from _common import clean_text, load_json, save_json, slug_hash


def main():
    ap = argparse.ArgumentParser(description="Copy an already-obtained image/screenshot into workspace and attach provenance to a raw listing.")
    ap.add_argument("raw_file")
    ap.add_argument("source_id")
    ap.add_argument("image_file")
    ap.add_argument("--images-dir", required=True)
    ap.add_argument("--source-url", default="")
    ap.add_argument("--caption", default="")
    ap.add_argument("--kind", default="listing_page", choices=["listing_page","interior","exterior","street","public_area","map","floorplan","rendering","user_photo","other"])
    args = ap.parse_args()
    src = Path(args.image_file)
    if not src.exists(): raise SystemExit(f"image not found: {src}")
    rows = load_json(args.raw_file, [])
    match = next((r for r in rows if r.get("source_id") == args.source_id), None)
    if match is None: raise SystemExit(f"source_id not found: {args.source_id}")
    dest_dir = Path(args.images_dir); dest_dir.mkdir(parents=True, exist_ok=True)
    suffix = src.suffix.lower() or ".png"
    dest = dest_dir / f"{args.source_id}_{args.kind}_{slug_hash(src.name,args.caption,prefix='img',length=8).split('_',1)[1]}{suffix}"
    shutil.copy2(src, dest)
    ref = {"local_path": str(dest), "source_url": args.source_url or match.get("source_url") or "", "caption": args.caption, "kind": args.kind}
    match.setdefault("image_refs", []).append(ref)
    save_json(args.raw_file, rows)
    print(dest.resolve())

if __name__ == "__main__": main()
