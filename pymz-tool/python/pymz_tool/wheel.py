"""Wheel packaging for pymz extensions.

Builds PEP 427-compatible wheels using the standard library ``zipfile`` module.
"""
from __future__ import absolute_import

import hashlib
import json
import os
import sys
import sysconfig
import zipfile

from ._compat import Any  # noqa: F401

from .manifest import MANIFEST_FILENAME


def _hash_and_size(data):
    # type: (bytes) -> tuple
    digest = hashlib.sha256(data).hexdigest()
    return "sha256=" + digest, len(data)


def _normalize_platform_tag(tag):
    # type: (str) -> str
    return tag.replace("-", "_").replace(".", "_")


def _wheel_platform_tag(manifest):
    # type: (dict) -> str
    """Determine the platform tag for the wheel."""
    if manifest.get("platform_tag"):
        return _normalize_platform_tag(manifest["platform_tag"])
    try:
        from packaging.tags import sys_tags
        for tag in sys_tags():
            return _normalize_platform_tag(tag.platform)
    except ImportError:
        pass
    return _normalize_platform_tag(sysconfig.get_platform())


def _runtime_is_abi3(runtime):
    # type: (str) -> bool
    return runtime == "cpython3-limited"


def _extension_digits(module, filename):
    # type: (str, str) -> str | None
    """Extract the cpython-XY digits or 'abi3' from an extension filename."""
    prefix = module + ".cpython-"
    if filename.startswith(prefix):
        rest = filename[len(prefix):]
        dash = rest.find("-")
        if dash > 0:
            return rest[:dash]
    if filename.startswith(module + ".abi3."):
        return "abi3"
    return None


def _py_tag(runtime, ext_digits, python_version):
    # type: (str, str | None, str | None) -> str
    if _runtime_is_abi3(runtime):
        return "cp310"
    if ext_digits and ext_digits != "abi3":
        return "cp" + ext_digits
    if python_version:
        return "cp" + python_version.replace(".", "")
    return "cp%d%d" % (sys.version_info[0], sys.version_info[1])


def _abi_tag(runtime, ext_digits):
    # type: (str, str | None) -> str
    if _runtime_is_abi3(runtime):
        return "abi3"
    if ext_digits and ext_digits != "abi3":
        return "cp" + ext_digits
    return "cp%d%d" % (sys.version_info[0], sys.version_info[1])


def _read_bytes(path):
    # type: (str) -> bytes
    with open(path, "rb") as f:
        return f.read()


def _dist_info_name(distribution, version):
    # type: (str, str) -> str
    return "%s-%s.dist-info" % (distribution, version)


def _record_line(arcname, data):
    # type: (str, bytes) -> str
    h, s = _hash_and_size(data)
    return "%s,%s,%d" % (arcname, h, s)


