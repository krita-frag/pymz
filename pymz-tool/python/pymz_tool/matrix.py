"""Build orchestration for pymz extensions.

Provides:

- ``Entry`` -- a single matrix build cell (runtime x version x target) plus the
  per-cell Python cross-compilation overrides.
- ``expand_matrix`` / ``build_matrix_from_cli`` -- produce ``Entry`` lists from
  ``pymz.json`` or CLI overrides, sharing one expansion path.
- ``run_zig_build`` -- low-level ``zig build`` invocation.
- ``build_one_cell`` -- build, collect, manifest, and package one ``Entry``.
  This is the single shared implementation used by the CLI ``build`` command,
  the PEP 517 ``build_wheel``/``build_editable`` backends, and the matrix
  builder.
- ``run_matrix`` -- parallel multi-cell orchestration.

Matrix semantics: the result is the cross product of runtimes x python-versions
x targets. ``platform_tags`` is aligned by index with ``targets`` (each target
maps to at most one platform tag), not cross-producted, because a wheel
platform tag is a function of the build target.
"""
from __future__ import absolute_import

import os
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

from ._compat import (
    Any,
    DEFAULT_RUNTIME,
    DEFAULT_ZIG_TARGET,
    resolve_runtime_for_manifest,
    default_zig_target,
)
from .config import load_config, get_project_info, python_version_string
from .errors import PymzBuildError, PymzConfigError
from .manifest import build_manifest, write_manifest, collect_artifacts
from .wheel import build_wheel as _build_wheel

# Per-entry Python cross-compilation override fields forwarded to ``zig build``
# as ``-Dpymz-python-*`` options. Centralised so the config expander, the CLI
# expander, and ``build_one_cell`` agree on the field set.
_ENTRY_PYTHON_FIELDS = (
    "python_config",
    "python",
    "python_includes",
    "python_ldflags",
    "python_libs",
    "python_ext_suffix",
    "python_version",
)


class Entry(object):
    """One build matrix cell.

    ``target`` is ``None`` for the host (``native``) target. ``platform_tag``
    is the wheel platform tag for this cell, or ``None`` to derive it from the
    target Python at packaging time.
    """

    __slots__ = (
        "runtime", "version", "target", "platform_tag",
        "python_config", "python", "python_includes", "python_ldflags",
        "python_libs", "python_ext_suffix", "python_version",
    )

    def __init__(self, runtime, version, target, platform_tag, **python_fields):
        self.runtime = runtime
        self.version = version
        self.target = target
        self.platform_tag = platform_tag
        for f in _ENTRY_PYTHON_FIELDS:
            setattr(self, f, python_fields.get(f))

    def as_dict(self):
        # type: () -> dict[str, Any]
        d = {
            "runtime": self.runtime,
            "version": self.version,
            "target": self.target,
            "platform_tag": self.platform_tag,
        }
        for f in _ENTRY_PYTHON_FIELDS:
            d[f] = getattr(self, f)
        return d

    def __repr__(self):
        return "Entry(runtime=%r, version=%r, target=%r, platform_tag=%r)" % (
            self.runtime, self.version, self.target, self.platform_tag,
        )


def _normalize_target(target):
    """``"native"`` (and empty) maps to ``None`` meaning the host target."""
    if not target or target == "native":
        return None
    return target


def _pair_targets_platform_tags(targets, platform_tags):
    # type: (list[str], list[str]) -> list[tuple[str | None, str | None]]
    """Zip *targets* with *platform_tags* by index.

    Each target maps to at most one platform tag (a wheel platform tag is a
    function of the build target), so this is an alignment, not a cross
    product. Missing tags default to ``None`` (derived at packaging time).
    """
    pairs = []
    for i, target in enumerate(targets):
        pt = platform_tags[i] if i < len(platform_tags) else None
        pairs.append((_normalize_target(target), pt))
    return pairs


