"""pymz 扩展的构建编排。

提供：

- ``Entry`` —— 单个矩阵构建单元格（运行环境 x 版本 x 目标）加上每个单元格的 Python 交叉编译覆盖。
- ``expand_matrix`` / ``build_matrix_from_cli`` —— 从 ``pymz.json`` 或 CLI 覆盖生成 ``Entry`` 列表，
  共享一个展开路径。
- ``run_zig_build`` —— 底层的 ``zig build`` 调用。
- ``build_one_cell`` —— 构建、收集、清单和打包一个 ``Entry``。
  这是 CLI ``build`` 命令、PEP 517 ``build_wheel``/``build_editable`` 后端以及矩阵构建器
  共享的单一实现。
- ``run_matrix`` —— 并行多单元格编排。

矩阵语义：结果是运行环境 x Python 版本 x 目标的笛卡尔积。
``platform_tags`` 按索引与 ``targets`` 对齐（每个目标最多映射一个平台标签），
而非笛卡尔积，因为 wheel 平台标签是构建目标的一个函数。
"""
from __future__ import absolute_import

import hashlib
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from ._compat import (
    Any,
    DEFAULT_RUNTIME,
    DEFAULT_ZIG_TARGET,
    resolve_runtime_for_manifest,
    default_zig_target,
)
from .config import load_config, get_project_info, python_version_string
from .errors import PymzBuildError, PymzConfigError
from .manifest import build_manifest, write_manifest, collect_artifacts
from .wheel import build_wheel as _build_wheel

__all__ = [
    "Entry",
    "expand_matrix",
    "build_matrix_from_cli",
    "run_zig_build",
    "build_one_cell",
    "run_matrix",
]

# 每个条目的 Python 交叉编译覆盖字段，转发给 ``zig build`` 作为 ``-Dpymz-python-*`` 选项。
# 集中存放，使配置展开器、CLI 展开器和 ``build_one_cell`` 在字段集合上达成一致。
_ENTRY_PYTHON_FIELDS = (
    "python_config",
    "python",
    "python_includes",
    "python_ldflags",
    "python_libs",
    "python_ext_suffix",
    "python_version",
)


class Entry(object):
    """一个构建矩阵单元格。

    ``target`` 为 ``None`` 表示主机（``native``）目标。``platform_tag``
    是该单元格的 wheel 平台标签，或 ``None`` 以在打包时从目标 Python 派生。
    """

    __slots__ = (
        "runtime", "version", "target", "platform_tag",
    ) + _ENTRY_PYTHON_FIELDS

    def __init__(self, runtime, version, target, platform_tag, **python_fields):
        self.runtime = runtime
        self.version = version
        self.target = target
        self.platform_tag = platform_tag
        for f in _ENTRY_PYTHON_FIELDS:
            setattr(self, f, python_fields.get(f))

    def as_dict(self):
        # type: () -> dict[str, Any]
        d = {
            "runtime": self.runtime,
            "version": self.version,
            "target": self.target,
            "platform_tag": self.platform_tag,
        }
        for f in _ENTRY_PYTHON_FIELDS:
            d[f] = getattr(self, f)
        return d

    def __repr__(self):
        return "Entry(runtime=%r, version=%r, target=%r, platform_tag=%r)" % (
            self.runtime, self.version, self.target, self.platform_tag,
        )


def _normalize_target(target):
    """``"native"``（和空字符串）映射为 ``None``，表示主机目标。"""
    if not target or target == "native":
        return None
    return target


def _pair_targets_platform_tags(targets, platform_tags):
    # type: (list[str], list[str]) -> list[tuple[str | None, str | None]]
    """按索引将 *targets* 与 *platform_tags* 配对。

    每个目标最多映射一个平台标签（wheel 平台标签是构建目标的一个函数），
    因此这是对齐操作，而非笛卡尔积。缺失的标签默认为 ``None``（在打包时派生）。
    """
    pairs = []
    for i, target in enumerate(targets):
        pt = platform_tags[i] if i < len(platform_tags) else None
        pairs.append((_normalize_target(target), pt))
    return pairs


