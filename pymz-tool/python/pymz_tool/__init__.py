"""pymz-tool：构建和打包 Zig 后端的 Python 扩展。

提供四个入口点：
- PEP 517/660 后端（``pymz_tool.backend``）——Python 3.8+
- CLI（``pymz_tool.cli``）——Python 3.8+
- 运行时加载器（``pymz_tool.loader``）——Python 3.8+
- Setuptools 集成（``pymz_tool.setuptools``）——Python 2.7+（用于 setup.py 构建）
"""
from __future__ import absolute_import

import sys

# python_version_string 始终可用，与 setuptools 无关。
from .config import python_version_string

__all__ = ["python_version_string"]

# Setuptools 集成在安装 setuptools 时即可使用。
# 在 Python 2 上这是唯一的构建路径；在 Python 3 上，它补充了 PEP 517 后端，
# 供仍使用 setup.py 的项目使用。
try:
    from .setuptools import (
        ZigPackageSpec,
        build_ext_class,
    )
    __all__.extend([
        "ZigPackageSpec",
        "build_ext_class",
    ])
except ImportError:
    ZigPackageSpec = None
    build_ext_class = None

# PEP 517 后端、CLI 和加载器需要 Python 3。
if sys.version_info[0] >= 3:
    from .backend import (
        build_editable,
        build_sdist,
        build_wheel,
        get_requires_for_build_editable,
        get_requires_for_build_sdist,
        get_requires_for_build_wheel,
        prepare_metadata_for_build_editable,
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
        "load_extension",
        "cli_main",
    ])