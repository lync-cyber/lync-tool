#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
from io import StringIO
from pathlib import Path
from typing import Any

from _common import clean_text, load_json, now_iso, save_json, slug_hash
from _optional_deps import get_pandas

LIST_FIELDS = {"features", "business_constraints", "red_flags", "image_refs"}


def norm_header(value: Any) -> str:
    text = clean_text(value).lower()
    return re.sub(r"[\s\-_—–/\\()（）\[\]【】,.，。:：]+", "", text)


def json_safe(value: Any) -> Any:
    if value is None:
        return None
    if type(value).__name__ in {"NAType", "NaTType"}:
        return None
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    try:
        # pandas NA / NaT without importing pandas directly
        if value != value:  # noqa: PLR0124
            return None
    except Exception:
        pass
    if hasattr(value, "isoformat") and not isinstance(value, str):
        try:
            return value.isoformat()
        except Exception:
            pass
    if isinstance(value, (str, int, float, bool)):
        return value
    return clean_text(value)


def split_list(value: Any, separators: list[str]) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [clean_text(x) for x in value if clean_text(x)]
    text = clean_text(value)
    if not text:
        return []
    pattern = "|".join(re.escape(x) for x in separators if x)
    parts = re.split(pattern, text) if pattern else [text]
    return [clean_text(x) for x in parts if clean_text(x)]


def load_aliases(path: Path) -> tuple[dict[str, list[str]], list[str]]:
    cfg = load_json(path, {})
    fields = cfg.get("fields", {}) if isinstance(cfg, dict) else {}
    seps = cfg.get("list_separators", ["|", ";", "；", "、", ",", "，", "\n"])
    return {k: list(v) for k, v in fields.items() if isinstance(v, list)}, list(seps)