def expand_matrix(runtimes, python_versions, targets, platform_tags, python_fields=None):
    # type: (list[str] | None, list[str] | None, list[str] | None, list[str] | None, dict | None) -> list[Entry]
    """运行环境 x Python 版本 x 目标的笛卡尔积。

    ``targets`` 按索引与 ``platform_tags`` 配对。``python_fields``
    （来自 ``pymz.json`` 矩阵条目）附加到每个生成的单元格，因此
    当调用者合并它们时，配置声明的交叉编译覆盖在 CLI 驱动的展开中仍然有效。
    """
    runtimes = runtimes or [DEFAULT_RUNTIME]
    python_versions = python_versions or []
    targets = targets or ["native"]
    platform_tags = platform_tags or []
    pf = python_fields or {}

    entries = []
    for runtime in runtimes:
        for version in python_versions:
            for target_triple, pt in _pair_targets_platform_tags(targets, platform_tags):
                entries.append(Entry(
                    runtime=runtime,
                    version=version,
                    target=target_triple,
                    platform_tag=pt,
                    **{f: pf.get(f) for f in _ENTRY_PYTHON_FIELDS}
                ))
    return entries


def _entries_from_config(matrix_config):
    # type: (list[dict[str, Any]]) -> list[Entry]
    """将 ``pymz.json`` ``matrix`` 条目展开为 ``Entry`` 对象。

    每个配置条目可能携带每个条目的 Python 配置字段，这些字段被转发给 ``zig build`` 用于交叉编译::

        [[tool.pymz.matrix]]
        runtime = "cpython3"
        versions = ["3.10", "3.11"]
        targets = ["native"]
        python_config = "/path/to/python3.10-config"
        python_includes = "-I/usr/include/python3.10"
        python_ldflags = "-L/usr/lib -lpython3.10"
        python_ext_suffix = ".cpython-310-x86_64-linux-gnu.so"
        python_version = "3.10"
    """
    entries = []
    for cfg_entry in matrix_config:
        runtime = cfg_entry.get("runtime", DEFAULT_RUNTIME)
        versions = cfg_entry.get("versions", [])
        targets = cfg_entry.get("targets", ["native"])
        platform_tags = cfg_entry.get("platform-tags", [])
        pf = {f: cfg_entry.get(f) for f in _ENTRY_PYTHON_FIELDS}
        entries.extend(expand_matrix(
            [runtime], versions, targets, platform_tags, python_fields=pf,
        ))
    return entries


def build_matrix_from_cli(
    runtimes=None,         # type: list[str] | None
    python_versions=None,  # type: list[str] | None
    targets=None,          # type: list[str] | None
    platform_tags=None,    # type: list[str] | None
):
    # type: (...) -> list[Entry]
    """从 CLI 覆盖参数构建矩阵条目。

    结果是 *runtimes* x *python_versions* x *targets* 的笛卡尔积（三者叉乘）。
    *platform_tags* 按索引与 *targets* 对齐。每个单元格的 Python 交叉编译字段保持
    ``None``；CLI 覆盖完全替换配置矩阵，因此有意不合并配置的每个单元格字段。
    """
    return expand_matrix(runtimes, python_versions, targets, platform_tags)


def _find_zig():
    # type: () -> str
    return os.environ.get("PYMZ_ZIG", "zig")


