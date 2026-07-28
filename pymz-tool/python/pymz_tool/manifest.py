"""pymz 扩展产物的构建清单写入器/读取器。

清单（``pymz-manifest.json``）是运行时加载器的单一真相源。
它在构建时写入，在导入时由 ``pymz_tool.loader`` 读取。
"""
from __future__ import absolute_import

import io
import json
import os

from ._compat import Any, SCHEMA_VERSION  # noqa: F401

MANIFEST_FILENAME = "pymz-manifest.json"

__all__ = [
    "SCHEMA_VERSION",
    "MANIFEST_FILENAME",
    "build_manifest",
    "write_manifest",
    "collect_artifacts",
]


def build_manifest(
    modules,      # type: list[str] | str
    version,      # type: str
    runtime,      # type: str
    distribution, # type: str
    package_dir,  # type: str
    artifacts,    # type: list
    python_versions=None,  # type: list | None
    platform_tag=None,     # type: str | None
    zig_target=None,       # type: str | None
):
    # type: (...) -> dict
    """从构建参数构建清单字典。

    *modules* 可以是模块名称列表或单个模块名称字符串。
    """
    if isinstance(modules, str):
        modules = [modules]
    return {
        "schema_version": SCHEMA_VERSION,
        "modules": modules,
        "module": modules[0] if modules else "",  # backward compat
        "version": version,
        "runtime": runtime,
        "distribution": distribution,
        "package_dir": package_dir,
        "python_versions": python_versions or [],
        "platform_tag": platform_tag,
        "zig_target": zig_target,
        "artifacts": artifacts,
    }


def write_manifest(manifest, output_dir):
    # type: (dict, Any) -> str
    """将 *manifest* 写入 *output_dir* 中的 ``pymz-manifest.json``。返回路径。"""
    path = os.path.join(str(output_dir), MANIFEST_FILENAME)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, indent=2))
    return path


def collect_artifacts(lib_dir, modules):
    # type: (Any, Any) -> list
    """从 *lib_dir* 收集一个或多个 *modules* 的已构建产物。

    *modules* 可以是单个模块名称字符串或名称列表。

    返回 ``{"filename": ..., "kind": "extension"|"stub", "module": <module_name>}`` 字典的列表。
    """
    if isinstance(modules, str):
        modules = [modules]

    artifacts = []
    d = str(lib_dir)
    if not os.path.isdir(d):
        return artifacts
    for name in sorted(os.listdir(d)):
        full = os.path.join(d, name)
        if not os.path.isfile(full):
            continue
        if name == MANIFEST_FILENAME:
            continue
        # 与每个模块名称匹配（最长前缀匹配，避免 _foo 与 _foobar 碰撞）。
        matched_module = None
        for mod in modules:
            if name.startswith(mod):
                if matched_module is None or len(mod) > len(matched_module):
                    matched_module = mod
        if matched_module is None:
            continue
        if name.endswith(".pyi"):
            artifacts.append({"filename": name, "kind": "stub", "module": matched_module})
        elif name.endswith((".so", ".pyd")):
            artifacts.append({"filename": name, "kind": "extension", "module": matched_module})
    return artifacts