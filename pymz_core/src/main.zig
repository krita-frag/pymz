//! pymz build scaffold — reusable helpers for building Python extensions
//! with Zig across Python versions and target platforms.
//!
//! Import this file from a project's `build.zig` to get:
//!   * Python configuration detection (python-config / sysconfig)
//!   * Automatic Python-extension file naming (cpython-XY-platform.so, etc.)
//!   * Cross-platform linking rules (Unix runtime-link, Windows import-lib)

const builtin = @import("builtin");
const std = @import("std");

/// Detected Python interpreter configuration used to configure compilation.
pub const PythonConfig = struct {
    version: []const u8,
    major: u32,
    minor: u32,
    includes: []const u8,
    ldflags: []const u8,
    libs: []const u8,
    ext_suffix: []const u8,
};

pub const PythonVersion = struct {
    major: u32,
    minor: u32,
};

pub const Runtime = []const u8;

/// Options for `addPythonExtension`.
pub const ExtensionOptions = struct {
    /// Module name as Python sees it (e.g. "jsonz").
    name: []const u8,
    /// Root Zig source file for the extension module.
    root_source_file: std.Build.LazyPath,
    /// The pymz Zig module (`@import("pymz")`) to link against.
    pymz_module: *std.Build.Module,
    /// Python configuration discovered at build time.
    py: PythonConfig,
    /// Target triple for the compiled extension.
    target: std.Build.ResolvedTarget,
    /// Optimization mode.
    optimize: std.builtin.OptimizeMode,
    /// Runtime/backend name selected for this extension.
    runtime: Runtime,
    /// If true, link the Python import library on Windows. Most projects want
    /// this; set to false only if you supply your own import lib.
    link_python_on_windows: bool = true,
    /// Optional path to a Windows Python import library (.lib or .dll.a).
    /// When provided, this is linked on Windows instead of searching
    /// `python-config --libs` for a `-lpythonXY` flag.
    windows_import_lib: ?std.Build.LazyPath = null,
};

/// Add a Python extension module shared library and return the install step that
/// places it under `<prefix>/lib` with the correct Python-extension filename.
pub fn addPythonExtension(b: *std.Build, options: ExtensionOptions) !*std.Build.Step.InstallFile {
    const root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
    });
    root.addImport("pymz", options.pymz_module);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = options.name,
        .root_module = root,
    });

    // Extension modules rely on the Python interpreter to resolve C API symbols
    // at load time, so we do not link against python-config's libs on ELF/macOS.
    // Windows requires the Python import library to resolve declspec(dllimport)
    // symbols at link time.
    lib.root_module.link_libc = true;
    lib.linker_allow_shlib_undefined = options.target.result.os.tag != .windows;

    if (options.target.result.os.tag == .windows) {
        lib.root_module.addCMacro("MS_WINDOWS", "1");
        if (options.link_python_on_windows) {
            if (options.windows_import_lib) |import_lib| {
                lib.root_module.addObjectFile(import_lib);
            } else {
                var linked_python = false;
                var lib_it = std.mem.tokenizeScalar(u8, options.py.libs, ' ');
                while (lib_it.next()) |flag| {
                    if (std.mem.startsWith(u8, flag, "-l")) {
                        const lib_name = flag[2..];
                        if (std.mem.startsWith(u8, lib_name, "python")) {
                            lib.root_module.linkSystemLibrary(lib_name, .{});
                            linked_python = true;
                        }
                    }
                }
                if (!linked_python) {
                    std.log.warn(
                        "no Windows Python import library found for {s}; the target may fail at link time",
                        .{options.py.version},
                    );
                }
            }
        }
    }

    const ext_name = computeExtensionName(
        b,
        options.name,
        options.py,
        options.target,
        options.runtime,
    );
    return b.addInstallFile(lib.getEmittedBin(), b.pathJoin(&.{ "lib", ext_name }));
}

