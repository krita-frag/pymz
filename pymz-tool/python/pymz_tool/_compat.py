"""pymz-tool 模块间共享的内部兼容性辅助工具。

集中处理每个构建入口点（CLI、PEP 517 后端、setuptools 集成、矩阵构建器）都需要的问题：

- ``runtime`` 和 ``zig-target`` 的规范默认值。保持为命名常量可保证每个入口点使用相同的默认值，
  而非各自选择自己的魔法字符串。
- 一个 ``typing.Any`` 导入垫片，使 Python 2.7（缺少标准 ``typing`` 模块）
  无需在每个模块中写 ``try/except ImportError`` 样板代码。
"""
from __future__ import absolute_import

import sys

#: 用户未选择时使用的构建时运行环境。``"auto"`` 根据检测到的解释器主版本号
#: 解析为 ``cpython2`` 或 ``cpython3``，因此单个配置可同时用于 Python 2 和 3 主机。
DEFAULT_RUNTIME = "auto"

#: 当配置和 CLI 均未覆盖时使用的 ``zig build`` 步骤名称。
#: 项目应在其 ``build.zig`` 中声明同名步骤。``"pymz"`` 是项目无关的
#: 通用默认值，不暗示任何特定示例。
DEFAULT_ZIG_TARGET = "pymz"

#: 默认的 Python 源目录。
DEFAULT_PACKAGE_DIR = "python"

#: 当构建时运行环境为 ``"auto"`` 时，记录在清单中的具体运行环境名称。
#: 清单在导入时被读取，那时 ``"auto"`` 具有歧义性，
#: 因此构建在写入前将其解析为具体名称。
MANIFEST_RUNTIME_AUTO_FALLBACK = "cpython3"


#: 清单 schema 版本的单一真相源。``manifest.py`` 写入，``loader.py`` 读取。
SCHEMA_VERSION = 1

__all__ = [
    "DEFAULT_RUNTIME",
    "DEFAULT_ZIG_TARGET",
    "DEFAULT_PACKAGE_DIR",
    "MANIFEST_RUNTIME_AUTO_FALLBACK",
    "SCHEMA_VERSION",
    "Any",
    "Optional",
    "resolve_runtime_for_manifest",
    "default_zig_target",
]


def resolve_runtime_for_manifest(runtime):
    # type: (str) -> str
    """返回要记录在清单中的具体运行环境名称。

    ``"auto"`` 是构建时便利选项，不能泄漏到清单中，
    因此被规范化为回退值。其他任何值直接透传。
    """
    if runtime == DEFAULT_RUNTIME:
        return MANIFEST_RUNTIME_AUTO_FALLBACK
    return runtime


def default_zig_target(config):
    # type: (dict) -> str
    """返回 *config* 中的 zig-target 或规范默认值。"""
    if config:
        return config.get("zig-target", DEFAULT_ZIG_TARGET)
    return DEFAULT_ZIG_TARGET

if sys.version_info[0] >= 3:
    from typing import Any, Optional  # noqa: F401  re-exported for callers
else:  # pragma: no cover - exercised on Python 2.7
    Any = None  # type: ignore
    Optional = None  # type: ignore