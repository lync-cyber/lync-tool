#!/usr/bin/env python3
from __future__ import annotations
import argparse
from copy import deepcopy
from _common import clean_text, load_json, norm_text, now_iso, numeric_price_from_raw, parse_number, save_json, slug_hash


def normalize(row: dict, month_days: float) -> dict:
    r = deepcopy(row)
    warnings = list(r.get("normalization_warnings") or [])
    r.setdefault("source_id", slug_hash(r.get("source_url"), r.get("listing_title"), prefix="src"))
    r.setdefault("captured_at", now_iso())
    r.setdefault("red_flags", [])
    r.setdefault("features", [])
    r.setdefault("business_constraints", [])
    r.setdefault("image_refs", [])
    r["project_name_norm"] = norm_text(r.get("project_name"))
    r["address_norm"] = norm_text(r.get("address_raw"))

    area = parse_number(r.get("area_sqm"))
    r["area_sqm"] = area
    parsed = numeric_price_from_raw(r.get("asking_price_raw"))
    for key in ("rent_rmb_sqm_day", "rent_rmb_month", "sale_total_rmb", "sale_rmb_sqm"):
        val = parse_number(r.get(key))
        if val is None:
            val = parsed.get(key)
        r[key] = val

    if r.get("transaction_type") in ("rent", "租赁", "租") or r.get("rent_rmb_sqm_day") is not None or r.get("rent_rmb_month") is not None:
        r["transaction_type"] = "rent"
        if area and area > 0:
            if r.get("rent_rmb_sqm_day") is not None and r.get("rent_rmb_month") is None:
                r["rent_rmb_month"] = round(r["rent_rmb_sqm_day"] * area * month_days, 2)
                r["rent_conversion_basis"] = f"daily_rate × area × {month_days:g} days/month"
            elif r.get("rent_rmb_month") is not None and r.get("rent_rmb_sqm_day") is None:
                r["rent_rmb_sqm_day"] = round(r["rent_rmb_month"] / area / month_days, 4)
                r["rent_conversion_basis"] = f"monthly_rent ÷ area ÷ {month_days:g} days/month"
        else:
            if r.get("rent_rmb_sqm_day") is not None:
                warnings.append("cannot_compute_monthly_rent_without_area")
    elif r.get("transaction_type") in ("sale", "出售", "购买", "买") or r.get("sale_total_rmb") is not None or r.get("sale_rmb_sqm") is not None:
        r["transaction_type"] = "sale"
        if area and area > 0:
            if r.get("sale_total_rmb") is not None and r.get("sale_rmb_sqm") is None:
                r["sale_rmb_sqm"] = round(r["sale_total_rmb"] / area, 2)
            elif r.get("sale_rmb_sqm") is not None and r.get("sale_total_rmb") is None:
                r["sale_total_rmb"] = round(r["sale_rmb_sqm"] * area, 2)
    else:
        warnings.append("transaction_type_unknown")

    legacy_property_fee = parse_number(r.get("property_fee")) if r.get("property_fee") not in (None, "") else None
    property_fee_psm = parse_number(r.get("property_fee_rmb_sqm_month"))
    property_fee_month = parse_number(r.get("property_fee_rmb_month"))
    property_basis = clean_text(r.get("property_fee_basis")).lower()
    if property_fee_psm is None and legacy_property_fee is not None and property_basis in {"per_sqm_month", "元/㎡/月", "sqm_month"}:
        property_fee_psm = legacy_property_fee
    if property_fee_month is None and legacy_property_fee is not None and property_basis in {"monthly_total", "月总额", "month"}:
        property_fee_month = legacy_property_fee
    included = r.get("property_fee_included") is True or property_basis == "included"
    if included:
        property_fee_month = 0.0
    elif property_fee_month is None and property_fee_psm is not None and area:
        property_fee_month = round(property_fee_psm * area, 2)
    other_recurring = parse_number(r.get("other_recurring_costs_rmb_month"))
    aircon_fixed = parse_number(r.get("aircon_fixed_rmb_month"))
    known_other = sum(x for x in (other_recurring, aircon_fixed) if x is not None)
    base_rent = r.get("rent_rmb_month")
    r["property_fee"] = legacy_property_fee
    r["property_fee_rmb_sqm_month"] = property_fee_psm
    r["property_fee_rmb_month"] = property_fee_month
    r["other_recurring_costs_rmb_month"] = other_recurring
    r["aircon_fixed_rmb_month"] = aircon_fixed
    r["fixed_monthly_cost_rmb"] = round(base_rent + property_fee_month + known_other, 2) if base_rent is not None and property_fee_month is not None else None
    components_confirmed = r.get("fixed_cost_components_confirmed") is True
    r["fixed_cost_components_confirmed"] = components_confirmed
    r["fixed_monthly_cost_status"] = "complete" if r["fixed_monthly_cost_rmb"] is not None and components_confirmed else ("partial" if base_rent is not None else "unavailable")
    facts = r.get("facts")
    r["facts"] = facts if isinstance(facts, dict) else {}
    if not clean_text(r.get("source_url")):
        warnings.append("missing_source_url")
    if not clean_text(r.get("project_name")) and not clean_text(r.get("address_raw")):
        warnings.append("missing_project_and_address")
    if area is None:
        warnings.append("missing_area")
    if r.get("transaction_type") == "rent" and r.get("rent_rmb_sqm_day") is None and r.get("rent_rmb_month") is None:
        warnings.append("missing_rent_price")
    if r.get("transaction_type") == "rent" and r.get("fixed_monthly_cost_status") != "complete":
        warnings.append("fixed_monthly_cost_incomplete")
    if r.get("transaction_type") == "sale" and r.get("sale_total_rmb") is None and r.get("sale_rmb_sqm") is None:
        warnings.append("missing_sale_price")
    r["normalization_warnings"] = sorted(set(warnings))
    return r


def main():
    ap = argparse.ArgumentParser(description="Normalize raw commercial property listing fields and price units.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--month-days", type=float, default=365/12, help="Days per month conversion basis; default 365/12")
    args = ap.parse_args()
    rows = load_json(args.input, [])
    if not isinstance(rows, list):
        raise SystemExit("input must be a JSON array")
    out = [normalize(r, args.month_days) for r in rows if isinstance(r, dict)]
    save_json(args.output, out)
    warn_count = sum(bool(r.get("normalization_warnings")) for r in out)
    print(f"normalized={len(out)} with_warnings={warn_count}")

if __name__ == "__main__":
    main()