def load_explicit_mapping(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    data = load_json(path, {})
    if not isinstance(data, dict):
        raise SystemExit("mapping JSON must be an object of canonical_field -> input_column")
    return {clean_text(k): clean_text(v) for k, v in data.items() if clean_text(k) and clean_text(v)}


def auto_mapping(columns: list[str], aliases: dict[str, list[str]], explicit: dict[str, str]) -> dict[str, str]:
    normalized = {norm_header(c): c for c in columns}
    out = {}
    for canonical, input_col in explicit.items():
        if input_col not in columns:
            # permit normalized matching for explicit mappings
            actual = normalized.get(norm_header(input_col))
            if not actual:
                raise SystemExit(f"mapping column not found: {input_col}")
            input_col = actual
        out[canonical] = input_col
    for canonical, names in aliases.items():
        if canonical in out:
            continue
        candidates = [canonical] + names
        hits = [normalized[norm_header(x)] for x in candidates if norm_header(x) in normalized]
        # Prefer first alias order; only map one field once.
        if hits:
            out[canonical] = hits[0]
    return out


def read_stdlib(path: Path) -> list[dict[str, Any]]:
    suffix = path.suffix.lower()
    if suffix in {".json"}:
        data = load_json(path, [])
        if isinstance(data, list):
            return [x for x in data if isinstance(x, dict)]
        if isinstance(data, dict):
            # Accept common wrappers.
            for key in ("listings", "data", "rows", "items"):
                if isinstance(data.get(key), list):
                    return [x for x in data[key] if isinstance(x, dict)]
            return [data]
        return []
    if suffix in {".jsonl", ".ndjson"}:
        rows = []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if isinstance(obj, dict):
                rows.append(obj)
        return rows
    if suffix in {".csv", ".tsv"}:
        delimiter = "\t" if suffix == ".tsv" else ","
        with path.open("r", encoding="utf-8-sig", newline="") as f:
            return [dict(r) for r in csv.DictReader(f, delimiter=delimiter)]
    raise RuntimeError(f"{suffix or path.name} requires pandas or is unsupported")


def read_with_pandas(path: Path, table_index: int | None) -> list[dict[str, Any]]:
    pd = get_pandas(required=True)
    suffix = path.suffix.lower()
    if suffix in {".csv", ".tsv"}:
        df = pd.read_csv(path, sep="\t" if suffix == ".tsv" else ",", dtype=object)
    elif suffix == ".json":
        try:
            df = pd.read_json(path, dtype=False)
        except ValueError:
            data = load_json(path, [])
            if isinstance(data, dict):
                for key in ("listings", "data", "rows", "items"):
                    if isinstance(data.get(key), list):
                        data = data[key]
                        break
            df = pd.json_normalize(data)
    elif suffix in {".jsonl", ".ndjson"}:
        df = pd.read_json(path, lines=True, dtype=False)
    elif suffix in {".xlsx", ".xlsm", ".xls"}:
        df = pd.read_excel(path, dtype=object)
    elif suffix in {".html", ".htm"}:
        html_text = path.read_text(encoding="utf-8", errors="replace")
        tables = pd.read_html(StringIO(html_text))
        if not tables:
            return []
        if table_index is not None:
            if table_index < 0 or table_index >= len(tables):
                raise SystemExit(f"table-index out of range; found {len(tables)} tables")
            df = tables[table_index]
        else:
            # Concatenate only tables with at least two columns; provenance keeps source table index unavailable by design.
            usable = [t for t in tables if len(t.columns) >= 2]
            df = pd.concat(usable, ignore_index=True, sort=False) if usable else tables[0]
    else:
        raise RuntimeError(f"unsupported input format: {suffix or path.name}")
    df = df.where(pd.notna(df), None)
    return [{str(k): json_safe(v) for k, v in row.items()} for row in df.to_dict(orient="records")]


def canonicalize_row(
    row: dict[str, Any], mapping: dict[str, str], separators: list[str], defaults: dict[str, Any], input_path: Path
) -> dict[str, Any]:
    out: dict[str, Any] = {}
    consumed = set()
    for canonical, source_col in mapping.items():
        if source_col not in row:
            continue
        consumed.add(source_col)
        value = json_safe(row.get(source_col))
        if canonical in LIST_FIELDS:
            value = split_list(value, separators)
        out[canonical] = value
    for key, value in defaults.items():
        if value not in (None, "") and not clean_text(out.get(key)):
            out[key] = value
    out.setdefault("captured_at", now_iso())
    out.setdefault("verification_status", "unverified")
    out.setdefault("features", [])
    out.setdefault("business_constraints", [])
    out.setdefault("red_flags", [])
    out.setdefault("image_refs", [])
    out["import_provenance"] = {
        "input_file": str(input_path),
        "imported_at": now_iso(),
        "mapped_columns": mapping,
    }
    extras = {str(k): json_safe(v) for k, v in row.items() if k not in consumed and json_safe(v) not in (None, "")}
    if extras:
        out["import_extra"] = extras
    out.setdefault("source_id", slug_hash(out.get("source_url"), out.get("listing_title"), out.get("project_name"), out.get("area_sqm"), prefix="src"))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Bulk-import CSV/XLSX/JSON/JSONL/HTML tables into raw listing JSON with canonical field mapping.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--aliases", default=str(Path(__file__).resolve().parents[1] / "references/field-aliases.json"))
    ap.add_argument("--mapping", help="JSON file: canonical_field -> input_column")
    ap.add_argument("--platform", default="")
    ap.add_argument("--asset-type", default="")
    ap.add_argument("--transaction-type", choices=["rent", "sale", ""], default="")
    ap.add_argument("--table-index", type=int, help="For HTML input, select one pandas read_html table")
    ap.add_argument("--append", action="store_true", help="Append to existing output and exact-dedupe source URL/ID")
    ap.add_argument("--engine", choices=["auto", "pandas", "stdlib"], default="auto")
    args = ap.parse_args()

    path = Path(args.input)
    if not path.exists():
        raise SystemExit(f"input not found: {path}")
    aliases, separators = load_aliases(Path(args.aliases))
    explicit = load_explicit_mapping(args.mapping)
    pd = get_pandas(required=False)
    use_pandas = args.engine == "pandas" or (args.engine == "auto" and pd is not None)
    if args.engine == "pandas" and pd is None:
        raise SystemExit("pandas requested but unavailable; run `uv sync --frozen` from the skill root")
    try:
        rows = read_with_pandas(path, args.table_index) if use_pandas else read_stdlib(path)
    except Exception as exc:
        if args.engine == "auto" and use_pandas and path.suffix.lower() in {".json", ".jsonl", ".ndjson", ".csv", ".tsv"}:
            rows = read_stdlib(path)
            use_pandas = False
        else:
            raise SystemExit(f"import failed: {exc}") from exc
    if not rows:
        save_json(args.output, load_json(args.output, []) if args.append else [])
        print("imported=0")
        return
    columns = []
    seen_cols = set()
    for row in rows:
        for col in row.keys():
            if col not in seen_cols:
                seen_cols.add(col); columns.append(col)
    mapping = auto_mapping(columns, aliases, explicit)
    defaults = {"source_platform": args.platform, "asset_type": args.asset_type, "transaction_type": args.transaction_type}
    converted = [canonicalize_row(r, mapping, separators, defaults, path) for r in rows]

    output = load_json(args.output, []) if args.append else []
    if not isinstance(output, list):
        raise SystemExit("existing output must be a JSON array")
    seen = {(clean_text(x.get("source_url")) or clean_text(x.get("source_id"))) for x in output if isinstance(x, dict)}
    added = 0
    for row in converted:
        key = clean_text(row.get("source_url")) or clean_text(row.get("source_id"))
        if key and key in seen:
            continue
        output.append(row); added += 1
        if key:
            seen.add(key)
    save_json(args.output, output)
    print(json.dumps({
        "engine": "pandas" if use_pandas else "stdlib",
        "input_rows": len(rows),
        "added": added,
        "output_rows": len(output),
        "mapped_fields": mapping,
        "unmapped_columns": [c for c in columns if c not in set(mapping.values())]
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
