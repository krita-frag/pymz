"""Runtime backend selection loader for pymz-built extension wheels.

Reads ``pymz-config.json`` next to the importing package and loads the
extension artifact whose runtime/ABI/platform tags best match the current
interpreter.

The config path can be overridden with the ``PYMZ_CONFIG`` environment
variable, which is useful for embedded Python or test scenarios where the
config file is not in the standard package location.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any

__all__ = ["load_extension", "select_variant", "best_matching_variant"]


def _implementation_tag() -> str:
    return sys.implementation.name


def _python_version() -> str:
    major, minor = sys.version_info[:2]
    return f"{major}.{minor}"


def _python_version_digits() -> str:
    major, minor = sys.version_info[:2]
    return f"{major}{minor}"


def _abi_tag() -> str:
    return f"cp{_python_version_digits()}"


def _platform_tag() -> str:
    import sysconfig

    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


def _parse_macos_version(platform_tag: str) -> tuple[int, int]:
    parts = platform_tag.split("_")
    if len(parts) >= 3:
        try:
            return (int(parts[1]), int(parts[2]))
        except ValueError:
            pass
    return (0, 0)


def _platform_compatible(variant_platform: str) -> bool:
    current = _platform_tag()
    if current == variant_platform:
        return True
    if not (current.startswith("macosx_") and variant_platform.startswith("macosx_")):
        return False
    cur_arch = current.rsplit("_", 1)[-1]
    var_arch = variant_platform.rsplit("_", 1)[-1]
    if cur_arch != var_arch:
        return False
    return _parse_macos_version(current) >= _parse_macos_version(variant_platform)


def _is_python_runtime(runtime: str) -> bool:
    """Headless or other non-Python runtimes cannot be loaded by this loader."""
    return runtime.startswith("cpython") or runtime in {"pypy", "pypy3", "graalpython"}


def _match_score(variant: dict[str, Any]) -> int:
    """Higher score means better match for the current interpreter."""
    runtime = variant.get("runtime", "")
    if not _is_python_runtime(runtime):
        return -1

    score = 0
    if variant.get("python_version") == _python_version():
        score += 100
    if variant.get("abi_tag") == _abi_tag():
        score += 50
    if _platform_compatible(variant.get("platform_tag", "")):
        score += 25
    if runtime.startswith(_implementation_tag()):
        score += 10
    if runtime == "cpython3-limited":
        score += 5
    return score


def best_matching_variant(config: dict[str, Any]) -> dict[str, Any]:
    """Return the variant from *config* that best matches this interpreter."""
    variants = config.get("variants", [])
    if not variants:
        raise RuntimeError("pymz-config.json contains no variants")
    return max(variants, key=_match_score)


# Backwards-compatible alias.
select_variant = best_matching_variant


def _resolve_config_path(config_path: Path | str | None, package_dir: Path | None) -> Path:
    """Resolve the config path, honouring ``PYMZ_CONFIG`` and package defaults."""
    if config_path is not None:
        return Path(config_path)

    env_path = os.environ.get("PYMZ_CONFIG")
    if env_path:
        return Path(env_path)

    if package_dir is None:
        raise ValueError("config_path, PYMZ_CONFIG, or package_dir must be provided")

    return package_dir / "pymz-config.json"


def load_extension(
    config_path: Path | str | None = None,
    *,
    module_name: str | None = None,
    package_dir: Path | str | None = None,
) -> Any:
    """Load the best-matching extension described by ``pymz-config.json``.

    Parameters
    ----------
    config_path:
        Explicit path to a ``pymz-config.json`` file. If omitted, ``PYMZ_CONFIG``
        is consulted, then ``<package_dir>/pymz-config.json``.
    module_name:
        Fully-qualified module name for the loaded extension (e.g. ``"jsonz._jsonz"``).
        When omitted it is derived from ``config["module"]`` and *package_dir*.
    package_dir:
        Directory containing the config file and extension artifacts. Required
        unless *config_path* or ``PYMZ_CONFIG`` is set.
    """
    resolved_config = _resolve_config_path(config_path, Path(package_dir) if package_dir else None)

    with open(resolved_config, encoding="utf-8") as f:
        config = json.load(f)

    variant = best_matching_variant(config)
    if not _is_python_runtime(variant.get("runtime", "")):
        raise RuntimeError(
            f"Selected variant uses non-Python runtime {variant.get('runtime')!r}; "
            "it cannot be loaded into a Python interpreter"
        )

    ext_path = resolved_config.parent / variant["filename"]
    if not ext_path.exists():
        raise FileNotFoundError(
            f"Extension artifact not found: {ext_path} "
            f"(selected variant: {variant})"
        )

    resolved_module = module_name
    if resolved_module is None:
        base = config.get("module", "_extension")
        if package_dir is not None:
            pkg_name = Path(package_dir).name
            resolved_module = f"{pkg_name}.{base}"
        else:
            resolved_module = base

    loader = importlib.machinery.ExtensionFileLoader(
        resolved_module, str(ext_path)
    )
    spec = importlib.util.spec_from_loader(resolved_module, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[resolved_module] = module
    loader.exec_module(module)
    return module
