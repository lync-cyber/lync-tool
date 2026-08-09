#!/usr/bin/env python3
from __future__ import annotations
import argparse
from collections import Counter
from copy import deepcopy
from difflib import SequenceMatcher
from _common import choose_level, clean_text, comparable_area, load_json, median, norm_text, platform_key, save_json, slug_hash
from _optional_deps import get_pandas


def same_floor(a: dict, b: dict) -> bool:
    fa, fb = clean_text(a.get("floor")), clean_text(b.get("floor"))
    return bool(fa and fb and fa == fb)


def same_unit(a: dict, b: dict) -> bool:
    ua, ub = norm_text(a.get("unit_or_room")), norm_text(b.get("unit_or_room"))
    return bool(ua and ub and ua == ub)


def name_similarity(a: str, b: str) -> float:
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    return SequenceMatcher(None, a, b).ratio()


def exact_image_overlap(a: dict, b: dict) -> bool:
    def urls(row):
        out = set()
        for item in row.get("image_refs") or []:
            if isinstance(item, str):
                out.add(item)
            elif isinstance(item, dict):
                for k in ("source_url", "local_path", "url"):
                    if item.get(k):
                        out.add(str(item[k]))
        return out
    x, y = urls(a), urls(b)
    return bool(x and y and x.intersection(y))


def duplicate_score(a: dict, b: dict) -> tuple[float, list[str]]:
    score, reasons = 0.0, []
    pa = a.get("project_name_norm") or norm_text(a.get("project_name"))
    pb = b.get("project_name_norm") or norm_text(b.get("project_name"))
    aa = a.get("address_norm") or norm_text(a.get("address_raw"))
    ab = b.get("address_norm") or norm_text(b.get("address_raw"))
    pn = name_similarity(pa, pb)
    an = name_similarity(aa, ab)
    if pa and pb and pn >= 0.96:
        score += 4; reasons.append("same_project")
    elif pa and pb and pn >= 0.88:
        score += 2; reasons.append("similar_project")
    if aa and ab and an >= 0.96:
        score += 3; reasons.append("same_address")
    if same_unit(a, b):
        score += 5; reasons.append("same_unit")
    if same_floor(a, b):
        score += 2; reasons.append("same_floor")
    if comparable_area(a.get("area_sqm"), b.get("area_sqm"), 0.03):
        score += 3; reasons.append("area_within_3pct")
    elif comparable_area(a.get("area_sqm"), b.get("area_sqm"), 0.05):
        score += 2; reasons.append("area_within_5pct")
    if exact_image_overlap(a, b):
        score += 5; reasons.append("exact_image_overlap")
    if clean_text(a.get("contact_visible")) and clean_text(a.get("contact_visible")) == clean_text(b.get("contact_visible")):
        score += 1; reasons.append("same_contact")
    # Strong merge requires physical identity evidence, not merely same project.
    return score, reasons


def should_merge(a: dict, b: dict) -> tuple[bool, list[str]]:
    score, reasons = duplicate_score(a, b)
    if "same_unit" in reasons and ("same_project" in reasons or "same_address" in reasons):
        return True, reasons
    if "exact_image_overlap" in reasons and "area_within_5pct" in reasons and ("same_project" in reasons or "same_address" in reasons):
        return True, reasons
    if "same_project" in reasons and "same_floor" in reasons and "area_within_3pct" in reasons and score >= 9:
        return True, reasons
    if "same_address" in reasons and "same_floor" in reasons and "area_within_3pct" in reasons and score >= 8:
        return True, reasons
    return False, reasons


