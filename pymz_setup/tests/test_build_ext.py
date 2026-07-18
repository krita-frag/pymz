# -*- coding: utf-8 -*-
"""Unit tests for :mod:`pymz_setup.build_ext`.

These tests cover the pure-Python helpers in :mod:`pymz_setup.build_ext`
without invoking ``zig`` or the CPython C API. They are written to run on
both Python 2.7 and Python 3.8+ so that the same suite executes inside the
``py27-smoke`` CI job and the main matrix.
"""
from __future__ import print_function, unicode_literals

import os
import sys
import tempfile
import unittest

from pymz_setup.build_ext import (
    ZigPackageSpec,
    ensure_dir,
    find_generated_extension,
    find_generated_stub,
    python_version_string,
)


class PythonVersionStringTests(unittest.TestCase):
    def test_returns_dotted_major_minor(self):
        result = python_version_string()
        expected = "%d.%d" % (sys.version_info[0], sys.version_info[1])
        self.assertEqual(result, expected)

    def test_starts_with_major_version(self):
        major = sys.version_info[0]
        self.assertTrue(
            python_version_string().startswith("%d." % major),
            "version string should start with the major version",
        )

    def test_contains_minor_version(self):
        minor = sys.version_info[1]
        self.assertIn(".%d" % minor, python_version_string())


class EnsureDirTests(unittest.TestCase):
    def test_creates_nested_directories(self):
        tmp = tempfile.mkdtemp()
        target = os.path.join(tmp, "a", "b", "c")
        try:
            ensure_dir(target)
            self.assertTrue(os.path.isdir(target))
        finally:
            # Best-effort cleanup; ignore errors.
            try:
                os.removedirs(target)
            except OSError:
                pass

    def test_idempotent_on_existing_directory(self):
        tmp = tempfile.mkdtemp()
        try:
            ensure_dir(tmp)
            self.assertTrue(os.path.isdir(tmp))
        finally:
            try:
                os.rmdir(tmp)
            except OSError:
                pass


class ZigPackageSpecTests(unittest.TestCase):
    def _make_spec(self, **kwargs):
        defaults = dict(
            root="/tmp/project",
            package_name="jsonz",
            extension_name="_jsonz",
        )
        defaults.update(kwargs)
        return ZigPackageSpec(**defaults)

    def test_root_is_absolute(self):
        spec = self._make_spec(root="relative/path")
        self.assertTrue(os.path.isabs(spec.root), spec.root)

    def test_python_package_dir_joins_source_and_package(self):
        spec = self._make_spec(root="/tmp/project")
        expected = os.path.join(
            os.path.abspath("/tmp/project"), "python", "jsonz"
        )
        self.assertEqual(spec.python_package_dir, expected)

    def test_zig_lib_dir_under_root(self):
        spec = self._make_spec(root="/tmp/project")
        self.assertEqual(
            spec.zig_lib_dir,
            os.path.join(os.path.abspath("/tmp/project"), "zig-out", "lib"),
        )

    def test_extension_import_name_is_dotted(self):
        spec = self._make_spec()
        self.assertEqual(spec.extension_import_name, "jsonz._jsonz")

    def test_stub_filename_uses_extension_name(self):
        spec = self._make_spec()
        self.assertEqual(spec.stub_filename, "_jsonz.pyi")

    def test_zig_executable_defaults_to_env_var(self):
        old = os.environ.get("PYMZ_ZIG")
        os.environ["PYMZ_ZIG"] = "/custom/zig"
        try:
            spec = self._make_spec()
            self.assertEqual(spec.zig_executable, "/custom/zig")
        finally:
            if old is None:
                del os.environ["PYMZ_ZIG"]
            else:
                os.environ["PYMZ_ZIG"] = old

    def test_zig_executable_explicit_overrides_env(self):
        old = os.environ.get("PYMZ_ZIG")
        os.environ["PYMZ_ZIG"] = "/env/zig"
        try:
            spec = self._make_spec(zig_executable="/explicit/zig")
            self.assertEqual(spec.zig_executable, "/explicit/zig")
        finally:
            if old is None:
                del os.environ["PYMZ_ZIG"]
            else:
                os.environ["PYMZ_ZIG"] = old

    def test_zig_build_command_includes_version_flag(self):
        spec = self._make_spec()
        cmd = spec.zig_build_command("3.12")
        self.assertEqual(cmd[0], spec.zig_executable)
        self.assertEqual(cmd[1], "build")
        self.assertEqual(cmd[2], spec.zig_step)
        self.assertEqual(cmd[3], "-Dpython-version=3.12")

    def test_custom_zig_step_used_in_command(self):
        spec = self._make_spec(zig_step="custom_step")
        cmd = spec.zig_build_command("3.11")
        self.assertIn("custom_step", cmd)


class FindGeneratedArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.lib_dir = os.path.join(self.tmp, "zig-out", "lib")
        os.makedirs(self.lib_dir)

    def tearDown(self):
        # Best-effort cleanup.
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_find_generated_extension_picks_shared_lib(self):
        ext_name = "_jsonz"
        # Create a stub file (should be skipped) and a shared lib.
        open(os.path.join(self.lib_dir, "%s.pyi" % ext_name), "w").close()
        # Use a fake suffix matching the glob pattern.
        shared_path = os.path.join(self.lib_dir, "%s.cpython-312-darwin.so" % ext_name)
        open(shared_path, "w").close()
        result = find_generated_extension(self.lib_dir, ext_name)
        self.assertEqual(os.path.basename(result), os.path.basename(shared_path))

    def test_find_generated_extension_raises_when_missing(self):
        with self.assertRaises(RuntimeError):
            find_generated_extension(self.lib_dir, "_missing")

    def test_find_generated_stub_returns_path(self):
        ext_name = "_jsonz"
        stub_path = os.path.join(self.lib_dir, "%s.pyi" % ext_name)
        open(stub_path, "w").close()
        result = find_generated_stub(self.lib_dir, ext_name)
        self.assertEqual(result, stub_path)

    def test_find_generated_stub_raises_when_missing(self):
        with self.assertRaises(RuntimeError):
            find_generated_stub(self.lib_dir, "_missing")


if __name__ == "__main__":
    unittest.main()
