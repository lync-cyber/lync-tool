#!/usr/bin/env python3
from __future__ import annotations
import argparse
from copy import deepcopy
from _common import clamp, clean_text, ensure_list, get_path, load_json, read_registry, save_json, source_role, source_weight


def contains_any(text, needles):
    t = clean_text(text).lower()
    return any(clean_text(n).lower() in t for n in needles if clean_text(n))


def all_property_text(p):
    parts = [p.get("project_name"), p.get("address_raw"), p.get("district"), p.get("submarket"), p.get("floor")]
    parts += list(p.get("features") or []) + list(p.get("business_constraints") or [])
    for v in p.get("listing_versions") or []:
        parts += [v.get("listing_title"), v.get("raw_evidence_notes")]
        parts += list(v.get("features") or []) + list(v.get("business_constraints") or [])
    return " ".join(clean_text(x) for x in parts if x is not None)


def get_budget(brief, key):
    b = brief.get("budget") or {}
    val = b.get(key) if isinstance(b, dict) else None
    try:
        return float(val) if val is not None else None
    except Exception:
        return None


def rent_cost(p, brief):
    budget = brief.get("budget") or {}
    basis = budget.get("cost_basis")
    if basis == "fixed_monthly_cost" or (basis in (None, "", "unknown") and budget.get("fixed_monthly_cost_max_rmb") is not None):
        return p.get("fixed_monthly_cost_rmb"), "fixed_monthly_cost"
    return p.get("rent_rmb_month"), "base_rent"


def compare_requirement(actual, operator, expected):
    if operator == "truthy":
        return bool(actual)
    if operator in {"lt", "lte", "gt", "gte"}:
        try:
            actual_num, expected_num = float(actual), float(expected)
            return {
                "lt": actual_num < expected_num,
                "lte": actual_num <= expected_num,
                "gt": actual_num > expected_num,
                "gte": actual_num >= expected_num,
            }[operator]
        except (TypeError, ValueError):
            return False
    if operator == "eq":
        return actual == expected
    if operator == "neq":
        return actual != expected
    if operator == "in":
        return actual in ensure_list(expected)
    if operator == "contains_any":
        haystack = ensure_list(actual)
        return any(contains_any(item, ensure_list(expected)) for item in haystack)
    return False


def hard_filter(p, brief):
    failures, unknowns = [], []
    area = p.get("area_sqm")
    ar = brief.get("area_range") or {}
    amin, amax = ar.get("min_sqm"), ar.get("max_sqm")
    if amin is not None:
        if area is None: unknowns.append("area_min")
        elif area < float(amin): failures.append("area_below_min")
    if amax is not None:
        if area is None: unknowns.append("area_max")
        elif area > float(amax): failures.append("area_above_max")

    if p.get("transaction_type") == "rent":
        cost, cost_basis = rent_cost(p, brief)
        monthly_max = get_budget(brief, "fixed_monthly_cost_max_rmb") if cost_basis == "fixed_monthly_cost" else get_budget(brief, "monthly_max_rmb")
        daily_max = get_budget(brief, "rent_sqm_day_max")
        if monthly_max is not None:
            if cost is None: unknowns.append(cost_basis)
            elif cost > monthly_max: failures.append(f"{cost_basis}_budget_exceeded")
        if cost_basis == "fixed_monthly_cost" and p.get("fixed_monthly_cost_status") != "complete":
            unknowns.append("fixed_monthly_cost_components")
        if daily_max is not None:
            if p.get("rent_rmb_sqm_day") is None: unknowns.append("daily_rent")
            elif p.get("rent_rmb_sqm_day") > daily_max: failures.append("daily_rate_exceeded")
    else:
        total_max = get_budget(brief, "sale_total_max_rmb")
        if total_max is not None:
            if p.get("sale_total_rmb") is None: unknowns.append("sale_total")
            elif p.get("sale_total_rmb") > total_max: failures.append("sale_budget_exceeded")

    location_strategy = brief.get("location_strategy") or {}
    mode = clean_text(location_strategy.get("mode")) or "citywide_with_preferences"
    areas = ensure_list(location_strategy.get("hard_boundary_areas") or brief.get("target_areas")) if mode == "hard_boundary" else []
    if areas:
        location = " ".join(clean_text(p.get(k)) for k in ("district", "submarket", "address_raw", "project_name"))
        if not clean_text(location):
            unknowns.append("target_area")
        elif not contains_any(location, areas):
            failures.append("outside_target_area")

    text = all_property_text(p)
    for req in ensure_list(brief.get("must_have")):
        if not clean_text(req):
            continue
        # Unknown unless explicit natural-language match exists. The worker can replace with structured fields for stronger gating.
        if not contains_any(text, [req]):
            unknowns.append(f"must_have:{req}")
    for ex in ensure_list(brief.get("exclusions")):
        if clean_text(ex) and contains_any(text, [ex]):
            failures.append(f"excluded:{ex}")
    for req in ensure_list(brief.get("hard_requirements")):
        if not isinstance(req, dict):
            continue
        rid = clean_text(req.get("id")) or clean_text(req.get("field")) or "requirement"
        actual = get_path(p, req.get("field"))
        if actual in (None, "", "unknown"):
            if req.get("unknown_policy", "verify_first") == "exclude":
                failures.append(f"hard_requirement_unknown:{rid}")
            else:
                unknowns.append(f"hard_requirement:{rid}")
        elif not compare_requirement(actual, req.get("operator"), req.get("value")):
            failures.append(f"hard_requirement_failed:{rid}")
    return failures, unknowns