/// Add the backend runtime option shared by all backend implementations.
pub fn configureBackendModule(module: *std.Build.Module, runtime: Runtime) void {
    const options = module.owner.addOptions();
    options.addOption([]const u8, "runtime", runtime);
    module.addOptions("pymz_options", options);
}

/// Configure the built-in CPython backend with translated C API headers.
pub fn configureCpythonBackendModuleFromDependency(
    module: *std.Build.Module,
    py: PythonConfig,
    runtime: Runtime,
    pymz_dep: *std.Build.Dependency,
) void {
    const b = module.owner;
    const target = module.resolved_target orelse b.graph.host;
    const optimize = module.optimize orelse .Debug;
    configureBackendModule(module, runtime);
    const translate_c = b.addTranslateC(.{
        .root_source_file = pymz_dep.path("src/runtime/cpython/python_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.defineCMacro("PY_SSIZE_T_CLEAN", "1");
    if (runtimeIsLimitedApi(runtime)) {
        translate_c.defineCMacro("Py_LIMITED_API", "0x030A0000");
    }

    module.addCMacro("PY_SSIZE_T_CLEAN", "1");
    if (runtimeIsLimitedApi(runtime)) {
        module.addCMacro("Py_LIMITED_API", "0x030A0000");
    }
    module.addCMacro("PYMZ_PYTHON_MAJOR", module.owner.fmt("{d}", .{py.major}));
    module.addCMacro("PYMZ_PYTHON_MINOR", module.owner.fmt("{d}", .{py.minor}));

    var include_it = std.mem.tokenizeScalar(u8, py.includes, ' ');
    while (include_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const path: std.Build.LazyPath = .{ .cwd_relative = flag[2..] };
            module.addIncludePath(path);
            translate_c.addIncludePath(path);
        }
    }

    module.addImport("python_c", translate_c.createModule());
}

/// Configure a custom backend module that does not need the CPython C API.
pub fn configureBackendModuleFromDependency(
    module: *std.Build.Module,
    runtime: Runtime,
) void {
    configureBackendModule(module, runtime);
}

/// Apply linker flags from `python-config --ldflags` / `--libs` to a compile
/// step. Used for the stub generator, which is a standalone executable and
/// therefore must resolve Python C API symbols at link time.
fn applyPythonLinkFlags(compile: *std.Build.Step.Compile, py: PythonConfig) void {
    const target = compile.root_module.resolved_target orelse compile.root_module.owner.graph.host;
    if (target.result.os.tag == .macos) {
        // python-config on macOS does not emit -framework Python because
        // extension modules rely on runtime resolution. For a standalone
        // executable we must link the framework explicitly.
        var include_it = std.mem.tokenizeScalar(u8, py.includes, ' ');
        if (include_it.next()) |first_flag| {
            if (std.mem.startsWith(u8, first_flag, "-I")) {
                const include_dir = first_flag[2..];
                var dir = include_dir;
                // Climb from Versions/X.Y/include/pythonX.Y to Python.framework.
                for (0..4) |_| {
                    dir = std.fs.path.dirname(dir) orelse break;
                }
                if (std.fs.path.dirname(dir)) |frameworks_dir| {
                    compile.root_module.addFrameworkPath(.{ .cwd_relative = frameworks_dir });
                }
            }
        }
        compile.root_module.linkFramework("Python", .{});
    }

    var buf_it = std.mem.tokenizeScalar(u8, py.ldflags, ' ');
    while (buf_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-L")) {
            const path: std.Build.LazyPath = .{ .cwd_relative = flag[2..] };
            compile.root_module.addLibraryPath(path);
        } else if (std.mem.eql(u8, flag, "-framework")) {
            const framework = buf_it.next() orelse continue;
            compile.root_module.linkFramework(framework, .{});
        } else if (std.mem.startsWith(u8, flag, "-l")) {
            compile.root_module.linkSystemLibrary(flag[2..], .{});
        }
    }
    buf_it = std.mem.tokenizeScalar(u8, py.libs, ' ');
    while (buf_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-L")) {
            const path: std.Build.LazyPath = .{ .cwd_relative = flag[2..] };
            compile.root_module.addLibraryPath(path);
        } else if (std.mem.eql(u8, flag, "-framework")) {
            const framework = buf_it.next() orelse continue;
            compile.root_module.linkFramework(framework, .{});
        } else if (std.mem.startsWith(u8, flag, "-l")) {
            compile.root_module.linkSystemLibrary(flag[2..], .{});
        }
    }
}

