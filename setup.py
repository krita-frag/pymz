#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Setup script for the pymz_setup helper package.

Py2.7-compatible: this file is the single source of metadata. pyproject.toml
only carries build-system hints and tool configs (black/isort/etc.), never
duplicating fields here. Run `python setup.py install` on legacy Pythons or
`pip install .` on modern Pythons — both converge here.
"""
from __future__ import print_function

import os

from setuptools import find_packages, setup


HERE = os.path.abspath(os.path.dirname(__file__))


def _read(name):
    path = os.path.join(HERE, name)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") if hasattr(open, "__call__") else open(path, "r") as fh:
        return fh.read()


setup(
    name="pymz_setup",
    version="0.1.0",
    description=(
        "setuptools helpers for shipping Zig-backed Python extension modules "
        "built with pymz."
    ),
    long_description=_read("README.md") or "",
    long_description_content_type="text/markdown",
    url="https://github.com/pymz/pymz",
    license="MIT",
    packages=find_packages(include=["pymz_setup", "pymz_setup.*"]),
    package_data={"pymz_setup": ["py.typed"]},
    python_requires=">=2.7",
    install_requires=["setuptools>=42"],
    classifiers=[
        "Development Status :: 3 - Alpha",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 2",
        "Programming Language :: Python :: 2.7",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Programming Language :: Python :: 3.14",
        "Topic :: Software Development :: Build Tools",
        "Topic :: Software Development :: Compilers",
    ],
    keywords="zig python extension c-api wheel build",
)
