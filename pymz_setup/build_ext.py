from __future__ import print_function

import glob
import os
import shutil
import subprocess
import sys

from setuptools.command.build_ext import build_ext as build_ext_base


def python_version_string():
    return "%d.%d" % sys.version_info[:2]


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


class ZigPackageSpec(object):
    def __init__(
        self,
        root,
        package_name,
        extension_name,
        zig_step="example",
        python_source_dir="python",
        zig_executable=None,
    ):
        self.root = os.path.abspath(root)
        self.package_name = package_name
        self.extension_name = extension_name
        self.zig_step = zig_step
        self.python_source_dir = python_source_dir
        self.zig_executable = zig_executable or os.environ.get("PYMZ_ZIG", "zig")

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
    def stub_filename(self):
        return "%s.pyi" % self.extension_name

    def zig_build_command(self, python_version):
        return [
            self.zig_executable,
            "build",
            self.zig_step,
            "-Dpython-version=%s" % python_version,
        ]


def find_generated_extension(zig_lib_dir, extension_name):
    pattern = os.path.join(zig_lib_dir, "%s*" % extension_name)
    for path in sorted(glob.glob(pattern)):
        if path.endswith(".pyi") or os.path.isdir(path):
            continue
        return path
    raise RuntimeError("built extension not found")


def find_generated_stub(zig_lib_dir, extension_name):
    stub_source = os.path.join(zig_lib_dir, "%s.pyi" % extension_name)
    if not os.path.exists(stub_source):
        raise RuntimeError("generated stub not found")
    return stub_source


def sync_generated_artifacts(spec, build_lib, copy_to_source):
    ext_source = find_generated_extension(spec.zig_lib_dir, spec.extension_name)
    stub_source = find_generated_stub(spec.zig_lib_dir, spec.extension_name)

    target_dirs = [os.path.join(build_lib, spec.package_name)]
    if copy_to_source:
        target_dirs.append(spec.python_package_dir)

    for target_dir in target_dirs:
        ensure_dir(target_dir)
        shutil.copy2(ext_source, os.path.join(target_dir, os.path.basename(ext_source)))
        shutil.copy2(stub_source, os.path.join(target_dir, spec.stub_filename))


def build_ext_class(spec):
    class ZigBuildExt(build_ext_base):
        def run(self):
            old_cwd = os.getcwd()
            try:
                os.chdir(spec.root)
                subprocess.check_call(spec.zig_build_command(python_version_string()))
                sync_generated_artifacts(spec, self.build_lib, self.inplace)
                self.run_command("build_py")
            finally:
                os.chdir(old_cwd)

    return ZigBuildExt
