//! pymz build scaffold — reusable helpers for building Python extensions
//! with Zig across Python versions and target platforms.
//!
//! Import this file from a project's `build.zig` to get:
//!   * Python configuration detection (python-config / sysconfig)
//!   * Automatic Python-extension file naming (cpython-XY-platform.so, etc.)
//!   * Cross-platform linking rules (Unix runtime-link, Windows import-lib)

const builtin = @import("builtin");
const std = @import("std");

const default_cross_targets = .{
    // musl is used for Linux cross targets because the Zig toolchain ships
    // musl headers without _Float128 issues. To run on glibc Python builds
    // you still need to provide target Python headers/libs separately.
    .{ "x86_64-linux-musl", "x86_64-linux" },
    .{ "x86_64-windows-gnu", "x86_64-windows" },
    .{ "aarch64-linux-musl", "aarch64-linux" },
};

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

pub const Runtime = enum {
    cpython2,
    cpython3,

    pub fn name(self: Runtime) []const u8 {
        return switch (self) {
            .cpython2 => "cpython2",
            .cpython3 => "cpython3",
        };
    }
};

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
    /// Runtime backend selected for this extension.
    runtime: Runtime,
    /// If true, link the Python import library on Windows. Most projects want
    /// this; set to false only if you supply your own import lib.
    link_python_on_windows: bool = true,
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
    configurePythonModule(root, options.py, options.runtime);

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

    const ext_name = computeExtensionName(b, options.name, options.py, options.target);
    return b.addInstallFile(lib.getEmittedBin(), b.pathJoin(&.{ "lib", ext_name }));
}

/// Add Python include paths, version macros, and the translated CPython C API
/// module so pymz can specialize via comptime.
pub fn configurePythonModule(module: *std.Build.Module, py: PythonConfig, runtime: Runtime) void {
    const pymz_dep = module.owner.dependency("pymz", .{});
    configurePythonModuleFromDependency(module, py, runtime, pymz_dep);
}

