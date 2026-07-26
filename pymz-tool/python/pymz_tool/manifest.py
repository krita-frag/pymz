"""Build manifest writer/reader for pymz extension artifacts.

The manifest (``pymz-manifest.json``) is the single source of truth for the
runtime loader. It is written during the build and read at import time by
``pymz_tool.loader``.
"""
from __future__ import absolute_import

import io
import json
import os

from ._compat import Any  # noqa: F401

SCHEMA_VERSION = 1
MANIFEST_FILENAME = "pymz-manifest.json"


def build_manifest(
    modules,      # type: list[str] | str
    version,      # type: str
    runtime,      # type: str
    distribution, # type: str
    package_dir,  # type: str
    artifacts,    # type: list
    python_versions=None,  # type: list | None
    platform_tag=None,     # type: str | None
    zig_target=None,       # type: str | None
):
    # type: (...) -> dict
    """Build a manifest dict from build parameters.

    *modules* can be a list of module names or a single module name string.
    """
    if isinstance(modules, str):
        modules = [modules]
    return {
        "schema_version": SCHEMA_VERSION,
        "modules": modules,
        "module": modules[0] if modules else "",  # backward compat
        "version": version,
        "runtime": runtime,
        "distribution": distribution,
        "package_dir": package_dir,
        "python_versions": python_versions or [],
        "platform_tag": platform_tag,
        "zig_target": zig_target,
        "artifacts": artifacts,
    }


def write_manifest(manifest, output_dir):
    # type: (dict, Any) -> str
    """Write *manifest* as ``pymz-manifest.json`` in *output_dir*. Returns the path."""
    path = os.path.join(str(output_dir), MANIFEST_FILENAME)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, indent=2))
    return path


def collect_artifacts(lib_dir, modules):
    # type: (Any, Any) -> list
    """Collect built artifacts from *lib_dir* for one or more *modules*.

    *modules* can be a single module name string or a list of names.

    Returns a list of ``{"filename": ..., "kind": "extension"|"stub",
    "module": <module_name>}`` dicts.
    """
    if isinstance(modules, str):
        modules = [modules]

    artifacts = []
    d = str(lib_dir)
    if not os.path.isdir(d):
        return artifacts
    for name in sorted(os.listdir(d)):
        full = os.path.join(d, name)
        if not os.path.isfile(full):
            continue
        if name == MANIFEST_FILENAME:
            continue
        # Match against each module name.
        matched_module = None
        for mod in modules:
            if name.startswith(mod):
                matched_module = mod
                break
        if matched_module is None:
            continue
        if name.endswith(".pyi"):
            artifacts.append({"filename": name, "kind": "stub", "module": matched_module})
        elif name.endswith((".so", ".pyd")):
            artifacts.append({"filename": name, "kind": "extension", "module": matched_module})
    return artifacts
