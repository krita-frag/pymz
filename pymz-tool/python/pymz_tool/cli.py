"""pymz-tool 的纯 Python CLI。

用法::

    pymz-tool build    [--release|--debug] [-o DIR] [--runtime RT]
                       [--module NAME] [--distribution NAME]
                       [--package-dir DIR] [--version VER]
                       [--zig-target STEP] [--platform-tag TAG]
                       [--pymz-backend-source PATH[;PATH...]]
    pymz-tool matrix   [-o DIR] [--runtimes RT,RT...]
                       [--python-versions V,V...]
                       [--targets T,T...] [--platform-tags T,T...]
                       [--module NAME] [--distribution NAME]
                       [--package-dir DIR] [--version VER]
                       [--release|--debug] [--zig-target STEP]
                       [--pymz-backend-source PATH[;PATH...]]
    pymz-tool develop  [-o DIR] [--runtime RT] [--zig-target STEP]
    pymz-tool config
"""
from __future__ import print_function, absolute_import

import argparse
import json
import sys
import tempfile
from pathlib import Path

from ._compat import DEFAULT_RUNTIME, DEFAULT_ZIG_TARGET, default_zig_target
from .config import load_config, get_project_info, python_version_string
from .errors import PymzError
from .matrix import build_one_cell, run_matrix
from .backend import build_editable as _do_editable

__all__ = ["main"]

def _add_project_args(parser):
    """添加 ``build`` 和 ``matrix`` 共享的项目标识覆盖参数。"""
    parser.add_argument("--module", help="Extension module name")
    parser.add_argument("--distribution", help="Distribution name")
    parser.add_argument("--package-dir", help="Python package source directory")
    parser.add_argument("--version", help="Project version")


def _add_build_args(parser):
    """添加 ``build`` 和 ``matrix`` 共享的构建模式和输出覆盖参数。"""
    parser.add_argument("--release", action="store_true", default=None,
                        help="Build in release mode (default; explicit no-op)")
    parser.add_argument("--debug", action="store_true",
                        help="Build in debug mode")
    parser.add_argument("-o", "--out", help="Output directory (default: dist)")
    parser.add_argument("--zig-target",
                        help="Zig build step name (default: %s)" % DEFAULT_ZIG_TARGET)


def _build_parser():
    parser = argparse.ArgumentParser(
        prog="pymz-tool",
        description="Build pymz Zig-backed Python extensions",
    )
    sub = parser.add_subparsers(dest="command")

    build = sub.add_parser("build", help="Build a wheel for the current Python")
    _add_project_args(build)
    _add_build_args(build)
    build.add_argument("--runtime", default=None,
                       help="Runtime: auto, cpython2, cpython3, cpython3-limited")
    build.add_argument("--platform-tag", help="Wheel platform tag override")
    build.add_argument("--pymz-backend-source",
                       help="Backend source path(s), semicolon-separated")

    matrix = sub.add_parser("matrix", help="Build wheels for all matrix entries")
    _add_project_args(matrix)
    _add_build_args(matrix)
    matrix.add_argument("--runtimes",
                        help="Comma-separated runtimes (overrides [tool.pymz.matrix])")
    matrix.add_argument("--python-versions",
                        help="Comma-separated Python versions (overrides [tool.pymz.matrix])")
    matrix.add_argument("--targets",
                        help="Comma-separated zig targets (overrides [tool.pymz.matrix])")
    matrix.add_argument("--platform-tags",
                        help="Comma-separated platform tags (overrides [tool.pymz.matrix])")
    matrix.add_argument("--pymz-backend-source",
                        help="Backend source path(s), semicolon-separated")

    develop = sub.add_parser("develop", help="Build extension in-place for development")
    develop.add_argument("-o", "--out", help="Output directory (default: dist)")
    develop.add_argument("--runtime", default=None,
                         help="Runtime: auto, cpython2, cpython3, cpython3-limited")
    develop.add_argument("--zig-target", help="Zig build step name")
    develop.add_argument("--release", action="store_true", default=None,
                         help="Build in release mode")
    develop.add_argument("--debug", action="store_true",
                         help="Build in debug mode (default for develop)")
    develop.add_argument("--pymz-backend-source",
                         help="Backend source path(s), semicolon-separated")

    sub.add_parser("config", help="Print current [tool.pymz] configuration")

    return parser



