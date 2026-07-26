//! pymz build scaffold - reusable helpers for building Python extensions
//! with Zig across Python versions and target platforms.
//!
//! Import this file from a project's `build.zig` to get:
//!   * Python configuration detection (python-config / sysconfig)
//!   * Automatic Python-extension file naming (cpython-XY-platform.so, etc.)
//!   * Cross-platform linking rules (Unix runtime-link, Windows import-lib)
//!
//! Implementation details live in the sibling modules; this file is the public
//! entry point and orchestrates `buildProject`.

const std = @import("std");
const python_config = @import("python_config.zig");
const extension = @import("extension.zig");
const cross = @import("cross.zig");

pub const RuntimeId = python_config.RuntimeId;
pub const Runtime = python_config.Runtime;
pub const PythonConfig = python_config.PythonConfig;
pub const PythonVersion = python_config.PythonVersion;
pub const ExtensionOptions = extension.ExtensionOptions;
pub const addPythonExtension = extension.addPythonExtension;
pub const configureBackendModule = extension.configureBackendModule;
pub const configureCpythonBackendModule = extension.configureCpythonBackendModule;
pub const configureBackendModuleFromDependency = extension.configureBackendModuleFromDependency;
pub const computeExtensionName = extension.computeExtensionName;
pub const runtimeIsLimitedApi = python_config.runtimeIsLimitedApi;
pub const runtimeIsLimitedApiByName = python_config.runtimeIsLimitedApiByName;
pub const resolveRuntime = python_config.resolveRuntime;
pub const resolveDefaultPythonConfig = python_config.resolveDefaultPythonConfig;
pub const resolvePythonConfigExact = python_config.resolvePythonConfigExact;
pub const resolvePythonConfigMaybe = python_config.resolvePythonConfigMaybe;
pub const discoverPythonConfig = python_config.discoverPythonConfig;
pub const discoverPythonConfigExpected = python_config.discoverPythonConfigExpected;
pub const parseVersions = python_config.parseVersions;
pub const parsePythonVersion = python_config.parsePythonVersion;

pub const HookContext = extension.HookContext;
pub const BuildHooks = extension.BuildHooks;
pub const PythonOverrides = python_config.PythonOverrides;

/// Errors surfaced to the caller of `buildProject`. User-actionable option
/// problems are distinct from missing-dependency errors so callers can present
/// a helpful message instead of a panic stack. `OutOfMemory` is included
/// because the build-graph allocations (e.g. the cross-target artifact slots)
/// route through the build allocator.
pub const BuildProjectError = error{
    InvalidRuntime,
    CustomBackendRequiresExplicitRuntime,
    LimitedApiRequiresPython310,
    InvalidOption,
    MissingPymzDependency,
    MissingPymzToolDependency,
    OutOfMemory,
};

pub const ProjectOptions = struct {
    module_name: []const u8,
    /// Root source file for the extension module. **Required** -- the Zig
    /// build system (build.zig) is the canonical place for Zig source layout
    /// configuration, not pyproject.toml.
    root_source_file: std.Build.LazyPath,
    /// Optional default step name; defaults to `module_name`.
    step_name: ?[]const u8 = null,
    /// Optional default multi step name; defaults to `{module_name}-multi`.
    multi_step_name: ?[]const u8 = null,
    /// Optional hooks for custom linking, C sources, or install steps.
    hooks: BuildHooks = .{},

    /// Path to the `pymz` package root source file. Defaults to the
    /// conventional `pymz/src/pymz.zig` inside the `pymz` dependency.
    pymz_root_file: ?std.Build.LazyPath = null,
    /// Path to the backend contract file. Defaults to `pymz/src/contract.zig`.
    pymz_contract_file: ?std.Build.LazyPath = null,
    /// Path to the default backend implementation. Defaults to
    /// `pymz/src/backend.zig`.
    pymz_backend_file: ?std.Build.LazyPath = null,
    /// Path to the C header used by the CPython backend. Defaults to
    /// `pymz/src/runtime/cpython/python_c.h`.
    pymz_python_c_header: ?std.Build.LazyPath = null,
    /// Path to the CPython compatibility include directory. Defaults to
    /// `pymz/src/runtime/cpython`.
    pymz_cpython_include_dir: ?std.Build.LazyPath = null,
};

