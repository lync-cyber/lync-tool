#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

from _common import clean_text, now_iso, numeric_price_from_raw, parse_number, save_json, slug_hash
from _optional_deps import get_bs4, preferred_html_parser

LABELS = {
    "project_name": ["项目名称", "楼盘名称", "楼宇名称", "楼盘", "项目", "写字楼名称"],
    "address_raw": ["详细地址", "项目地址", "楼盘地址", "地址", "位置"],
    "area_sqm": ["建筑面积", "出租面积", "面积", "使用面积"],
    "floor": ["所在楼层", "楼层"],
    "unit_or_room": ["房号", "室号", "单元"],
    "asking_price_raw": ["租金", "报价", "价格", "售价", "总价", "单价"],
    "property_fee": ["物业费", "物业管理费"],
}
AREA_RE = re.compile(r"(?P<value>\d+(?:\.\d+)?)\s*(?:㎡|m2|m²|平(?:方米)?)", re.I)
PRICE_SNIPPET_RE = re.compile(
    r"(?:\d+(?:\.\d+)?\s*(?:元|万|万元)?\s*/?\s*(?:㎡|m2|m²|平(?:方米)?)?\s*/?\s*(?:天|日|月)?|\d+(?:\.\d+)?\s*(?:万|万元))",
    re.I,
)


def add_candidate(bucket: dict[str, list[dict[str, Any]]], field: str, value: Any, source: str, confidence: str, evidence: str = "") -> None:
    if value in (None, ""):
        return
    item = {"value": value, "source": source, "confidence": confidence, "evidence": clean_text(evidence)[:300]}
    existing = bucket.setdefault(field, [])
    key = json.dumps(item["value"], ensure_ascii=False, sort_keys=True) if isinstance(item["value"], (dict, list)) else clean_text(item["value"])
    for old in existing:
        old_key = json.dumps(old["value"], ensure_ascii=False, sort_keys=True) if isinstance(old["value"], (dict, list)) else clean_text(old["value"])
        if old_key == key and old.get("source") == source:
            return
    existing.append(item)


