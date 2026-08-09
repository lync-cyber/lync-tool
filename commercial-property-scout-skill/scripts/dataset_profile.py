#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from _common import clean_text, load_json, median, platform_key, read_registry, save_json, source_role
from _optional_deps import get_pandas

CORE_FIELDS = [
    "source_platform", "source_url", "project_name", "address_raw", "district", "submarket",
    "area_sqm", "asking_price_raw", "rent_rmb_sqm_day", "rent_rmb_month", "sale_total_rmb",
    "sale_rmb_sqm", "captured_at"
]


def q(values: list[float], p: float) -> float | None:
    vals = sorted(float(x) for x in values if x is not None and not math.isnan(float(x)))
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * p
    lo, hi = int(math.floor(pos)), int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    frac = pos - lo
    return vals[lo] * (1 - frac) + vals[hi] * frac


def stdlib_profile(rows: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(rows)
    missing = {}
    for f in CORE_FIELDS:
        count = sum(1 for r in rows if r.get(f) in (None, "", [], {}))
        missing[f] = {"missing": count, "ratio": round(count / n, 4) if n else 0.0}
    by_platform = Counter(clean_text(r.get("source_platform")) or "unknown" for r in rows)
    by_district = Counter(clean_text(r.get("district")) or "unknown" for r in rows)
    by_project = Counter(clean_text(r.get("project_name")) or "unknown" for r in rows)
    price_fields = ["rent_rmb_sqm_day", "rent_rmb_month", "sale_rmb_sqm", "sale_total_rmb", "area_sqm"]
    stats = {}
    for f in price_fields:
        vals = []
        for r in rows:
            try:
                v = float(r.get(f)) if r.get(f) is not None else None
                if v is not None and not math.isnan(v):
                    vals.append(v)
            except Exception:
                pass
        stats[f] = {
            "count": len(vals), "min": min(vals) if vals else None, "p25": q(vals, .25),
            "median": median(vals), "p75": q(vals, .75), "max": max(vals) if vals else None
        }
    return {
        "engine": "stdlib",
        "row_count": n,
        "missingness": missing,
        "counts_by_platform": dict(by_platform.most_common()),
        "counts_by_district": dict(by_district.most_common()),
        "top_projects": dict(by_project.most_common(30)),
        "numeric_summary": stats,
    }


def pandas_profile(rows: list[dict[str, Any]]) -> dict[str, Any]:
    pd = get_pandas(required=True)
    df = pd.DataFrame(rows)
    n = len(df)
    missing = {}
    for f in CORE_FIELDS:
        if f not in df.columns:
            missing[f] = {"missing": n, "ratio": 1.0 if n else 0.0}
            continue
        s = df[f]
        is_missing = s.isna() | s.astype(str).str.strip().isin(["", "[]", "{}"])
        count = int(is_missing.sum())
        missing[f] = {"missing": count, "ratio": round(count / n, 4) if n else 0.0}

    def counts(field: str, top: int | None = None):
        if field not in df.columns:
            return {}
        s = df[field].fillna("unknown").astype(str).str.strip().replace("", "unknown")
        vc = s.value_counts(dropna=False)
        if top is not None:
            vc = vc.head(top)
        return {str(k): int(v) for k, v in vc.items()}

    numeric = {}
    for f in ("rent_rmb_sqm_day", "rent_rmb_month", "sale_rmb_sqm", "sale_total_rmb", "area_sqm"):
        if f not in df.columns:
            numeric[f] = {"count": 0, "min": None, "p25": None, "median": None, "p75": None, "max": None}
            continue
        s = pd.to_numeric(df[f], errors="coerce").dropna()
        numeric[f] = {
            "count": int(s.count()),
            "min": float(s.min()) if len(s) else None,
            "p25": float(s.quantile(.25)) if len(s) else None,
            "median": float(s.median()) if len(s) else None,
            "p75": float(s.quantile(.75)) if len(s) else None,
            "max": float(s.max()) if len(s) else None,
        }

    group_price = []
    if {"district", "asset_type", "rent_rmb_sqm_day"}.issubset(df.columns):
        work = df.copy()
        work["rent_rmb_sqm_day"] = pd.to_numeric(work["rent_rmb_sqm_day"], errors="coerce")
        g = work.dropna(subset=["rent_rmb_sqm_day"]).groupby(["district", "asset_type"], dropna=False)["rent_rmb_sqm_day"].agg(["count", "median", "min", "max"]).reset_index()
        for row in g.to_dict(orient="records"):
            group_price.append({
                "district": clean_text(row.get("district")) or "unknown",
                "asset_type": clean_text(row.get("asset_type")) or "unknown",
                "count": int(row.get("count") or 0),
                "median": float(row.get("median")) if row.get("median") is not None else None,
                "min": float(row.get("min")) if row.get("min") is not None else None,
                "max": float(row.get("max")) if row.get("max") is not None else None,
            })

    return {
        "engine": "pandas",
        "row_count": n,
        "missingness": missing,
        "counts_by_platform": counts("source_platform"),
        "counts_by_district": counts("district"),
        "top_projects": counts("project_name", 30),
        "numeric_summary": numeric,
        "rent_summary_by_district_asset": group_price,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate reusable data-quality/source/price profile for raw or normalized listings.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--engine", choices=["auto", "pandas", "stdlib"], default="auto")
    ap.add_argument("--csv-dir", help="With pandas, also write simple CSV summary tables here")
    ap.add_argument("--source-registry", help="Optional source registry for canonical platform and role coverage")
    args = ap.parse_args()

    rows = load_json(args.input, [])
    if not isinstance(rows, list):
        raise SystemExit("input must be a JSON array")
    rows = [r for r in rows if isinstance(r, dict)]
    pd = get_pandas(required=False)
    use_pd = args.engine == "pandas" or (args.engine == "auto" and pd is not None)
    if args.engine == "pandas" and pd is None:
        raise SystemExit("pandas requested but unavailable")
    profile = pandas_profile(rows) if use_pd else stdlib_profile(rows)
    registry = read_registry(args.source_registry)
    canonical = Counter(platform_key(r.get("source_platform", "")) for r in rows)
    roles = Counter(source_role(r.get("source_platform", ""), registry) for r in rows)
    total = sum(canonical.values())
    dominant = canonical.most_common(1)[0] if canonical else ("unknown", 0)
    profile["counts_by_canonical_platform"] = dict(canonical.most_common())
    profile["counts_by_source_role"] = dict(roles.most_common())
    profile["source_concentration"] = {
        "dominant_platform": dominant[0],
        "dominant_count": dominant[1],
        "dominant_share": round(dominant[1] / total, 4) if total else 0.0,
    }
    save_json(args.output, profile)

    if args.csv_dir and use_pd:
        pd = get_pandas(required=True)
        outdir = Path(args.csv_dir); outdir.mkdir(parents=True, exist_ok=True)
        for key in ("counts_by_platform", "counts_by_district", "top_projects"):
            table = pd.DataFrame(list(profile.get(key, {}).items()), columns=["key", "count"])
            table.to_csv(outdir / f"{key}.csv", index=False, encoding="utf-8-sig")
        pd.DataFrame(profile.get("rent_summary_by_district_asset", [])).to_csv(outdir / "rent_summary_by_district_asset.csv", index=False, encoding="utf-8-sig")
    print(json.dumps({"engine": profile["engine"], "row_count": profile["row_count"], "output": str(Path(args.output).resolve())}, ensure_ascii=False))


if __name__ == "__main__":
    main()
