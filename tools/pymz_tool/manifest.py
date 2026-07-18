"""Manifest helpers for pymz build outputs."""

from __future__ import print_function

import json
import os


MANIFEST_SUFFIX = ".pymz-manifest.json"
SCHEMA_VERSION = 1


class Artifact(object):
    """A single file produced by a pymz build."""

    def __init__(self, filename, kind="extension"):
        self.filename = filename
        self.kind = kind

    @classmethod
    def from_filename(cls, filename):
        kind = "stub" if filename.endswith(".pyi") else "extension"
        return cls(filename=filename, kind=kind)

    def to_dict(self):
        return {
            "filename": self.filename,
            "kind": self.kind,
        }


class BuildManifest(object):
    """Serialized description of a build output directory."""

    def __init__(
        self,
        module,
        version,
        zig_target,
        runtime,
        release,
        lib_dir,
        schema_version=SCHEMA_VERSION,
        python_version=None,
        python_versions=None,
        artifacts=None,
    ):
        self.module = module
        self.version = version
        self.zig_target = zig_target
        self.runtime = runtime
        self.release = release
        self.lib_dir = lib_dir
        self.schema_version = schema_version
        self.python_version = python_version
        self.python_versions = list(python_versions or [])
        self.artifacts = list(artifacts or [])

    def extension_filenames(self):
        return [artifact.filename for artifact in self.artifacts if artifact.kind == "extension"]

    def stub_filenames(self):
        return [artifact.filename for artifact in self.artifacts if artifact.kind == "stub"]

    def to_dict(self):
        return {
            "schema_version": self.schema_version,
            "module": self.module,
            "version": self.version,
            "zig_target": self.zig_target,
            "runtime": self.runtime,
            "release": self.release,
            "lib_dir": self.lib_dir,
            "python_version": self.python_version,
            "python_versions": list(self.python_versions),
            "artifacts": [artifact.to_dict() for artifact in self.artifacts],
        }

    @classmethod
    def from_dict(cls, data):
        artifacts = [Artifact(**item) for item in data.get("artifacts", [])]
        return cls(
            schema_version=int(data.get("schema_version", SCHEMA_VERSION)),
            module=str(data["module"]),
            version=str(data["version"]),
            zig_target=str(data["zig_target"]),
            runtime=str(data["runtime"]),
            release=bool(data.get("release", False)),
            lib_dir=str(data["lib_dir"]),
            python_version=data.get("python_version"),
            python_versions=list(data.get("python_versions", [])),
            artifacts=artifacts,
        )

    def write(self, path):
        with open(path, "w") as f:
            f.write(json.dumps(self.to_dict(), indent=2, sort_keys=True) + "\n")

    @classmethod
    def read(cls, path):
        with open(path, "r") as f:
            return cls.from_dict(json.loads(f.read()))


def manifest_path_for(lib_dir, module_name):
    return os.path.join(str(lib_dir), "%s%s" % (module_name, MANIFEST_SUFFIX))
