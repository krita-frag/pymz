"""pymz-tool 的异常层级。

所有 pymz-tool 构建/配置失败抛出 ``PymzError`` 子类，以便
调用者（CLI、PEP 517 后端、测试）可以区分 pymz 失败与
通用 ``RuntimeError``/``OSError``，而无需使用宽泛的 ``except Exception`` 块。
"""
from __future__ import absolute_import


class PymzError(Exception):
    """所有 pymz-tool 失败的基类。"""


class PymzConfigError(PymzError):
    """当项目配置（pymz.json/pyproject.toml）无效或不足以描述构建时抛出
    （例如未声明模块）。"""


class PymzBuildError(PymzError):
    """当 ``zig build`` 调用或产物收集失败时抛出。"""


class PymzManifestError(PymzError):
    """当 ``pymz-manifest.json`` 的读写或校验失败时抛出。"""


__all__ = [
    "PymzError",
    "PymzConfigError",
    "PymzBuildError",
    "PymzManifestError",
]