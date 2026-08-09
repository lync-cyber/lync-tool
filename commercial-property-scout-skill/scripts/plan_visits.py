#!/usr/bin/env python3
from __future__ import annotations
import argparse
import math
from collections import defaultdict
from _common import clean_text, load_json, save_json


def dist(a, b):
    lat1, lon1, lat2, lon2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    dlat, dlon = lat2-lat1, lon2-lon1
    h = math.sin(dlat/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(dlon/2)**2
    return 6371 * 2 * math.asin(math.sqrt(h))


def coords(p):
    try:
        lat, lon = float(p.get("lat")), float(p.get("long"))
        if -90 <= lat <= 90 and -180 <= lon <= 180:
            return (lat, lon)
    except Exception:
        pass
    return None


def greedy_order(items):
    if len(items) < 2 or any(coords(x) is None for x in items):
        return sorted(items, key=lambda x: (-float(x.get("decision_score") or 0), clean_text(x.get("project_name"))))
    remaining = items[:]
    start = max(remaining, key=lambda x: float(x.get("decision_score") or 0))
    ordered = [start]; remaining.remove(start)
    while remaining:
        cur = coords(ordered[-1])
        nxt = min(remaining, key=lambda x: dist(cur, coords(x)))
        ordered.append(nxt); remaining.remove(nxt)
    return ordered


def group_key(p):
    return clean_text(p.get("submarket")) or clean_text(p.get("district")) or "其他区域"


def main():
    ap = argparse.ArgumentParser(description="Group high-value candidates into practical site-visit sessions.")
    ap.add_argument("properties")
    ap.add_argument("brief")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--max-per-session", type=int, default=5)
    args = ap.parse_args()
    props = load_json(args.properties, [])
    brief = load_json(args.brief, {})
    candidates = [p for p in props if p.get("recommendation_status") in ("site_visit_candidate", "verify_first") and p.get("hard_filter", {}).get("passed", True)]
    candidates.sort(key=lambda x: float(x.get("decision_score") or 0), reverse=True)
    groups = defaultdict(list)
    for p in candidates:
        groups[group_key(p)].append(p)
    sessions = []
    session_no = 1
    for area, items in sorted(groups.items(), key=lambda kv: max(float(x.get("decision_score") or 0) for x in kv[1]), reverse=True):
        ordered = greedy_order(items)
        for i in range(0, len(ordered), args.max_per_session):
            chunk = ordered[i:i+args.max_per_session]
            sessions.append({
                "session": session_no,
                "area": area,
                "suggested_slot": "half_day",
                "reservation_status": "to_confirm",
                "stops": [{
                    "order": j+1,
                    "property_id": p.get("property_id"),
                    "project_name": p.get("project_name"),
                    "address": p.get("address_raw"),
                    "decision_score": p.get("decision_score"),
                    "verification_level": p.get("verification_level"),
                    "recommendation_status": p.get("recommendation_status"),
                    "focus": (p.get("red_flags") or [])[:3]
                } for j, p in enumerate(chunk)],
                "routing_note": "Coordinates available: greedy nearest-neighbor order." if all(coords(x) for x in chunk) else "No complete coordinates: grouped by submarket/district and ranked by decision score; verify actual transit order with a map before departure."
            })
            session_no += 1
    plan = {
        "start_location": (brief.get("site_visit_constraints") or {}).get("start_location", ""),
        "transport_mode": (brief.get("site_visit_constraints") or {}).get("transport_mode", "public_transit"),
        "sessions": sessions,
        "notes": [
            "Do not represent estimated routing as real-time travel time unless verified with a map/navigation source.",
            "verify_first candidates should be confirmed before reserving a physical visit slot."
        ]
    }
    save_json(args.output, plan)
    print(f"sessions={len(sessions)} stops={sum(len(s['stops']) for s in sessions)}")

if __name__ == "__main__":
    main()