pub fn runtimeIsLimitedApi(runtime: Runtime) bool {
    return std.mem.startsWith(u8, runtime, "cpython3-limited") or
        std.mem.startsWith(u8, runtime, "cpython3_limited");
}

pub fn runtimeIsHeadless(runtime: Runtime) bool {
    return std.mem.eql(u8, runtime, "headless");
}

pub fn resolveRuntime(requested: []const u8, py: PythonConfig) !Runtime {
    if (std.mem.eql(u8, requested, "auto")) {
        return switch (py.major) {
            2 => "cpython2",
            3 => "cpython3",
            else => return error.UnsupportedPythonMajor,
        };
    }

    if (std.mem.eql(u8, requested, "headless")) {
        return "headless";
    }

    if (std.mem.eql(u8, requested, "cpython2")) {
        if (py.major != 2) return error.RuntimePythonVersionMismatch;
        return "cpython2";
    }

    if (std.mem.eql(u8, requested, "cpython3")) {
        if (py.major != 3) return error.RuntimePythonVersionMismatch;
        return "cpython3";
    }

    if (std.mem.eql(u8, requested, "cpython3-limited") or
        std.mem.eql(u8, requested, "cpython3_limited"))
    {
        if (py.major != 3) return error.RuntimePythonVersionMismatch;
        return "cpython3-limited";
    }

    return requested;
}

/// Locate the default python-config executable for the host environment.
///
/// `PYMZ_PYTHON_CONFIG` may contain a semicolon-separated candidate list. The
/// first usable entry wins. Otherwise we try the host-default Python 3
/// executable names.
pub fn resolveDefaultPythonConfig(b: *std.Build) ![]const u8 {
    if (std.c.getenv("PYMZ_PYTHON_CONFIG")) |cfg| {
        if (try resolvePythonConfigFromEnvCandidates(b, std.mem.span(cfg), null)) |candidate| {
            return candidate;
        }
        return error.PythonConfigNotFound;
    }

    const candidates = .{
        "python3-config",
        "python-config",
    };

    inline for (candidates) |cand| {
        if (std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ cand, "--includes" },
        })) |result| {
            const ok = result.term == .exited and result.term.exited == 0;
            b.allocator.free(result.stdout);
            b.allocator.free(result.stderr);
            if (ok) return b.dupe(cand);
        } else |_| {}
    }

    return error.PythonConfigNotFound;
}

/// Locate a python-config executable matching the requested version.
///
/// `PYMZ_PYTHON_CONFIG` may contain a semicolon-separated candidate list. Each
/// candidate is validated and the first exact version match wins.
pub fn resolvePythonConfigExact(b: *std.Build, version: []const u8) ![]const u8 {
    if (std.c.getenv("PYMZ_PYTHON_CONFIG")) |cfg| {
        if (try resolvePythonConfigFromEnvCandidates(b, std.mem.span(cfg), version)) |candidate| {
            return candidate;
        }
        return error.PythonConfigNotFound;
    }

    const candidates = .{
        b.fmt("python{s}-config", .{version}),
        b.fmt("python{s}-config", .{try majorOnly(version)}),
    };

    inline for (candidates) |cand| {
        if (std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ cand, "--includes" },
        })) |result| {
            const ok = result.term == .exited and result.term.exited == 0;
            b.allocator.free(result.stdout);
            b.allocator.free(result.stderr);
            if (ok) {
                const duped = b.dupe(cand);
                const discovered: ?PythonConfig = discoverPythonConfigExpected(b, duped, version) catch |err| switch (err) {
                    error.PythonVersionMismatch => null,
                    else => return err,
                };
                if (discovered != null) {
                    return duped;
                }
            }
        } else |_| {}
    }

    return error.PythonConfigNotFound;
}

