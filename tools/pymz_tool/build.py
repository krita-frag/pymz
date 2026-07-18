"""Invoke ``zig build`` and emit a manifest for the produced artifacts."""

from __future__ import print_function

import os
import shutil
import subprocess

from .manifest import Artifact, BuildManifest, manifest_path_for


def _find_zig():
    """Return the zig executable, raising if it cannot be found."""
    zig = shutil.which("zig") if hasattr(shutil, "which") else None
    if zig is None:
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            candidate = os.path.join(directory, "zig")
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                zig = candidate
                break
    if zig is None:
        raise RuntimeError("zig executable not found on PATH")
    return zig


def _default_prefix_dir():
    return "zig-out"


def _default_lib_dir(prefix=None):
    return os.path.join(prefix or _default_prefix_dir(), "lib")


def _iter_files(lib_dir):
    for name in sorted(os.listdir(lib_dir)):
        path = os.path.join(lib_dir, name)
        if os.path.isfile(path):
            yield name, path


def _collect_artifacts(lib_dir, module_name):
    artifacts = []
    if not os.path.isdir(lib_dir):
        raise IOError("build output directory does not exist: %s" % lib_dir)

    manifest_name = os.path.basename(manifest_path_for(lib_dir, module_name))
    for name, path in _iter_files(lib_dir):
        del path
        if name == manifest_name:
            continue
        if name == "%s.pyi" % module_name:
            artifacts.append(Artifact.from_filename(name))
            continue
        if name.startswith("%s." % module_name):
            artifacts.append(Artifact.from_filename(name))
    if not any(artifact.kind == "extension" for artifact in artifacts):
        raise RuntimeError("no extension artifacts were produced for %s" % module_name)
    return artifacts


def _clear_previous_artifacts(lib_dir, module_name):
    if not os.path.isdir(lib_dir):
        return

    manifest_name = os.path.basename(manifest_path_for(lib_dir, module_name))
    for name, path in _iter_files(lib_dir):
        if name == manifest_name:
            os.unlink(path)
            continue
        if name == "%s.pyi" % module_name or name.startswith("%s." % module_name):
            os.unlink(path)


def _same_path(source, target):
    return os.path.abspath(source) == os.path.abspath(target)


def _sync_artifacts(source_lib_dir, target_lib_dir, artifacts):
    if _same_path(source_lib_dir, target_lib_dir):
        return

    if not os.path.isdir(target_lib_dir):
        os.makedirs(target_lib_dir)
    for artifact in artifacts:
        source_path = os.path.join(source_lib_dir, artifact.filename)
        target_path = os.path.join(target_lib_dir, artifact.filename)
        shutil.copy2(source_path, target_path)


def _split_versions(raw):
    if raw is None:
        return None
    versions = [part.strip() for part in raw.split(",")]
    versions = [version for version in versions if version]
    return versions or None


def _emit_manifest(
    module_name,
    version,
    zig_target,
    python_version,
    python_versions,
    pymz_runtime,
    release,
    lib_dir,
    artifacts,
):
    manifest = BuildManifest(
        module=module_name,
        version=version,
        zig_target=zig_target,
        runtime=pymz_runtime,
        release=release,
        lib_dir=os.path.abspath(lib_dir),
        python_version=python_version,
        python_versions=list(python_versions or []),
        artifacts=list(artifacts),
    )
    manifest_path = manifest_path_for(lib_dir, module_name)
    manifest.write(manifest_path)
    return manifest_path


def build_extension(
    module_name,
    version="0.0.0",
    zig_target="example",
    python_version=None,
    python_versions=None,
    pymz_runtime="auto",
    release=False,
    prefix=None,
    extension_dir=None,
    build_file=None,
):
    """Run Zig and return the generated manifest path."""
    if python_version and python_versions:
        raise ValueError("use either python_version or python_versions, not both")

    source_lib_dir = _default_lib_dir(prefix)
    target_lib_dir = extension_dir if extension_dir else source_lib_dir
    cmd = [_find_zig(), "build"]
    if build_file:
        cmd.extend(["--build-file", build_file])
    cmd.append(zig_target)
    if prefix:
        cmd.extend(["-p", prefix])
    cmd.append("-Dpymz-runtime=%s" % pymz_runtime)
    if python_version:
        cmd.append("-Dpython-version=%s" % python_version)
    if python_versions:
        cmd.append("-Dpython-versions=%s" % python_versions)
    if release:
        cmd.append("-Doptimize=ReleaseFast")

    _clear_previous_artifacts(source_lib_dir, module_name)
    subprocess.check_call(cmd, env=os.environ.copy())
    artifacts = _collect_artifacts(source_lib_dir, module_name)
    if not _same_path(target_lib_dir, source_lib_dir):
        _clear_previous_artifacts(target_lib_dir, module_name)
        _sync_artifacts(source_lib_dir, target_lib_dir, artifacts)
    return _emit_manifest(
        module_name,
        version,
        zig_target,
        python_version,
        _split_versions(python_versions),
        pymz_runtime,
        release,
        target_lib_dir,
        artifacts,
    )
