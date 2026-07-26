"""pymz-tool: build and package Zig-backed Python extensions.

Provides four entry points:
- PEP 517/660 backend (``pymz_tool.backend``) -- Python 3.8+
- CLI (``pymz_tool.cli``) -- Python 3.8+
- Runtime loader (``pymz_tool.loader``) -- Python 3.8+
- Setuptools integration (``pymz_tool.setuptools``) -- Python 2.7+ (for setup.py builds)

Naming note: the PEP 517 ``build_wheel`` hook lives in ``pymz_tool.backend`` and
is the canonical ``pymz_tool.build_wheel``. The setuptools helper that builds a
wheel from a ``ZigPackageSpec`` is exported as ``build_wheel_from_spec``; the
distinct name keeps the two callables (which take incompatible arguments) from
shadowing each other at the package root.
"""
from __future__ import absolute_import

import sys

# python_version_string is always available regardless of setuptools.
from .config import python_version_string

__all__ = ["python_version_string"]

# Setuptools integration is available whenever setuptools is installed.
# On Python 2 this is the only build path; on Python 3 it supplements the
# PEP 517 backend for projects that still use setup.py.
try:
    from .setuptools import (
        ZigPackageSpec,
        build_ext_class,
        build_wheel_from_spec,
        ensure_dir,
        find_generated_extension,
        find_generated_stub,
        sync_generated_artifacts,
    )
    __all__.extend([
        "ZigPackageSpec",
        "build_ext_class",
        "build_wheel_from_spec",
        "ensure_dir",
        "find_generated_extension",
        "find_generated_stub",
        "sync_generated_artifacts",
    ])
except ImportError:
    ZigPackageSpec = None
    build_ext_class = None
    build_wheel_from_spec = None
    ensure_dir = None
    find_generated_extension = None
    find_generated_stub = None
    sync_generated_artifacts = None

# PEP 517 backend, CLI, and loader require Python 3.
if sys.version_info[0] >= 3:
    from .backend import (
        build_editable,
        build_sdist,
        build_wheel,
        get_requires_for_build_editable,
        get_requires_for_build_sdist,
        get_requires_for_build_wheel,
        prepare_metadata_for_build_editable,
        prepare_metadata_for_build_sdist,
        prepare_metadata_for_build_wheel,
    )
    from .loader import load_extension
    from .cli import main as cli_main
    __all__.extend([
        "build_wheel",
        "build_editable",
        "build_sdist",
        "get_requires_for_build_wheel",
        "get_requires_for_build_editable",
        "get_requires_for_build_sdist",
        "prepare_metadata_for_build_wheel",
        "prepare_metadata_for_build_editable",
        "prepare_metadata_for_build_sdist",
        "load_extension",
        "cli_main",
    ])
