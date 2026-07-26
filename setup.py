#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Compatibility entry point for ``python setup.py``.

The implementation lives in ``pymz-tool/setup.py`` so Python 2 and Python 3
use exactly the same package metadata and artifact-copying logic.
"""
from __future__ import print_function

import os
import runpy


ROOT = os.path.abspath(os.path.dirname(__file__))
TOOL_ROOT = os.path.join(ROOT, "pymz-tool")
os.chdir(TOOL_ROOT)
runpy.run_path(os.path.join(TOOL_ROOT, "setup.py"), run_name="__main__")