def build_editable_wheel(wheel_dir, distribution, version, package_root):
    # type: (Any, str, str, Any) -> str
    """Build a ``.pth``-based editable wheel that adds *package_root* to
    ``sys.path``.

    The wheel carries no extension bytes; the extension is built in-place into
    the package source tree by the caller, so the editable wheel only needs a
    ``.pth`` entry plus the standard ``dist-info`` members. Centralising this
    here keeps all wheel-layout logic in one module.
    """
    from pathlib import Path
    wheel_dir = Path(str(wheel_dir))
    wheel_dir.mkdir(parents=True, exist_ok=True)
    wheel_name = "%s-%s-py3-none-any.whl" % (distribution, version)
    wheel_path = wheel_dir / wheel_name
    dist_info = _dist_info_name(distribution, version)

    pth_name = "%s.pth" % distribution
    pth_data = (str(Path(str(package_root)).resolve()) + "\n").encode()

    metadata_data = (
        "Metadata-Version: 2.1\n"
        "Name: %s\n"
        "Version: %s\n"
    ) % (distribution, version)
    metadata_data = metadata_data.encode()

    wheel_text = (
        b"Wheel-Version: 1.0\n"
        b"Generator: pymz-build-backend\n"
        b"Root-Is-Purelib: false\n"
        b"Tag: py3-none-any\n"
    )

    record_lines = [
        _record_line(pth_name, pth_data),
        _record_line(dist_info + "/METADATA", metadata_data),
        _record_line(dist_info + "/WHEEL", wheel_text),
        "%s/RECORD,," % dist_info,
    ]
    record_data = ("\n".join(record_lines) + "\n").encode()

    with zipfile.ZipFile(str(wheel_path), "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(pth_name, pth_data)
        zf.writestr(dist_info + "/METADATA", metadata_data)
        zf.writestr(dist_info + "/WHEEL", wheel_text)
        zf.writestr(dist_info + "/RECORD", record_data)

    return wheel_name


def build_wheel(wheel_dir, manifest, lib_dir, root):
    # type: (Any, dict, Any, Any) -> str
    """Build a wheel from *manifest* and artifacts in *lib_dir*.

    Returns the wheel filename.
    """
    wheel_dir = str(wheel_dir)
    lib_dir = str(lib_dir)
    root = str(root)

    distribution = manifest["distribution"]
    version = manifest["version"]
    module = manifest.get("module") or (manifest.get("modules") or [""])[0]
    runtime = manifest.get("runtime", "cpython3")
    package_dir = manifest.get("package_dir", "")
    python_versions = manifest.get("python_versions", [])
    python_version = python_versions[0] if python_versions else None

    extensions = [a for a in manifest["artifacts"] if a["kind"] == "extension"]
    if not extensions:
        raise RuntimeError("no extension artifact in manifest")

    # Use the first extension's filename to determine ABI tags.
    ext_filename = extensions[0]["filename"]
    ext_digits = _extension_digits(module, ext_filename)

    py_tag = _py_tag(runtime, ext_digits, python_version)
    abi_tag = _abi_tag(runtime, ext_digits)
    platform_tag = _wheel_platform_tag(manifest)

    wheel_name = "%s-%s-%s-%s-%s.whl" % (distribution, version, py_tag, abi_tag, platform_tag)
    wheel_path = os.path.join(wheel_dir, wheel_name)
    dist_info = _dist_info_name(distribution, version)

    archive_prefix = (distribution + "/") if package_dir else ""
    records = []  # type: list

    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # Extension artifacts and stubs.
        for artifact in manifest["artifacts"]:
            src = os.path.join(lib_dir, artifact["filename"])
            if not os.path.isfile(src):
                continue
            data = _read_bytes(src)
            arcname = archive_prefix + artifact["filename"]
            zf.writestr(arcname, data)
            records.append(_record_line(arcname, data))

        # Python source files from package_dir.
        if package_dir:
            pkg_root = os.path.join(root, package_dir, distribution)
            if os.path.isdir(pkg_root):
                pkg_base = os.path.join(root, package_dir)
                for dirpath, dirnames, filenames in os.walk(pkg_root):
                    dirnames.sort()
                    for fname in sorted(filenames):
                        full = os.path.join(dirpath, fname)
                        if fname == MANIFEST_FILENAME:
                            continue
                        rel = os.path.relpath(full, pkg_base).replace(os.sep, "/")
                        if any(rel.endswith(a["filename"]) for a in manifest["artifacts"]):
                            continue
                        data = _read_bytes(full)
                        zf.writestr(rel, data)
                        records.append(_record_line(rel, data))

        # Runtime manifest (fixed archive name, beside the extension).
        manifest_data = json.dumps(manifest, indent=2).encode()
        manifest_arcname = archive_prefix + MANIFEST_FILENAME
        zf.writestr(manifest_arcname, manifest_data)
        records.append(_record_line(manifest_arcname, manifest_data))

        # METADATA
        metadata_lines = [
            "Metadata-Version: 2.1",
            "Name: %s" % distribution,
            "Version: %s" % version,
        ]
        if manifest.get("summary"):
            metadata_lines.append("Summary: %s" % manifest["summary"])
        if runtime == "cpython2":
            metadata_lines.append("Requires-Python: >=2.7,<3")
        elif _runtime_is_abi3(runtime):
            metadata_lines.append("Requires-Python: >=3.10")
        else:
            metadata_lines.append("Requires-Python: >=3")
        metadata_data = ("\n".join(metadata_lines) + "\n").encode()
        metadata_arcname = dist_info + "/METADATA"
        zf.writestr(metadata_arcname, metadata_data)
        records.append(_record_line(metadata_arcname, metadata_data))

        # WHEEL
        wheel_lines = [
            "Wheel-Version: 1.0",
            "Generator: pymz-tool",
            "Root-Is-Purelib: false",
            "Tag: %s-%s-%s" % (py_tag, abi_tag, platform_tag),
        ]
        wheel_data = ("\n".join(wheel_lines) + "\n").encode()
        wheel_arcname = dist_info + "/WHEEL"
        zf.writestr(wheel_arcname, wheel_data)
        records.append(_record_line(wheel_arcname, wheel_data))

        # RECORD (must be last; its own entry has no hash/size).
        record_arcname = dist_info + "/RECORD"
        record_lines = list(records) + ["%s,," % record_arcname]
        record_data = ("\n".join(record_lines) + "\n").encode()
        zf.writestr(record_arcname, record_data)

    return wheel_name