fn resolvePythonConfigFromEnvCandidates(
    b: *std.Build,
    raw: []const u8,
    expected_version: ?[]const u8,
) !?[]const u8 {
    var candidates = std.mem.splitScalar(u8, raw, ';');
    while (candidates.next()) |candidate_raw| {
        const candidate = std.mem.trim(u8, candidate_raw, " \t");
        if (candidate.len == 0) continue;
        const compatible = if (expected_version) |version| blk: {
            const discovered = discoverPythonConfigExpected(b, candidate, version) catch |err| switch (err) {
                error.PythonVersionMismatch => break :blk false,
                else => return err,
            };
            _ = discovered;
            break :blk true;
        } else blk: {
            _ = try discoverPythonConfig(b, candidate);
            break :blk true;
        };
        if (compatible) {
            return b.dupe(candidate);
        }
    }
    return null;
}

/// Like `resolvePythonConfigExact`, but returns null instead of an error.
pub fn resolvePythonConfigMaybe(b: *std.Build, version: []const u8) ?[]const u8 {
    return resolvePythonConfigExact(b, version) catch null;
}

/// Discover all Python build flags from a python-config executable.
pub fn discoverPythonConfig(b: *std.Build, python_config: []const u8) !PythonConfig {
    const python_exec = if (std.mem.endsWith(u8, python_config, "-config"))
        python_config[0 .. python_config.len - 7]
    else
        return error.InvalidPythonConfig;

    const version = try runConfig(b, python_exec, &.{
        "-c",
        "import sys; print('{}.{}'.format(sys.version_info.major, sys.version_info.minor))",
    });

    const includes = try runConfig(b, python_config, &.{"--includes"});
    const ldflags = try runConfig(b, python_config, &.{"--ldflags"});
    const libs = try runConfig(b, python_config, &.{"--libs"});
    const ext_suffix = runConfig(b, python_exec, &.{
        "-c",
        "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or '')",
    }) catch "<unknown>";

    var it = std.mem.splitScalar(u8, version, '.');
    const major = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidVersion, 10);
    const minor = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidVersion, 10);

    return .{
        .version = version,
        .major = major,
        .minor = minor,
        .includes = includes,
        .ldflags = ldflags,
        .libs = libs,
        .ext_suffix = ext_suffix,
    };
}

/// Discover Python configuration and verify that it matches `expected_version`.
pub fn discoverPythonConfigExpected(
    b: *std.Build,
    python_config: []const u8,
    expected_version: []const u8,
) !PythonConfig {
    const py = try discoverPythonConfig(b, python_config);
    const expected = try parsePythonVersion(expected_version);
    if (py.major != expected.major or py.minor != expected.minor) {
        return error.PythonVersionMismatch;
    }
    return py;
}

