from __future__ import print_function

import os

from setuptools import Extension, setup

from pymz_setup import ZigPackageSpec, build_ext_class


ROOT = os.path.abspath(os.path.dirname(__file__))


SPEC = ZigPackageSpec(
    root=ROOT,
    package_name="jsonz",
    extension_name="_jsonz",
    zig_step="example",
)


build_ext = build_ext_class(SPEC)


setup(
    name="jsonz",
    version="0.1.0",
    description="Fast, Zig-backed JSON utilities for Python",
    python_requires=">=2.7",
    packages=["jsonz"],
    package_dir={"": "python"},
    package_data={"jsonz": ["_jsonz.pyi", "py.typed"]},
    ext_modules=[Extension(SPEC.extension_import_name, sources=[])],
    cmdclass={"build_ext": build_ext},
)
