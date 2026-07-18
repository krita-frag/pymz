"""PEP 517 build backend for pymz_tool projects."""

from __future__ import print_function

import os
import tarfile


def _config_setting(config_settings, key, default=None):
    if not config_settings:
        return default
    if key in config_settings:
        value = config_settings[key]
        return value[0] if isinstance(value, list) else value
    dashed = key.replace("_", "-")
    if dashed in config_settings:
        value = config_settings[dashed]
        return value[0] if isinstance(value, list) else value
    return default


def _config_flag(config_settings, key, default=False):
    value = _config_setting(config_settings, key)
    if value is None:
        return default
    return str(value).lower() not in set(["0", "false", "no", "off"])


def get_requires_for_build_wheel(config_settings=None):
    """Return the list of build requirements for building a wheel."""
    del config_settings
    return []


def get_requires_for_build_sdist(config_settings=None):
    """Return the list of build requirements for building an sdist."""
    del config_settings
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    """Build a wheel for the current platform and copy it into ``wheel_directory``."""
    del metadata_directory
    from .build import build_extension
    from .config import load_config
    from .wheel import make_wheel

    cfg = load_config()
    release = _config_flag(config_settings, "release", True)
    runtime = _config_setting(config_settings, "runtime", cfg.runtime) or "auto"
    python_version = _config_setting(config_settings, "python_version", cfg.python_version)
    python_versions = _config_setting(config_settings, "python_versions", cfg.python_versions)
    zig_target = _config_setting(config_settings, "zig_target", cfg.zig_target) or cfg.zig_target
    extension_dir = _config_setting(
        config_settings,
        "extension_dir",
        cfg.extension_dir,
    ) or cfg.extension_dir

    manifest_path = build_extension(
        cfg.module,
        version=cfg.version,
        zig_target=zig_target,
        python_version=python_version,
        python_versions=python_versions,
        pymz_runtime=runtime,
        release=release,
        extension_dir=extension_dir,
    )
    wheel_path = make_wheel(
        manifest_path,
        out_dir=wheel_directory,
        metadata=cfg.to_metadata(),
    )
    return os.path.basename(wheel_path)


def build_sdist(sdist_directory, config_settings=None):
    """Build a source distribution containing setup.py and Zig sources."""
    del config_settings
    from .config import load_config

    cfg = load_config()
    name = cfg.module
    version = cfg.version
    sdist_name = "%s-%s" % (name, version)
    sdist_filename = "%s.tar.gz" % sdist_name
    sdist_path = os.path.join(sdist_directory, sdist_filename)

    with tarfile.open(sdist_path, "w:gz") as tar:
        for path in [
            "setup.py",
            "build.zig",
            "build.zig.zon",
            "README.md",
            "pymz",
            "pymz-build",
            "examples",
            os.path.join("tools", "pymz"),
            os.path.join("tools", "pyproject.toml"),
        ]:
            if os.path.exists(path):
                tar.add(path, arcname=os.path.join(sdist_name, path))

    return sdist_filename
