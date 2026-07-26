"""Setuptools integration for ``setup.py``-based builds (Python 2.7 and 3).

This module provides the same build capabilities as the PEP 517 backend
(``pymz_tool.backend``) but through the traditional ``setup.py`` interface.
Both paths produce wheels with ``pymz-manifest.json`` so the runtime loader
works identically.

Configuration split:
- ``pymz.json``: extension module name, zig step, build matrix.
- ``setup.py`` / ``pyproject.toml`` ``[project]``: package name, version, package_dir.

Usage in a project ``setup.py``::

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

After ``python setup.py build_ext``, the manifest is written alongside the
extension in ``build_lib``.  ``python setup.py bdist_wheel`` then produces a
wheel containing the extension, stub, manifest, and Python sources.
"""

from __future__ import print_function

import glob
import os
import shutil
import subprocess

from setuptools.command.build_ext import build_ext as build_ext_base

from ._compat import DEFAULT_RUNTIME, DEFAULT_ZIG_TARGET
from .config import python_version_string
from .manifest import build_manifest, write_manifest, collect_artifacts


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


class ZigPackageSpec(object):
    """Project configuration for a Zig-backed setuptools extension.

    Attributes:
        root: Project root directory (absolute path).
        package_name: Python package name (e.g. "mypkg").
        extension_name: First extension module name (backward compat).
        modules: List of ``{"name": ..., "zig_target": ...}`` dicts.
        version: Project version string.
        runtime: Target runtime ("cpython2", "cpython3", "cpython3-limited").
        zig_step: Default zig build step name.
        python_source_dir: Directory containing Python package sources.
        zig_executable: Path to zig executable (default from PYMZ_ZIG env or "zig").
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
        # Multi-module support: explicit list or single-module fallback.
        if modules:
            self.modules = modules
        else:
            self.modules = [{"name": extension_name, "zig_target": zig_step}]

    @classmethod
    def from_config(cls, root, distribution=None, version=None, package_dir=None):
        """Create a spec from ``pymz.json`` + packaging metadata.

        ``pymz.json`` provides the extension module names, zig steps, and matrix.
        Packaging metadata (distribution, version, package_dir) comes from
        *pyproject.toml* ``[project]`` on Python 3, or from the explicit
        keyword arguments (typically passed by ``setup.py`` on Python 2).
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

    # Alias for backward compatibility.
    from_pyproject = from_config

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
        """List of extension module names."""
        return [m["name"] for m in self.modules]

    def zig_build_commands(self, python_version):
        """Return a list of ``zig build`` commands, one per unique step.

        The runtime flag is omitted when it is the default (``"auto"``) so zig
        build resolves the runtime from the detected interpreter, matching
        ``matrix.run_zig_build``.
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
        """Return a single ``zig build`` command (backward compat, first step)."""
        cmds = self.zig_build_commands(python_version)
        return cmds[0] if cmds else []


def find_generated_extension(zig_lib_dir, extension_name):
    """Locate the compiled extension file in *zig_lib_dir*."""
    pattern = os.path.join(zig_lib_dir, "%s*" % extension_name)
    for path in sorted(glob.glob(pattern)):
        if path.endswith(".pyi") or os.path.isdir(path):
            continue
        return path
    raise RuntimeError("built extension not found")


def find_generated_stub(zig_lib_dir, extension_name):
    """Locate the generated ``.pyi`` stub in *zig_lib_dir*."""
    stub_source = os.path.join(zig_lib_dir, "%s.pyi" % extension_name)
    if not os.path.exists(stub_source):
        raise RuntimeError("generated stub not found")
    return stub_source


def sync_generated_artifacts(spec, build_lib, copy_to_source):
    """Copy built extensions and stubs into setuptools' build_lib and optionally the source tree."""
    target_dirs = [os.path.join(build_lib, spec.package_name)]
    if copy_to_source:
        target_dirs.append(spec.python_package_dir)

    for target_dir in target_dirs:
        ensure_dir(target_dir)
        for mod_name in spec.extension_names:
            ext_source = find_generated_extension(spec.zig_lib_dir, mod_name)
            stub_source = find_generated_stub(spec.zig_lib_dir, mod_name)
            shutil.copy2(ext_source, os.path.join(target_dir, os.path.basename(ext_source)))
            shutil.copy2(stub_source, os.path.join(target_dir, "%s.pyi" % mod_name))


def _write_manifest(spec, build_lib):
    """Write ``pymz-manifest.json`` next to the extensions in *build_lib*.

    This enables the runtime loader (``pymz_tool.loader``) to locate the
    correct extension artifacts at import time.
    """
    artifacts = collect_artifacts(spec.zig_lib_dir, spec.extension_names)
    if not artifacts:
        return
    manifest = build_manifest(
        modules=spec.extension_names,
        version=spec.version,
        runtime=spec.runtime,
        distribution=spec.package_name,
        package_dir=spec.python_source_dir,
        artifacts=artifacts,
        python_versions=[python_version_string()],
        zig_target=spec.zig_step,
    )
    pkg_dir = os.path.join(build_lib, spec.package_name)
    write_manifest(manifest, pkg_dir)


def build_ext_class(spec):
    """Create a setuptools ``build_ext`` command class that runs ``zig build``.

    After building, extensions, stubs, and ``pymz-manifest.json`` are copied
    into ``build_lib`` so that ``bdist_wheel`` produces a complete wheel.
    Supports multi-module specs (runs each unique zig step once).
    """
    class ZigBuildExt(build_ext_base):
        def run(self):
            old_cwd = os.getcwd()
            try:
                os.chdir(spec.root)
                for cmd in spec.zig_build_commands(python_version_string()):
                    subprocess.check_call(cmd)
                sync_generated_artifacts(spec, self.build_lib, self.inplace)
                _write_manifest(spec, self.build_lib)
                self.run_command("build_py")
            finally:
                os.chdir(old_cwd)

    return ZigBuildExt


def build_wheel_from_spec(spec, wheel_dir):
    """Build a wheel directly from a ``ZigPackageSpec`` without setuptools' command system.

    This is an alternative to ``python setup.py bdist_wheel`` for environments
    where the ``wheel`` package is not installed.  It reuses the same wheel
    packaging logic (``pymz_tool.wheel.build_wheel``) as the PEP 517 backend so
    both paths produce byte-identical wheel layouts.

    The ``_from_spec`` suffix distinguishes this helper (which takes a
    ``ZigPackageSpec``) from the PEP 517 ``build_wheel`` hook (which takes the
    standard ``(wheel_directory, config_settings, metadata_directory)`` tuple).
    """
    from .wheel import build_wheel as _build_wheel

    ensure_dir(wheel_dir)

    # Run zig build if not already built.
    lib_dir = spec.zig_lib_dir
    if not os.path.isdir(lib_dir):
        old_cwd = os.getcwd()
        try:
            os.chdir(spec.root)
            for cmd in spec.zig_build_commands(python_version_string()):
                subprocess.check_call(cmd)
        finally:
            os.chdir(old_cwd)

    artifacts = collect_artifacts(lib_dir, spec.extension_names)
    if not any(a["kind"] == "extension" for a in artifacts):
        raise RuntimeError("no extension artifact found in %s" % lib_dir)

    manifest = build_manifest(
        modules=spec.extension_names,
        version=spec.version,
        runtime=spec.runtime,
        distribution=spec.package_name,
        package_dir=spec.python_source_dir,
        artifacts=artifacts,
        python_versions=[python_version_string()],
        zig_target=spec.zig_step,
    )
    write_manifest(manifest, lib_dir)

    return _build_wheel(wheel_dir, manifest, lib_dir, spec.root)
