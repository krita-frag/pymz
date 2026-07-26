"""Tests for the runtime backend-selection loader."""

import json
import os
import sys
from pathlib import Path

import pytest

import pymz_loader


def _platform_tag() -> str:
    import sysconfig

    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


def test_loader_selects_exact_match():
    config = {
        "version": "1",
        "module": "_jsonz",
        "variants": [
            {
                "runtime": "cpython3",
                "python_version": "99.99",
                "abi_tag": "cp9999",
                "platform_tag": "never_matches",
                "filename": "wrong.so",
            },
            {
                "runtime": "cpython3",
                "python_version": f"{sys.version_info.major}.{sys.version_info.minor}",
                "abi_tag": pymz_loader._abi_tag(),
                "platform_tag": _platform_tag(),
                "filename": "right.so",
            },
        ],
    }

    selected = pymz_loader.best_matching_variant(config)
    assert selected["filename"] == "right.so"


def test_loader_falls_back_to_limited_abi():
    config = {
        "version": "1",
        "module": "_jsonz",
        "variants": [
            {
                "runtime": "cpython3-limited",
                "python_version": "3.10",
                "abi_tag": "abi3",
                "platform_tag": _platform_tag(),
                "filename": "limited.so",
            },
            {
                "runtime": "cpython3",
                "python_version": "3.8",
                "abi_tag": "cp38",
                "platform_tag": _platform_tag(),
                "filename": "old.so",
            },
        ],
    }

    selected = pymz_loader.best_matching_variant(config)
    if sys.version_info[:2] == (3, 8):
        assert selected["filename"] == "old.so"
    else:
        assert selected["filename"] == "limited.so"


def test_loader_skips_headless_variants():
    """Headless variants are ignored when picking a Python extension."""
    config = {
        "version": "1",
        "module": "_jsonz",
        "variants": [
            {
                "runtime": "headless",
                "python_version": None,
                "abi_tag": "none",
                "platform_tag": "any",
                "filename": "_jsonz-headless",
            },
            {
                "runtime": "cpython3",
                "python_version": f"{sys.version_info.major}.{sys.version_info.minor}",
                "abi_tag": pymz_loader._abi_tag(),
                "platform_tag": _platform_tag(),
                "filename": "right.so",
            },
        ],
    }

    selected = pymz_loader.best_matching_variant(config)
    assert selected["filename"] == "right.so"


def test_pymz_config_env_override(tmp_path: Path):
    """PYMZ_CONFIG can point to a config outside the package directory."""
    config = {
        "version": "1",
        "module": "_jsonz",
        "variants": [
            {
                "runtime": "cpython3",
                "python_version": f"{sys.version_info.major}.{sys.version_info.minor}",
                "abi_tag": pymz_loader._abi_tag(),
                "platform_tag": _platform_tag(),
                "filename": "fake.so",
            },
        ],
    }
    config_path = tmp_path / "pymz-config.json"
    config_path.write_text(json.dumps(config))

    old = os.environ.get("PYMZ_CONFIG")
    os.environ["PYMZ_CONFIG"] = str(config_path)
    try:
        with pytest.raises(FileNotFoundError):
            pymz_loader.load_extension(module_name="jsonz._jsonz")
    finally:
        if old is None:
            os.environ.pop("PYMZ_CONFIG", None)
        else:
            os.environ["PYMZ_CONFIG"] = old
        sys.modules.pop("jsonz._jsonz", None)
