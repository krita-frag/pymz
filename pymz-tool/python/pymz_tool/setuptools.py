"""``setup.py`` 构建的 Setuptools 集成（Python 2.7 和 3）。

此模块提供与 PEP 517 后端（``pymz_tool.backend``）相同的构建能力，
但通过传统的 ``setup.py`` 接口。两种路径都产生带有 ``pymz-manifest.json`` 的 wheel，
因此运行时加载器的工作方式相同。

配置划分：
- ``pymz.json``：扩展模块名、zig 步骤、构建矩阵。
- ``setup.py`` / ``pyproject.toml`` ``[project]``：包名、版本、package_dir。

项目 ``setup.py`` 中的用法::

    from pymz_tool import ZigPackageSpec, build_ext_class

    spec = ZigPackageSpec.from_config(
        ".",
        distribution="mypkg",       # from setup(name=...) / [project] name
        version="0.1.0",            # from setup(version=...) / [project] version
        package_dir="python",       # from setup(package_dir=...)
    )

    setup(
        name=spec.package_name,
        version=spec.version,
        packages=[spec.package_name],
        package_dir={"": spec.python_source_dir},
        cmdclass={"build_ext": build_ext_class(spec)},
    )

执行 ``python setup.py build_ext`` 后，清单会被写入扩展旁边的 ``build_lib`` 中。
然后 ``python setup.py bdist_wheel`` 会生成一个包含扩展、存根、清单和 Python 源码的 wheel。
"""

from __future__ import print_function, absolute_import

import os
import shutil
import subprocess

from setuptools.command.build_ext import build_ext as build_ext_base

from ._compat import DEFAULT_RUNTIME, DEFAULT_ZIG_TARGET, resolve_runtime_for_manifest
from .config import python_version_string
from .errors import PymzBuildError
from .manifest import build_manifest, write_manifest, collect_artifacts

__all__ = [
    "ZigPackageSpec",
    "build_ext_class",
    "find_generated_extension",
    "find_generated_stub",
    "sync_generated_artifacts",
    "ensure_dir",
]


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


class ZigPackageSpec(object):
    """Zig 后端的 setuptools 扩展的项目配置。

    属性：
        root: 项目根目录（绝对路径）。
        package_name: Python 包名（例如 "mypkg"）。
        extension_name: 第一个扩展模块名（向后兼容）。
        modules: ``{"name": ..., "zig_target": ...}`` 字典的列表。
        version: 项目版本字符串。
        runtime: 目标运行环境（"cpython2"、"cpython3"、"cpython3-limited"）。
        zig_step: 默认的 zig 构建步骤名称。
        python_source_dir: 包含 Python 包源码的目录。
        zig_executable: zig 可执行文件的路径（默认来自 PYMZ_ZIG 环境变量或 "zig"）。
    """

    def __init__(
        self,
        root,
        package_name,
        extension_name,
        version="0.0.0",
        runtime=DEFAULT_RUNTIME,
        zig_step=DEFAULT_ZIG_TARGET,
        python_source_dir="python",
        zig_executable=None,
        modules=None,
    ):
        self.root = os.path.abspath(root)
        self.package_name = package_name
        self.extension_name = extension_name
        self.version = version
        self.runtime = runtime
        self.zig_step = zig_step
        self.python_source_dir = python_source_dir
        self.zig_executable = zig_executable or os.environ.get("PYMZ_ZIG", "zig")
        # 多模块支持：显式列表或单模块回退。
        if modules:
            self.modules = modules
        else:
            self.modules = [{"name": extension_name, "zig_target": zig_step}]

    @classmethod
    def from_config(cls, root, distribution=None, version=None, package_dir=None):
        """从 ``pymz.json`` + 打包元数据创建规格。

        ``pymz.json`` 提供扩展模块名、zig 步骤和矩阵。
        打包元数据（distribution、version、package_dir）来自
        *pyproject.toml* ``[project]``（Python 3 上）或显式关键字参数
        （通常在 Python 2 上由 ``setup.py`` 传递）。
        """
        from .config import load_config, get_project_info
        root = os.path.abspath(root)
        config = load_config(root)
        overrides = {}
        if distribution:
            overrides["distribution"] = distribution
        if version:
            overrides["version"] = version
        if package_dir:
            overrides["package_dir"] = package_dir
        project = get_project_info(root, overrides=overrides or None)
        modules = project.get("modules") or [{"name": project["module"], "zig_target": config.get("zig-target", DEFAULT_ZIG_TARGET)}]
        return cls(
            root,
            project["distribution"],
            project["module"],
            version=project["version"],
            runtime=config.get("runtime", DEFAULT_RUNTIME),
            zig_step=config.get("zig-target", DEFAULT_ZIG_TARGET),
            python_source_dir=project["package_dir"],
            modules=modules,
        )

    @property
    def python_package_dir(self):
        return os.path.join(self.root, self.python_source_dir, self.package_name)

    @property
    def zig_lib_dir(self):
        return os.path.join(self.root, "zig-out", "lib")

    @property
    def extension_import_name(self):
        return "%s.%s" % (self.package_name, self.extension_name)

    @property
    def extension_names(self):
        """扩展模块名称列表。"""
        return [m["name"] for m in self.modules]

    def zig_build_commands(self, python_version):
        """返回 ``zig build`` 命令列表，每个唯一步骤一个。

        当运行环境为默认值（``"auto"``）时省略运行环境标志，以便 zig
        构建从检测到的解释器解析运行环境，匹配 ``matrix.run_zig_build``。
        """
        seen = set()
        commands = []
        for mod in self.modules:
            step = mod.get("zig_target", self.zig_step)
            if step in seen:
                continue
            seen.add(step)
            cmd = [
                self.zig_executable,
                "build",
                step,
                "-Dpython-version=%s" % python_version,
            ]
            if self.runtime and self.runtime != DEFAULT_RUNTIME:
                cmd.append("-Dpymz-runtime=%s" % self.runtime)
            commands.append(cmd)
        return commands

    def zig_build_command(self, python_version):
        """返回单个 ``zig build`` 命令（向后兼容，第一个步骤）。"""
        cmds = self.zig_build_commands(python_version)
        return cmds[0] if cmds else []


