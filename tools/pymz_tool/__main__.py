"""Command-line interface for pymz_tool."""

from __future__ import print_function

import argparse
import sys

from .build import build_extension
from .config import load_config
from .scaffold import init_project
from .wheel import make_wheel, make_wheels


def main(argv=None):
    cfg = load_config()
    parser = argparse.ArgumentParser(
        prog="pymz-tool",
        description="Build Zig-Python extension wheels",
    )
    subparsers = parser.add_subparsers()
    parser.set_defaults(command=None)

    build_parser = subparsers.add_parser("build", help="Build a wheel for the current platform")
    build_parser.set_defaults(command="build")
    build_parser.add_argument("--module", help="Python extension module name")
    build_parser.add_argument("--version", help="Package version")
    build_parser.add_argument("--release", action="store_true", help="Build with optimizations")
    build_parser.add_argument("--python-version", help="Exact Python version to build against")
    build_parser.add_argument(
        "--pymz-runtime",
        help="Runtime backend to build: auto, cpython2, cpython3",
    )
    build_parser.add_argument("--zig-target", help="Zig build step to run")
    build_parser.add_argument("--extension-dir", help="Directory for built extension artifacts")
    build_parser.add_argument("-o", "--out", default="dist", help="Output directory")

    matrix_parser = subparsers.add_parser(
        "matrix",
        help="Build a multi-version manifest for smoke checks",
    )
    matrix_parser.set_defaults(command="matrix")
    matrix_parser.add_argument("--module", help="Python extension module name")
    matrix_parser.add_argument("--version", help="Package version")
    matrix_parser.add_argument("--release", action="store_true", help="Build with optimizations")
    matrix_parser.add_argument(
        "--python-versions",
        help="Comma-separated Python versions for multi-version build smoke checks",
    )
    matrix_parser.add_argument(
        "--pymz-runtime",
        help="Runtime backend to build: auto, cpython2, cpython3",
    )
    matrix_parser.add_argument("--zig-target", help="Zig build step to run")
    matrix_parser.add_argument("--extension-dir", help="Directory for built extension artifacts")
    matrix_parser.add_argument(
        "--wheel-out",
        help="Output directory for published wheels built from the manifest",
    )

    init_parser = subparsers.add_parser("init", help="Create a starter pymz_tool project")
    init_parser.set_defaults(command="init")
    init_parser.add_argument("name", help="Project name")
    init_parser.add_argument(
        "--module",
        help="Python module name; defaults to a sanitized project name",
    )
    init_parser.add_argument("--dir", help="Target directory; defaults to the project name")
    init_parser.add_argument("--description", help="Project description")
    init_parser.add_argument(
        "--runtime",
        choices=("auto", "cpython2", "cpython3"),
        default="auto",
        help="Default runtime backend for the scaffold",
    )
    init_parser.add_argument("--force", action="store_true", help="Overwrite existing files")

    args = parser.parse_args(argv)
    command = getattr(args, "command", None)

    if command == "build":
        manifest_path = build_extension(
            args.module or cfg.module,
            version=args.version or cfg.version,
            zig_target=args.zig_target or cfg.zig_target,
            python_version=args.python_version,
            pymz_runtime=args.pymz_runtime or cfg.runtime,
            release=args.release,
            extension_dir=args.extension_dir or cfg.extension_dir,
        )
        wheel_path = make_wheel(
            manifest_path,
            out_dir=args.out,
            metadata=cfg.to_metadata(),
        )
        print(wheel_path)
    elif command == "matrix":
        python_versions = args.python_versions or cfg.python_versions
        if not python_versions:
            parser.error(
                "matrix requires --python-versions or [tool.pymz_tool].python-versions"
            )
        manifest_path = build_extension(
            args.module or cfg.module,
            version=args.version or cfg.version,
            zig_target=args.zig_target or cfg.zig_target,
            python_versions=python_versions,
            pymz_runtime=args.pymz_runtime or cfg.runtime,
            release=args.release,
            extension_dir=args.extension_dir or cfg.extension_dir,
        )
        print(manifest_path)
        if args.wheel_out:
            for wheel_path in make_wheels(
                manifest_path,
                out_dir=args.wheel_out,
                metadata=cfg.to_metadata(),
            ):
                print(wheel_path)
    elif command == "init":
        target_dir = args.dir or args.name
        project_path = init_project(
            target_dir,
            project_name=args.name,
            module_name=args.module,
            description=args.description,
            runtime=args.runtime,
            force=args.force,
        )
        print(project_path)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
