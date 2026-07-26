"""Configuration reader for pymz projects.

**Responsibility split:**

- ``pymz.json`` -- pymz build configuration: which extension module to build,
  which ``zig build`` step to invoke, and the build matrix (runtimes x versions
  x targets).  JSON is in the Python 2.7/3 standard library, so no third-party
  parser is needed.

- ``pyproject.toml`` ``[project]`` -- Python packaging metadata: package name,
  version, description.  Read by the PEP 517 backend on Python 3.

- ``setup.py`` -- Python packaging metadata on Python 2.7 (where
  ``pyproject.toml`` ``[project]`` is not read by old setuptools).

- ``build.zig`` -- Zig build configuration: entry files, optimize mode,
  install directories, link libraries.

``pymz.json`` does not duplicate packaging metadata (name, version) or Zig
build settings.  It only contains what is unique to pymz: the extension module
name, the zig step to invoke, and the build matrix.
"""
from __future__ import absolute_import

import io
import json
import os
import re
import sys

from ._compat import Any, DEFAULT_PACKAGE_DIR, DEFAULT_ZIG_TARGET  # noqa: F401
from .errors import PymzConfigError

PYMZ_JSON_FILENAME = "pymz.json"


def _load_toml_file(path):
    # type: (Any) -> dict
    """Load a TOML file using the best available parser.

    Needed for reading ``pyproject.toml`` ``[project]`` metadata on Python 3,
    or ``[tool.pymz]`` as fallback when ``pymz.json`` is absent.  Raises a
    ``PymzConfigError`` with an actionable message when no TOML parser is
    installed instead of propagating a bare ``ImportError``.
    """
    try:
        import tomllib
        with open(str(path), "rb") as f:
            return tomllib.load(f)
    except ImportError:
        pass
    try:
        import tomli
        with open(str(path), "rb") as f:
            return tomli.load(f)
    except ImportError:
        pass
    try:
        import toml
    except ImportError:
        raise PymzConfigError(
            "reading pyproject.toml requires the 'toml' package on Python %s; "
            "install 'toml' or use Python >= 3.11" % sys.version.split()[0]
        )
    with open(str(path)) as f:
        return toml.load(f)


def load_pymz_json(root):
    # type: (Any) -> dict | None
    """Load ``pymz.json`` from *root*.  Returns ``None`` if absent."""
    path = os.path.join(str(root), PYMZ_JSON_FILENAME)
    if not os.path.isfile(path):
        return None
    with io.open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_pyproject(root):
    # type: (Any) -> dict
    """Load ``pyproject.toml`` from *root*."""
    return _load_toml_file(os.path.join(str(root), "pyproject.toml"))


def load_config(root):
    # type: (Any) -> dict
    """Load pymz build configuration from ``pymz.json``.

    Falls back to ``[tool.pymz]`` in ``pyproject.toml`` when ``pymz.json`` is
    absent.  ``[tool.pymz]`` and ``[tool.pymz_tool]`` are both accepted as the
    same table (the latter is the underscore alias); a project should use one
    consistently.
    """
    data = load_pymz_json(root)
    if data is not None:
        return data
    py = load_pyproject(root)
    tool = py.get("tool", {})
    return tool.get("pymz") or tool.get("pymz_tool") or {}


def get_modules(root):
    # type: (Any) -> list[dict[str, str]]
    """Return a list of module specs from ``pymz.json``.

    Each spec is ``{"name": "_foo", "zig_target": "example"}``.

    Supports both multi-module format (``"modules": [...]``) and single-module
    format (``"module": "_foo", "zig-target": "example"``).  When no module is
    declared, derives one from the project distribution name.
    """
    config = load_config(root)
    default_target = config.get("zig-target", DEFAULT_ZIG_TARGET)

    if "modules" in config:
        return [
            {
                "name": m["name"],
                "zig_target": m.get("zig-target", default_target),
            }
            for m in config["modules"]
        ]

    # Single module.
    module_name = config.get("module", "")
    if module_name:
        return [{"name": module_name, "zig_target": default_target}]

    # Derive from project name.  Configuration errors surface as
    # ``PymzConfigError`` rather than being swallowed, so a broken
    # pyproject.toml is not silently turned into "no modules".
    project = get_project_info(root)
    if not project["module"]:
        return []
    return [{"name": project["module"], "zig_target": default_target}]


def get_project_info(root, overrides=None):
    # type: (Any, dict | None) -> dict
    """Resolve project identity from packaging metadata + pymz build config.

    Packaging metadata (name, version) comes from ``pyproject.toml``
    ``[project]`` on Python 3, or from *overrides* (typically passed by
    ``setup.py`` on Python 2).  The extension module names come from
    ``pymz.json``.

    *overrides* keys: ``distribution``, ``version``, ``package_dir``.

    Returns a dict with: ``name``, ``version``, ``module`` (first module, for
    backward compat), ``modules`` (list of module specs), ``distribution``,
    ``package_dir``.
    """
    config = load_config(root)
    overrides = overrides or {}

    # Extension modules: from pymz.json (build config).
    modules = _modules_from(config, overrides)
    first_module = modules[0]["name"] if modules else ""

    # Packaging metadata: from overrides (setup.py) or pyproject.toml [project].
    name = overrides.get("distribution", "")
    version = overrides.get("version", "")
    package_dir = overrides.get("package_dir", "")

    if not name or not version or not package_dir:
        try:
            py = load_pyproject(root)
            project = py.get("project", {})
            if not name:
                name = project.get("name", "")
            if not version:
                version = project.get("version", "")
        except (IOError, OSError, PymzConfigError):
            pass

    if not name:
        name = "extension"
    if not first_module:
        first_module = _snake_to_identifier(name)
    if not package_dir:
        package_dir = DEFAULT_PACKAGE_DIR

    return {
        "name": name,
        "version": version,
        "module": first_module,
        "modules": modules,
        "distribution": name,
        "package_dir": package_dir,
    }


def _modules_from(config, overrides):
    # type: (dict, dict) -> list[dict[str, str]]
    """Return module specs from *config*, honouring an explicit ``module``
    override (used when the CLI pins a single module)."""
    default_target = config.get("zig-target", DEFAULT_ZIG_TARGET)
    if "modules" in config:
        return [
            {
                "name": m["name"],
                "zig_target": m.get("zig-target", default_target),
            }
            for m in config["modules"]
        ]
    module_name = overrides.get("module") or config.get("module", "")
    if module_name:
        return [{"name": module_name, "zig_target": default_target}]
    return []


def get_matrix(root):
    # type: (Any) -> list
    """Load the build matrix from ``pymz.json``."""
    config = load_config(root)
    return config.get("matrix", [])


def _snake_to_identifier(name):
    # type: (str) -> str
    return re.sub(r"[-_.]+", "_", name)


def python_version_string():
    # type: () -> str
    return "%d.%d" % sys.version_info[:2]