def iter_json_nodes(obj: Any):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from iter_json_nodes(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from iter_json_nodes(value)


def text_value(obj: Any) -> str:
    if isinstance(obj, str):
        return clean_text(obj)
    if isinstance(obj, dict):
        # Schema.org PostalAddress or QuantitativeValue
        if "streetAddress" in obj:
            bits = [obj.get(k) for k in ("streetAddress", "addressLocality", "addressRegion", "postalCode")]
            return clean_text(" ".join(clean_text(x) for x in bits if clean_text(x)))
        if "value" in obj:
            unit = obj.get("unitText") or obj.get("unitCode") or ""
            return clean_text(f"{obj.get('value')} {unit}")
    return ""


def extract_jsonld(soup, candidates: dict[str, list[dict[str, Any]]]) -> list[Any]:
    blobs = []
    for script in soup.find_all("script", attrs={"type": re.compile(r"application/ld\+json", re.I)}):
        raw = script.string or script.get_text(" ", strip=True)
        if not clean_text(raw):
            continue
        try:
            data = json.loads(raw)
        except Exception:
            # Some pages concatenate JSON objects or contain trailing semicolons; keep parser conservative.
            try:
                data = json.loads(raw.strip().rstrip(";"))
            except Exception:
                continue
        blobs.append(data)
        for node in iter_json_nodes(data):
            typ = node.get("@type")
            types = [clean_text(x).lower() for x in typ] if isinstance(typ, list) else [clean_text(typ).lower()]
            node_source = "jsonld:" + ("/".join(x for x in types if x) or "object")
            name = text_value(node.get("name"))
            if name and any(x in types for x in ("realestatelisting", "place", "apartment", "office", "product", "accommodation", "localbusiness")):
                add_candidate(candidates, "project_name", name, node_source, "medium", name)
            addr = text_value(node.get("address"))
            if addr:
                add_candidate(candidates, "address_raw", addr, node_source, "high", addr)
            floor_size = node.get("floorSize") or node.get("floor_size")
            area_text = text_value(floor_size)
            m = AREA_RE.search(area_text)
            if m:
                add_candidate(candidates, "area_sqm", float(m.group("value")), node_source, "high", area_text)
            elif isinstance(floor_size, dict) and parse_number(floor_size.get("value")) is not None:
                unit = clean_text(floor_size.get("unitText") or floor_size.get("unitCode"))
                if any(x in unit.lower() for x in ("sqm", "m2", "m²", "平方米", "㎡", "mtk")):
                    add_candidate(candidates, "area_sqm", parse_number(floor_size.get("value")), node_source, "high", json.dumps(floor_size, ensure_ascii=False))
            if "price" in node:
                price_text = text_value(node.get("price")) or clean_text(node.get("price"))
                currency = clean_text(node.get("priceCurrency"))
                unit_text = clean_text(node.get("unitText") or node.get("unitCode"))
                evidence = clean_text(" ".join(x for x in (price_text, currency, unit_text) if x))
                if evidence:
                    add_candidate(candidates, "asking_price_raw", evidence, node_source, "medium", evidence)
                    parsed = numeric_price_from_raw(evidence)
                    for key, value in parsed.items():
                        if value is not None:
                            add_candidate(candidates, key, value, node_source, "medium", evidence)
    return blobs


def meta_map(soup) -> dict[str, str]:
    out: dict[str, str] = {}
    for tag in soup.find_all("meta"):
        key = clean_text(tag.get("property") or tag.get("name") or tag.get("itemprop"))
        value = clean_text(tag.get("content"))
        if key and value and key.lower() not in out:
            out[key.lower()] = value
    return out


def labelled_text_candidates(soup, candidates: dict[str, list[dict[str, Any]]]) -> None:
    # Limit to short blocks so a whole page does not become evidence for one label.
    for field, labels in LABELS.items():
        for label in labels:
            pattern = re.compile(rf"(^|[\s：:]){re.escape(label)}\s*[：:]?", re.I)
            for node in soup.find_all(string=pattern, limit=12):
                parent = node.parent
                texts = []
                if parent is not None:
                    txt = clean_text(parent.get_text(" ", strip=True))
                    if txt:
                        texts.append(txt)
                    sib = parent.find_next_sibling()
                    if sib is not None:
                        st = clean_text(sib.get_text(" ", strip=True))
                        if st:
                            texts.append(st)
                evidence = clean_text(" ".join(texts))[:500]
                if not evidence or len(evidence) > 500:
                    continue
                value_text = re.sub(rf".*?{re.escape(label)}\s*[：:]?\s*", "", evidence, count=1, flags=re.I).strip()
                if field == "area_sqm":
                    m = AREA_RE.search(value_text or evidence)
                    if m:
                        add_candidate(candidates, field, float(m.group("value")), "labelled_text", "medium", evidence)
                elif field == "property_fee":
                    n = parse_number(value_text)
                    if n is not None:
                        add_candidate(candidates, field, n, "labelled_text", "medium", evidence)
                elif field == "asking_price_raw":
                    m = PRICE_SNIPPET_RE.search(value_text or evidence)
                    text = clean_text(m.group(0) if m else value_text)
                    if text:
                        add_candidate(candidates, field, text, "labelled_text", "medium", evidence)
                        parsed = numeric_price_from_raw(evidence)
                        for key, value in parsed.items():
                            if value is not None:
                                add_candidate(candidates, key, value, "labelled_text", "medium", evidence)
                else:
                    if value_text and len(value_text) <= 120:
                        add_candidate(candidates, field, value_text, "labelled_text", "medium", evidence)


def visible_text(soup, max_chars: int) -> str:
    clone = soup
    for tag in clone.find_all(["script", "style", "noscript", "template", "svg", "canvas"]):
        tag.extract()
    text = clean_text(clone.get_text(" ", strip=True))
    return text[:max_chars]


def extract_images(soup, base_url: str, meta: dict[str, str], limit: int) -> list[dict[str, str]]:
    out = []
    seen = set()

    def add(url: str, source: str, alt: str = ""):
        url = clean_text(url)
        if not url:
            return
        resolved = urljoin(base_url, url) if base_url else url
        if resolved.startswith("data:") or resolved in seen:
            return
        seen.add(resolved)
        out.append({"url": resolved, "source": source, "alt": clean_text(alt)[:200]})

    for key in ("og:image", "twitter:image", "twitter:image:src"):
        if meta.get(key):
            add(meta[key], f"meta:{key}")
    for img in soup.find_all("img"):
        for attr in ("src", "data-src", "data-original", "data-lazy-src"):
            if img.get(attr):
                add(img.get(attr), f"img:{attr}", img.get("alt") or "")
                break
        if len(out) >= limit:
            break
    return out[:limit]


def conflict_warnings(candidates: dict[str, list[dict[str, Any]]]) -> list[str]:
    warnings = []
    for field in ("area_sqm", "rent_rmb_sqm_day", "rent_rmb_month", "sale_total_rmb", "sale_rmb_sqm", "project_name", "address_raw"):
        vals = []
        for x in candidates.get(field, []):
            v = x.get("value")
            if v not in vals:
                vals.append(v)
        if len(vals) > 1:
            warnings.append(f"multiple_candidates:{field}:{len(vals)}")
    return warnings


def choose_field(candidates: dict[str, list[dict[str, Any]]], field: str):
    rank = {"high": 3, "medium": 2, "low": 1}
    xs = candidates.get(field, [])
    if not xs:
        return None
    xs = sorted(xs, key=lambda x: rank.get(x.get("confidence"), 0), reverse=True)
    top_rank = rank.get(xs[0].get("confidence"), 0)
    top_values = []
    for x in xs:
        if rank.get(x.get("confidence"), 0) != top_rank:
            break
        if x.get("value") not in top_values:
            top_values.append(x.get("value"))
    return top_values[0] if len(top_values) == 1 and top_rank >= 2 else None


def extract_one(path: Path, source_url: str, platform: str, max_text_chars: int, max_images: int) -> dict[str, Any]:
    BeautifulSoup = get_bs4(required=True)
    parser = preferred_html_parser()
    raw = path.read_text(encoding="utf-8", errors="replace")
    soup = BeautifulSoup(raw, parser)
    candidates: dict[str, list[dict[str, Any]]] = {}
    jsonld = extract_jsonld(soup, candidates)
    meta = meta_map(soup)
    canonical_tag = soup.find("link", rel=lambda v: v and "canonical" in (v if isinstance(v, list) else [v]))
    canonical = clean_text(canonical_tag.get("href")) if canonical_tag else ""
    effective_url = source_url or canonical
    if canonical and effective_url:
        canonical = urljoin(effective_url, canonical)
    elif canonical:
        effective_url = canonical
    title = clean_text(meta.get("og:title") or (soup.title.string if soup.title and soup.title.string else ""))
    description = clean_text(meta.get("description") or meta.get("og:description"))
    if title:
        add_candidate(candidates, "listing_title", title, "meta/title", "high", title)
    labelled_text_candidates(soup, candidates)
    text_excerpt = visible_text(soup, max_text_chars)
    images = extract_images(soup, effective_url, meta, max_images)
    warnings = conflict_warnings(candidates)
    if not effective_url:
        warnings.append("missing_source_url")
    return {
        "html_file": str(path),
        "parsed_at": now_iso(),
        "parser": parser,
        "source_platform": platform,
        "source_url": effective_url,
        "canonical_url": canonical,
        "title": title,
        "description": description,
        "field_candidates": candidates,
        "image_candidates": images,
        "visible_text_excerpt": text_excerpt,
        "jsonld": jsonld,
        "extraction_warnings": sorted(set(warnings)),
    }


def listing_stub(extract: dict[str, Any], asset_type: str, transaction_type: str) -> dict[str, Any]:
    c = extract.get("field_candidates", {})
    row = {
        "source_platform": extract.get("source_platform") or "",
        "source_url": extract.get("source_url") or "",
        "captured_at": now_iso(),
        "listing_title": choose_field(c, "listing_title") or extract.get("title") or "",
        "transaction_type": transaction_type,
        "asset_type": asset_type,
        "project_name": choose_field(c, "project_name") or "",
        "address_raw": choose_field(c, "address_raw") or "",
        "area_sqm": choose_field(c, "area_sqm"),
        "floor": choose_field(c, "floor") or "",
        "unit_or_room": choose_field(c, "unit_or_room") or "",
        "asking_price_raw": choose_field(c, "asking_price_raw") or "",
        "rent_rmb_sqm_day": choose_field(c, "rent_rmb_sqm_day"),
        "rent_rmb_month": choose_field(c, "rent_rmb_month"),
        "sale_total_rmb": choose_field(c, "sale_total_rmb"),
        "sale_rmb_sqm": choose_field(c, "sale_rmb_sqm"),
        "property_fee": choose_field(c, "property_fee"),
        "features": [],
        "business_constraints": [],
        "image_refs": [],
        "verification_status": "V0",
        "red_flags": [],
        "raw_evidence_notes": f"Auto-extracted from saved HTML; review field_candidates before promotion. File: {extract.get('html_file')}",
        "html_extract_provenance": {
            "html_file": extract.get("html_file"),
            "parser": extract.get("parser"),
            "extraction_warnings": extract.get("extraction_warnings") or [],
        },
    }
    row["source_id"] = slug_hash(row.get("source_url"), row.get("listing_title"), row.get("project_name"), row.get("area_sqm"), prefix="src")
    if extract.get("extraction_warnings"):
        row["red_flags"].append("html_auto_extraction_requires_review")
    return row


def main() -> None:
    ap = argparse.ArgumentParser(description="Parse locally saved listing HTML with BeautifulSoup. No network requests are made.")
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--output", required=True, help="JSON list of page extraction records")
    ap.add_argument("--source-url", default="", help="Base/original URL; use only when processing one page or same-base pages")
    ap.add_argument("--platform", default="")
    ap.add_argument("--asset-type", default="")
    ap.add_argument("--transaction-type", choices=["rent", "sale", ""], default="")
    ap.add_argument("--emit-listings", help="Also write conservative raw listing stubs")
    ap.add_argument("--append-listings", action="store_true")
    ap.add_argument("--max-text-chars", type=int, default=20000)
    ap.add_argument("--max-images", type=int, default=60)
    args = ap.parse_args()

    get_bs4(required=True)
    paths = []
    for item in args.inputs:
        p = Path(item)
        if p.is_dir():
            paths.extend(sorted(list(p.glob("*.html")) + list(p.glob("*.htm"))))
        elif p.exists():
            paths.append(p)
        else:
            raise SystemExit(f"input not found: {p}")
    extracts = [extract_one(p, args.source_url if len(paths) == 1 else "", args.platform, args.max_text_chars, args.max_images) for p in paths]
    save_json(args.output, extracts)
    if args.emit_listings:
        rows = load_json(args.emit_listings, []) if args.append_listings else []
        if not isinstance(rows, list):
            raise SystemExit("emit-listings target must be a JSON array")
        seen = {clean_text(x.get("source_url")) or clean_text(x.get("source_id")) for x in rows if isinstance(x, dict)}
        for ex in extracts:
            stub = listing_stub(ex, args.asset_type, args.transaction_type)
            key = clean_text(stub.get("source_url")) or clean_text(stub.get("source_id"))
            if key and key in seen:
                continue
            rows.append(stub)
            if key:
                seen.add(key)
        save_json(args.emit_listings, rows)
    print(json.dumps({"pages": len(extracts), "parser": preferred_html_parser(), "emit_listings": bool(args.emit_listings)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
