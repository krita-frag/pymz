from __future__ import print_function

from setuptools import setup


setup(
    name="pymz-tool",
    version="0.1.0",
    description="Build backend and CLI for Zig-Python extensions",
    long_description="pymz-tool builds Python extension modules from Zig sources.",
    python_requires=">=2.7",
    packages=["pymz_tool"],
    package_dir={"pymz_tool": "tools/pymz_tool"},
    package_data={"pymz_tool": ["py.typed", "build.zig"]},
    entry_points={"console_scripts": ["pymz-tool=pymz_tool.__main__:main"]},
)