/// Build a standalone extension project with multi-version smoke-test steps.
///
/// Returns the primary (host-target) extension artifact, or `null` when the
/// build is only answering a metadata query (e.g. `--help` or
/// `--list-steps`) and no artifact was produced.
pub fn buildProject(
    b: *std.Build,
    options: ProjectOptions,
) BuildProjectError!?*std.Build.Step.Compile {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const requested_runtime_raw = b.option(
        []const u8,
        "pymz-runtime",
        "Backend runtime to build: auto, cpython2, cpython3, cpython3-limited, or custom",
    ) orelse "auto";
    const requested_runtime: ?Runtime = if (std.mem.eql(u8, requested_runtime_raw, "auto"))
        null
    else
        RuntimeId.fromString(requested_runtime_raw) catch return error.InvalidRuntime;
    const backend_source_raw = b.option(
        []const u8,
        "pymz-backend-source",
        "Root source file for the backend module; defaults to pymz's built-in backend entrypoint",
    );
    const pymz_dep = b.lazyDependency("pymz", .{}) orelse return error.MissingPymzDependency;

    // Resolve pymz file paths. Callers can override any of these to decouple
    // their project from the default pymz package layout.
    const pymz_root_file = options.pymz_root_file orelse pymz_dep.path("src/pymz.zig");
    const pymz_contract_file = options.pymz_contract_file orelse pymz_dep.path("src/contract.zig");
    const pymz_backend_file = options.pymz_backend_file orelse pymz_dep.path("src/backend.zig");
    const pymz_python_c_header = options.pymz_python_c_header orelse pymz_dep.path("src/runtime/cpython/python_c.h");
    const pymz_cpython_include_dir = options.pymz_cpython_include_dir orelse pymz_dep.path("src/runtime/cpython");
    const pymz_tool_dep = b.lazyDependency("pymz-tool", .{}) orelse return error.MissingPymzToolDependency;
    const pymz_core_module = b.createModule(.{
        .root_source_file = pymz_tool_dep.path("src/core/main.zig"),
    });

    const python_version = b.option(
        []const u8,
        "python-version",
        "Python version to build against (e.g. 2.7, 3.12)",
    );
    const python_versions = b.option(
        []const u8,
        "python-versions",
        "Comma-separated Python versions to build (e.g. 3.11,3.12,3.13)",
    );

    if (python_version != null and python_versions != null) {
        return error.InvalidOption;
    }

    const explicit_versions: ?[]const []const u8 = blk: {
        if (python_versions) |raw| {
            break :blk parseVersions(b, raw) catch return error.InvalidOption;
        }
        if (python_version) |version| {
            break :blk &.{version};
        }
        break :blk null;
    };

    const skip_cross = b.option(
        bool,
        "skip-cross",
        "Skip cross-compilation targets in example-multi",
    ) orelse false;
    const cross_targets_raw = b.option(
        []const u8,
        "cross-targets",
        "Comma-separated cross-compile targets (triple or triple:label)",
    );

    const cross_targets = cross.resolveCrossTargets(b, cross_targets_raw) catch return error.InvalidOption;

    const step_name = options.step_name orelse options.module_name;
    const multi_step_name = options.multi_step_name orelse b.fmt("{s}-multi", .{options.module_name});

    const build_step = b.step(
        step_name,
        b.fmt("Build the {s} extension", .{options.module_name}),
    );
    const multi_step = b.step(
        multi_step_name,
        b.fmt("Build {s} for multiple Python versions and platforms", .{options.module_name}),
    );

    if (isMetadataQuery(b)) {
        return null;
    }

    // Build-option-driven Python configuration overrides. ``build.zig``
    // authors set them directly via ``-D`` options; when a field is non-null
    // it takes precedence over environment variables and python-config.
    // `fillFromEnv` picks up ``PYMZ_PYTHON_*`` env vars for any field not
    // pinned on the command line, realising the documented
    // ``-D option > env var > python-config`` precedence.
    const python_overrides: PythonOverrides = blk: {
        const from_options: PythonOverrides = .{
            .config = b.option([]const u8, "pymz-python-config", "Path to python-config script"),
            .includes = b.option([]const u8, "pymz-python-includes", "Raw Python include flags (cross-compile)"),
            .ldflags = b.option([]const u8, "pymz-python-ldflags", "Raw Python linker flags (cross-compile)"),
            .libs = b.option([]const u8, "pymz-python-libs", "Raw Python library flags (cross-compile)"),
            .ext_suffix = b.option([]const u8, "pymz-python-ext-suffix", "Python extension suffix (cross-compile)"),
            .version = b.option([]const u8, "pymz-python-version", "Python version for synthesised config (e.g. 3.12)"),
        };
        break :blk from_options.fillFromEnv();
    };

    const windows_import_lib: ?std.Build.LazyPath = blk: {
        const import_lib_opt = b.option(
            []const u8,
            "pymz-windows-import-lib",
            "Path to the Python import library for Windows cross-linking",
        );
        if (import_lib_opt) |raw| break :blk b.path(raw);

        // Fallback: read the ``PYMZ_WINDOWS_IMPORT_LIB`` env var when no
        // ``-Dpymz-windows-import-lib`` build option is supplied.
        if (std.c.getenv("PYMZ_WINDOWS_IMPORT_LIB")) |env_value| {
            std.log.warn("PYMZ_WINDOWS_IMPORT_LIB env var read as fallback; prefer -Dpymz-windows-import-lib", .{});
            break :blk b.path(std.mem.span(env_value));
        }
        break :blk null;
    };

    const primary_py = blk: {
        if (python_version) |version| {
            const primary_config = resolvePythonConfigExact(b, version, python_overrides) catch return error.InvalidOption;
            break :blk discoverPythonConfigExpected(b, primary_config, version, python_overrides) catch return error.InvalidOption;
        }

        const primary_config = resolveDefaultPythonConfig(b, python_overrides) catch return error.InvalidOption;
        break :blk discoverPythonConfig(b, primary_config, python_overrides) catch return error.InvalidOption;
    };
    const backend_source_file = if (backend_source_raw) |raw|
        b.path(raw)
    else
        pymz_backend_file;
    const backend_runtime = resolveBackendRuntime(
        requested_runtime_raw,
        requested_runtime,
        backend_source_raw,
        primary_py,
    ) catch |err| switch (err) {
        error.CustomBackendRequiresExplicitRuntime => return error.CustomBackendRequiresExplicitRuntime,
        else => return error.InvalidOption,
    };
    if (backend_runtime.isLimitedApi() and
        (primary_py.major != 3 or primary_py.minor < 10))
    {
        return error.LimitedApiRequiresPython310;
    }

    const project_source = options.root_source_file;

    // All inputs that stay constant across the host build and every cross
    // target are captured once in `ext_ctx` so the per-target build helper
    // only needs the bits that actually vary: target, Python config, runtime.
    const use_cpython_backend = backend_source_raw == null;
    const ext_ctx: ExtensionBuildContext = .{
        .optimize = optimize,
        .pymz_core_module = pymz_core_module,
        .pymz_contract_file = pymz_contract_file,
        .pymz_root_file = pymz_root_file,
        .backend_source_file = backend_source_file,
        .backend_python_c_header = if (use_cpython_backend) pymz_python_c_header else null,
        .backend_cpython_include_dir = if (use_cpython_backend) pymz_cpython_include_dir else null,
        .pymz_dep = pymz_dep,
        .project_source = project_source,
        .module_name = options.module_name,
        .windows_import_lib = windows_import_lib,
        .hooks = options.hooks,
    };

    const project_artifact = buildExtensionArtifact(
        b,
        ext_ctx,
        target,
        primary_py,
        backend_runtime,
    ) catch return error.InvalidOption;
    // Install the host artifact into ``<prefix>/lib`` under the exact Python
    // extension filename (e.g. ``_jsonz.cpython-314-darwin.so``). ``installArtifact``
    // is not used because the library ``name`` carries the full ext suffix, which
    // Zig would mangle into ``lib<name>.dylib``; installing the emitted bin with
    // the artifact's ``name`` as the destination preserves the suffix Python's
    // import machinery and ``collect_artifacts`` expect.
    const install_host = b.addInstallFileWithDir(
        project_artifact.getEmittedBin(),
        .lib,
        project_artifact.name,
    );
    build_step.dependOn(&install_host.step);
    build_step.dependOn(&project_artifact.step);

    // Pre-build the host-OS cross artifacts once so the multi-step can depend
    // on them without rebuilding when iterating Python versions.
    var primary_cross_artifacts = try b.allocator.alloc(?*std.Build.Step.Compile, cross_targets.len);
    @memset(primary_cross_artifacts, null);

    for (cross_targets, 0..) |cross_target_config, index| {
        if (skip_cross) break;
        const triple = cross_target_config.triple;
        const label = cross_target_config.label;
        const cross_target = resolveCrossTarget(b, triple) catch return error.InvalidOption;
        if (cross.shouldSkipCrossTarget(cross_target)) continue;
        const cross_artifact = buildExtensionArtifact(
            b,
            ext_ctx,
            cross_target,
            primary_py,
            backend_runtime,
        ) catch return error.InvalidOption;
        primary_cross_artifacts[index] = cross_artifact;

        const cross_step = b.step(
            b.fmt("{s}-{s}", .{ options.module_name, label }),
            b.fmt("Cross compile {s} for {s}", .{ options.module_name, triple }),
        );
        cross_step.dependOn(&cross_artifact.step);
    }

    var built_count: usize = 0;
    var skipped_count: usize = 0;

    if (explicit_versions) |versions| {
        // Per-version matrix: for each Python version, build the native
        // artifact plus every cross target whose OS matches the host.
        for (versions) |version| {
            const config = resolvePythonConfigMaybe(b, version, python_overrides) orelse {
                std.log.warn("skip python {s}: exact python-config not found", .{version});
                skipped_count += 1;
                continue;
            };
            const py = discoverPythonConfigExpected(b, config, version, python_overrides) catch |err| {
                switch (err) {
                    error.PythonVersionMismatch => {
                        std.log.warn(
                            "skip python {s}: discovered interpreter version mismatch",
                            .{version},
                        );
                        skipped_count += 1;
                        continue;
                    },
                    else => return error.InvalidOption,
                }
            };
            const runtime = resolveBackendRuntime(
                requested_runtime_raw,
                requested_runtime,
                backend_source_raw,
                py,
            ) catch |err| switch (err) {
                error.CustomBackendRequiresExplicitRuntime => return error.CustomBackendRequiresExplicitRuntime,
                else => return error.InvalidOption,
            };
            const native_artifact = buildExtensionArtifact(
                b,
                ext_ctx,
                target,
                py,
                runtime,
            ) catch return error.InvalidOption;
            multi_step.dependOn(&native_artifact.step);
            built_count += 1;

            built_count += wireCrossTargetsForVersion(
                b,
                ext_ctx,
                multi_step,
                cross_targets,
                py,
                runtime,
                version,
                skip_cross,
                &skipped_count,
            ) catch 0;
        }
    } else {
        // No explicit versions: the multi-step is the host build plus the
        // pre-built host-OS cross artifacts.
        multi_step.dependOn(build_step);
        built_count += 1;
        for (cross_targets, 0..) |cross_target_config, index| {
            if (skip_cross) break;
            const triple = cross_target_config.triple;
            const cross_target = resolveCrossTarget(b, triple) catch return error.InvalidOption;
            if (primary_py.major < 3) {
                std.log.warn(
                    "skip target {s} for default host Python: Python 2 import loaders do not support tagged multi-platform suffixes",
                    .{triple},
                );
                skipped_count += 1;
            } else if (cross.shouldSkipCrossTarget(cross_target)) {
                std.log.warn(
                    "skip target {s} for default host Python: cross-linking requires a target Python toolchain",
                    .{triple},
                );
                skipped_count += 1;
            } else {
                multi_step.dependOn(&primary_cross_artifacts[index].?.step);
                built_count += 1;
            }
        }
    }
    std.log.info("{s} plan: {d} build artifact(s), {d} skipped variant(s)", .{
        multi_step_name,
        built_count,
        skipped_count,
    });

    return project_artifact;
}