def find_generated_extension(zig_lib_dir, extension_name):
    """在 *zig_lib_dir* 中定位已编译的扩展文件。

    用 ``extension_name + "."`` 前缀匹配，避免 ``_foo`` 与 ``_foobar`` 碰撞。
    """
    prefix = extension_name + "."
    for name in sorted(os.listdir(zig_lib_dir)):
        if not name.startswith(prefix):
            continue
        path = os.path.join(zig_lib_dir, name)
        if name.endswith(".pyi") or os.path.isdir(path):
            continue
        return path
    raise PymzBuildError(
        "built extension not found for %r in %s" % (extension_name, zig_lib_dir)
    )


def find_generated_stub(zig_lib_dir, extension_name):
    """在 *zig_lib_dir* 中定位生成的 ``.pyi`` 存根。不存在时返回 ``None``。"""
    stub_source = os.path.join(zig_lib_dir, "%s.pyi" % extension_name)
    if not os.path.exists(stub_source):
        return None
    return stub_source


def sync_generated_artifacts(spec, build_lib, copy_to_source):
    """将构建的扩展和存根复制到 setuptools 的 build_lib 中，并可选择复制到源码树中。"""
    target_dirs = [os.path.join(build_lib, spec.package_name)]
    if copy_to_source:
        target_dirs.append(spec.python_package_dir)

    for target_dir in target_dirs:
        ensure_dir(target_dir)
        for mod_name in spec.extension_names:
            ext_source = find_generated_extension(spec.zig_lib_dir, mod_name)
            shutil.copy2(ext_source, os.path.join(target_dir, os.path.basename(ext_source)))
            stub_source = find_generated_stub(spec.zig_lib_dir, mod_name)
            if stub_source:
                shutil.copy2(stub_source, os.path.join(target_dir, "%s.pyi" % mod_name))


def _run_zig_build(spec):
    # type: (ZigPackageSpec) -> None
    """为 *spec* 中的每个唯一步骤运行 ``zig build``。"""
    for cmd in spec.zig_build_commands(python_version_string()):
        try:
            subprocess.check_call(cmd, cwd=spec.root)
        except subprocess.CalledProcessError as exc:
            raise PymzBuildError(
                "zig build failed (exit %d): %s"
                % (exc.returncode, " ".join(cmd))
            )


def _build_manifest_for_spec(spec, artifacts):
    """从 *spec* 和收集的 *artifacts* 构建清单字典。

    使用 ``resolve_runtime_for_manifest`` 将 ``"auto"`` 规范化为具体运行环境，
    匹配 PEP 517 / 矩阵路径。
    """
    return build_manifest(
        modules=spec.extension_names,
        version=spec.version,
        runtime=resolve_runtime_for_manifest(spec.runtime),
        distribution=spec.package_name,
        package_dir=spec.python_source_dir,
        artifacts=artifacts,
        python_versions=[python_version_string()],
        zig_target=spec.zig_step,
    )


def _write_manifest(spec, build_lib):
    """将 ``pymz-manifest.json`` 写入 *build_lib* 中扩展旁边。

    这使得运行时加载器（``pymz_tool.loader``）可以在导入时定位正确的扩展产物。
    """
    artifacts = collect_artifacts(spec.zig_lib_dir, spec.extension_names)
    if not artifacts:
        return
    manifest = _build_manifest_for_spec(spec, artifacts)
    pkg_dir = os.path.join(build_lib, spec.package_name)
    write_manifest(manifest, pkg_dir)


def build_ext_class(spec):
    """创建一个运行 ``zig build`` 的 setuptools ``build_ext`` 命令类。

    构建后，扩展、存根和 ``pymz-manifest.json`` 被复制到 ``build_lib`` 中，
    以便 ``bdist_wheel`` 生成完整的 wheel。支持多模块规格（每个唯一 zig 步骤运行一次）。
    """
    class ZigBuildExt(build_ext_base):
        def run(self):
            _run_zig_build(spec)
            sync_generated_artifacts(spec, self.build_lib, self.inplace)
            _write_manifest(spec, self.build_lib)
            self.run_command("build_py")

    return ZigBuildExt