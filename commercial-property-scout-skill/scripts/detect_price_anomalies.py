#!/usr/bin/env python3
from __future__ import annotations

import argparse
from copy import deepcopy
from typing import Any

from _common import clean_text, load_json, median, pct_diff, save_json
from _optional_deps import get_pandas


def area_close(a, b, tol=0.30):
    if a is None or b is None or a <= 0 or b <= 0:
        return True
    return abs(a - b) / max(a, b) <= tol


def comparable_pool_stdlib(target, props, value_field):
    asset = clean_text(target.get("asset_type"))
    project = clean_text(target.get("project_name_norm") or target.get("project_name"))
    area = target.get("area_sqm")
    same_project = [p for p in props if p is not target and clean_text(p.get("project_name_norm") or p.get("project_name")) == project and clean_text(p.get("asset_type")) == asset and p.get(value_field) is not None]
    if len(same_project) >= 4:
        return same_project, "same_project"

    submarket = clean_text(target.get("submarket"))
    if submarket:
        group = [p for p in props if p is not target and clean_text(p.get("submarket")) == submarket and clean_text(p.get("asset_type")) == asset and p.get(value_field) is not None and area_close(area, p.get("area_sqm"), .30)]
        if len(group) >= 4:
            return group, "same_submarket_area±30%"

    district = clean_text(target.get("district"))
    if district:
        group = [p for p in props if p is not target and clean_text(p.get("district")) == district and clean_text(p.get("asset_type")) == asset and p.get(value_field) is not None and area_close(area, p.get("area_sqm"), .30)]
        if len(group) >= 4:
            return group, "same_district_area±30%"
    return [], "insufficient_comparables"


def label(delta):
    if delta is None:
        return "unknown"
    if delta <= -0.30:
        return "low_ge_30pct"
    if delta <= -0.20:
        return "low_20_30pct"
    if delta <= -0.15:
        return "low_15_20pct"
    if delta >= 0.35:
        return "high_ge_35pct"
    return "within_expected_band"


def annotate(p: dict[str, Any], pool_values: list[float], scope: str, value_field: str) -> dict[str, Any]:
    base = median(pool_values)
    val = p.get(value_field)
    delta = pct_diff(val, base)
    anomaly = label(delta)
    p["price_anomaly"] = {
        "metric": value_field,
        "comparable_scope": scope,
        "comparable_count": len(pool_values),
        "comparable_median": round(base, 4) if base is not None else None,
        "candidate_value": val,
        "delta_vs_median": round(delta, 4) if delta is not None else None,
        "label": anomaly,
        "interpretation": "warning_only_not_fraud_determination"
    }
    flags = list(p.get("red_flags") or [])
    if anomaly == "low_15_20pct":
        flags.append("price_lightly_below_comparables")
    elif anomaly == "low_20_30pct":
        flags.append("price_materially_below_comparables")
    elif anomaly == "low_ge_30pct":
        flags.append("price_extremely_below_comparables_requires_explanation")
    p["red_flags"] = sorted(set(flags))
    return p


