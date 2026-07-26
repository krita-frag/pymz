"""Runtime backend selection loader for pymz-built extension wheels.

Reads ``pymz-manifest.json`` next to the importing package and loads the
extension artifacts whose filenames best match the current interpreter.
Supports both single-module and multi-module manifests.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import logging
import sys
import sysconfig
from pathlib import Path
from typing import Any

__all__ = ["load_extension"]

logger = logging.getLogger("pymz_tool.loader")

MANIFEST_FILENAME = "pymz-manifest.json"
EXPECTED_SCHEMA_VERSION = 1


def _implementation_name() -> str:
    return sys.implementation.name


def _python_version() -> str:
    major, minor = sys.version_info[:2]
    return f"{major}.{minor}"


def _abi_tag() -> str:
    impl = sys.implementation.name
    major, minor = sys.version_info[:2]
    return f"{impl}{major}{minor}"


def _ext_suffix() -> str:
    """Return the platform extension suffix (e.g. '.cpython-312-darwin.so')."""
    return sysconfig.get_config_var("EXT_SUFFIX") or ".so"


def _abi3_suffix() -> str:
    """Return the stable ABI suffix for the current platform."""
    ext = _ext_suffix()
    if "." in ext:
        return ".abi3" + ext[ext.rfind("."):]
    return ".abi3.so"


def _load_manifest(package_dir: Path) -> dict[str, Any]:
    """Read the runtime manifest for ``package_dir``."""
    path = package_dir / MANIFEST_FILENAME
    if not path.is_file():
        raise FileNotFoundError(
            f"runtime manifest not found at {path}; ensure the package was "
            f"built with pymz-tool which emits pymz-manifest.json"
        )
    with open(path, encoding="utf-8") as f:
        manifest = json.load(f)
    schema_version = manifest.get("schema_version")
    if schema_version != EXPECTED_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported pymz-manifest.json schema version {schema_version!r} "
            f"at {path}; expected {EXPECTED_SCHEMA_VERSION}"
        )
    return manifest


def _candidate_suffixes() -> list[str]:
    """Return ordered list of suffix candidates for the current interpreter."""
    candidates = [_ext_suffix()]
    impl = _implementation_name()
    if impl == "cpython" and sys.version_info >= (3, 10):
        candidates.append(_abi3_suffix())
    candidates.append(".so")
    candidates.append(".pyd")
    return candidates


def _select_extension_for_module(
    module: str, artifacts: list[dict[str, Any]]
) -> str | None:
    """Pick the best extension artifact filename for *module*.

    Selection priority:
      1. Exact ABI/platform-specific suffix (e.g. _foo.cpython-312-darwin.so).
      2. Stable ABI suffix (e.g. _foo.abi3.so) on CPython 3.10+.
      3. Python 2 style fallback (_foo.so / _foo.pyd).
    """
    available: set[str] = {
        a["filename"] for a in artifacts
        if a.get("kind") == "extension"
        and a.get("module", "") == module
    }
    for suffix in _candidate_suffixes():
        candidate = f"{module}{suffix}"
        if candidate in available:
            return candidate
    return None


def _resolve_module_name(
    module: str, manifest: dict[str, Any], package_dir: Path
) -> str:
    package = manifest.get("distribution") or package_dir.name
    return f"{package}.{module}"


def load_extension(package_dir: Path | str) -> Any:
    """Load all extension modules described by ``pymz-manifest.json``.

    For single-module manifests, returns the loaded extension module.
    For multi-module manifests, loads all extensions and returns a dict
    mapping module names to loaded modules.

    Parameters
    ----------
    package_dir:
        Directory containing ``pymz-manifest.json`` and the compiled extension
        artifacts.
    """
    package_dir = Path(package_dir)
    manifest = _load_manifest(package_dir)

    # Determine module list (support both multi-module and single-module).
    modules = manifest.get("modules") or []
    if not modules:
        single = manifest.get("module")
        if single:
            modules = [single]

    if not modules:
        raise RuntimeError("pymz-manifest.json has no 'modules' or 'module'")

    artifacts = manifest.get("artifacts", [])
    loaded = {}

    for module in modules:
        artifact = _select_extension_for_module(module, artifacts)
        if artifact is None:
            raise FileNotFoundError(
                f"No compatible extension artifact for module '{module}' "
                f"on {_implementation_name()} {_python_version()} ({_abi_tag()}) "
                f"in {package_dir}"
            )

        artifact_path = package_dir / artifact
        if not artifact_path.is_file():
            raise FileNotFoundError(
                f"manifest listed artifact {artifact!r} but it is missing at {artifact_path}"
            )

        resolved = _resolve_module_name(module, manifest, package_dir)
        logger.debug("pymz_tool.loader: loading %s as %s", artifact_path, resolved)

        loader = importlib.machinery.ExtensionFileLoader(resolved, str(artifact_path))
        spec = importlib.util.spec_from_loader(resolved, loader)
        ext_module = importlib.util.module_from_spec(spec)
        sys.modules[resolved] = ext_module
        loader.exec_module(ext_module)
        loaded[module] = ext_module

    # Backward compat: return the single module directly for single-module manifests.
    if len(loaded) == 1:
        return next(iter(loaded.values()))
    return loaded
