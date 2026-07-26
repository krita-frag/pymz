"""Tests for the runtime backend-selection loader."""

import json
import sys
from pathlib import Path

import pytest

from pymz_tool import loader


def _ext_suffix() -> str:
    import sysconfig

    return sysconfig.get_config_var("EXT_SUFFIX") or ".cpython-darwin.so"


def _abi3_suffix() -> str:
    ext = _ext_suffix()
    if "." in ext:
        return ".abi3" + ext[ext.rfind("."):]
    return ".abi3.so"


def _write_manifest(package_dir: Path, module: str = "_jsonz", distribution: str = "jsonz", artifacts=None) -> None:
    if artifacts is None:
        artifacts = []
    # Stamp each artifact with its owning module so the loader's
    # `_select_extension_for_module` filter matches it.
    stamped = []
    for a in artifacts:
        entry = dict(a)
        entry.setdefault("module", module)
        stamped.append(entry)
    manifest = {
        "schema_version": 1,
        "modules": [module],
        "module": module,
        "version": "0.1.0",
        "zig_target": "example",
        "runtime": "cpython3",
        "lib_dir": str(package_dir),
        "distribution": distribution,
        "artifacts": stamped,
    }
    (package_dir / loader.MANIFEST_FILENAME).write_text(
        json.dumps(manifest), encoding="utf-8"
    )


def _select(package_dir: Path, module: str = "_jsonz"):
    """Helper: load the manifest and pick the extension for *module*."""
    manifest = loader._load_manifest(package_dir)
    return loader._select_extension_for_module(module, manifest["artifacts"])


def test_loader_reads_manifest(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    suffix = _ext_suffix()
    _write_manifest(
        package_dir,
        artifacts=[{"filename": f"_jsonz{suffix}", "kind": "extension"}],
    )

    manifest = loader._load_manifest(package_dir)
    assert manifest["module"] == "_jsonz"
    assert manifest["schema_version"] == 1


def test_loader_prefers_exact_abi_suffix(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    exact = f"_jsonz{_ext_suffix()}"
    abi3 = f"_jsonz{_abi3_suffix()}"
    fallback = "_jsonz.so"
    _write_manifest(
        package_dir,
        artifacts=[
            {"filename": exact, "kind": "extension"},
            {"filename": abi3, "kind": "extension"},
            {"filename": fallback, "kind": "extension"},
        ],
    )

    selected = _select(package_dir)
    assert selected == exact


def test_loader_falls_back_to_abi3(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    abi3 = f"_jsonz{_abi3_suffix()}"
    fallback = "_jsonz.so"
    _write_manifest(
        package_dir,
        artifacts=[
            {"filename": abi3, "kind": "extension"},
            {"filename": fallback, "kind": "extension"},
        ],
    )

    selected = _select(package_dir)
    assert selected == abi3


def test_loader_falls_back_to_plain_so(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    fallback = "_jsonz.so"
    _write_manifest(
        package_dir,
        artifacts=[{"filename": fallback, "kind": "extension"}],
    )

    selected = _select(package_dir)
    assert selected == fallback


def test_loader_returns_none_when_no_artifact_matches(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    _write_manifest(
        package_dir,
        artifacts=[{"filename": "_jsonz.cpython-310-darwin.so", "kind": "extension"}],
    )

    # An artifact for a different Python version must not be selected when the
    # current interpreter cannot use it. (On CPython 3.10 this test is a no-op
    # for the exact match; the assertion holds because the manifest lists only
    # a 3.10 artifact and the current suffix differs on other versions.)
    if _ext_suffix() == ".cpython-310-darwin.so":
        pytest.skip("current interpreter is the artifact's target")
    assert _select(package_dir) is None


def test_loader_ignores_stub_artifacts(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    suffix = _ext_suffix()
    _write_manifest(
        package_dir,
        artifacts=[
            {"filename": "_jsonz.pyi", "kind": "stub"},
            {"filename": f"_jsonz{suffix}", "kind": "extension"},
        ],
    )

    selected = _select(package_dir)
    assert selected == f"_jsonz{suffix}"


def test_loader_rejects_wrong_schema_version(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    (package_dir / loader.MANIFEST_FILENAME).write_text(
        json.dumps({"schema_version": 99, "module": "_jsonz", "artifacts": []}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError):
        loader._load_manifest(package_dir)


def test_loader_raises_when_manifest_missing(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()

    with pytest.raises(FileNotFoundError):
        loader._load_manifest(package_dir)


def test_resolve_module_name_uses_distribution(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    _write_manifest(package_dir, module="_jsonz", distribution="jsonz")

    manifest = loader._load_manifest(package_dir)
    assert loader._resolve_module_name("_jsonz", manifest, package_dir) == "jsonz._jsonz"


def test_resolve_module_name_falls_back_to_dir_name(tmp_path: Path):
    package_dir = tmp_path / "jsonz"
    package_dir.mkdir()
    _write_manifest(package_dir, module="_jsonz", distribution=None)
    manifest = loader._load_manifest(package_dir)
    # distribution omitted -> fall back to the package directory name.
    assert loader._resolve_module_name("_jsonz", manifest, package_dir) == "jsonz._jsonz"