def run_zig_build(
    root,
    step,
    prefix,
    runtime=None,             # type: Any
    python_version=None,      # type: Any
    python_versions=None,     # type: Any
    target=None,              # type: Any
    release=True,             # type: bool
    extra_args=None,          # type: Any
    backend_source=None,      # type: Any
    python_config=None,       # type: Any
    python_includes=None,     # type: Any
    python_ldflags=None,      # type: Any
    python_libs=None,         # type: Any
    python_ext_suffix=None,   # type: Any
    python_version_override=None,  # type: Any
):
    # type: (...) -> None
    """使用给定选项运行 ``zig build <step>``。

    Python 配置覆盖作为 ``-Dpymz-python-*`` 构建选项转发。
    当提供了所有四个原始标志（includes、ldflags、ext_suffix、version）时，
    构建可以在没有主机 ``python-config`` 的情况下进行。
    """
    root = Path(str(root))
    prefix = Path(str(prefix))

    cmd = [_find_zig(), "build", step, "-p", str(prefix)]
    # Zig 0.16 解析 `-Dname=value`（单个 token）；空格分隔的 `-Dname value` 形式
    # 对于字符串选项会被拒绝，因此每个转发的选项都使用 `=` 发出。
    if runtime and runtime != DEFAULT_RUNTIME:
        cmd.append("-Dpymz-runtime=" + runtime)
    if python_version:
        cmd.append("-Dpython-version=" + python_version)
    if python_versions:
        cmd.append("-Dpython-versions=" + python_versions)
    if target:
        cmd.append("-Dtarget=" + target)
    if release:
        cmd.append("-Doptimize=ReleaseFast")
    if backend_source:
        cmd.append("-Dpymz-backend-source=" + backend_source)
    if python_config:
        cmd.append("-Dpymz-python-config=" + python_config)
    if python_includes:
        cmd.append("-Dpymz-python-includes=" + python_includes)
    if python_ldflags:
        cmd.append("-Dpymz-python-ldflags=" + python_ldflags)
    if python_libs:
        cmd.append("-Dpymz-python-libs=" + python_libs)
    if python_ext_suffix:
        cmd.append("-Dpymz-python-ext-suffix=" + python_ext_suffix)
    if python_version_override:
        cmd.append("-Dpymz-python-version=" + python_version_override)
    if extra_args:
        cmd.extend(extra_args)
    try:
        subprocess.check_call(cmd, cwd=str(root))
    except subprocess.CalledProcessError as exc:
        raise PymzBuildError(
            "zig build failed for step %r (target=%s, runtime=%s): %s"
            % (step, target or "native", runtime or DEFAULT_RUNTIME, exc)
        )


def _resolve_modules(project, step):
    # type: (dict, str) -> list[dict[str, str]]
    """返回 *project* 的模块规格，当未声明任何模块时，默认为 *step* 处的单个模块。

    若 *project* 既未声明 ``modules`` 也未声明 ``module``，则返回的模块名是空字符串，
    会让后续 ``build_manifest`` 生成空模块名清单，wheel 打包时 ``archive_prefix`` 异常。
    此处在入口处显式断言，给出可归因的失败而非远端打包阶段的崩溃。
    """
    modules = project.get("modules") or []
    if modules:
        return modules
    name = project.get("module", "")
    if not name:
        raise PymzConfigError(
            "project has no 'module' or 'modules' declaration; "
            "set \"module\" in pymz.json or [tool.pymz] in pyproject.toml, "
            "or pass --module"
        )
    return [{"name": name, "zig_target": step}]


def _run_steps_for_modules(root, step, prefix, modules, **zig_kwargs):
    # type: (Any, str, Any, list[dict[str, str]], **Any) -> None
    """为 *modules* 中每个唯一的 zig 步骤运行一次 ``zig build``。"""
    seen_steps = set()
    for mod in modules:
        mod_step = mod.get("zig_target", step)
        if mod_step in seen_steps:
            continue
        seen_steps.add(mod_step)
        run_zig_build(root, mod_step, prefix, **zig_kwargs)


def _make_manifest(project, modules, runtime, artifacts, python_versions, platform_tag, step):
    # type: (dict, list[dict[str, str]], str, list, list[str], Any, str) -> dict
    """从解析的构建参数构建清单字典。"""
    module_names = [m["name"] for m in modules if m.get("name")]
    return build_manifest(
        modules=module_names,
        version=project["version"],
        runtime=resolve_runtime_for_manifest(runtime),
        distribution=project["distribution"],
        package_dir=project["package_dir"],
        artifacts=artifacts,
        python_versions=python_versions,
        platform_tag=platform_tag,
        zig_target=step,
    )


