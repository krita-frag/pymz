"""pymz 构建的扩展 wheel 的运行时后端选择加载器。

读取导入包旁边的 ``pymz-manifest.json``，并加载文件名与当前解释器最匹配的扩展产物。
支持单模块和多模块清单。
"""
from __future__ import absolute_import

import io
import json
import logging
import os
import sys
import sysconfig

from ._compat import Any, Optional  # noqa: F401
from .manifest import MANIFEST_FILENAME, SCHEMA_VERSION as EXPECTED_SCHEMA_VERSION

__all__ = ["load_extension"]

logger = logging.getLogger("pymz_tool.loader")

# Python 2.7 has no FileNotFoundError (added in Python 3.3); IOError is the
# closest equivalent and is aliased to OSError on Python 3.
if sys.version_info[0] < 3:  # pragma: no cover - Python 2.7
    FileNotFoundError = IOError  # type: ignore


def _implementation_name():
    # type: () -> str
    if hasattr(sys, "implementation"):
        return sys.implementation.name
    return "cpython"  # pragma: no cover - Python 2.7


def _python_version():
    # type: () -> str
    major, minor = sys.version_info[:2]
    return "%d.%d" % (major, minor)


def _abi_tag():
    # type: () -> str
    impl = _implementation_name()
    major, minor = sys.version_info[:2]
    return "%s%d%d" % (impl, major, minor)


def _ext_suffix():
    # type: () -> str
    """返回平台扩展后缀（例如 '.cpython-312-darwin.so'）。"""
    suffix = sysconfig.get_config_var("EXT_SUFFIX")
    if not suffix:
        suffix = sysconfig.get_config_var("SO") or ".so"
    return suffix


def _abi3_suffix():
    # type: () -> str
    """返回当前平台的稳定 ABI 后缀。"""
    ext = _ext_suffix()
    if "." in ext:
        return ".abi3" + ext[ext.rfind("."):]
    return ".abi3.so"


def _load_manifest(package_dir):
    # type: (Any) -> dict
    """读取 ``package_dir`` 的运行时清单。"""
    path = os.path.join(str(package_dir), MANIFEST_FILENAME)
    if not os.path.isfile(path):
        raise FileNotFoundError(
            "runtime manifest not found at %s; ensure the package was "
            "built with pymz-tool which emits pymz-manifest.json" % path
        )
    with io.open(path, encoding="utf-8") as f:
        manifest = json.load(f)
    schema_version = manifest.get("schema_version")
    if schema_version != EXPECTED_SCHEMA_VERSION:
        raise ValueError(
            "unsupported pymz-manifest.json schema version %r "
            "at %s; expected %r" % (schema_version, path, EXPECTED_SCHEMA_VERSION)
        )
    return manifest


def _candidate_suffixes():
    # type: () -> list
    """返回当前解释器的候选后缀的有序列表。"""
    candidates = [_ext_suffix()]
    impl = _implementation_name()
    if impl == "cpython" and sys.version_info >= (3, 10):
        candidates.append(_abi3_suffix())
    candidates.append(".so")
    candidates.append(".pyd")
    return candidates


def _select_extension_for_module(module, artifacts):
    # type: (str, list) -> Optional[str]
    """为 *module* 选择最佳扩展产物文件名。

    选择优先级：
      1. 精确的 ABI/平台特定后缀（例如 _foo.cpython-312-darwin.so）。
      2. CPython 3.10+ 上的稳定 ABI 后缀（例如 _foo.abi3.so）。
      3. Python 2 风格回退（_foo.so / _foo.pyd）。
    """
    available = set(
        a["filename"] for a in artifacts
        if a.get("kind") == "extension"
        and a.get("module", "") == module
    )
    for suffix in _candidate_suffixes():
        candidate = "%s%s" % (module, suffix)
        if candidate in available:
            return candidate
    return None


def _resolve_module_name(module, manifest, package_dir):
    # type: (str, dict, Any) -> str
    package = manifest.get("distribution") or os.path.basename(str(package_dir))
    return "%s.%s" % (package, module)


def _load_extension_file(resolved, artifact_path):
    # type: (str, str) -> Any
    """加载 *artifact_path* 处的编译扩展，注册为 *resolved* 模块名。"""
    if sys.version_info[0] >= 3:
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.ExtensionFileLoader(resolved, str(artifact_path))
        spec = importlib.util.spec_from_loader(resolved, loader)
        ext_module = importlib.util.module_from_spec(spec)
        sys.modules[resolved] = ext_module
        loader.exec_module(ext_module)
        return ext_module
    else:  # pragma: no cover - Python 2.7
        import imp
        fp = open(str(artifact_path), "rb")
        try:
            return imp.load_module(
                resolved, fp, str(artifact_path),
                (os.path.splitext(str(artifact_path))[1], "rb", imp.C_EXTENSION),
            )
        finally:
            fp.close()


def load_extension(package_dir):
    # type: (Any) -> Any
    """加载 ``pymz-manifest.json`` 描述的所有扩展模块。

    对于单模块清单，返回已加载的扩展模块。
    对于多模块清单，加载所有扩展并返回模块名称到已加载模块的映射。

    参数
    ----------
    package_dir:
        包含 ``pymz-manifest.json`` 和已编译扩展产物的目录。
    """
    package_dir = str(package_dir)
    manifest = _load_manifest(package_dir)

    # 确定模块列表（支持多模块和单模块）。
    modules = manifest.get("modules") or []
    if not modules:
        single = manifest.get("module")
        if single:
            modules = [single]

    if not modules:
        raise RuntimeError("pymz-manifest.json has no 'modules' or 'module'")

    artifacts = manifest.get("artifacts", [])
    loaded = {}

    for module in modules:
        artifact = _select_extension_for_module(module, artifacts)
        if artifact is None:
            raise FileNotFoundError(
                "No compatible extension artifact for module '%s' "
                "on %s %s (%s) in %s"
                % (module, _implementation_name(), _python_version(),
                   _abi_tag(), package_dir)
            )

        artifact_path = os.path.join(package_dir, artifact)
        if not os.path.isfile(artifact_path):
            raise FileNotFoundError(
                "manifest listed artifact %r but it is missing at %s"
                % (artifact, artifact_path)
            )

        resolved = _resolve_module_name(module, manifest, package_dir)
        logger.debug("pymz_tool.loader: loading %s as %s", artifact_path, resolved)

        ext_module = _load_extension_file(resolved, artifact_path)
        loaded[module] = ext_module

    # 向后兼容：对于单模块清单，直接返回单个模块。
    if len(loaded) == 1:
        return next(iter(loaded.values()))
    return loaded
