"""Load pymz_tool project configuration from pyproject.toml."""

from __future__ import print_function


try:
    import tomllib
except ImportError:  # pragma: no cover
    try:
        import tomli as tomllib
    except ImportError:  # pragma: no cover
        tomllib = None


class ProjectConfig(object):
    """Project metadata and pymz_tool build defaults."""

    def __init__(
        self,
        module,
        version,
        description,
        requires_python,
        license,
        zig_target,
        extension_dir,
        runtime="auto",
        python_version=None,
        python_versions=None,
    ):
        self.module = module
        self.version = version
        self.description = description
        self.requires_python = requires_python
        self.license = license
        self.zig_target = zig_target
        self.extension_dir = extension_dir
        self.runtime = runtime
        self.python_version = python_version
        self.python_versions = python_versions

    def to_metadata(self):
        return {
            "description": self.description,
            "requires_python": self.requires_python,
            "license": self.license,
        }


def _default_config():
    return ProjectConfig(
        module="extension",
        version="0.0.0",
        description="Zig-backed Python extension",
        requires_python=">=2.7",
        license={"text": "MIT"},
        zig_target="example",
        extension_dir="zig-out/lib",
    )


def load_config(path="pyproject.toml"):
    """Read ``pyproject.toml`` and return a structured pymz_tool config."""
    if tomllib is None:
        return _default_config()

    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except IOError:
        return _default_config()

    project = data.get("project", {})
    tool = data.get("tool", {}).get("pymz_tool", {})

    return ProjectConfig(
        module=tool.get("module", project.get("name", "unknown")),
        version=project.get("version", "0.0.0"),
        description=project.get("description", ""),
        requires_python=project.get("requires-python", ""),
        license=project.get("license", {}),
        zig_target=tool.get("zig_target", "example"),
        extension_dir=tool.get("extension_dir", "zig-out/lib"),
        runtime=tool.get("runtime", "auto"),
        python_version=tool.get("python-version"),
        python_versions=tool.get("python-versions"),
    )