def expand_matrix(runtimes, python_versions, targets, platform_tags, python_fields=None):
    # type: (list[str] | None, list[str] | None, list[str] | None, list[str] | None, dict | None) -> list[Entry]
    """Cross product of runtimes x python-versions x targets.

    ``targets`` is zipped by index with ``platform_tags``. ``python_fields``
    (from a ``pymz.json`` matrix entry) is attached to every produced cell, so
    config-declared cross-compilation overrides survive CLI-driven expansion
    when the caller merges them in.
    """
    runtimes = runtimes or [DEFAULT_RUNTIME]
    python_versions = python_versions or []
    targets = targets or ["native"]
    platform_tags = platform_tags or []
    pf = python_fields or {}

    entries = []
    for runtime in runtimes:
        for version in python_versions:
            for target_triple, pt in _pair_targets_platform_tags(targets, platform_tags):
                entries.append(Entry(
                    runtime=runtime,
                    version=version,
                    target=target_triple,
                    platform_tag=pt,
                    **{f: pf.get(f) for f in _ENTRY_PYTHON_FIELDS}
                ))
    return entries


def _entries_from_config(matrix_config):
    # type: (list[dict[str, Any]]) -> list[Entry]
    """Expand ``pymz.json`` ``matrix`` entries into ``Entry`` objects.

    Each config entry may carry per-entry Python configuration fields forwarded
    to ``zig build`` for cross-compilation::

        [[tool.pymz.matrix]]
        runtime = "cpython3"
        versions = ["3.10", "3.11"]
        targets = ["native"]
        python_config = "/path/to/python3.10-config"
        python_includes = "-I/usr/include/python3.10"
        python_ldflags = "-L/usr/lib -lpython3.10"
        python_ext_suffix = ".cpython-310-x86_64-linux-gnu.so"
        python_version = "3.10"
    """
    entries = []
    for cfg_entry in matrix_config:
        runtime = cfg_entry.get("runtime", DEFAULT_RUNTIME)
        versions = cfg_entry.get("versions", [])
        targets = cfg_entry.get("targets", ["native"])
        platform_tags = cfg_entry.get("platform-tags", [])
        pf = {f: cfg_entry.get(f) for f in _ENTRY_PYTHON_FIELDS}
        entries.extend(expand_matrix(
            [runtime], versions, targets, platform_tags, python_fields=pf,
        ))
    return entries


def build_matrix_from_cli(
    runtimes=None,         # type: list[str] | None
    python_versions=None,  # type: list[str] | None
    targets=None,          # type: list[str] | None
    platform_tags=None,    # type: list[str] | None
):
    # type: (...) -> list[Entry]
    """Build matrix entries from CLI override parameters.

    The result is the cross product of *runtimes* x *python_versions* x
    *targets* (cross product of all three).  *platform_tags* is aligned by
    index with *targets*.  Per-cell Python cross-compilation fields are left
    ``None``; CLI overrides replace the config matrix entirely, so config
    per-cell fields are intentionally not merged.
    """
    return expand_matrix(runtimes, python_versions, targets, platform_tags)


def _find_zig():
    # type: () -> str
    return os.environ.get("PYMZ_ZIG", "zig")


def run_zig_build(
    root,
    step,
    prefix,
    runtime=None,             # type: Any
    python_version=None,      # type: Any
    python_versions=None,     # type: Any
    target=None,              # type: Any
    release=True,             # type: bool
    extra_args=None,          # type: Any
    backend_source=None,      # type: Any
    python_config=None,       # type: Any
    python_includes=None,     # type: Any
    python_ldflags=None,      # type: Any
    python_libs=None,         # type: Any
    python_ext_suffix=None,   # type: Any
    python_version_override=None,  # type: Any
):
    # type: (...) -> None
    """Run ``zig build <step>`` with the given options.

    Python configuration overrides are forwarded as ``-Dpymz-python-*`` build
    options.  When all four raw flags (includes, ldflags, ext_suffix, version)
    are provided, the build can proceed without a host ``python-config``.
    """
    from pathlib import Path
    root = Path(str(root))
    prefix = Path(str(prefix))

    cmd = [_find_zig(), "build", step, "-p", str(prefix)]
    # Zig 0.16 parses `-Dname=value` (single token); the space-separated
    # `-Dname value` form is rejected as a flag for string options, so every
    # forwarded option is emitted with `=`.
    if runtime and runtime != DEFAULT_RUNTIME:
        cmd.append("-Dpymz-runtime=" + runtime)
    if python_version:
        cmd.append("-Dpython-version=" + python_version)
    if python_versions:
        cmd.append("-Dpython-versions=" + python_versions)
    if target:
        cmd.append("-Dtarget=" + target)
    if release:
        cmd.append("-Doptimize=ReleaseFast")
    if backend_source:
        cmd.append("-Dpymz-backend-source=" + backend_source)
    if python_config:
        cmd.append("-Dpymz-python-config=" + python_config)
    if python_includes:
        cmd.append("-Dpymz-python-includes=" + python_includes)
    if python_ldflags:
        cmd.append("-Dpymz-python-ldflags=" + python_ldflags)
    if python_libs:
        cmd.append("-Dpymz-python-libs=" + python_libs)
    if python_ext_suffix:
        cmd.append("-Dpymz-python-ext-suffix=" + python_ext_suffix)
    if python_version_override:
        cmd.append("-Dpymz-python-version=" + python_version_override)
    if extra_args:
        cmd.extend(extra_args)
    try:
        subprocess.check_call(cmd, cwd=str(root))
    except subprocess.CalledProcessError as exc:
        raise PymzBuildError(
            "zig build failed for step %r (target=%s, runtime=%s): %s"
            % (step, target or "native", runtime or DEFAULT_RUNTIME, exc)
        )


