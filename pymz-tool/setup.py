#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Build the pymz-tool Python package on Python 2.7 and Python 3.

No native binary is built; the CLI and PEP 517 backend are pure Python.
Metadata lives in ``pyproject.toml`` as the single source of truth.
"""
from __future__ import print_function

import sys

from setuptools import setup

if sys.version_info[0] >= 3:
    # Python 3: pyproject.toml is authoritative.
    setup()
else:
    # Python 2.7: pyproject.toml [project] is ignored by old setuptools.
    # PY2_METADATA mirrors pyproject.toml exactly.
    PY2_METADATA = dict(
        name="pymz-tool",
        version="0.1.0",
        description="Zig build tool and Python integration package for pymz extensions",
        packages=["pymz_tool"],
        package_dir={"": "python"},
        package_data={"pymz_tool": ["py.typed"]},
        include_package_data=True,
        python_requires=">=2.7",
        install_requires=[
            "tomli>=1; python_version >= '3' and python_version < '3.11'",
            "toml>=0.10; python_version < '3'",
        ],
        entry_points={"console_scripts": ["pymz-tool=pymz_tool.cli:main"]},
    )
    setup(**PY2_METADATA)
