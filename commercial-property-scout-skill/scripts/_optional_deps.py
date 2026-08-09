#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any


@dataclass(frozen=True)
class DependencyStatus:
    available: bool
    version: str = ""
    error: str = ""

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def _probe(module_name: str) -> DependencyStatus:
    try:
        mod = __import__(module_name)
        return DependencyStatus(True, str(getattr(mod, "__version__", "unknown")), "")
    except Exception as exc:  # pragma: no cover - environment dependent
        return DependencyStatus(False, "", f"{type(exc).__name__}: {exc}")


def dependency_report() -> dict[str, dict[str, Any]]:
    return {
        "pandas": _probe("pandas").as_dict(),
        "bs4": _probe("bs4").as_dict(),
        "lxml": _probe("lxml").as_dict(),
        "openpyxl": _probe("openpyxl").as_dict(),
    }


def get_pandas(required: bool = False):
    try:
        import pandas as pd
        return pd
    except Exception as exc:
        if required:
            raise RuntimeError("pandas is required for this operation. Run `uv sync --frozen` from the skill root") from exc
        return None


def get_bs4(required: bool = False):
    try:
        from bs4 import BeautifulSoup
        return BeautifulSoup
    except Exception as exc:
        if required:
            raise RuntimeError("beautifulsoup4 is required for this operation. Run `uv sync --frozen` from the skill root") from exc
        return None


def preferred_html_parser() -> str:
    try:
        import lxml  # noqa: F401
        return "lxml"
    except Exception:
        return "html.parser"