def _resolve_modules(project, step):
    # type: (dict, str) -> list[dict[str, str]]
    """Return the module specs for *project*, defaulting to a single module at
    *step* when none are declared."""
    modules = project.get("modules") or []
    if modules:
        return modules
    return [{"name": project.get("module", ""), "zig_target": step}]


def _run_steps_for_modules(root, step, prefix, modules, **zig_kwargs):
    # type: (Any, str, Any, list[dict[str, str]], **Any) -> None
    """Run one ``zig build`` per unique zig step across *modules*."""
    seen_steps = set()
    for mod in modules:
        mod_step = mod.get("zig_target", step)
        if mod_step in seen_steps:
            continue
        seen_steps.add(mod_step)
        run_zig_build(root, mod_step, prefix, **zig_kwargs)


def _make_manifest(project, modules, runtime, artifacts, python_versions, platform_tag, step):
    # type: (dict, list[dict[str, str]], str, list, list[str], Any, str) -> dict
    """Build a manifest dict from resolved build parameters."""
    module_names = [m["name"] for m in modules if m.get("name")]
    return build_manifest(
        modules=module_names,
        version=project["version"],
        runtime=resolve_runtime_for_manifest(runtime),
        distribution=project["distribution"],
        package_dir=project["package_dir"],
        artifacts=artifacts,
        python_versions=python_versions,
        platform_tag=platform_tag,
        zig_target=step,
    )


def build_one_cell(
    root,              # type: Any
    step,              # type: str
    prefix,            # type: Any
    out_dir,           # type: Any
    project,           # type: dict[str, str]
    *,                 # keyword-only from here:
    runtime=DEFAULT_RUNTIME,    # type: str
    python_version=None,        # type: Any
    python_versions=None,       # type: Any
    target=None,                # type: Any
    platform_tag=None,          # type: Any
    release=True,               # type: bool
    backend_source=None,        # type: Any
    python_config=None,         # type: Any
    python_includes=None,       # type: Any
    python_ldflags=None,        # type: Any
    python_libs=None,           # type: Any
    python_ext_suffix=None,     # type: Any
    python_version_override=None,  # type: Any
):
    # type: (...) -> str
    """Build, collect, manifest, and package a single matrix cell.

    This is the single shared implementation used by the CLI ``build`` command,
    the PEP 517 ``build_wheel`` and ``build_editable`` backends, and the matrix
    builder.  Returns the wheel filename.
    """
    from pathlib import Path
    root = Path(str(root))
    prefix = Path(str(prefix))
    out_dir = Path(str(out_dir))

    pv = python_versions or python_version or python_version_string()
    modules = _resolve_modules(project, step)

    _run_steps_for_modules(
        root, step, prefix, modules,
        runtime=runtime,
        python_version=python_version,
        python_versions=pv,
        target=target,
        release=release,
        backend_source=backend_source,
        python_config=python_config,
        python_includes=python_includes,
        python_ldflags=python_ldflags,
        python_libs=python_libs,
        python_ext_suffix=python_ext_suffix,
        python_version_override=python_version_override,
    )

    lib_dir = prefix / "lib"
    if not lib_dir.is_dir():
        raise PymzBuildError("zig build did not produce lib/ at %s" % lib_dir)

    module_names = [m["name"] for m in modules if m.get("name")]
    artifacts = collect_artifacts(lib_dir, module_names)
    if not any(a["kind"] == "extension" for a in artifacts):
        raise PymzBuildError("no extension artifact found in %s" % lib_dir)

    manifest = _make_manifest(
        project, modules, runtime, artifacts,
        [pv] if pv else [], platform_tag, step,
    )
    write_manifest(manifest, lib_dir)

    return _build_wheel(out_dir, manifest, lib_dir, root)


