#!/usr/bin/env python
"""Build script for the showcase example extension."""
from __future__ import print_function

import sys

from setuptools import setup

from pymz_tool import ZigPackageSpec, build_ext_class

DISTRIBUTION = "showcase"
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