def run_stdlib(props: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for original in props:
        p = deepcopy(original)
        value_field = "rent_rmb_sqm_day" if p.get("transaction_type") == "rent" else "sale_rmb_sqm"
        pool, scope = comparable_pool_stdlib(p, props, value_field)
        out.append(annotate(p, [x.get(value_field) for x in pool if x.get(value_field) is not None], scope, value_field))
    return out


def run_pandas(props: list[dict[str, Any]]) -> list[dict[str, Any]]:
    pd = get_pandas(required=True)
    if not props:
        return []
    df = pd.DataFrame(props).copy()
    df["__idx"] = range(len(df))
    if "project_name_norm" not in df.columns:
        df["project_name_norm"] = ""
    if "project_name" not in df.columns:
        df["project_name"] = ""
    for field in ("asset_type", "submarket", "district", "transaction_type"):
        if field not in df.columns:
            df[field] = ""
        df[field] = df[field].fillna("").astype(str).str.strip()
    df["__project"] = df["project_name_norm"].fillna("").astype(str).str.strip()
    empty_project = df["__project"].eq("")
    df.loc[empty_project, "__project"] = df.loc[empty_project, "project_name"].fillna("").astype(str).str.strip()
    if "area_sqm" not in df.columns:
        df["area_sqm"] = None
    df["area_sqm"] = pd.to_numeric(df["area_sqm"], errors="coerce")
    for field in ("rent_rmb_sqm_day", "sale_rmb_sqm"):
        if field not in df.columns:
            df[field] = None
        df[field] = pd.to_numeric(df[field], errors="coerce")

    # Pre-block by asset/project/submarket/district. This avoids repeated full-table scans.
    project_groups = {k: g for k, g in df.groupby(["asset_type", "__project"], dropna=False, sort=False)}
    submarket_groups = {k: g for k, g in df.groupby(["asset_type", "submarket"], dropna=False, sort=False)}
    district_groups = {k: g for k, g in df.groupby(["asset_type", "district"], dropna=False, sort=False)}

    out = []
    for idx, original in enumerate(props):
        p = deepcopy(original)
        tx = clean_text(p.get("transaction_type"))
        value_field = "rent_rmb_sqm_day" if tx == "rent" else "sale_rmb_sqm"
        asset = clean_text(p.get("asset_type"))
        project = clean_text(p.get("project_name_norm") or p.get("project_name"))
        submarket = clean_text(p.get("submarket"))
        district = clean_text(p.get("district"))
        area = p.get("area_sqm")
        pool_df = project_groups.get((asset, project))
        scope = "insufficient_comparables"
        candidates = None
        if pool_df is not None:
            candidates = pool_df[(pool_df["__idx"] != idx) & pool_df[value_field].notna()]
            if len(candidates) >= 4:
                scope = "same_project"
        if scope == "insufficient_comparables" and submarket:
            g = submarket_groups.get((asset, submarket))
            if g is not None:
                cand = g[(g["__idx"] != idx) & g[value_field].notna()].copy()
                if area is not None and float(area) > 0:
                    a = float(area)
                    # symmetric relative tolerance using max(a,b) <= 30%
                    cand = cand[(cand["area_sqm"].isna()) | (((cand["area_sqm"] - a).abs() / cand["area_sqm"].clip(lower=a)) <= .30)]
                if len(cand) >= 4:
                    candidates = cand; scope = "same_submarket_area±30%"
        if scope == "insufficient_comparables" and district:
            g = district_groups.get((asset, district))
            if g is not None:
                cand = g[(g["__idx"] != idx) & g[value_field].notna()].copy()
                if area is not None and float(area) > 0:
                    a = float(area)
                    cand = cand[(cand["area_sqm"].isna()) | (((cand["area_sqm"] - a).abs() / cand["area_sqm"].clip(lower=a)) <= .30)]
                if len(cand) >= 4:
                    candidates = cand; scope = "same_district_area±30%"
        values = [] if candidates is None or scope == "insufficient_comparables" else [float(x) for x in candidates[value_field].dropna().tolist()]
        out.append(annotate(p, values, scope, value_field))
    return out


def main():
    ap = argparse.ArgumentParser(description="Flag price anomalies relative to conservative comparable-property medians.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--engine", choices=["auto", "pandas", "stdlib"], default="auto")
    args = ap.parse_args()
    props = load_json(args.input, [])
    if not isinstance(props, list):
        raise SystemExit("input must be a JSON array")
    props = [p for p in props if isinstance(p, dict)]
    pd = get_pandas(required=False)
    use_pd = args.engine == "pandas" or (args.engine == "auto" and pd is not None)
    if args.engine == "pandas" and pd is None:
        raise SystemExit("pandas requested but unavailable")
    out = run_pandas(props) if use_pd else run_stdlib(props)
    save_json(args.output, out)
    counts = {}
    for p in out:
        k = p.get("price_anomaly", {}).get("label")
        counts[k] = counts.get(k, 0) + 1
    print({"engine": "pandas" if use_pd else "stdlib", "counts": counts})


if __name__ == "__main__":
    main()
