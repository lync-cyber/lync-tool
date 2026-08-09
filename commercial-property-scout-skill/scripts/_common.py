#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import re
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse

NULL_STRINGS = {"", "unknown", "未知", "不详", "n/a", "na", "null", "none", "-", "--"}


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: str | Path, default: Any = None) -> Any:
    p = Path(path)
    if not p.exists():
        if default is not None:
            return default
        raise FileNotFoundError(p)
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)


def json_safe(value: Any) -> Any:
    """Recursively convert pandas/numpy missing values and non-JSON scalars to stable JSON values."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if type(value).__name__ in {"NAType", "NaTType"}:
        return None
    if isinstance(value, float):
        return None if math.isnan(value) or math.isinf(value) else value
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [json_safe(v) for v in value]
    # pandas Timestamp / datetime-like values
    if hasattr(value, "isoformat"):
        try:
            return value.isoformat()
        except Exception:
            pass
    # numpy scalar values generally expose item().
    if hasattr(value, "item"):
        try:
            return json_safe(value.item())
        except Exception:
            pass
    try:
        if value != value:
            return None
    except Exception:
        pass
    return clean_text(value)


def save_json(path: str | Path, data: Any) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(json_safe(data), f, ensure_ascii=False, indent=2, allow_nan=False)
        f.write("\n")
    tmp.replace(p)


def is_unknown(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return value.strip().lower() in NULL_STRINGS
    return False


def clean_text(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    text = re.sub(r"\s+", " ", text)
    return text


def norm_text(value: Any) -> str:
    text = clean_text(value).lower()
    text = re.sub(r"[\s\-—_·•,，.。/\\()（）\[\]【】]+", "", text)
    for suffix in ("写字楼", "商务楼", "办公楼", "商业广场", "广场", "大厦", "中心"):
        if len(text) > len(suffix) + 2 and text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    return text


def slug_hash(*parts: Any, prefix: str = "id", length: int = 12) -> str:
    raw = "|".join(clean_text(p) for p in parts)
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:length]
    return f"{prefix}_{digest}"


def parse_number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        if isinstance(value, float) and math.isnan(value):
            return None
        return float(value)
    text = clean_text(value).replace(",", "")
    if not text:
        return None
    m = re.search(r"-?\d+(?:\.\d+)?", text)
    if not m:
        return None
    try:
        return float(m.group(0))
    except ValueError:
        return None


def median(values: Iterable[float | int | None]) -> float | None:
    vals = [float(v) for v in values if v is not None and not math.isnan(float(v))]
    if not vals:
        return None
    return float(statistics.median(vals))


def pct_diff(value: float | None, base: float | None) -> float | None:
    if value is None or base in (None, 0):
        return None
    return (float(value) - float(base)) / float(base)


def domain_from_url(url: str) -> str:
    try:
        host = urlparse(url).netloc.lower().split(":")[0]
    except Exception:
        return ""
    return host[4:] if host.startswith("www.") else host


def platform_key(name: str) -> str:
    n = clean_text(name).lower()
    aliases = {
        "业主/项目官方": ["项目官网", "开发商", "业主招商", "物业招商", "官方招商"],
        "政府官方": ["政府", "房管局", "规划局", "网上房地产", "官方交易"],
        "贝壳": ["贝壳", "ke.com", "链家商业", "链家"],
        "房天下": ["房天下", "fang.com"],
        "安居客": ["安居客", "anjuke"],
        "58同城": ["58同城", "58.com", "58"],
        "JLL": ["jll", "仲量联行"],
        "CBRE": ["cbre", "世邦魏理仕"],
        "Colliers": ["colliers", "高力国际"],
        "Savills": ["savills", "第一太平戴维斯"],
        "Cushman & Wakefield": ["cushman", "戴德梁行"],
    }
    for key, words in aliases.items():
        if any(w.lower() in n for w in words):
            return key
    return clean_text(name) or "unknown"


def comparable_area(a: float | None, b: float | None, tolerance: float = 0.05) -> bool:
    if a is None or b is None or a <= 0 or b <= 0:
        return False
    return abs(a - b) / max(a, b) <= tolerance


def clamp(v: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, v))


def read_registry(path: str | Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        data = load_json(path, {})
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def source_weight(platform: str, registry: dict[str, Any]) -> float:
    key = platform_key(platform)
    entries = registry.get("platforms", {}) if isinstance(registry, dict) else {}
    if key in entries:
        return float(entries[key].get("base_confidence", 50))
    for candidate, payload in entries.items():
        if candidate.lower() in clean_text(platform).lower():
            return float(payload.get("base_confidence", 50))
    return float(registry.get("default_base_confidence", 50)) if registry else 50.0


def source_role(platform: str, registry: dict[str, Any]) -> str:
    key = platform_key(platform)
    entries = registry.get("platforms", {}) if isinstance(registry, dict) else {}
    payload = entries.get(key, {})
    return clean_text(payload.get("role")) or "unknown"


def get_path(data: dict[str, Any], path: str) -> Any:
    current: Any = data
    for part in clean_text(path).split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def choose_level(levels: Iterable[str]) -> str:
    order = {"V0": 0, "V1": 1, "V2": 2, "V3": 3}
    best = "V0"
    for level in levels:
        if order.get(clean_text(level).upper(), -1) > order[best]:
            best = clean_text(level).upper()
    return best


def ensure_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def numeric_price_from_raw(raw: Any) -> dict[str, float | None]:
    """Conservative parser. It extracts only strongly signaled common units."""
    text = clean_text(raw).replace(",", "")
    out = {"rent_rmb_sqm_day": None, "rent_rmb_month": None, "sale_total_rmb": None, "sale_rmb_sqm": None}
    if not text:
        return out

    m = re.search(r"(\d+(?:\.\d+)?)\s*元?\s*/?\s*(?:㎡|m2|m²|平(?:方米)?)\s*/?\s*(?:天|日)", text, re.I)
    if m:
        out["rent_rmb_sqm_day"] = float(m.group(1))
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:万)?\s*元?\s*/?\s*(?:月|每月)", text)
    if m:
        val = float(m.group(1))
        if "万" in m.group(0):
            val *= 10000
        out["rent_rmb_month"] = val
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:万|万元)", text)
    if m and any(k in text for k in ("出售", "总价", "售价", "万")):
        out["sale_total_rmb"] = float(m.group(1)) * 10000
    m = re.search(r"(\d+(?:\.\d+)?)\s*元?\s*/?\s*(?:㎡|m2|m²|平(?:方米)?)", text, re.I)
    if m and not out["rent_rmb_sqm_day"] and any(k in text for k in ("售价", "单价", "元/㎡", "元/平")):
        out["sale_rmb_sqm"] = float(m.group(1))
    return out
