"""PEP 517 build backend for pymz Zig-backed Python extensions.

This backend shells out to the ``pymz-tool`` CLI to compile extension wheels.
It intentionally supports one backend source per build; multi-backend builds
belong to the CLI matrix mode, not to PEP 517's single-wheel contract.
The tool must be available on ``$PATH`` or pointed to with ``PYMZ_TOOL``.
When running from the pymz source tree, the backend can build ``pymz-tool``
automatically.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib


__all__ = [
    "build_wheel",
    "build_editable",
    "build_sdist",
    "get_requires_for_build_wheel",
    "get_requires_for_build_editable",
    "get_requires_for_build_sdist",
]


def _load_pyproject(root: Path) -> dict[str, Any]:
    with open(root / "pyproject.toml", "rb") as f:
        return tomllib.load(f)


def _read_config(root: Path) -> dict[str, Any]:
    data = _load_pyproject(root)
    return data.get("tool", {}).get("pymz_backend", {})


def _snake_to_identifier(name: str) -> str:
    """Convert a distribution name to a likely extension module name."""
    return re.sub(r"[-_.]+", "_", name)


def _locate_tool() -> str:
    explicit = os.environ.get("PYMZ_TOOL")
    if explicit:
        return explicit

    from_path = shutil.which("pymz-tool")
    if from_path:
        return from_path

    # Development layout: this file lives under
    # pymz_backend/pymz_backend/__init__.py
    repo_tool = Path(__file__).resolve().parents[2] / "pymz-tool"
    binary = repo_tool / "zig-out" / "bin" / "pymz-tool"
    if binary.exists():
        return str(binary)

    # Try to build the tool from the sibling source tree.
    if repo_tool.exists():
        subprocess.run(["zig", "build"], cwd=str(repo_tool), check=True)
        if binary.exists():
            return str(binary)

    raise RuntimeError(
        "pymz-tool not found. Set PYMZ_TOOL or install pymz-tool on $PATH."
    )


def _split_semicolon_separated(raw: str) -> list[str]:
    return [part.strip() for part in raw.split(";") if part.strip()]


def _single_backend_source(raw: str | None) -> str | None:
    if raw is None:
        return None

    sources = _split_semicolon_separated(raw)
    if len(sources) != 1:
        raise RuntimeError(
            "PEP 517 backend only accepts one backend source; "
            "use pymz-tool build for multi-backend builds."
        )
    return sources[0]


def _run_tool(args: list[str], cwd: Path) -> None:
    tool = _locate_tool()
    cmd = [tool, *args]
    subprocess.run(cmd, cwd=str(cwd), check=True)


def _build_options_from_config(
    root: Path,
    config: dict[str, Any],
    config_settings: dict[str, Any] | None,
    command: str = "build",
) -> list[str]:
    project = _load_pyproject(root)
    project_name = project.get("project", {}).get("name", "extension")
    project_version = project.get("project", {}).get("version", "0.0.0")

    def pick(*keys: str) -> Any:
        for key in keys:
            if key in config:
                return config[key]
            if config_settings and key in config_settings:
                return config_settings[key]
        return None

    module = pick("module") or _snake_to_identifier(
        project.get("project", {}).get("module_name", project_name)
    )
    version = pick("version") or project_version
    distribution = pick("distribution") or project_name
    package_dir = pick("package-dir")
    runtime = pick("runtime")
    backend_source = pick("backend-source")

    args = [
        command,
        "--module",
        str(module),
        "--version",
        str(version),
        "--distribution",
        str(distribution),
    ]
    if package_dir:
        args.extend(["--package-dir", str(package_dir)])
    if runtime:
        args.extend(["--pymz-runtime", str(runtime)])
    backend_source = _single_backend_source(backend_source)
    if backend_source:
        args.extend(["--pymz-backend-source", str(backend_source)])

    if command == "develop":
        return args

    zig_target = pick("zig-target") or "example"
    platform_tag = pick("platform-tag")
    release = pick("release")
    if release is None:
        release = True

    args.extend(["--zig-target", str(zig_target)])
    if release:
        args.append("--release")
    if platform_tag:
        args.extend(["--platform-tag", str(platform_tag)])

    return args


def build_wheel(
    wheel_directory: str,
    config_settings: dict[str, Any] | None = None,
    metadata_directory: str | None = None,
) -> str:
    root = Path.cwd()
    config = _read_config(root)
    args = _build_options_from_config(root, config, config_settings)

    with tempfile.TemporaryDirectory(prefix="pymz-backend-") as tmp:
        args.extend(["-o", tmp])
        _run_tool(args, root)
        out = Path(tmp)
        wheels = list(out.glob("*.whl"))
        if not wheels:
            raise RuntimeError("pymz-tool did not produce a wheel")
        if len(wheels) > 1:
            raise RuntimeError(
                f"pymz-tool produced multiple wheels: {[w.name for w in wheels]}"
            )
        wheel = wheels[0]
        dest = Path(wheel_directory) / wheel.name
        shutil.copy2(str(wheel), str(dest))
        return dest.name


def build_sdist(
    sdist_directory: str,
    config_settings: dict[str, Any] | None = None,
) -> str:
    root = Path.cwd()
    config = _read_config(root)
    project = _load_pyproject(root)
    distribution = (
        config.get("distribution")
        or project.get("project", {}).get("name")
        or "extension"
    )
    version = (
        config.get("version") or project.get("project", {}).get("version") or "0.0.0"
    )

    name = f"{distribution}-{version}"
    sdist = Path(sdist_directory) / f"{name}.tar.gz"

    exclude = {
        "zig-out",
        "zig-cache",
        ".zig-cache",
        ".git",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        "dist",
        "build",
        ".DS_Store",
    }

    with tarfile.open(str(sdist), "w:gz") as tar:
        for path in root.iterdir():
            if path.name in exclude:
                continue
            arcname = f"{name}/{path.name}"
            tar.add(str(path), arcname=arcname)

    return sdist.name


def build_editable(
    wheel_directory: str,
    config_settings: dict[str, Any] | None = None,
    metadata_directory: str | None = None,
) -> str:
    """PEP 660 editable install for packages with compiled extensions.

    Builds the extension in-place with ``pymz-tool develop`` and produces a
    wheel containing only a ``.pth`` file pointing to the source package tree.
    """
    root = Path.cwd()
    config = _read_config(root)
    args = _build_options_from_config(root, config, config_settings, command="develop")
    _run_tool(args, root)

    project = _load_pyproject(root)
    distribution = (
        config.get("distribution")
        or project.get("project", {}).get("name")
        or "extension"
    )
    version = (
        config.get("version") or project.get("project", {}).get("version") or "0.0.0"
    )
    package_dir = config.get("package-dir")
    package_root = root / package_dir if package_dir else root

    return _make_editable_wheel(
        root, distribution, version, package_root, Path(wheel_directory)
    )


def _hash_and_size(data: bytes) -> tuple[str, int]:
    digest = hashlib.sha256(data).hexdigest()
    return f"sha256={digest}", len(data)


def _make_editable_wheel(
    root: Path,
    distribution: str,
    version: str,
    package_root: Path,
    wheel_directory: Path,
) -> str:
    wheel_name = f"{distribution}-{version}-py3-none-any.whl"
    wheel_path = wheel_directory / wheel_name

    dist_info = f"{distribution}-{version}.dist-info"

    pth_name = f"{distribution}.pth"
    pth_data = f"{package_root.resolve()}\n".encode()
    pth_hash, pth_size = _hash_and_size(pth_data)

    metadata_text = (
        f"Metadata-Version: 2.1\n"
        f"Name: {distribution}\n"
        f"Version: {version}\n"
    ).encode()
    metadata_hash, metadata_size = _hash_and_size(metadata_text)

    wheel_text = (
        b"Wheel-Version: 1.0\n"
        b"Generator: pymz-build-backend\n"
        b"Root-Is-Purelib: false\n"
        b"Tag: py3-none-any\n"
    )
    wheel_hash, wheel_size = _hash_and_size(wheel_text)

    record_lines: list[str] = [
        f"{pth_name},{pth_hash},{pth_size}",
        f"{dist_info}/METADATA,{metadata_hash},{metadata_size}",
        f"{dist_info}/WHEEL,{wheel_hash},{wheel_size}",
        f"{dist_info}/RECORD,,",
    ]
    record_data = "\n".join(record_lines).encode()

    with zipfile.ZipFile(str(wheel_path), "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(pth_name, pth_data)
        zf.writestr(f"{dist_info}/METADATA", metadata_text)
        zf.writestr(f"{dist_info}/WHEEL", wheel_text)
        zf.writestr(f"{dist_info}/RECORD", record_data)

    return wheel_path.name


def get_requires_for_build_wheel(
    config_settings: dict[str, Any] | None = None,
) -> list[str]:
    return []


def get_requires_for_build_editable(
    config_settings: dict[str, Any] | None = None,
) -> list[str]:
    return []


def get_requires_for_build_sdist(
    config_settings: dict[str, Any] | None = None,
) -> list[str]:
    return []
