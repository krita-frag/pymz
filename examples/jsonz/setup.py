from __future__ import print_function

import os
import sys

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext as build_ext_base


ROOT = os.path.abspath(os.path.dirname(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(ROOT, os.pardir, os.pardir))
TOOLS = os.path.join(PROJECT_ROOT, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)


class build_ext(build_ext_base):
    def run(self):
        from pymz_tool.build import build_extension

        old_cwd = os.getcwd()
        try:
            os.chdir(ROOT)
            build_extension(
                "jsonz",
                version="0.1.0",
                zig_target="example",
                pymz_runtime="auto",
                release=False,
                prefix="zig-out",
                extension_dir=os.path.join(ROOT, "zig-out", "lib"),
            )
        finally:
            os.chdir(old_cwd)


setup(
    name="jsonz",
    version="0.1.0",
    description="Fast, Zig-backed JSON utilities for Python",
    python_requires=">=2.7",
    ext_modules=[Extension("jsonz", sources=[])],
    cmdclass={"build_ext": build_ext},
)
