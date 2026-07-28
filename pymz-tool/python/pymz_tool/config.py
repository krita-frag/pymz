"""pymz 项目的配置读取器。

**职责划分：**

- ``pymz.json`` —— pymz 构建配置：构建哪个扩展模块、调用哪个 ``zig build`` 步骤以及构建矩阵
  （运行环境 x 版本 x 目标）。JSON 在 Python 2.7/3 标准库中，因此无需第三方解析器。

- ``pyproject.toml`` ``[project]`` —— Python 打包元数据：包名、版本、描述。
  由 PEP 517 后端在 Python 3 上读取。

- ``setup.py`` —— Python 2.7 上的 Python 打包元数据（因为旧的 setuptools 不读取
  ``pyproject.toml`` ``[project]``）。

- ``build.zig`` —— Zig 构建配置：入口文件、优化模式、安装目录、链接库。

``pymz.json`` 不重复打包元数据（名称、版本）或 Zig 构建设置。
它只包含 pymz 特有的内容：扩展模块名、要调用的 zig 步骤以及构建矩阵。
"""
from __future__ import absolute_import

import io
import json
import os
import re
import sys

from ._compat import Any, DEFAULT_PACKAGE_DIR, DEFAULT_ZIG_TARGET, Optional  # noqa: F401
from .errors import PymzConfigError

PYMZ_JSON_FILENAME = "pymz.json"

#: ``pymz.json`` 配置文件的 schema 版本。可选字段；存在且不匹配时拒绝。
PYMZ_JSON_SCHEMA_VERSION = 1

__all__ = [
    "PYMZ_JSON_FILENAME",
    "PYMZ_JSON_SCHEMA_VERSION",
    "load_pymz_json",
    "load_pyproject",
    "load_config",
    "get_project_info",
    "python_version_string",
]


def _load_toml_file(path):
    # type: (Any) -> dict
    """使用最佳可用解析器加载 TOML 文件。

    需要在 Python 3 上读取 ``pyproject.toml`` ``[project]`` 元数据，
    或在 ``pymz.json`` 不存在时读取 ``[tool.pymz]`` 作为回退。
    当未安装 TOML 解析器时，抛出带有可操作消息的 ``PymzConfigError``，
    而非传播裸的 ``ImportError``。
    """
    try:
        import tomllib
        with open(str(path), "rb") as f:
            return tomllib.load(f)
    except ImportError:
        pass
    try:
        import tomli
        with open(str(path), "rb") as f:
            return tomli.load(f)
    except ImportError:
        pass
    try:
        import toml
    except ImportError:
        raise PymzConfigError(
            "reading pyproject.toml requires the 'toml' package on Python %s; "
            "install 'toml' or use Python >= 3.11" % sys.version.split()[0]
        )
    with open(str(path)) as f:
        return toml.load(f)


def load_pymz_json(root):
    # type: (Any) -> Optional[dict]
    """从 *root* 加载 ``pymz.json``。不存在时返回 ``None``。"""
    path = os.path.join(str(root), PYMZ_JSON_FILENAME)
    if not os.path.isfile(path):
        return None
    with io.open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_pyproject(root):
    # type: (Any) -> dict
    """从 *root* 加载 ``pyproject.toml``。"""
    return _load_toml_file(os.path.join(str(root), "pyproject.toml"))


def load_config(root):
    # type: (Any) -> dict
    """从 ``pymz.json`` 加载 pymz 构建配置。

    当 ``pymz.json`` 不存在时，回退到 ``pyproject.toml`` 中的 ``[tool.pymz]``。
    ``pymz.json`` 的 ``schema_version`` 字段是可选的；存在且不匹配时抛出
    ``PymzConfigError``，以便未来不兼容变更可检测。
    """
    data = load_pymz_json(root)
    if data is not None:
        sv = data.get("schema_version")
        if sv is not None and sv != PYMZ_JSON_SCHEMA_VERSION:
            raise PymzConfigError(
                "pymz.json schema_version %r is not supported (expected %r)"
                % (sv, PYMZ_JSON_SCHEMA_VERSION)
            )
        return data
    py = load_pyproject(root)
    tool = py.get("tool", {})
    return tool.get("pymz") or tool.get("pymz_tool") or {}


def get_project_info(root, overrides=None):
    # type: (Any, Optional[dict]) -> dict
    """从打包元数据 + pymz 构建配置解析项目标识。

    打包元数据（名称、版本）在 Python 3 上来自 ``pyproject.toml`` ``[project]``，
    或来自 *overrides*（通常在 Python 2 上由 ``setup.py`` 传递）。
    扩展模块名称来自 ``pymz.json``。

    *overrides* 键：``distribution``、``version``、``package_dir``。

    返回包含以下字段的字典：``name``、``version``、``module``（第一个模块，向后兼容）、
    ``modules``（模块规格列表）、``distribution``、``package_dir``。
    """
    config = load_config(root)
    overrides = overrides or {}

    # 扩展模块：来自 pymz.json（构建配置）。
    modules = _modules_from(config, overrides)
    first_module = modules[0]["name"] if modules else ""

    # 打包元数据：来自 overrides（setup.py）或 pyproject.toml [project]。
    name = overrides.get("distribution", "")
    version = overrides.get("version", "")
    package_dir = overrides.get("package_dir", "")

    if not name or not version or not package_dir:
        try:
            py = load_pyproject(root)
            project = py.get("project", {})
            if not name:
                name = project.get("name", "")
            if not version:
                version = project.get("version", "")
        except (IOError, OSError, PymzConfigError):
            pass

    if not name:
        name = "extension"
    if not first_module:
        first_module = _snake_to_identifier(name)
    if not package_dir:
        package_dir = DEFAULT_PACKAGE_DIR

    return {
        "name": name,
        "version": version,
        "module": first_module,
        "modules": modules,
        "distribution": name,
        "package_dir": package_dir,
    }


def _modules_from(config, overrides):
    # type: (dict, dict) -> list[dict[str, str]]
    """从 *config* 返回模块规格，尊重显式的 ``module`` 覆盖
    （当 CLI 固定单个模块时使用）。"""
    default_target = config.get("zig-target", DEFAULT_ZIG_TARGET)
    if "modules" in config:
        return [
            {
                "name": m["name"],
                "zig_target": m.get("zig-target", default_target),
            }
            for m in config["modules"]
        ]
    module_name = overrides.get("module") or config.get("module", "")
    if module_name:
        return [{"name": module_name, "zig_target": default_target}]
    return []


def _snake_to_identifier(name):
    # type: (str) -> str
    return re.sub(r"[-_.]+", "_", name)


def python_version_string():
    # type: () -> str
    return "%d.%d" % sys.version_info[:2]