/// Resolve the backend runtime for a build cell.
///
/// When no custom backend source is supplied, the runtime is auto-resolved
/// from the Python major version (or the explicit `requested_runtime`).
/// A custom backend source requires an explicit runtime, because auto
/// resolution is tied to CPython's `python-config` discovery.
fn resolveBackendRuntime(
    requested_runtime_raw: []const u8,
    requested_runtime: ?Runtime,
    backend_source_raw: ?[]const u8,
    py: PythonConfig,
) !Runtime {
    if (backend_source_raw == null) {
        return resolveRuntime(requested_runtime_raw, py);
    }
    if (requested_runtime) |runtime| return runtime;
    std.log.err("pymz-runtime must be set explicitly when using a custom backend source", .{});
    return error.CustomBackendRequiresExplicitRuntime;
}

/// Wire cross-target artifacts for one Python version onto `multi_step`.
///
/// Returns the number of cross artifacts actually built. Skip policy:
/// Python 2 cannot emit tagged multi-platform suffixes, and cross-linking to
/// a non-host OS requires a target Python toolchain the host does not have.
/// Both cases are logged and counted as skipped rather than failing the build.
fn wireCrossTargetsForVersion(
    b: *std.Build,
    ext_ctx: ExtensionBuildContext,
    multi_step: *std.Build.Step,
    cross_targets: []const cross.CrossTargetConfig,
    py: PythonConfig,
    runtime: Runtime,
    version: []const u8,
    skip_cross: bool,
    skipped_count: *usize,
) !usize {
    var built: usize = 0;
    for (cross_targets) |cross_target_config| {
        if (skip_cross) break;
        const triple = cross_target_config.triple;
        const cross_target = try resolveCrossTarget(b, triple);
        if (py.major < 3) {
            std.log.warn(
                "skip target {s} for python {s}: Python 2 import loaders do not support tagged multi-platform suffixes",
                .{ triple, version },
            );
            skipped_count.* += 1;
        } else if (cross.shouldSkipCrossTarget(cross_target)) {
            std.log.warn(
                "skip target {s} for python {s}: cross-linking requires a target Python toolchain",
                .{ triple, version },
            );
            skipped_count.* += 1;
        } else {
            const cross_artifact = try buildExtensionArtifact(
                b,
                ext_ctx,
                cross_target,
                py,
                runtime,
            );
            multi_step.dependOn(&cross_artifact.step);
            built += 1;
        }
    }
    return built;
}

