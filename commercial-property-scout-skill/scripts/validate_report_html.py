#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

from _common import now_iso, save_json
from _optional_deps import get_bs4, preferred_html_parser

REQUIRED_IDS = ["summary", "brief", "profile", "sources", "collection", "market", "shortlist-section", "properties", "verification", "visits"]
PLACEHOLDER_RE = re.compile(r"\{\{[^{}]+\}\}")


def issue(issues, severity, code, detail=""):
    issues.append({"severity": severity, "code": code, "detail": detail})


def main():
    ap = argparse.ArgumentParser(description="Validate rendered HTML structure, unresolved placeholders, duplicate IDs and local assets using BeautifulSoup.")
    ap.add_argument("html")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    BeautifulSoup = get_bs4(required=True)
    html_path = Path(args.html)
    if not html_path.exists():
        raise SystemExit(f"HTML not found: {html_path}")
    raw = html_path.read_text(encoding="utf-8", errors="replace")
    soup = BeautifulSoup(raw, preferred_html_parser())
    issues = []

    placeholders = sorted(set(PLACEHOLDER_RE.findall(raw)))
    if placeholders:
        issue(issues, "blocker", "unresolved_template_placeholders", ", ".join(placeholders[:20]))
    if soup.html is None or soup.body is None:
        issue(issues, "blocker", "missing_html_or_body")
    if soup.title is None or not soup.title.get_text(strip=True):
        issue(issues, "warning", "missing_title")

    ids = [tag.get("id") for tag in soup.find_all(attrs={"id": True}) if tag.get("id")]
    for ident, count in Counter(ids).items():
        if count > 1:
            issue(issues, "blocker", "duplicate_html_id", f"{ident} x{count}")
    for ident in REQUIRED_IDS:
        if ident not in ids:
            issue(issues, "blocker", "missing_required_section", ident)

    broken_local = []
    external_images = 0
    for img in soup.find_all("img"):
        src = (img.get("src") or "").strip()
        if not src:
            issue(issues, "warning", "image_missing_src")
            continue
        parsed = urlparse(src)
        if parsed.scheme in {"http", "https", "data", "file"}:
            if parsed.scheme in {"http", "https"}:
                external_images += 1
            continue
        local = (html_path.parent / src).resolve()
        if not local.exists():
            broken_local.append(src)
    if broken_local:
        issue(issues, "warning", "broken_local_images", "; ".join(sorted(set(broken_local))[:30]))
    if external_images:
        issue(issues, "info", "external_image_dependencies", str(external_images))

    # Links to local anchors should resolve.
    anchors = set(ids)
    missing_anchors = []
    for a in soup.find_all("a", href=True):
        href = a.get("href", "")
        if href.startswith("#") and href[1:] and href[1:] not in anchors:
            missing_anchors.append(href)
    if missing_anchors:
        issue(issues, "warning", "broken_internal_anchors", "; ".join(sorted(set(missing_anchors))[:30]))

    # Internal detail-card anchors do not satisfy the source-link contract.
    shortlist = soup.find("table", id="shortlist")
    if shortlist is not None:
        for row_number, row in enumerate(shortlist.select("tbody tr"), start=1):
            has_external = False
            for anchor in row.find_all("a", href=True):
                parsed = urlparse((anchor.get("href") or "").strip())
                if parsed.scheme in {"http", "https"} and parsed.netloc:
                    has_external = True
                    break
            if not has_external:
                label = row.get_text(" ", strip=True)[:120]
                issue(issues, "blocker", "shortlist_row_missing_source_link", f"row {row_number}: {label}")

    counts = Counter(i["severity"] for i in issues)
    report = {
        "checked_at": now_iso(),
        "html": str(html_path),
        "parser": preferred_html_parser(),
        "summary": {
            "blockers": counts.get("blocker", 0),
            "warnings": counts.get("warning", 0),
            "info": counts.get("info", 0),
            "valid_for_delivery": counts.get("blocker", 0) == 0,
        },
        "issues": issues,
    }
    save_json(args.output, report)
    print(report["summary"])
    if args.strict and counts.get("blocker", 0):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