def _resolve_project(root, opts):
    """从配置 + CLI 覆盖解析项目信息。"""
    project = get_project_info(root)
    if getattr(opts, "module", None):
        project["module"] = opts.module
    if getattr(opts, "distribution", None):
        project["distribution"] = opts.distribution
    if getattr(opts, "package_dir", None):
        project["package_dir"] = opts.package_dir
    if getattr(opts, "version", None):
        project["version"] = opts.version
    return project


def _resolve_release(opts, default=True):
    """解析构建模式。*default* 在未显式指定 --release/--debug 时使用。"""
    if getattr(opts, "debug", False):
        return False
    if getattr(opts, "release", None) is not None:
        return True
    return default


def _split_list(raw, sep, default=None):
    """将分隔字符串分割为去除空白的列表。空时返回 *default*。"""
    if not raw:
        return default
    parts = [p.strip() for p in raw.split(sep) if p.strip()]
    return parts if parts else default


def _split_backend_sources(raw):
    """将分号分隔的后端源字符串分割为列表。空时返回 ``[None]``。"""
    return _split_list(raw, ";", [None])


def _split_csv(raw):
    """将逗号分隔的字符串分割为列表。空时返回 ``None``。"""
    return _split_list(raw, ",", None)


def _cmd_build(root, opts):
    config = load_config(root)
    project = _resolve_project(root, opts)
    out_dir = Path(opts.out) if opts.out else root / "dist"
    release = _resolve_release(opts)
    runtime = opts.runtime or config.get("runtime", DEFAULT_RUNTIME)
    step = opts.zig_target or default_zig_target(config)
    platform_tag = opts.platform_tag
    backend_sources = _split_backend_sources(opts.pymz_backend_source)

    out_dir.mkdir(parents=True, exist_ok=True)

    wheels = []
    for bs in backend_sources:
        with tempfile.TemporaryDirectory(prefix="pymz-build-") as tmp:
            prefix = Path(tmp)
            wheel_name = build_one_cell(
                root, step, prefix, out_dir, project,
                runtime=runtime,
                python_version=python_version_string(),
                release=release,
                platform_tag=platform_tag,
                backend_source=bs,
            )
            wheels.append(wheel_name)

    for w in wheels:
        print(w)
    return 0


def _cmd_matrix(root, opts):
    out_dir = Path(opts.out) if opts.out else root / "dist"
    release = _resolve_release(opts)

    # CLI 覆盖在提供任何参数时完全替换 [tool.pymz.matrix]。
    cli_overrides = None
    runtimes = _split_csv(opts.runtimes) if opts.runtimes else None
    python_versions = _split_csv(opts.python_versions) if opts.python_versions else None
    targets = _split_csv(opts.targets) if opts.targets else None
    platform_tags = _split_csv(opts.platform_tags) if opts.platform_tags else None

    if runtimes or python_versions or targets or platform_tags:
        cli_overrides = {
            "runtimes": runtimes,
            "python_versions": python_versions,
            "targets": targets,
            "platform_tags": platform_tags,
        }

    project_overrides = {}
    if opts.module:
        project_overrides["module"] = opts.module
    if opts.distribution:
        project_overrides["distribution"] = opts.distribution
    if opts.package_dir:
        project_overrides["package_dir"] = opts.package_dir
    if opts.version:
        project_overrides["version"] = opts.version

    step = opts.zig_target
    backend_sources = _split_backend_sources(opts.pymz_backend_source)

    wheels = run_matrix(
        root, out_dir, release,
        cli_overrides=cli_overrides,
        project_overrides=project_overrides if project_overrides else None,
        step=step,
        backend_sources=backend_sources,
    )
    for w in wheels:
        print(w)
    return 0


