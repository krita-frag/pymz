"""Internal compatibility helpers shared across pymz-tool modules.

Centralises two concerns that every build entry point (CLI, PEP 517 backend,
setuptools integration, matrix builder) needs:

- Canonical default values for ``runtime`` and ``zig-target``. Keeping these as
  named constants guarantees every entry point agrees on the same default
  instead of each site picking its own magic string.
- A single ``typing.Any`` import shim so Python 2.7 (which lacks the standard
  ``typing`` module) does not require a per-module ``try/except ImportError``
  boilerplate.
"""
from __future__ import absolute_import

import sys

#: Build-time runtime used when the user does not pick one. ``"auto"`` resolves
#: to ``cpython2`` or ``cpython3`` from the detected interpreter's major
#: version, so a single config works across Python 2 and 3 hosts.
DEFAULT_RUNTIME = "auto"

#: ``zig build`` step name used when neither config nor CLI overrides it. This
#: matches the step name projects declare in their ``build.zig`` by convention.
DEFAULT_ZIG_TARGET = "example"

#: Default Python source directory.
DEFAULT_PACKAGE_DIR = "python"

#: Concrete runtime recorded in a manifest when the build-time runtime was
#: ``"auto"``. Manifests are read at import time where ``"auto"`` is ambiguous,
#: so the build resolves it to a concrete name before writing.
MANIFEST_RUNTIME_AUTO_FALLBACK = "cpython3"


def resolve_runtime_for_manifest(runtime):
    # type: (str) -> str
    """Return the concrete runtime name to record in a manifest.

    ``"auto"`` is a build-time convenience and must not leak into manifests,
    so it is normalised to the fallback. Any other value is passed through.
    """
    if runtime == DEFAULT_RUNTIME:
        return MANIFEST_RUNTIME_AUTO_FALLBACK
    return runtime


def default_zig_target(config):
    # type: (dict) -> str
    """Return the zig-target from *config* or the canonical default."""
    if config:
        return config.get("zig-target", DEFAULT_ZIG_TARGET)
    return DEFAULT_ZIG_TARGET

if sys.version_info[0] >= 3:
    from typing import Any  # noqa: F401  re-exported for callers
else:  # pragma: no cover - exercised on Python 2.7
    Any = None  # type: ignore