/// Shared inputs for building a Python extension artifact across the host
/// target and every cross-target variant in a single `buildProject` call.
///
/// Capturing these once lets `buildExtensionArtifact` vary only the pieces
/// that actually differ per artifact: `target`, `py`, and `runtime`.
const ExtensionBuildContext = struct {
    optimize: std.builtin.OptimizeMode,
    pymz_core_module: *std.Build.Module,
    pymz_contract_file: std.Build.LazyPath,
    pymz_root_file: std.Build.LazyPath,
    backend_source_file: std.Build.LazyPath,
    /// Pre-resolved optional CPython backend inputs: both are non-null when
    /// the default backend is used, and both null when a custom backend
    /// source overrides them. `use_cpython_backend` is derived from this.
    backend_python_c_header: ?std.Build.LazyPath,
    backend_cpython_include_dir: ?std.Build.LazyPath,
    pymz_dep: *std.Build.Dependency,
    project_source: std.Build.LazyPath,
    module_name: []const u8,
    windows_import_lib: ?std.Build.LazyPath,
    hooks: BuildHooks,
};

/// Build a single Python extension artifact (backend module + pymz module +
/// extension shared library) for the given target, Python config, and
/// runtime.
///
/// This wraps the `createBackendModule` -> `createPymzModule` ->
/// `addPythonExtension` sequence for the host build and every cross-target
/// variant. The caller wires the returned artifact onto the appropriate build
/// step (`build_step`, `multi_step`, or a per-target `cross_step`).
fn buildExtensionArtifact(
    b: *std.Build,
    ctx: ExtensionBuildContext,
    target: std.Build.ResolvedTarget,
    py: PythonConfig,
    runtime: Runtime,
) !*std.Build.Step.Compile {
    const use_cpython_backend = ctx.backend_python_c_header != null;
    // The contract module (`contract.zig`) is created once and shared by both
    // the backend module and the pymz module so the file is owned by exactly
    // one module. `contract.zig` only imports `std`, so it needs no target or
    // Python configuration.
    const contract_module = b.createModule(.{
        .root_source_file = ctx.pymz_contract_file,
    });
    const backend_module = extension.createBackendModule(
        b,
        target,
        ctx.optimize,
        ctx.pymz_core_module,
        contract_module,
        ctx.backend_source_file,
        runtime,
        py,
        use_cpython_backend,
        ctx.backend_python_c_header,
        ctx.backend_cpython_include_dir,
    );
    const pymz_module = extension.createPymzModule(
        b,
        target,
        ctx.optimize,
        ctx.pymz_root_file,
        backend_module,
        contract_module,
    );
    return addPythonExtension(b, .{
        .name = ctx.module_name,
        .root_source_file = ctx.project_source,
        .pymz_module = pymz_module,
        .pymz_dep = ctx.pymz_dep,
        .py = py,
        .target = target,
        .optimize = ctx.optimize,
        .runtime = runtime,
        .windows_import_lib = ctx.windows_import_lib,
        .hooks = ctx.hooks,
    });
}

/// Parse a cross-compilation triple into a `ResolvedTarget`.
///
/// Shared by every cross-target loop so the parse call site stays consistent
/// and the loops focus on skip policy and step wiring.
fn resolveCrossTarget(
    b: *std.Build,
    triple: []const u8,
) !std.Build.ResolvedTarget {
    return b.resolveTargetQuery(
        try std.Target.Query.parse(.{ .arch_os_abi = triple }),
    );
}

fn isMetadataQuery(b: *std.Build) bool {
    const args = b.args orelse return false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return true;
        if (std.mem.eql(u8, arg, "-h")) return true;
        if (std.mem.eql(u8, arg, "--list-steps")) return true;
    }
    return false;
}