def _build_and_manifest(
    root,              # type: Any
    step,              # type: str
    prefix,            # type: Any
    project,           # type: dict[str, str]
    *,                 # keyword-only from here:
    runtime=DEFAULT_RUNTIME,    # type: str
    python_version=None,        # type: Any
    python_versions=None,       # type: Any
    target=None,                # type: Any
    release=True,               # type: bool
    backend_source=None,        # type: Any
    python_config=None,         # type: Any
    python_includes=None,       # type: Any
    python_ldflags=None,        # type: Any
    python_libs=None,           # type: Any
    python_ext_suffix=None,     # type: Any
    python_version_override=None,  # type: Any
    platform_tag=None,          # type: Any
):
    # type: (...) -> tuple[dict, Any, list]
    """构建扩展、收集产物、写入清单。

    由 ``build_one_cell``（wheel 路径）和 ``backend.build_editable``
    （可编辑路径）共享，使 zig-build + 收集 + 清单逻辑保持在同一位置。
    返回 ``(manifest, lib_dir, artifacts)``。
    """
    root = Path(str(root))
    prefix = Path(str(prefix))

    # Zig 侧 buildProject 在 python_version 与 python_versions 同时非空时返回
    # error.InvalidOption；在此显式断言，使配置错误在此处给出可归因的失败，
    # 而非在 zig build 子进程失败后才暴露。
    if python_version is not None and python_versions is not None:
        raise PymzConfigError(
            "python_version and python_versions are mutually exclusive "
            "(got python_version=%r, python_versions=%r)" % (python_version, python_versions)
        )

    pv = python_versions or python_version or python_version_string()
    modules = _resolve_modules(project, step)

    # 仅转发实际非空的版本字段给 zig build，避免单/复数同时出现触发
    # Zig 侧 error.InvalidOption。pv 仅用于清单生成，不传给 zig。
    _run_steps_for_modules(
        root, step, prefix, modules,
        runtime=runtime,
        python_version=python_version,
        python_versions=python_versions,
        target=target,
        release=release,
        backend_source=backend_source,
        python_config=python_config,
        python_includes=python_includes,
        python_ldflags=python_ldflags,
        python_libs=python_libs,
        python_ext_suffix=python_ext_suffix,
        python_version_override=python_version_override,
    )

    lib_dir = prefix / "lib"
    if not lib_dir.is_dir():
        raise PymzBuildError("zig build did not produce lib/ at %s" % lib_dir)

    module_names = [m["name"] for m in modules if m.get("name")]
    artifacts = collect_artifacts(lib_dir, module_names)
    if not any(a["kind"] == "extension" for a in artifacts):
        raise PymzBuildError("no extension artifact found in %s" % lib_dir)

    manifest = _make_manifest(
        project, modules, runtime, artifacts,
        [pv] if pv else [], platform_tag, step,
    )
    write_manifest(manifest, lib_dir)

    return manifest, lib_dir, artifacts


def build_one_cell(
    root,              # type: Any
    step,              # type: str
    prefix,            # type: Any
    out_dir,           # type: Any
    project,           # type: dict[str, str]
    *,                 # keyword-only from here:
    runtime=DEFAULT_RUNTIME,    # type: str
    python_version=None,        # type: Any
    python_versions=None,       # type: Any
    target=None,                # type: Any
    platform_tag=None,          # type: Any
    release=True,               # type: bool
    backend_source=None,        # type: Any
    python_config=None,         # type: Any
    python_includes=None,       # type: Any
    python_ldflags=None,        # type: Any
    python_libs=None,           # type: Any
    python_ext_suffix=None,     # type: Any
    python_version_override=None,  # type: Any
):
    # type: (...) -> str
    """构建、收集、清单和打包单个矩阵单元格。

    这是 CLI ``build`` 命令、PEP 517 ``build_wheel`` 后端和矩阵构建器
    共享的单一实现。返回 wheel 文件名。
    """
    out_dir = Path(str(out_dir))

    manifest, lib_dir, _artifacts = _build_and_manifest(
        root, step, prefix, project,
        runtime=runtime,
        python_version=python_version,
        python_versions=python_versions,
        target=target,
        release=release,
        backend_source=backend_source,
        python_config=python_config,
        python_includes=python_includes,
        python_ldflags=python_ldflags,
        python_libs=python_libs,
        python_ext_suffix=python_ext_suffix,
        python_version_override=python_version_override,
        platform_tag=platform_tag,
    )

    return _build_wheel(out_dir, manifest, lib_dir, root)


def _build_single(
    root,              # type: Any
    step,              # type: str
    project,           # type: dict[str, str]
    entry,             # type: Entry
    out_dir,           # type: Any
    release=True,      # type: bool
    backend_source=None,  # type: str | None
):
    # type: (...) -> str
    """构建单个 ``Entry`` 并打包 wheel。"""
    root = Path(str(root))
    out_dir = Path(str(out_dir))

    runtime = entry.runtime
    python_version = entry.version
    target = entry.target
    platform_tag = entry.platform_tag

    if python_version:
        prefix = out_dir / ("build-%s-%s" % (runtime, python_version))
    else:
        prefix = out_dir / ("build-%s" % runtime)
    if backend_source:
        bs_hash = hashlib.sha256(backend_source.encode("utf-8")).hexdigest()[:8]
        prefix = prefix.parent / (prefix.name + "-" + bs_hash)

    return build_one_cell(
        root, step, prefix, out_dir, project,
        runtime=runtime,
        python_versions=python_version,
        target=target,
        platform_tag=platform_tag,
        release=release,
        backend_source=backend_source,
        python_config=entry.python_config,
        python_includes=entry.python_includes,
        python_ldflags=entry.python_ldflags,
        python_libs=entry.python_libs,
        python_ext_suffix=entry.python_ext_suffix,
        python_version_override=entry.python_version,
    )