def _cmd_develop(root, opts):
    config = load_config(root)
    out_dir = Path(opts.out) if opts.out else root / "dist"
    runtime = opts.runtime or config.get("runtime", DEFAULT_RUNTIME)
    step = opts.zig_target or default_zig_target(config)
    release = _resolve_release(opts, default=False)
    out_dir.mkdir(parents=True, exist_ok=True)

    config_settings = {}
    if runtime != DEFAULT_RUNTIME:
        config_settings["runtime"] = runtime
    if step:
        config_settings["zig-target"] = step
    config_settings["release"] = release
    if getattr(opts, "pymz_backend_source", None):
        config_settings["backend-source"] = opts.pymz_backend_source
    _do_editable(str(out_dir), config_settings=config_settings)
    return 0


def _cmd_config(root, opts):
    """打印当前 pymz 构建配置的摘要。"""
    config = load_config(root)
    if not config:
        print("No pymz.json or [tool.pymz] configuration found")
        return 0

    print("pymz configuration:")
    for key in sorted(config.keys()):
        if key == "matrix":
            print("  matrix:")
            for i, entry in enumerate(config["matrix"]):
                print("    [%d]" % i)
                for ek in sorted(entry.keys()):
                    print("      %s = %s" % (ek, json.dumps(entry[ek])))
        else:
            print("  %s = %s" % (key, json.dumps(config[key])))
    return 0


def main():
    # type: () -> int
    args = sys.argv[1:]
    if not args:
        _print_usage()
        return 1

    parser = _build_parser()
    opts = parser.parse_args(args)

    root = Path.cwd()

    try:
        if opts.command == "build":
            return _cmd_build(root, opts)
        elif opts.command == "matrix":
            return _cmd_matrix(root, opts)
        elif opts.command == "develop":
            return _cmd_develop(root, opts)
        elif opts.command == "config":
            return _cmd_config(root, opts)
        else:
            _print_usage()
            return 1
    except PymzError as e:
        # pymz 失败是用户可操作的：打印简洁消息并退出非零。
        # 意外错误（bug）以回溯形式传播。
        print("error: %s" % e, file=sys.stderr)
        return 1


def _print_usage():
    print("Usage: pymz-tool <command> [options]")
    print("")
    print("Commands:")
    print("  build     Build a wheel for the current Python")
    print("  matrix    Build wheels for all [tool.pymz.matrix] entries")
    print("  develop   Build extension in-place for development")
    print("  config    Print current [tool.pymz] configuration")
    print("")
    print("Common options:")
    print("  --module NAME         Extension module name")
    print("  --distribution NAME   Distribution name")
    print("  --package-dir DIR     Python package source directory")
    print("  --version VER         Project version")
    print("  --release             Build in release mode (default)")
    print("  --debug               Build in debug mode")
    print("  -o, --out DIR         Output directory (default: dist)")
    print("  --zig-target STEP     Zig build step name (default: %s)" % DEFAULT_ZIG_TARGET)
    print("  --runtime RT          Runtime: auto, cpython2, cpython3, cpython3-limited (default: auto)")
    print("  --platform-tag TAG    Wheel platform tag override (build)")
    print("  --runtimes RT,RT      Comma-separated runtimes (matrix)")
    print("  --python-versions V,V Comma-separated Python versions (matrix)")
    print("  --targets T,T         Comma-separated zig targets (matrix)")
    print("  --platform-tags T,T   Comma-separated platform tags (matrix)")
    print("  --pymz-backend-source PATH[;PATH...]")
    print("                        Backend source path(s), semicolon-separated")
    print("")
    print("Run 'pymz-tool <command> --help' for command-specific options.")


if __name__ == "__main__":
    raise SystemExit(main())