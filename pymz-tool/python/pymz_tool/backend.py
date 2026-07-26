"""PEP 517/660 build backend for pymz Zig-backed Python extensions.

Invokes ``zig build`` to compile extension modules, then packages artifacts
into wheels using the standard library ``zipfile`` module.  Both ``build_wheel``
and ``build_editable`` delegate the zig-build + collect + manifest work to the
shared ``matrix.build_one_cell`` helpers so the three build paths (CLI, PEP 517,
setuptools) do not diverge.
"""
from __future__ import absolute_import

import shutil
import tarfile
import tempfile
from pathlib import Path

from ._compat import Any, DEFAULT_RUNTIME, default_zig_target  # noqa: F401
from .config import load_config, get_project_info, python_version_string
from .errors import PymzBuildError
from .manifest import collect_artifacts, write_manifest
from .matrix import (
    build_one_cell,
    _resolve_modules,
    _run_steps_for_modules,
    _make_manifest,
)

__all__ = [
    "build_wheel",
    "build_editable",
    "build_sdist",
    "get_requires_for_build_wheel",
    "get_requires_for_build_editable",
    "get_requires_for_build_sdist",
]


def build_wheel(
    wheel_directory,
    config_settings=None,
    metadata_directory=None,
):
    # type: (str, dict[str, Any] | None, str | None) -> str
    """PEP 517 wheel build: compile extension, package into wheel."""
    root = Path.cwd()
    config = load_config(root)
    project = get_project_info(root)

    cs = config_settings or {}
    step = cs.get("zig-target", default_zig_target(config))
    runtime = cs.get("runtime", config.get("runtime", DEFAULT_RUNTIME))
    release = cs.get("release", True)

    out_dir = Path(wheel_directory)
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="pymz-build-") as tmp:
        prefix = Path(tmp)
        return build_one_cell(
            root, step, prefix, out_dir, project,
            runtime=runtime,
            python_version=python_version_string(),
            release=release,
        )


def build_sdist(
    sdist_directory,
    config_settings=None,
):
    # type: (str, dict[str, Any] | None) -> str
    """PEP 517 sdist build: create a source tarball."""
    root = Path.cwd()
    project = get_project_info(root)
    distribution = project["distribution"]
    version = project["version"]

    name = "%s-%s" % (distribution, version)
    sdist = Path(sdist_directory) / (name + ".tar.gz")

    exclude = {
        "zig-out", "zig-cache", ".zig-cache", ".git",
        "__pycache__", ".pytest_cache", ".mypy_cache",
        "dist", "build", ".DS_Store",
    }

    with tarfile.open(str(sdist), "w:gz") as tar:
        for path in root.iterdir():
            if path.name in exclude:
                continue
            arcname = "%s/%s" % (name, path.name)
            tar.add(str(path), arcname=arcname)

    return sdist.name


def build_editable(
    wheel_directory,
    config_settings=None,
    metadata_directory=None,
):
    # type: (str, dict[str, Any] | None, str | None) -> str
    """PEP 660 editable install: build extension in-place, produce .pth wheel.

    The extension is compiled into the project's ``zig-out/lib`` and copied
    into the package source tree so an editable install picks it up directly.
    The wheel itself carries only a ``.pth`` entry pointing at the package
    root.  Zig-build, artifact collection, and manifest construction reuse the
    shared ``matrix`` helpers so this path cannot drift from ``build_wheel``.
    """
    from .wheel import build_editable_wheel

    root = Path.cwd()
    config = load_config(root)
    project = get_project_info(root)

    cs = config_settings or {}
    step = cs.get("zig-target", default_zig_target(config))
    runtime = cs.get("runtime", config.get("runtime", DEFAULT_RUNTIME))

    modules = _resolve_modules(project, step)
    prefix = root / "zig-out"
    _run_steps_for_modules(
        root, step, prefix, modules,
        runtime=runtime,
        python_version=python_version_string(),
        release=False,
    )

    lib_dir = prefix / "lib"
    module_names = [m["name"] for m in modules if m.get("name")]
    artifacts = collect_artifacts(lib_dir, module_names)
    if not any(a["kind"] == "extension" for a in artifacts):
        raise PymzBuildError("no extension artifact found in %s" % lib_dir)

    manifest = _make_manifest(
        project, modules, runtime, artifacts,
        [python_version_string()], None, step,
    )
    write_manifest(manifest, lib_dir)

    # Copy artifacts into the package source directory for in-place use.
    if project["package_dir"]:
        package_dest = root / project["package_dir"] / project["distribution"]
    else:
        package_dest = root
    package_dest.mkdir(parents=True, exist_ok=True)
    for artifact in artifacts:
        src = lib_dir / artifact["filename"]
        shutil.copy2(str(src), str(package_dest / artifact["filename"]))
    write_manifest(manifest, package_dest)

    package_root = root / project["package_dir"] if project["package_dir"] else root
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
    """Write a PEP 517 metadata directory (``*.dist-info``) and return its name.

    Used by both ``prepare_metadata_for_build_wheel`` and
    ``prepare_metadata_for_build_editable``. The metadata is identical for both
    because the distribution name/version come from the project config, not
    from the wheel layout. Writing metadata up-front lets pip resolve the
    distribution name without running the (slow) zig build.
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


def prepare_metadata_for_build_sdist(metadata_directory, config_settings=None):
    # type: (str, dict[str, Any] | None) -> str
    return _write_metadata(metadata_directory)
