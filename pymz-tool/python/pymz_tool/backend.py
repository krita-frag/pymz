"""pymz Zig 后端的 Python 扩展的 PEP 517/660 构建后端。

调用 ``zig build`` 来编译扩展模块，然后使用标准库 ``zipfile`` 模块将产物打包到 wheel 中。
``build_wheel`` 委托给 ``matrix.build_one_cell``；``build_editable`` 委托给共享的
``matrix._build_and_manifest`` 辅助函数进行 zig-build + 收集 + 清单阶段，
然后为可编辑安装添加特定产物复制和 ``.pth`` wheel 打包。
"""
from __future__ import absolute_import

import io
import shutil
import tarfile
import tempfile
from pathlib import Path

from ._compat import Any, DEFAULT_RUNTIME, default_zig_target  # noqa: F401
from .config import load_config, get_project_info, python_version_string, load_pyproject
from .errors import PymzConfigError
from .manifest import write_manifest
from .matrix import (
    build_one_cell,
    _build_and_manifest,
)
from .wheel import build_editable_wheel

__all__ = [
    "build_wheel",
    "build_editable",
    "build_sdist",
    "get_requires_for_build_wheel",
    "get_requires_for_build_editable",
    "get_requires_for_build_sdist",
    "prepare_metadata_for_build_wheel",
    "prepare_metadata_for_build_editable",
]


def build_wheel(
    wheel_directory,
    config_settings=None,
    metadata_directory=None,
):
    # type: (str, dict[str, Any] | None, str | None) -> str
    """PEP 517 wheel 构建：编译扩展，打包到 wheel 中。"""
    root = Path.cwd()
    config = load_config(root)
    project = get_project_info(root)

    cs = config_settings or {}
    step = cs.get("zig-target", default_zig_target(config))
    runtime = cs.get("runtime", config.get("runtime", DEFAULT_RUNTIME))
    release = cs.get("release", True)
    platform_tag = cs.get("platform-tag")
    backend_source = cs.get("backend-source")

    out_dir = Path(wheel_directory)
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="pymz-build-") as tmp:
        prefix = Path(tmp)
        return build_one_cell(
            root, step, prefix, out_dir, project,
            runtime=runtime,
            python_version=python_version_string(),
            release=release,
            platform_tag=platform_tag,
            backend_source=backend_source,
        )


def _generate_pkg_info(project, pyproject=None):
    # type: (dict[str, Any], dict[str, Any] | None) -> str
    """生成 PEP 643 兼容的 PKG-INFO 内容。

    从 *project* 获取名称和版本；可选地从 *pyproject* 的 ``[project]``
    表获取 ``description``（作为 ``Summary``）和 ``requires-python``。
    """
    lines = [
        "Metadata-Version: 2.1",
        "Name: %s" % project["distribution"],
        "Version: %s" % project["version"],
    ]
    if pyproject:
        proj = pyproject.get("project", {})
        description = proj.get("description")
        if description:
            lines.append("Summary: %s" % description)
        requires_python = proj.get("requires-python")
        if requires_python:
            lines.append("Requires-Python: %s" % requires_python)
    return "\n".join(lines) + "\n"


def build_sdist(
    sdist_directory,
    config_settings=None,
):
    # type: (str, dict[str, Any] | None) -> str
    """PEP 517 sdist 构建：创建源码 tarball。

    生成的 tarball 包含 PEP 643 要求的 ``PKG-INFO`` 文件，
    使 ``pip`` 等工具无需解包即可解析 sdist 元数据。
    """
    root = Path.cwd()
    project = get_project_info(root)
    distribution = project["distribution"]
    version = project["version"]

    name = "%s-%s" % (distribution, version)
    sdist = Path(sdist_directory) / (name + ".tar.gz")

    exclude_names = {
        "zig-out", "zig-cache", ".zig-cache", ".git",
        "__pycache__", ".pytest_cache", ".mypy_cache",
        "dist", "build", ".tox", ".venv", "node_modules",
        ".eggs", ".ruff_cache", ".DS_Store",
    }

    def _sdist_filter(tarinfo):
        # 检查路径中的每个组件，使嵌套的 dist/、build/ 等目录也被排除。
        parts = tarinfo.name.split("/")
        for part in parts:
            if part in exclude_names:
                return None
        basename = parts[-1]
        if basename.endswith(".pyc") or basename.endswith(".pyo"):
            return None
        if basename.endswith(".egg-info"):
            return None
        return tarinfo

    # 读取 pyproject.toml 以获取可选的 description 和 requires-python。
    pyproject = None
    try:
        pyproject = load_pyproject(root)
    except (IOError, OSError, PymzConfigError):
        pass

    pkg_info_content = _generate_pkg_info(project, pyproject)

    with tarfile.open(str(sdist), "w:gz") as tar:
        for path in root.iterdir():
            if path.name in exclude_names:
                continue
            arcname = "%s/%s" % (name, path.name)
            tar.add(str(path), arcname=arcname, filter=_sdist_filter)

        # 添加 PEP 643 要求的 PKG-INFO 文件。
        pkg_info_data = pkg_info_content.encode("utf-8")
        info = tarfile.TarInfo("%s/PKG-INFO" % name)
        info.size = len(pkg_info_data)
        tar.addfile(info, io.BytesIO(pkg_info_data))

    return sdist.name


