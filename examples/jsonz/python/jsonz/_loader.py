"""Thin shim around ``pymz_loader`` for jsonz."""

from __future__ import annotations

from pathlib import Path

from pymz_loader import load_extension


def load_jsonz_extension() -> None:
    """Load the correct ``_jsonz`` artifact for the current interpreter."""
    load_extension(package_dir=Path(__file__).parent, module_name="jsonz._jsonz")
