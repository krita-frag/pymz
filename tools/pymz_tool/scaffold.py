"""Minimal starter-project scaffolding for pymz_tool."""

from __future__ import print_function

import os
import re
import shutil
import json
import subprocess
from textwrap import dedent


def _sanitize_module_name(name):
    return name.replace("-", "_")


def _ensure_empty_or_force(target_dir, force):
    if not os.path.exists(target_dir) or force:
        return
    if os.listdir(target_dir):
        raise OSError("target directory is not empty: %s" % target_dir)


def _write_text(path, data):
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, "w") as f:
        f.write(data)


def _zig_string(value):
    return json.dumps(value)


def _pymz_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, os.pardir))


def _copy_package(source_dir, target_dir):
    if os.path.exists(target_dir):
        shutil.rmtree(target_dir)
    shutil.copytree(source_dir, target_dir)


def _copy_packages(target_path):
    root = _pymz_root()
    for package_name in ("pymz", "pymz-build"):
        source_dir = os.path.join(root, package_name)
        target_dir = os.path.join(target_path, package_name)
        if not os.path.isdir(source_dir):
            raise OSError(
                "cannot find %s Zig package next to the installed pymz_tool tool"
                % package_name
            )
        _copy_package(source_dir, target_dir)


def _setup_py_template(project_name, module_name, description):
    del project_name
    return dedent(
        """
        from __future__ import print_function

        import os
        import sys

        from setuptools import Extension, setup
        from setuptools.command.build_ext import build_ext as build_ext_base


        ROOT = os.path.abspath(os.path.dirname(__file__))
        TOOLS = os.path.join(ROOT, "tools")
        if os.path.isdir(TOOLS) and TOOLS not in sys.path:
            sys.path.insert(0, TOOLS)


        class build_ext(build_ext_base):
            def run(self):
                from pymz_tool.build import build_extension

                build_extension(
                    %r,
                    version="0.1.0",
                    zig_target="example",
                    pymz_runtime="auto",
                    release=False,
                    extension_dir=os.path.join(ROOT, "zig-out", "lib"),
                )


        setup(
            name=%r,
            version="0.1.0",
            description=%r,
            python_requires=">=2.7",
            ext_modules=[Extension(%r, sources=[])],
            cmdclass={"build_ext": build_ext},
        )
        """
        % (module_name, module_name, description, module_name)
    ).lstrip()


def _zig_module_template(project_name, module_name):
    return dedent(
        """
        const pymz = @import("pymz");


        fn addImpl(a: i64, b: i64) pymz.Result(i64) {
            return @intCast(a + b);
        }


        pub const pymz_module = pymz.module(%s, .{
            .__pymz_param_names__ = .{
                .add = "a, b",
            },
            .add = pymz.function(addImpl, "Add two integers."),
        }, null, %s);


        comptime {
            _ = pymz_module;
        }
        """
        % (_zig_string(module_name), _zig_string("%s: a pymz starter module." % project_name))
    ).lstrip()


def _build_zig_template(module_name):
    return dedent(
        """
        const std = @import("std");
        const pymz_build = @import("pymz-build");


        pub fn build(b: *std.Build) !void {
            try pymz_build.buildProject(b, .{
                .module_name = %s,
                .root_source_file = b.path(%s),
            });
        }
        """
        % (
            _zig_string(module_name),
            _zig_string("%s.zig" % module_name),
        )
    ).lstrip()


def _build_zig_zon_template(package_name):
    return dedent(
        """
        .{
            .name = .%s,
            .version = "0.0.0",
            .fingerprint = 0x0,
            .minimum_zig_version = "0.16.0-dev.2979+e93834410",
            .dependencies = .{
                .@"pymz-build" = .{ .path = "pymz-build" },
                .pymz = .{ .path = "pymz" },
            },
            .paths = .{
                "build.zig",
                "build.zig.zon",
                "README.md",
                "setup.py",
                "pymz",
                "pymz-build",
                "src",
                "tests",
            },
        }
        """
        % package_name
    ).lstrip()


def _update_build_zig_zon_fingerprint(target_path):
    result = subprocess.run(
        ["zig", "build", "--build-file", "build.zig", "--help"],
        cwd=target_path,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    match = re.search(
        r"use this value: (0x[0-9a-fA-F]+)",
        result.stdout or "",
    )
    if match is None:
        if result.returncode == 0:
            return
        raise OSError("cannot determine Zig package fingerprint:\n%s" % (result.stdout or ""))

    fingerprint = match.group(1)
    build_zig_zon = os.path.join(target_path, "build.zig.zon")
    with open(build_zig_zon, "r") as f:
        content = f.read()
    content = re.sub(
        r"\.fingerprint = 0x[0-9a-fA-F]+,",
        ".fingerprint = %s," % fingerprint,
        content,
        count=1,
    )
    _write_text(build_zig_zon, content)


def _readme_template(project_name, module_name):
    return dedent(
        """
        # %s

        ```bash
        python setup.py build_ext --inplace
        PYTHONPATH=zig-out/lib python -c "import %s; print(%s.add(2, 3))"
        ```
        """
        % (project_name, module_name, module_name)
    ).lstrip()


def _test_template(module_name):
    return dedent(
        """
        import %s


        def test_add():
            assert %s.add(2, 3) == 5
        """
        % (module_name, module_name)
    ).lstrip()


def init_project(
    target_dir,
    project_name,
    module_name=None,
    description=None,
    runtime="auto",
    force=False,
):
    """Create a minimal pymz project and return its path."""
    del runtime

    target_path = os.path.abspath(target_dir)
    module = _sanitize_module_name(module_name or project_name)
    desc = description or "%s: Zig-backed Python extension" % project_name

    _ensure_empty_or_force(target_path, force)
    if not os.path.isdir(target_path):
        os.makedirs(target_path)

    _write_text(os.path.join(target_path, "setup.py"), _setup_py_template(project_name, module, desc))
    _write_text(os.path.join(target_path, "build.zig"), _build_zig_template(module))
    _write_text(os.path.join(target_path, "build.zig.zon"), _build_zig_zon_template(module))
    _write_text(os.path.join(target_path, "%s.zig" % module), _zig_module_template(project_name, module))
    _write_text(os.path.join(target_path, "README.md"), _readme_template(project_name, module))
    _write_text(
        os.path.join(target_path, "tests", "test_%s.py" % module),
        _test_template(module),
    )
    _copy_packages(target_path)
    _update_build_zig_zon_fingerprint(target_path)

    return target_path
