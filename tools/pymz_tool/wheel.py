"""Generate a PEP 427 wheel from a manifest of built extension files."""

from __future__ import print_function

import base64
import hashlib
import os
import re
import sysconfig
import zipfile

try:
    import importlib.machinery as importlib_machinery
except ImportError:  # pragma: no cover - Python 2 fallback.
    importlib_machinery = None

from .manifest import BuildManifest


def _mkdir_p(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def _platform_tag():
    """Return the wheel platform tag for the current host platform."""
    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


def _default_extension_suffix():
    ext_suffix = sysconfig.get_config_var("EXT_SUFFIX")
    if isinstance(ext_suffix, str) and ext_suffix:
        return ext_suffix
    ext_suffix = sysconfig.get_config_var("SO")
    if isinstance(ext_suffix, str) and ext_suffix:
        return ext_suffix
    return ".so"


def _extension_pattern(module_name):
    """Return a pattern that matches current-platform extension filenames."""
    ext_suffix = _default_extension_suffix()
    digit_match = re.search(r"\d+", ext_suffix)
    if digit_match is None:
        return re.compile(r"^%s%s$" % (re.escape(module_name), re.escape(ext_suffix)))

    prefix = re.escape(ext_suffix[: digit_match.start()])
    suffix = re.escape(ext_suffix[digit_match.end() :])
    return re.compile(
        r"^%s%s(?P<python_version>\d+)%s$" % (
            re.escape(module_name),
            prefix,
            suffix,
        )
    )


def _extension_candidates(module_name):
    """Return the exact extension filenames for the current interpreter."""
    suffixes = []
    ext_suffix = _default_extension_suffix()
    if ext_suffix:
        suffixes.append(ext_suffix)
    if importlib_machinery is not None:
        for suffix in importlib_machinery.EXTENSION_SUFFIXES:
            if suffix not in suffixes:
                suffixes.append(suffix)
    return ["%s%s" % (module_name, suffix) for suffix in suffixes]


def _python_tag_from_digits(version_digits):
    return "cp%s" % version_digits


def _abi_tag_from_digits(version_digits):
    soabi = sysconfig.get_config_var("SOABI")
    if isinstance(soabi, str) and soabi:
        match = re.match(r"^cpython-(\d+)([a-z]*)", soabi)
        if match and match.group(1) == version_digits:
            return "cp%s%s" % (version_digits, match.group(2))
    return "cp%s" % version_digits


def _version_digits_from_manifest(manifest):
    raw_version = manifest.python_version
    if raw_version is None and len(manifest.python_versions) == 1:
        raw_version = manifest.python_versions[0]
    if raw_version is None:
        return None
    return raw_version.replace(".", "")


def _wheel_tags_for_extension(manifest, extension_name):
    """Return (python_tag, abi_tag, platform_tag) for one extension artifact."""
    pattern = _extension_pattern(manifest.module)
    match = pattern.match(extension_name)
    if match is not None and "python_version" in match.groupdict():
        version_digits = match.group("python_version")
    else:
        version_digits = _version_digits_from_manifest(manifest)
        if version_digits is None:
            expected = ", ".join(_extension_candidates(manifest.module))
            raise ValueError(
                "cannot infer wheel tag for %r; expected one of [%s]" % (
                    extension_name,
                    expected,
                )
            )

    py_tag = _python_tag_from_digits(version_digits)
    abi_tag = _abi_tag_from_digits(version_digits)
    plat_tag = _platform_tag()
    return py_tag, abi_tag, plat_tag


def _hash_and_size(path):
    """Return (sha256=..., size) for a file on disk."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    digest = base64.urlsafe_b64encode(h.digest()).rstrip(b"=").decode("ascii")
    return "sha256=%s" % digest, os.path.getsize(path)


def _hash_bytes(data):
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _select_current_extension(manifest):
    """Pick the extension file for the running interpreter."""
    available = set(artifact.filename for artifact in manifest.artifacts)
    extension_names = _extension_candidates(manifest.module)
    selected_extension = next((name for name in extension_names if name in available), None)
    if selected_extension is None:
        expected = ", ".join(extension_names)
        found = ", ".join(sorted(available)) or "<none>"
        raise IOError(
            "missing built extension for %r; expected one of [%s], found [%s]" % (
                manifest.module,
                expected,
                found,
            )
        )
    return selected_extension


def _select_matrix_extensions(manifest):
    """Pick the extension files for the current platform across versions."""
    pattern = _extension_pattern(manifest.module)
    selected = [
        artifact.filename
        for artifact in manifest.artifacts
        if artifact.kind == "extension" and pattern.match(artifact.filename)
    ]
    if not selected:
        expected = pattern.pattern
        found = ", ".join(sorted(artifact.filename for artifact in manifest.artifacts)) or "<none>"
        raise IOError(
            "missing built extensions for %r; expected pattern %r, found [%s]" % (
                manifest.module,
                expected,
                found,
            )
        )
    return sorted(selected)


def _select_wheel_entries(manifest, extension_name):
    """Pick the files that belong in one wheel."""
    available = set(artifact.filename for artifact in manifest.artifacts)
    if extension_name not in available:
        raise IOError("missing built extension %r for %r" % (extension_name, manifest.module))

    selected = [extension_name]
    for artifact in manifest.artifacts:
        if artifact.kind == "stub" and artifact.filename in available:
            selected.append(artifact.filename)

    selected.append("py.typed")
    return selected


def _as_bytes(data):
    if isinstance(data, bytes):
        return data
    return data.encode("utf-8")


def _build_one_wheel(manifest, extension_name, out_dir, metadata):
    py_tag, abi_tag, plat_tag = _wheel_tags_for_extension(manifest, extension_name)
    wheel_name = "%s-%s-%s-%s-%s.whl" % (
        manifest.module,
        manifest.version,
        py_tag,
        abi_tag,
        plat_tag,
    )
    wheel_path = os.path.abspath(os.path.join(out_dir, wheel_name))
    dist_info = "%s-%s.dist-info" % (manifest.module, manifest.version)

    records = []
    selected_entries = _select_wheel_entries(manifest, extension_name)
    lib_dir = manifest.lib_dir

    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for entry in selected_entries:
            if entry == "py.typed":
                typed_data = b""
                zf.writestr(entry, typed_data)
                records.append((entry, _hash_bytes(typed_data), len(typed_data)))
                continue

            full_path = os.path.join(lib_dir, entry)
            zf.write(full_path, entry)
            file_hash, size = _hash_and_size(full_path)
            records.append((entry, file_hash, size))

        description = str(metadata.get("description", "") or "")
        requires_python = str(metadata.get("requires_python", "") or "")
        license_value = metadata.get("license", "")
        if hasattr(license_value, "get"):
            license_text = str(license_value.get("text", "") or "")
        else:
            license_text = str(license_value or "")

        metadata_lines = [
            "Metadata-Version: 2.1\n",
            "Name: %s\n" % manifest.module,
            "Version: %s\n" % manifest.version,
        ]
        if description:
            metadata_lines.append("Summary: %s\n" % description)
        if requires_python:
            metadata_lines.append("Requires-Python: %s\n" % requires_python)
        if license_text:
            metadata_lines.append("License: %s\n" % license_text)
        metadata_data = "".join(metadata_lines)
        metadata_path = os.path.join(dist_info, "METADATA")
        zf.writestr(metadata_path, metadata_data)
        records.append((metadata_path, _hash_bytes(_as_bytes(metadata_data)), len(metadata_data)))

        wheel_info = (
            "Wheel-Version: 1.0\n"
            "Generator: pymz-tool\n"
            "Root-Is-Purelib: false\n"
            "Tag: %s-%s-%s\n" % (py_tag, abi_tag, plat_tag)
        )
        wheel_info_path = os.path.join(dist_info, "WHEEL")
        zf.writestr(wheel_info_path, wheel_info)
        records.append((wheel_info_path, _hash_bytes(_as_bytes(wheel_info)), len(wheel_info)))

        record_lines = ["%s,%s,%s" % (path, file_hash, size) for path, file_hash, size in records]
        record_lines.append("%s/RECORD,," % dist_info)
        record_data = _as_bytes("\n".join(record_lines))
        record_path = os.path.join(dist_info, "RECORD")
        zf.writestr(record_path, record_data)

    return wheel_path


def make_wheel(manifest_path, out_dir="dist", metadata=None):
    """Build a wheel from the extension artifacts recorded in a manifest."""
    manifest = BuildManifest.read(manifest_path)
    _mkdir_p(out_dir)
    metadata = metadata or {}
    extension_name = _select_current_extension(manifest)
    return _build_one_wheel(manifest, extension_name, out_dir, metadata)


def make_wheels(manifest_path, out_dir="dist", metadata=None):
    """Build one wheel per current-platform extension artifact."""
    manifest = BuildManifest.read(manifest_path)
    _mkdir_p(out_dir)
    metadata = metadata or {}
    wheel_paths = []
    for extension_name in _select_matrix_extensions(manifest):
        wheel_paths.append(_build_one_wheel(manifest, extension_name, out_dir, metadata))
    return wheel_paths