def build_editable(
    wheel_directory,
    config_settings=None,
    metadata_directory=None,
):
    # type: (str, dict[str, Any] | None, str | None) -> str
    """PEP 660 可编辑安装：原地构建扩展，产生 .pth wheel。

    扩展被编译到项目的 ``zig-out/lib`` 并复制到包源码树中，
    使可编辑安装可以直接拾取。wheel 本身只携带一个指向包根目录的 ``.pth`` 条目。
    """
    root = Path.cwd()
    config = load_config(root)
    project = get_project_info(root)

    cs = config_settings or {}
    step = cs.get("zig-target", default_zig_target(config))
    runtime = cs.get("runtime", config.get("runtime", DEFAULT_RUNTIME))
    release = cs.get("release", False)
    backend_source = cs.get("backend-source")

    if not project["package_dir"]:
        raise PymzConfigError(
            "build_editable requires a non-empty package_dir; "
            "set 'package-dir' in pymz.json or [tool.pymz] in pyproject.toml"
        )

    prefix = root / "zig-out"
    manifest, lib_dir, artifacts = _build_and_manifest(
        root, step, prefix, project,
        runtime=runtime,
        python_version=python_version_string(),
        release=release,
        backend_source=backend_source,
    )

    # 将产物复制到包源码目录，以便原地使用。
    package_dest = root / project["package_dir"] / project["distribution"]
    package_dest.mkdir(parents=True, exist_ok=True)
    for artifact in artifacts:
        src = lib_dir / artifact["filename"]
        shutil.copy2(str(src), str(package_dest / artifact["filename"]))
    write_manifest(manifest, package_dest)

    package_root = root / project["package_dir"]
    return build_editable_wheel(
        Path(wheel_directory),
        project["distribution"],
        project["version"],
        package_root,
    )


def get_requires_for_build_wheel(config_settings=None):
    # type: (dict[str, Any] | None) -> list[str]
    return []


def get_requires_for_build_editable(config_settings=None):
    # type: (dict[str, Any] | None) -> list[str]
    return []


def get_requires_for_build_sdist(config_settings=None):
    # type: (dict[str, Any] | None) -> list[str]
    return []


def _write_metadata(metadata_directory):
    # type: (str) -> str
    """写入 PEP 517 元数据目录（``*.dist-info``）并返回其名称。

    由 ``prepare_metadata_for_build_wheel`` 和 ``prepare_metadata_for_build_editable`` 使用。
    两者的元数据相同，因为分发名称/版本来自项目配置，而非 wheel 布局。
    预先写入元数据让 pip 无需运行（缓慢的）zig 构建即可解析分发名称。
    """
    root = Path.cwd()
    project = get_project_info(root)
    distribution = project["distribution"]
    version = project["version"]
    dist_info = "%s-%s.dist-info" % (distribution, version)
    out = Path(str(metadata_directory)) / dist_info
    out.mkdir(parents=True, exist_ok=True)
    metadata = (
        "Metadata-Version: 2.1\n"
        "Name: %s\n"
        "Version: %s\n"
    ) % (distribution, version)
    (out / "METADATA").write_text(metadata)
    (out / "WHEEL").write_text(
        "Wheel-Version: 1.0\n"
        "Generator: pymz-build-backend\n"
        "Root-Is-Purelib: false\n"
        "Tag: py3-none-any\n"
    )
    return dist_info


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):
    # type: (str, dict[str, Any] | None) -> str
    return _write_metadata(metadata_directory)


def prepare_metadata_for_build_editable(metadata_directory, config_settings=None):
    # type: (str, dict[str, Any] | None) -> str
    return _write_metadata(metadata_directory)