def price_score(p, brief):
    if p.get("transaction_type") == "rent":
        price, basis = rent_cost(p, brief)
        ideal = get_budget(brief, "fixed_monthly_cost_ideal_rmb") if basis == "fixed_monthly_cost" else get_budget(brief, "monthly_ideal_rmb")
        maxv = get_budget(brief, "fixed_monthly_cost_max_rmb") if basis == "fixed_monthly_cost" else get_budget(brief, "monthly_max_rmb")
    else:
        price = p.get("sale_total_rmb")
        ideal = get_budget(brief, "sale_total_ideal_rmb")
        maxv = get_budget(brief, "sale_total_max_rmb")
    if price is None:
        return 45
    if ideal and ideal > 0:
        if price <= ideal: return 95
        if maxv and maxv > ideal:
            return clamp(95 - 45 * ((price - ideal) / (maxv - ideal)))
    if maxv and maxv > 0:
        return clamp(90 - 55 * max(0, price / maxv - .75) / .25)
    return 70


def area_score(p, brief):
    area = p.get("area_sqm")
    ar = brief.get("area_range") or {}
    amin, amax = ar.get("min_sqm"), ar.get("max_sqm")
    if area is None: return 45
    if amin is None and amax is None: return 70
    lo = float(amin) if amin is not None else 0
    hi = float(amax) if amax is not None else max(area, lo + 1)
    if lo <= area <= hi:
        mid = (lo + hi) / 2 if hi > lo else lo
        if hi > lo:
            return clamp(100 - 20 * abs(area - mid) / ((hi - lo) / 2))
        return 95
    return 20


def location_score(p, brief):
    location_strategy = brief.get("location_strategy") or {}
    mode = clean_text(location_strategy.get("mode")) or "citywide_with_preferences"
    if mode == "citywide": return 70
    areas = ensure_list(location_strategy.get("preferred_areas") or brief.get("target_areas"))
    if not areas: return 70
    loc = " ".join(clean_text(p.get(k)) for k in ("district", "submarket", "address_raw", "project_name"))
    return 92 if contains_any(loc, areas) else 62


def feature_score(p, brief):
    prefs = ensure_list(brief.get("nice_to_have"))
    if not prefs: return 70
    text = all_property_text(p)
    hits = sum(1 for x in prefs if contains_any(text, [x]))
    return clamp(45 + 55 * hits / max(1, len(prefs)))