/// Compute the standard Python extension module filename.
///
/// For native builds we prefer the exact EXT_SUFFIX reported by the target
/// interpreter. For cross builds we synthesize a reasonable suffix from the
/// target triple and Python version.
pub fn computeExtensionName(
    b: *std.Build,
    name: []const u8,
    py: PythonConfig,
    target: std.Build.ResolvedTarget,
    runtime: Runtime,
) []const u8 {
    const os = target.result.os.tag;
    if (runtimeIsLimitedApi(runtime)) {
        if (os == .windows) {
            return b.fmt("{s}.abi3.pyd", .{name});
        }
        return b.fmt("{s}.abi3.so", .{name});
    }

    const is_native = target.query.isNative();
    if (is_native and py.ext_suffix.len > 0 and !std.mem.eql(u8, py.ext_suffix, "<unknown>")) {
        // py.ext_suffix already starts with a dot, e.g. .cpython-312-darwin.so
        return b.fmt("{s}{s}", .{ name, py.ext_suffix });
    }

    const cpu = target.result.cpu.arch;
    const abi = target.result.abi;

    if (py.major < 3) {
        if (os == .windows) {
            return b.fmt("{s}.pyd", .{name});
        }
        return b.fmt("{s}.so", .{name});
    }

    if (os == .windows) {
        const plat = switch (cpu) {
            .x86_64 => "win_amd64",
            .aarch64 => "win_arm64",
            .x86 => "win32",
            else => b.fmt("{s}", .{@tagName(cpu)}),
        };
        return b.fmt("{s}.cp{d}{d}-{s}.pyd", .{ name, py.major, py.minor, plat });
    }

    if (os == .macos) {
        return b.fmt("{s}.cpython-{d}{d}-darwin.so", .{ name, py.major, py.minor });
    }

    if (os == .linux) {
        const arch = @tagName(cpu);
        const abi_tag = switch (abi) {
            .musl => "musl",
            .gnu, .gnuabin32, .gnuabi64, .gnueabi, .gnueabihf, .gnuf32, .gnusf, .gnux32 => "gnu",
            else => @tagName(abi),
        };
        return b.fmt("{s}.cpython-{d}{d}-{s}-linux-{s}.so", .{ name, py.major, py.minor, arch, abi_tag });
    }

    // Fallback for other POSIX-ish targets.
    return b.fmt("{s}.cpython-{d}{d}-{s}.so", .{ name, py.major, py.minor, @tagName(os) });
}

/// Parse a comma-separated list of Python versions (e.g. "3.11,3.12,3.13").
/// Caller owns the returned slice and the strings inside it.
pub fn parseVersions(b: *std.Build, raw: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(b.allocator);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(b.allocator, b.dupe(trimmed));
    }

    return list.toOwnedSlice(b.allocator);
}

pub const CrossTarget = struct {
    triple: []const u8,
    label: []const u8,
};

/// Parse a comma-separated list of cross-compile targets.
///
/// Each entry is either a bare Zig target triple (used as the label) or
/// `triple:label` to give the generated build step a short name.
pub fn parseCrossTargets(b: *std.Build, raw: []const u8) ![]const CrossTarget {
    var list: std.ArrayList(CrossTarget) = .empty;
    errdefer list.deinit(b.allocator);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':');
        const triple = if (colon) |c| trimmed[0..c] else trimmed;
        const label = if (colon) |c| trimmed[c + 1 ..] else trimmed;
        try list.append(b.allocator, .{
            .triple = b.dupe(triple),
            .label = b.dupe(label),
        });
    }

    return list.toOwnedSlice(b.allocator);
}

fn runConfig(b: *std.Build, python_config: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(b.allocator, []const u8, &[_][]const []const u8{ &.{python_config}, args });
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
    });
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        return error.PythonConfigFailed;
    }
    return std.mem.trim(u8, try b.allocator.dupe(u8, result.stdout), " \n\r\t");
}

fn majorOnly(version: []const u8) ![]const u8 {
    const idx = std.mem.indexOfScalar(u8, version, '.') orelse return error.InvalidVersion;
    return version[0..idx];
}

pub fn parsePythonVersion(version: []const u8) !PythonVersion {
    var it = std.mem.splitScalar(u8, version, '.');
    const major = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidVersion, 10);
    const minor = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidVersion, 10);
    return .{
        .major = major,
        .minor = minor,
    };
}

pub const ProjectOptions = struct {
    module_name: []const u8,
    root_source_file: std.Build.LazyPath,
};