pub fn configurePythonModuleFromDependency(
    module: *std.Build.Module,
    py: PythonConfig,
    runtime: Runtime,
    pymz_dep: *std.Build.Dependency,
) void {
    const b = module.owner;
    const target = module.resolved_target orelse b.graph.host;
    const optimize = module.optimize orelse .Debug;
    const translate_c = b.addTranslateC(.{
        .root_source_file = pymz_dep.path("src/runtime/cpython/python_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.defineCMacro("PY_SSIZE_T_CLEAN", "1");

    module.addCMacro("PY_SSIZE_T_CLEAN", "1");
    module.addCMacro("PYMZ_PYTHON_MAJOR", module.owner.fmt("{d}", .{py.major}));
    module.addCMacro("PYMZ_PYTHON_MINOR", module.owner.fmt("{d}", .{py.minor}));
    const options = b.addOptions();
    options.addOption([]const u8, "runtime", runtime.name());
    module.addOptions("pymz_options", options);

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

pub fn resolveRuntime(requested: []const u8, py: PythonConfig) !Runtime {
    const runtime: Runtime = if (std.mem.eql(u8, requested, "auto"))
        switch (py.major) {
            2 => .cpython2,
            3 => .cpython3,
            else => return error.UnsupportedPythonMajor,
        }
    else if (std.mem.eql(u8, requested, "cpython2"))
        .cpython2
    else if (std.mem.eql(u8, requested, "cpython3"))
        .cpython3
    else
        return error.UnsupportedRuntime;

    switch (runtime) {
        .cpython2 => if (py.major != 2) return error.RuntimePythonVersionMismatch,
        .cpython3 => if (py.major != 3) return error.RuntimePythonVersionMismatch,
    }
    return runtime;
}

/// Locate the default python-config executable for the host environment.
///
/// `PYMZ_PYTHON_CONFIG` environment variable takes precedence. Otherwise we try
/// the host-default Python 3 executable names.
pub fn resolveDefaultPythonConfig(b: *std.Build) ![]const u8 {
    if (std.c.getenv("PYMZ_PYTHON_CONFIG")) |cfg| {
        return b.dupe(std.mem.span(cfg));
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
/// `PYMZ_PYTHON_CONFIG` is allowed, but the discovered interpreter must still
/// match `version` exactly or discovery fails with `error.PythonVersionMismatch`.
pub fn resolvePythonConfigExact(b: *std.Build, version: []const u8) ![]const u8 {
    if (std.c.getenv("PYMZ_PYTHON_CONFIG")) |cfg| {
        const candidate = b.dupe(std.mem.span(cfg));
        _ = try discoverPythonConfigExpected(b, candidate, version);
        return candidate;
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
) []const u8 {
    const is_native = target.query.isNative();
    if (is_native and py.ext_suffix.len > 0 and !std.mem.eql(u8, py.ext_suffix, "<unknown>")) {
        // py.ext_suffix already starts with a dot, e.g. .cpython-312-darwin.so
        return b.fmt("{s}{s}", .{ name, py.ext_suffix });
    }

    const cpu = target.result.cpu.arch;
    const os = target.result.os.tag;
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
        "Runtime backend to build: auto, cpython2, cpython3",
    ) orelse "auto";
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

    const primary_py = blk: {
        if (python_version) |version| {
            const primary_config = try resolvePythonConfigExact(b, version);
            break :blk try discoverPythonConfigExpected(b, primary_config, version);
        }

        const primary_config = try resolveDefaultPythonConfig(b);
        break :blk try discoverPythonConfig(b, primary_config);
    };
    const primary_runtime = try resolveRuntime(requested_runtime, primary_py);
    const primary_pymz_module = createPymzModule(
        b,
        target,
        optimize,
        primary_py,
        primary_runtime,
        pymz_dep,
    );
    const stubgen_source = addStubgenSource(b);

    const project_artifact = try addPythonExtension(b, .{
        .name = options.module_name,
        .root_source_file = options.root_source_file,
        .pymz_module = primary_pymz_module,
        .py = primary_py,
        .target = target,
        .optimize = optimize,
        .runtime = primary_runtime,
    });
    build_step.dependOn(&project_artifact.step);

    const stubgen_pymz_module = b.createModule(.{
        .root_source_file = pymz_dep.path("src/pymz.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    configurePythonModuleFromDependency(stubgen_pymz_module, primary_py, primary_runtime, pymz_dep);

    const stubgen_extension_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = b.graph.host,
        .optimize = optimize,
    });
    stubgen_extension_module.addImport("pymz", stubgen_pymz_module);
    configurePythonModuleFromDependency(stubgen_extension_module, primary_py, primary_runtime, pymz_dep);

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
    const run_stubgen = b.addRunArtifact(stubgen_exe);
    const stub_file = run_stubgen.captureStdOut(.{});
    const install_stub = b.addInstallFile(
        stub_file,
        b.pathJoin(&.{ "lib", b.fmt("{s}.pyi", .{options.module_name}) }),
    );
    build_step.dependOn(&install_stub.step);

    var primary_cross_artifacts: [default_cross_targets.len]*std.Build.Step.InstallFile = undefined;

    inline for (default_cross_targets, 0..) |cross_target_config, index| {
        const triple = cross_target_config[0];
        const label = cross_target_config[1];
        const cross_target = b.resolveTargetQuery(
            try std.Target.Query.parse(.{ .arch_os_abi = triple }),
        );
        const cross_pymz_module = createPymzModule(
            b,
            cross_target,
            optimize,
            primary_py,
            primary_runtime,
            pymz_dep,
        );

        const cross_artifact = try addPythonExtension(b, .{
            .name = options.module_name,
            .root_source_file = options.root_source_file,
            .pymz_module = cross_pymz_module,
            .py = primary_py,
            .target = cross_target,
            .optimize = optimize,
            .runtime = primary_runtime,
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
            const runtime = try resolveRuntime(requested_runtime, py);
            const native_pymz_module = createPymzModule(
                b,
                target,
                optimize,
                py,
                runtime,
                pymz_dep,
            );

            const native_artifact = try addPythonExtension(b, .{
                .name = options.module_name,
                .root_source_file = options.root_source_file,
                .pymz_module = native_pymz_module,
                .py = py,
                .target = target,
                .optimize = optimize,
                .runtime = runtime,
            });
            multi_step.dependOn(&native_artifact.step);
            built_count += 1;

            inline for (default_cross_targets) |cross_target_config| {
                const triple = cross_target_config[0];
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
                    const cross_pymz_module = createPymzModule(
                        b,
                        cross_target,
                        optimize,
                        py,
                        runtime,
                        pymz_dep,
                    );
                    const cross_artifact = try addPythonExtension(b, .{
                        .name = options.module_name,
                        .root_source_file = options.root_source_file,
                        .pymz_module = cross_pymz_module,
                        .py = py,
                        .target = cross_target,
                        .optimize = optimize,
                        .runtime = runtime,
                    });
                    multi_step.dependOn(&cross_artifact.step);
                    built_count += 1;
                }
            }
        }
    } else {
        multi_step.dependOn(build_step);
        built_count += 1;
        inline for (default_cross_targets, 0..) |cross_target_config, index| {
            const triple = cross_target_config[0];
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
                multi_step.dependOn(&primary_cross_artifacts[index].step);
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

fn createPymzModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    py: PythonConfig,
    runtime: Runtime,
    pymz_dep: *std.Build.Dependency,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = pymz_dep.path("src/pymz.zig"),
        .target = target,
        .optimize = optimize,
    });
    configurePythonModuleFromDependency(module, py, runtime, pymz_dep);
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