def confidence_score(p, registry):
    platforms = p.get("source_platforms") or []
    weights = [source_weight(x, registry) for x in platforms]
    base = max(weights) if weights else 45
    score = base
    independent = int(p.get("independent_source_count") or 0)
    if independent >= 2: score += 8
    if independent >= 3: score += 5
    level = clean_text(p.get("verification_level")).upper()
    score += {"V0": 0, "V1": 7, "V2": 16, "V3": 25}.get(level, 0)
    if p.get("unit_or_room"): score += 4
    if p.get("area_sqm") is not None: score += 2
    if p.get("source_urls"): score += 2
    if p.get("image_refs"): score += 2
    if p.get("tax_basis") not in (None, "", "unknown"): score += 2
    flags = set(p.get("red_flags") or [])
    anomaly = (p.get("price_anomaly") or {}).get("label")
    if anomaly == "low_15_20pct": score -= 5
    elif anomaly == "low_20_30pct": score -= 12
    elif anomaly == "low_ge_30pct": score -= 22
    if "cross_source_price_spread_ge_20pct" in flags: score -= 8
    high_risk_keywords = ("刚租掉", "引流", "虚假", "价格冲突", "missing_source_url")
    if any(any(k in clean_text(flag) for k in high_risk_keywords) for flag in flags): score -= 10
    return round(clamp(score), 1)


def main():
    ap = argparse.ArgumentParser(description="Apply hard filters plus separate fit/confidence scores.")
    ap.add_argument("properties")
    ap.add_argument("brief")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--source-registry")
    args = ap.parse_args()
    props = load_json(args.properties, [])
    brief = load_json(args.brief, {})
    registry = read_registry(args.source_registry)
    out = []
    for original in props:
        p = deepcopy(original)
        roles = sorted(set(source_role(x, registry) for x in (p.get("source_platforms") or [])))
        p["source_roles"] = roles
        low_evidence_roles = {"broad_discovery", "lead_only", "unknown"}
        p["presentation_tier"] = "supplementary_lead" if roles and set(roles).issubset(low_evidence_roles) and int(p.get("independent_source_count") or 0) < 2 else "primary_shortlist"
        failures, unknowns = hard_filter(p, brief)
        components = {
            "price": round(price_score(p, brief), 1),
            "area": round(area_score(p, brief), 1),
            "location": round(location_score(p, brief), 1),
            "use_conditions": round(feature_score(p, brief), 1),
            "property_quality": 70.0,
            "execution_convenience": 65.0
        }
        fit = (components["price"] * .25 + components["area"] * .15 + components["location"] * .20 + components["use_conditions"] * .20 + components["property_quality"] * .10 + components["execution_convenience"] * .10)
        if failures: fit = min(fit, 35)
        conf = confidence_score(p, registry)
        decision = .75 * fit + .25 * conf
        gates = []
        if conf < 45: gates.append("confidence_below_45")
        if (p.get("price_anomaly") or {}).get("label") == "low_ge_30pct": gates.append("extreme_price_anomaly")
        if clean_text(p.get("verification_level")).upper() == "V0": gates.append("single_source_v0")
        if p["presentation_tier"] == "supplementary_lead": gates.append("broad_source_only")
        if unknowns: gates.append("hard_conditions_unknown")
        status = "excluded" if failures else ("verify_first" if gates else "site_visit_candidate")
        p["hard_filter"] = {"failures": failures, "unknowns": unknowns, "passed": not failures}
        p["fit_components"] = components
        p["fit_score"] = round(fit, 1)
        p["confidence_score"] = conf
        p["decision_score"] = round(decision, 1)
        p["ranking_gates"] = gates
        p["recommendation_status"] = status
        out.append(p)
    rankable = [p for p in out if p.get("recommendation_status") != "excluded"]
    rankable.sort(key=lambda x: (x.get("presentation_tier") == "primary_shortlist", x.get("recommendation_status") == "site_visit_candidate", x.get("decision_score", 0)), reverse=True)
    rank = 1
    for p in rankable:
        p["rank"] = rank; rank += 1
    save_json(args.output, out)
    print(f"scored={len(out)} site_visit={sum(p['recommendation_status']=='site_visit_candidate' for p in out)} verify_first={sum(p['recommendation_status']=='verify_first' for p in out)} excluded={sum(p['recommendation_status']=='excluded' for p in out)}")

if __name__ == "__main__":
    main()