def aggregate(cluster: list[dict]) -> dict:
    first = deepcopy(cluster[0])
    ids = [r.get("source_id") for r in cluster if r.get("source_id")]
    platforms = [platform_key(r.get("source_platform", "")) for r in cluster]
    urls = [r.get("source_url") for r in cluster if r.get("source_url")]
    daily = [r.get("rent_rmb_sqm_day") for r in cluster]
    monthly = [r.get("rent_rmb_month") for r in cluster]
    sale_total = [r.get("sale_total_rmb") for r in cluster]
    sale_psm = [r.get("sale_rmb_sqm") for r in cluster]
    property_fee_psm = [r.get("property_fee_rmb_sqm_month") for r in cluster]
    property_fee_month = [r.get("property_fee_rmb_month") for r in cluster]
    other_recurring = [r.get("other_recurring_costs_rmb_month") for r in cluster]
    aircon_fixed = [r.get("aircon_fixed_rmb_month") for r in cluster]
    fixed_monthly = [r.get("fixed_monthly_cost_rmb") for r in cluster]
    explicit_levels = [r.get("verification_level") or r.get("verification_status") for r in cluster]
    independent = len(set(p for p in platforms if p and p != "unknown"))
    inferred = "V1" if independent >= 2 else "V0"
    level = choose_level([inferred] + explicit_levels)
    fact_values = {}
    for row in cluster:
        for key, value in (row.get("facts") or {}).items():
            if value not in (None, "", "unknown"):
                fact_values.setdefault(key, []).append(value)
    facts, fact_conflicts = {}, []
    for key, values in fact_values.items():
        unique = {str(v) for v in values}
        if len(unique) == 1:
            facts[key] = values[0]
        else:
            facts[key] = None
            fact_conflicts.append(key)
    prop = {
        "property_id": slug_hash(first.get("project_name_norm") or first.get("project_name"), first.get("address_norm") or first.get("address_raw"), first.get("floor"), first.get("unit_or_room"), first.get("area_sqm"), prefix="prop"),
        "transaction_type": first.get("transaction_type"),
        "asset_type": first.get("asset_type"),
        "project_name": first.get("project_name"),
        "project_name_norm": first.get("project_name_norm") or norm_text(first.get("project_name")),
        "address_raw": first.get("address_raw"),
        "address_norm": first.get("address_norm") or norm_text(first.get("address_raw")),
        "district": first.get("district"),
        "submarket": first.get("submarket"),
        "area_sqm": median(r.get("area_sqm") for r in cluster),
        "area_basis": first.get("area_basis", "unknown"),
        "floor": first.get("floor", ""),
        "unit_or_room": first.get("unit_or_room", ""),
        "rent_rmb_sqm_day": median(daily),
        "rent_rmb_sqm_day_min": min([x for x in daily if x is not None], default=None),
        "rent_rmb_sqm_day_max": max([x for x in daily if x is not None], default=None),
        "rent_rmb_month": median(monthly),
        "rent_rmb_month_min": min([x for x in monthly if x is not None], default=None),
        "rent_rmb_month_max": max([x for x in monthly if x is not None], default=None),
        "sale_total_rmb": median(sale_total),
        "sale_rmb_sqm": median(sale_psm),
        "property_fee": median(r.get("property_fee") for r in cluster),
        "property_fee_rmb_sqm_month": median(property_fee_psm),
        "property_fee_rmb_month": median(property_fee_month),
        "other_recurring_costs_rmb_month": median(other_recurring),
        "aircon_fixed_rmb_month": median(aircon_fixed),
        "fixed_monthly_cost_rmb": median(fixed_monthly),
        "fixed_monthly_cost_status": "complete" if cluster and all(r.get("fixed_monthly_cost_status") == "complete" for r in cluster) else ("partial" if fixed_monthly else "unavailable"),
        "facts": facts,
        "tax_basis": Counter(clean_text(r.get("tax_basis")) or "unknown" for r in cluster).most_common(1)[0][0],
        "features": sorted(set(x for r in cluster for x in (r.get("features") or []) if isinstance(x, str))),
        "business_constraints": sorted(set(x for r in cluster for x in (r.get("business_constraints") or []) if isinstance(x, str))),
        "red_flags": sorted(set(x for r in cluster for x in (r.get("red_flags") or []) if isinstance(x, str))),
        "image_refs": [x for r in cluster for x in (r.get("image_refs") or [])],
        "source_ids": ids,
        "source_urls": urls,
        "source_platforms": sorted(set(platforms)),
        "source_count": len(cluster),
        "independent_source_count": independent,
        "verification_level": level,
        "listing_versions": cluster,
        "aggregation_notes": []
    }
    if prop["rent_rmb_sqm_day_min"] is not None and prop["rent_rmb_sqm_day_max"] is not None and prop["rent_rmb_sqm_day_min"] > 0:
        spread = prop["rent_rmb_sqm_day_max"] / prop["rent_rmb_sqm_day_min"] - 1
        if spread >= 0.2:
            prop["red_flags"].append("cross_source_price_spread_ge_20pct")
            prop["aggregation_notes"].append(f"cross-source daily rent spread {spread:.0%}")
    for key in fact_conflicts:
        prop["red_flags"].append(f"fact_conflict:{key}")
    return prop



