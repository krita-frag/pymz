#!/usr/bin/env python
"""Build script for the jsonz example extension.

Works on both Python 2.7 and Python 3.

- ``pymz.json`` provides the extension module name, zig step, and matrix.
- ``pyproject.toml`` ``[project]`` provides packaging metadata (name, version).
- On Python 2 where ``pyproject.toml`` ``[project]`` is not read by old
  setuptools, packaging metadata is passed explicitly to ``from_config()``.

Usage::

    python setup.py build_ext      # build the extension in-place
    python setup.py bdist_wheel    # build a wheel (requires the wheel package)
    python setup.py develop        # editable install
"""
from __future__ import print_function

import sys

from setuptools import setup

from pymz_tool import ZigPackageSpec, build_ext_class

# Packaging metadata declared here (same as pyproject.toml [project]).
# On Python 3, from_config reads these from pyproject.toml automatically.
# On Python 2, we pass them explicitly since old setuptools ignores [project].
DISTRIBUTION = "jsonz"
VERSION = "0.1.0"
PACKAGE_DIR = "python"

spec = ZigPackageSpec.from_config(
    ".",
    distribution=DISTRIBUTION,
    version=VERSION,
    package_dir=PACKAGE_DIR,
)

setup(
    name=spec.package_name,
    version=spec.version,
    packages=[spec.package_name],
    package_dir={"": spec.python_source_dir},
    cmdclass={"build_ext": build_ext_class(spec)},
    python_requires=">=%d.%d" % (sys.version_info[0], sys.version_info[1]),
    zip_safe=False,
)
