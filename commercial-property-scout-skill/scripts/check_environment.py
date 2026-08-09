#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import shutil
from pathlib import Path

from _optional_deps import dependency_report, preferred_html_parser


def main() -> None:
    ap = argparse.ArgumentParser(description="Report optional dependency availability and execution modes.")
    ap.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    ap.add_argument("--strict-enhanced", action="store_true", help="Exit non-zero unless pandas and beautifulsoup4 are available")
    args = ap.parse_args()

    deps = dependency_report()
    root = Path(__file__).resolve().parents[1]
    uv_path = shutil.which("uv")
    payload = {
        "python": sys.version.split()[0],
        "uv": {"available": bool(uv_path), "path": uv_path},
        "dependencies": deps,
        "preferred_html_parser": preferred_html_parser(),
        "modes": {
            "core_json_pipeline": "available",
            "pandas_enhanced": "available" if deps["pandas"]["available"] else "fallback_stdlib",
            "saved_html_extraction": "available" if deps["bs4"]["available"] else "unavailable",
            "xlsx_bulk_import": "available" if deps["pandas"]["available"] and deps["openpyxl"]["available"] else "unavailable",
            "fast_html_parser": "lxml" if deps["lxml"]["available"] else "html.parser",
        },
        "pyproject_file": str(root / "pyproject.toml"),
        "uv_lock_file": str(root / "uv.lock"),
        "uv_lock_present": (root / "uv.lock").exists(),
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"Python {payload['python']}")
        print(f"uv: {payload['uv']['path'] if payload['uv']['available'] else 'MISSING'}")
        print(f"uv.lock: {'present' if payload['uv_lock_present'] else 'missing'}")
        for name, status in deps.items():
            if status["available"]:
                print(f"{name}: {status['version']}")
            else:
                print(f"{name}: MISSING ({status['error']})")
        print("modes:")
        for k, v in payload["modes"].items():
            print(f"  {k}: {v}")
    if args.strict_enhanced and not (deps["pandas"]["available"] and deps["bs4"]["available"]):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