/// Build a standalone extension project with stub generation and multi-version
/// smoke-test steps.
pub fn buildProject(
    b: *std.Build,
    options: ProjectOptions,
) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const requested_runtime = b.option(
        []const u8,
        "pymz-runtime",
        "Backend runtime to build: auto, cpython2, cpython3, cpython3-limited, or custom",
    ) orelse "auto";
    const backend_source_raw = b.option(
        []const u8,
        "pymz-backend-source",
        "Root source file for the backend module; defaults to pymz's built-in backend entrypoint",
    );
    const pymz_dep = b.lazyDependency("pymz", .{}) orelse return error.MissingPymzDependency;

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
            break :blk try parseVersions(b, raw);
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
    const cross_targets: []const CrossTarget = blk: {
        if (cross_targets_raw) |raw| {
            break :blk try parseCrossTargets(b, raw);
        }
        break :blk &[_]CrossTarget{
            .{ .triple = "x86_64-linux-musl", .label = "x86_64-linux" },
            .{ .triple = "x86_64-windows-gnu", .label = "x86_64-windows" },
            .{ .triple = "aarch64-linux-musl", .label = "aarch64-linux" },
        };
    };

    const build_step = b.step(
        "example",
        b.fmt("Build the {s} extension", .{options.module_name}),
    );
    const multi_step = b.step(
        "example-multi",
        b.fmt("Build {s} for multiple Python versions and platforms", .{options.module_name}),
    );

    if (isMetadataQuery(b)) {
        return;
    }

    const windows_import_lib: ?std.Build.LazyPath = blk: {
        const raw = std.c.getenv("PYMZ_WINDOWS_IMPORT_LIB") orelse break :blk null;
        const path = std.mem.span(raw);
        break :blk b.path(path);
    };

    const primary_py = blk: {
        if (python_version) |version| {
            const primary_config = try resolvePythonConfigExact(b, version);
            break :blk try discoverPythonConfigExpected(b, primary_config, version);
        }

        const primary_config = try resolveDefaultPythonConfig(b);
        break :blk try discoverPythonConfig(b, primary_config);
    };
    const backend_source_file = if (backend_source_raw) |raw|
        b.path(raw)
    else
        pymz_dep.path("src/pymz_backend.zig");
    const backend_runtime = if (backend_source_raw == null)
        try resolveRuntime(requested_runtime, primary_py)
    else
        requested_runtime;
    const primary_backend_module = createBackendModule(
        b,
        target,
        optimize,
        pymz_dep,
        backend_source_file,
        backend_runtime,
        primary_py,
        backend_source_raw == null and !runtimeIsHeadless(backend_runtime),
    );
    const primary_pymz_module = createPymzModule(
        b,
        target,
        optimize,
        pymz_dep,
        primary_backend_module,
    );
    const stubgen_source = addStubgenSource(b);

    const project_artifact = try addPythonExtension(b, .{
        .name = options.module_name,
        .root_source_file = options.root_source_file,
        .pymz_module = primary_pymz_module,
        .py = primary_py,
        .target = target,
        .optimize = optimize,
        .runtime = backend_runtime,
        .windows_import_lib = windows_import_lib,
    });
    build_step.dependOn(&project_artifact.step);

    const stubgen_backend_module = createBackendModule(
        b,
        b.graph.host,
        optimize,
        pymz_dep,
        backend_source_file,
        backend_runtime,
        primary_py,
        backend_source_raw == null and !runtimeIsHeadless(backend_runtime),
    );
    const stubgen_pymz_module = createPymzModule(
        b,
        b.graph.host,
        optimize,
        pymz_dep,
        stubgen_backend_module,
    );

    const stubgen_extension_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = b.graph.host,
        .optimize = optimize,
    });
    stubgen_extension_module.addImport("pymz", stubgen_pymz_module);

    const stubgen_module = b.createModule(.{
        .root_source_file = stubgen_source,
        .target = b.graph.host,
        .optimize = optimize,
    });
    stubgen_module.addImport("extension", stubgen_extension_module);

    const stubgen_exe = b.addExecutable(.{
        .name = b.fmt("{s}_stubgen", .{options.module_name}),
        .root_module = stubgen_module,
    });
    stubgen_exe.root_module.link_libc = true;
    applyPythonLinkFlags(stubgen_exe, primary_py);
    const run_stubgen = b.addRunArtifact(stubgen_exe);
    const stub_file = run_stubgen.captureStdOut(.{});
    const install_stub = b.addInstallFile(
        stub_file,
        b.pathJoin(&.{ "lib", b.fmt("{s}.pyi", .{options.module_name}) }),
    );
    build_step.dependOn(&install_stub.step);

    var primary_cross_artifacts = try b.allocator.alloc(?*std.Build.Step.InstallFile, cross_targets.len);
    @memset(primary_cross_artifacts, null);

    for (cross_targets, 0..) |cross_target_config, index| {
        if (skip_cross) break;
        const triple = cross_target_config.triple;
        const label = cross_target_config.label;
        const cross_target = b.resolveTargetQuery(
            try std.Target.Query.parse(.{ .arch_os_abi = triple }),
        );
        const cross_backend_module = createBackendModule(
            b,
            cross_target,
            optimize,
            pymz_dep,
            backend_source_file,
            backend_runtime,
            primary_py,
            backend_source_raw == null and !runtimeIsHeadless(backend_runtime),
        );
        const cross_pymz_module = createPymzModule(
            b,
            cross_target,
            optimize,
            pymz_dep,
            cross_backend_module,
        );

        const cross_artifact = try addPythonExtension(b, .{
            .name = options.module_name,
            .root_source_file = options.root_source_file,
            .pymz_module = cross_pymz_module,
            .py = primary_py,
            .target = cross_target,
            .optimize = optimize,
            .runtime = backend_runtime,
            .windows_import_lib = windows_import_lib,
        });
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
        for (versions) |version| {
            const config = resolvePythonConfigMaybe(b, version) orelse {
                std.log.warn("skip python {s}: exact python-config not found", .{version});
                skipped_count += 1;
                continue;
            };
            const py = discoverPythonConfigExpected(b, config, version) catch |err| {
                switch (err) {
                    error.PythonVersionMismatch => {
                        std.log.warn(
                            "skip python {s}: discovered interpreter version mismatch",
                            .{version},
                        );
                        skipped_count += 1;
                        continue;
                    },
                    else => return err,
                }
            };
            const runtime = if (backend_source_raw == null)
                try resolveRuntime(requested_runtime, py)
            else
                requested_runtime;
            const native_backend_module = createBackendModule(
                b,
                target,
                optimize,
                pymz_dep,
                backend_source_file,
                runtime,
                py,
                backend_source_raw == null and !runtimeIsHeadless(runtime),
            );
            const native_pymz_module = createPymzModule(
                b,
                target,
                optimize,
                pymz_dep,
                native_backend_module,
            );

            const native_artifact = try addPythonExtension(b, .{
                .name = options.module_name,
                .root_source_file = options.root_source_file,
                .pymz_module = native_pymz_module,
                .py = py,
                .target = target,
                .optimize = optimize,
                .runtime = runtime,
                .windows_import_lib = windows_import_lib,
            });
            multi_step.dependOn(&native_artifact.step);
            built_count += 1;

            for (cross_targets) |cross_target_config| {
                if (skip_cross) break;
                const triple = cross_target_config.triple;
                const cross_target = b.resolveTargetQuery(
                    try std.Target.Query.parse(.{ .arch_os_abi = triple }),
                );
                if (py.major < 3) {
                    std.log.warn(
                        "skip target {s} for python {s}: Python 2 import loaders do not support tagged multi-platform suffixes",
                        .{ triple, version },
                    );
                    skipped_count += 1;
                } else if (shouldSkipCrossTarget(cross_target)) {
                    std.log.warn(
                        "skip target {s} for python {s}: Windows cross-link requires a target Python import library",
                        .{ triple, version },
                    );
                    skipped_count += 1;
                } else {
                    const cross_backend_module = createBackendModule(
                        b,
                        cross_target,
                        optimize,
                        pymz_dep,
                        backend_source_file,
                        runtime,
                        py,
                        backend_source_raw == null and !runtimeIsHeadless(runtime),
                    );
                    const cross_pymz_module = createPymzModule(
                        b,
                        cross_target,
                        optimize,
                        pymz_dep,
                        cross_backend_module,
                    );
                    const cross_artifact = try addPythonExtension(b, .{
                        .name = options.module_name,
                        .root_source_file = options.root_source_file,
                        .pymz_module = cross_pymz_module,
                        .py = py,
                        .target = cross_target,
                        .optimize = optimize,
                        .runtime = runtime,
                        .windows_import_lib = windows_import_lib,
                    });
                    multi_step.dependOn(&cross_artifact.step);
                    built_count += 1;
                }
            }
        }
    } else {
        multi_step.dependOn(build_step);
        built_count += 1;
        for (cross_targets, 0..) |cross_target_config, index| {
            if (skip_cross) break;
            const triple = cross_target_config.triple;
            const cross_target = b.resolveTargetQuery(
                try std.Target.Query.parse(.{ .arch_os_abi = triple }),
            );
            if (primary_py.major < 3) {
                std.log.warn(
                    "skip target {s} for default host Python: Python 2 import loaders do not support tagged multi-platform suffixes",
                    .{triple},
                );
                skipped_count += 1;
            } else if (shouldSkipCrossTarget(cross_target)) {
                std.log.warn(
                    "skip target {s} for default host Python: Windows cross-link requires a target Python import library",
                    .{triple},
                );
                skipped_count += 1;
            } else {
                multi_step.dependOn(&primary_cross_artifacts[index].?.step);
                built_count += 1;
            }
        }
    }
    std.log.info("{s}-multi plan: {d} build artifact(s), {d} skipped variant(s)", .{
        options.module_name,
        built_count,
        skipped_count,
    });
}