def run_matrix(
    root,                  # type: Any
    out_dir=None,          # type: Any
    release=True,          # type: bool
    cli_overrides=None,    # type: dict[str, Any] | None
    project_overrides=None,  # type: dict[str, str] | None
    step=None,             # type: str | None
    backend_sources=None,  # type: list[str] | None
):
    # type: (...) -> list[str]
    """从 ``pymz.json`` 或 CLI 覆盖运行构建矩阵。

    当提供了 *cli_overrides*（包含 ``runtimes``、``python_versions``、``targets``、``platform_tags`` 键）时，
    配置矩阵被 CLI 指定的矩阵完全覆盖。

    *project_overrides* 从 CLI 标志修补项目信息（module、distribution 等）。
    *step* 覆盖 zig 构建步骤名称。*backend_sources* 是后端源路径列表；
    每个条目为每个后端源构建一次。
    """
    root = Path(str(root))

    config = load_config(root)
    project = get_project_info(root)
    if project_overrides:
        project.update(project_overrides)

    step = step or default_zig_target(config)

    # 解析矩阵条目：CLI 覆盖优先于配置。
    if cli_overrides:
        entries = build_matrix_from_cli(
            cli_overrides.get("runtimes"),
            cli_overrides.get("python_versions"),
            cli_overrides.get("targets"),
            cli_overrides.get("platform_tags"),
        )
    else:
        entries = _entries_from_config(config.get("matrix", []))

    if not entries:
        raise PymzConfigError("no matrix entries found in pymz.json")

    out_dir = Path(str(out_dir)) if out_dir else root / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)

    # ``None`` 表示"使用 pymz 内置后端"。保留为哨兵值，
    # 以便下面的循环始终可以迭代。
    if not backend_sources:
        backend_sources = [None]  # type: list[Any]

    wheels = []  # type: list[str]

    # 失败时的清理策略：
    #   1. 首个 future 抛出后，对未启动的 future 调用 cancel()（ThreadPoolExecutor
    #      仅对未启动的 future 有效，但能避免新的子进程被启动）。
    #   2. 对已在运行的 future 设置有限等待，避免 `with` 退出时阻塞数分钟。
    #   3. 显式 shutdown(wait=False)，让 Python 解释器退出时清理线程。
    #   cancel_futures 参数（3.9+）若可用则一并启用。
    first_error = None  # type: Any
    first_error_entry = None  # type: Any
    executor = ThreadPoolExecutor(max_workers=4)
    try:
        futures = {}
        for entry in entries:
            for bs in backend_sources:
                future = executor.submit(
                    _build_single,
                    root, step, project,
                    entry, out_dir, release, bs,
                )
                futures[future] = entry

        for future in as_completed(futures):
            try:
                wheels.append(future.result())
            except (subprocess.CalledProcessError, OSError, PymzBuildError, PymzConfigError) as exc:
                # 使用矩阵单元格注释，以便并行失败可归因而非不透明的 CalledProcessError。
                # 捕获具体异常类型而非裸 Exception，符合 AGENTS.md 的"禁止裸 except Exception 吞错误"约定。
                first_error = exc
                first_error_entry = futures[future]
                # 取消所有未启动的 future，避免继续启动新的 zig build 子进程。
                for pending in futures:
                    pending.cancel()
                break
    finally:
        # cancel_futures 在 3.9+ 可用；3.8 忽略该参数无副作用。
        try:
            executor.shutdown(wait=False, cancel_futures=True)
        except TypeError:  # Python 3.8 不接受 cancel_futures 关键字
            executor.shutdown(wait=False)

    if first_error is not None:
        raise PymzBuildError(
            "matrix build failed for %s: %s" % (first_error_entry, first_error)
        ) from first_error

    return wheels