# Backward-compatible alias. The CLI/PEP517 backends call ``build_and_package``;
# ``build_one_cell`` is the canonical name. Both share one implementation.
build_and_package = build_one_cell


def _build_single(
    root,              # type: Any
    step,              # type: str
    project,           # type: dict[str, str]
    entry,             # type: Entry
    out_dir,           # type: Any
    release=True,      # type: bool
    backend_source=None,  # type: str | None
):
    # type: (...) -> str
    """Build a single ``Entry`` and package a wheel."""
    from pathlib import Path
    root = Path(str(root))
    out_dir = Path(str(out_dir))

    runtime = entry.runtime
    python_version = entry.version
    target = entry.target
    platform_tag = entry.platform_tag

    if python_version:
        prefix = out_dir / ("build-%s-%s" % (runtime, python_version))
    else:
        prefix = out_dir / ("build-%s" % runtime)
    if backend_source:
        import hashlib
        bs_hash = hashlib.sha256(backend_source.encode("utf-8")).hexdigest()[:8]
        prefix = prefix.parent / (prefix.name + "-" + bs_hash)

    return build_one_cell(
        root, step, prefix, out_dir, project,
        runtime=runtime,
        python_versions=python_version,
        target=target,
        platform_tag=platform_tag,
        release=release,
        backend_source=backend_source,
        python_config=entry.python_config,
        python_includes=entry.python_includes,
        python_ldflags=entry.python_ldflags,
        python_libs=entry.python_libs,
        python_ext_suffix=entry.python_ext_suffix,
        python_version_override=entry.python_version,
    )


def run_matrix(
    root,                  # type: Any
    out_dir=None,          # type: Any
    release=True,          # type: bool
    cli_overrides=None,    # type: dict[str, Any] | None
    project_overrides=None,  # type: dict[str, str] | None
    step=None,             # type: str | None
    backend_sources=None,  # type: list[str] | None
):
    # type: (...) -> list[str]
    """Run the build matrix from ``pymz.json`` or CLI overrides.

    When *cli_overrides* is provided (containing ``runtimes``,
    ``python_versions``, ``targets``, ``platform_tags`` keys), the config
    matrix is overridden entirely by the CLI-specified matrix.

    *project_overrides* patches the project info (module, distribution, etc.)
    from CLI flags.  *step* overrides the zig build step name.
    *backend_sources* is a list of backend source paths; each entry is built
    once per backend source.
    """
    from pathlib import Path
    root = Path(str(root))

    config = load_config(root)
    project = get_project_info(root)
    if project_overrides:
        project.update(project_overrides)

    step = step or default_zig_target(config)

    # Resolve matrix entries: CLI overrides take precedence over config.
    if cli_overrides:
        entries = build_matrix_from_cli(
            cli_overrides.get("runtimes"),
            cli_overrides.get("python_versions"),
            cli_overrides.get("targets"),
            cli_overrides.get("platform_tags"),
        )
    else:
        entries = _entries_from_config(config.get("matrix", []))

    if not entries:
        raise PymzConfigError("no matrix entries found in pymz.json")

    out_dir = Path(str(out_dir)) if out_dir else root / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)

    # ``None`` means "use pymz built-in backend". Kept as a sentinel so the
    # loop below can always iterate.
    if not backend_sources:
        backend_sources = [None]  # type: list[Any]

    wheels = []  # type: list[str]

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {}
        for entry in entries:
            for bs in backend_sources:
                future = executor.submit(
                    _build_single,
                    root, step, project,
                    entry, out_dir, release, bs,
                )
                futures[future] = entry
        for future in as_completed(futures):
            try:
                wheels.append(future.result())
            except Exception as exc:
                # Annotate with the matrix cell so a parallel failure is
                # attributable instead of an opaque CalledProcessError.
                entry = futures[future]
                raise PymzBuildError(
                    "matrix build failed for %s: %s" % (entry, exc)
                )

    return wheels