fn createBackendModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pymz_dep: *std.Build.Dependency,
    source_file: std.Build.LazyPath,
    runtime: Runtime,
    py: PythonConfig,
    use_cpython_backend: bool,
) *std.Build.Module {
    const backend_impl = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    if (use_cpython_backend) {
        configureCpythonBackendModuleFromDependency(backend_impl, py, runtime, pymz_dep);
    } else {
        configureBackendModule(backend_impl, runtime);
    }
    return backend_impl;
}

fn createPymzModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pymz_dep: *std.Build.Dependency,
    backend_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = pymz_dep.path("src/pymz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const write_files = b.addWriteFiles();
    const wrapper_source = write_files.add("pymz_backend_wrapper.zig",
        \\const backend_impl = @import("backend_impl");
        \\
        \\pub fn backendSpec() @TypeOf(backend_impl.backendSpec()) {
        \\    return backend_impl.backendSpec();
        \\}
        \\
        \\pub fn Backend() type {
        \\    return backend_impl.Backend();
        \\}
        \\
    );
    module.addAnonymousImport("pymz_backend", .{
        .root_source_file = wrapper_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend_impl", .module = backend_module },
        },
    });
    return module;
}

fn addStubgenSource(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("stubgen.zig",
        \\const std = @import("std");
        \\const extension = @import("extension");
        \\
        \\pub const pymz_stubgen = true;
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    try std.Io.File.stdout().writeStreamingAll(init.io, extension.pymz_module.stubContent());
        \\}
        \\
    );
}

fn shouldSkipCrossTarget(target: std.Build.ResolvedTarget) bool {
    return builtin.os.tag != .windows and target.result.os.tag == .windows;
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