def cluster_stdlib(rows: list[dict]) -> tuple[list[list[dict]], list[dict]]:
    """Complete sequential comparison. Prefer for small datasets because it maximizes recall."""
    clusters: list[list[dict]] = []
    review: list[dict] = []
    seen_review = set()
    for row in rows:
        placed = False
        for cluster in clusters:
            merge, reasons = should_merge(row, cluster[0])
            if merge:
                cluster.append(row); placed = True; break
            score, rs = duplicate_score(row, cluster[0])
            if 6 <= score < 9 and ("same_project" in rs or "same_address" in rs):
                key = tuple(sorted((clean_text(row.get("source_id")), clean_text(cluster[0].get("source_id")))))
                if key not in seen_review:
                    review.append({"a": row.get("source_id"), "b": cluster[0].get("source_id"), "score": score, "reasons": rs})
                    seen_review.add(key)
        if not placed:
            clusters.append([row])
    return clusters, review


def _area_bucket(value, width: float = 10.0):
    try:
        v = float(value)
        if v <= 0:
            return None
        return int(v // width)
    except Exception:
        return None


def candidate_pairs_pandas(rows: list[dict]) -> set[tuple[int, int]]:
    """Generate high-recall duplicate candidate pairs without all-pairs comparison."""
    pd = get_pandas(required=True)
    if not rows:
        return set()
    records = []
    for i, r in enumerate(rows):
        records.append({
            "idx": i,
            "project": r.get("project_name_norm") or norm_text(r.get("project_name")),
            "address": r.get("address_norm") or norm_text(r.get("address_raw")),
            "unit": norm_text(r.get("unit_or_room")),
            "floor": clean_text(r.get("floor")),
            "district": clean_text(r.get("district")),
            "area_bucket": _area_bucket(r.get("area_sqm")),
        })
    df = pd.DataFrame(records)
    pairs: set[tuple[int, int]] = set()

    def add_groups(cols, require_nonempty=True, max_group=250):
        if any(c not in df.columns for c in cols):
            return
        work = df
        if require_nonempty:
            mask = None
            for c in cols:
                m = work[c].notna() & work[c].astype(str).str.strip().ne("")
                mask = m if mask is None else (mask & m)
            work = work[mask] if mask is not None else work
        for _, g in work.groupby(cols, dropna=False, sort=False):
            ids = [int(x) for x in g["idx"].tolist()]
            if len(ids) < 2:
                continue
            # Very large weak blocks are skipped; stronger keys below/above cover physical identity.
            if len(ids) > max_group:
                continue
            for a_i in range(len(ids)):
                for b_i in range(a_i + 1, len(ids)):
                    a, b = ids[a_i], ids[b_i]
                    pairs.add((a, b) if a < b else (b, a))

    # Strong identity blocks plus bounded project/address blocks to preserve manual-review recall.
    add_groups(["project"], max_group=180)
    add_groups(["address"], max_group=180)
    add_groups(["project", "unit"], max_group=120)
    add_groups(["address", "unit"], max_group=120)
    add_groups(["project", "floor", "area_bucket"], max_group=180)
    add_groups(["address", "floor", "area_bucket"], max_group=180)
    # High-recall fuzzy-name review block for slightly different project spellings.
    add_groups(["district", "floor", "area_bucket"], max_group=120)

    # Exact image overlap is a strong clue and can be indexed directly.
    image_to_rows: dict[str, list[int]] = {}
    for i, row in enumerate(rows):
        keys = set()
        for item in row.get("image_refs") or []:
            if isinstance(item, str):
                keys.add(item)
            elif isinstance(item, dict):
                for k in ("source_url", "local_path", "url"):
                    if item.get(k):
                        keys.add(str(item[k]))
        for key in keys:
            image_to_rows.setdefault(key, []).append(i)
    for ids in image_to_rows.values():
        if 2 <= len(ids) <= 100:
            for a_i in range(len(ids)):
                for b_i in range(a_i + 1, len(ids)):
                    a, b = ids[a_i], ids[b_i]
                    pairs.add((a, b) if a < b else (b, a))
    return pairs


def cluster_blocked(rows: list[dict]) -> tuple[list[list[dict]], list[dict], int]:
    pairs = candidate_pairs_pandas(rows)
    parent = list(range(len(rows)))
    rank = [0] * len(rows)

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if rank[ra] < rank[rb]:
            parent[ra] = rb
        elif rank[ra] > rank[rb]:
            parent[rb] = ra
        else:
            parent[rb] = ra; rank[ra] += 1

    review = []
    for a, b in sorted(pairs):
        merge, reasons = should_merge(rows[a], rows[b])
        if merge:
            union(a, b)
        else:
            score, rs = duplicate_score(rows[a], rows[b])
            if 6 <= score < 9 and ("same_project" in rs or "same_address" in rs):
                review.append({"a": rows[a].get("source_id"), "b": rows[b].get("source_id"), "score": score, "reasons": rs})
    groups: dict[int, list[dict]] = {}
    for i, row in enumerate(rows):
        groups.setdefault(find(i), []).append(row)
    return list(groups.values()), review, len(pairs)


def main():
    ap = argparse.ArgumentParser(description="Conservatively cluster duplicate listing ads into physical property candidates.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--review-output", help="Write possible duplicate pairs not auto-merged")
    ap.add_argument("--engine", choices=["auto", "pandas", "stdlib"], default="auto")
    ap.add_argument("--pandas-threshold", type=int, default=250, help="Auto mode uses blocked pandas candidate generation at/above this listing count")
    args = ap.parse_args()
    rows = load_json(args.input, [])
    if not isinstance(rows, list):
        raise SystemExit("input must be a JSON array")
    rows = [r for r in rows if isinstance(r, dict)]
    pd = get_pandas(required=False)
    use_blocked = args.engine == "pandas" or (args.engine == "auto" and pd is not None and len(rows) >= args.pandas_threshold)
    if args.engine == "pandas" and pd is None:
        raise SystemExit("pandas requested but unavailable")
    if use_blocked:
        clusters, review, pair_count = cluster_blocked(rows)
        engine = "pandas_blocked"
    else:
        clusters, review = cluster_stdlib(rows)
        pair_count = None
        engine = "stdlib_full_compare"
    props = [aggregate(c) for c in clusters]
    save_json(args.output, props)
    if args.review_output:
        save_json(args.review_output, review)
    extra = f" candidate_pairs={pair_count}" if pair_count is not None else ""
    print(f"engine={engine} listings={len(rows)} properties={len(props)} possible_duplicate_pairs={len(review)}{extra}")

if __name__ == "__main__":
    main()
