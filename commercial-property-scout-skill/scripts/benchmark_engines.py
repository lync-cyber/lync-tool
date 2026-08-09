#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from _optional_deps import dependency_report


def synth(n: int) -> list[dict]:
    rows = []
    for i in range(n):
        project_idx = i // 10
        area = 180 + (i % 10) * 4
        daily = 4.0 + (i % 10) * .1
        rows.append({
            "source_id": f"s{i}",
            "source_platform": "贝壳" if i % 2 else "房天下",
            "source_url": f"https://benchmark.invalid/{i}",
            "transaction_type": "rent",
            "asset_type": "写字楼",
            "project_name": f"项目{project_idx:04d}",
            "project_name_norm": f"项目{project_idx:04d}",
            "address_raw": f"浦东测试路{project_idx}号",
            "address_norm": f"浦东测试路{project_idx}号",
            "district": "浦东",
            "submarket": f"商圈{project_idx // 10}",
            "area_sqm": area,
            "floor": f"{i % 20}F",
            "unit_or_room": f"{100000+i}",
            "rent_rmb_sqm_day": daily,
            "rent_rmb_month": daily * area * 365 / 12,
            "features": [], "business_constraints": [], "red_flags": [], "image_refs": []
        })
    return rows


def timed(cmd):
    t = time.perf_counter()
    p = subprocess.run([str(x) for x in cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return round(time.perf_counter() - t, 4), p.returncode, p.stdout.strip(), p.stderr.strip()


def main():
    ap = argparse.ArgumentParser(description="Maintenance benchmark for pandas vs stdlib duplicate/anomaly engines using synthetic data.")
    ap.add_argument("--rows", type=int, default=600)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    deps = dependency_report()
    if not deps["pandas"]["available"]:
        raise SystemExit("pandas unavailable; benchmark requires enhanced dependencies")
    skill = Path(__file__).resolve().parents[1]
    py = sys.executable
    results = []
    with tempfile.TemporaryDirectory(prefix="property-scout-bench-") as td:
        td = Path(td)
        inp = td / "rows.json"
        inp.write_text(json.dumps(synth(args.rows), ensure_ascii=False), encoding="utf-8")
        for script in ("detect_price_anomalies.py", "dedupe_properties.py"):
            for engine in ("stdlib", "pandas"):
                out = td / f"{script}_{engine}.json"
                cmd = [py, skill/"scripts"/script, inp, "-o", out, "--engine", engine]
                if script == "dedupe_properties.py" and engine == "pandas":
                    cmd += ["--pandas-threshold", "1"]
                secs, code, stdout, stderr = timed(cmd)
                results.append({"script": script, "engine": engine, "seconds": secs, "returncode": code, "stdout": stdout, "stderr": stderr})
    payload = {"rows": args.rows, "results": results, "note": "Synthetic maintenance benchmark; thresholds are environment-dependent."}
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"rows={args.rows}")
        for r in results:
            print(f"{r['script']:28} {r['engine']:7} {r['seconds']:8.4f}s rc={r['returncode']}")


if __name__ == "__main__":
    main()
