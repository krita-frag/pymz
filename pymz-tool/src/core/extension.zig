const std = @import("std");
const python_config = @import("python_config.zig");

pub const PythonConfig = python_config.PythonConfig;
pub const Runtime = python_config.Runtime;
pub const runtimeIsLimitedApi = python_config.runtimeIsLimitedApi;

/// Context passed to `BuildHooks` callbacks.
///
/// Gives the project's `build.zig` enough information to perform custom
/// linking, add C source files, or attach additional build steps without
/// reaching into pymz internals.
pub const HookContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    py: PythonConfig,
    runtime: Runtime,
};

/// Hooks that let a project's `build.zig` customize the extension module and
/// artifact after pymz has created them.
///
/// `configure_module` is called after the root module is created and the
/// Python include/link paths are wired, but before the shared library is
/// instantiated. Use it to call `module.linkSystemLibrary`,
/// `module.addCSourceFile`, `module.addIncludePath`, etc.
///
/// `configure_artifact` is called after `addLibrary` returns the
/// `*std.Build.Step.Compile`. Use it to call `artifact.dependOn`,
/// `artifact.installHeader`, etc.
pub const BuildHooks = struct {
    configure_module: ?*const fn (
        module: *std.Build.Module,
        ctx: HookContext,
    ) void = null,

    configure_artifact: ?*const fn (
        artifact: *std.Build.Step.Compile,
        ctx: HookContext,
    ) void = null,
};

/// Options for adding a Python extension artifact.
pub const ExtensionOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    pymz_module: *std.Build.Module,
    pymz_dep: *std.Build.Dependency,
    py: PythonConfig,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime: Runtime,
    windows_import_lib: ?std.Build.LazyPath = null,
    hooks: BuildHooks = .{},
};

/// Compute the platform-specific extension filename using the discovered
/// `ext_suffix` from the target Python interpreter.
///
/// For stable-ABI (`cpython3-limited`) runtimes the suffix is forced to
/// `.abi3.so` (or `.abi3.pyd` on Windows) regardless of the host interpreter's
/// `ext_suffix`, which typically reports a versioned tag like
/// `.cpython-310-x86_64-linux-gnu.so`.
pub fn computeExtensionName(
    allocator: std.mem.Allocator,
    name: []const u8,
    runtime: Runtime,
    target: std.Build.ResolvedTarget,
    py: PythonConfig,
) ![:0]const u8 {
    if (runtimeIsLimitedApi(runtime)) {
        const ext: []const u8 = if (target.result.os.tag == .windows) ".abi3.pyd" else ".abi3.so";
        return std.mem.concatWithSentinel(allocator, u8, &.{ name, ext }, 0);
    }
    return std.mem.concatWithSentinel(allocator, u8, &.{ name, py.ext_suffix }, 0);
}

/// Parse a whitespace-separated string of linker flags (`-L`, `-framework`,
/// `-l`) and apply them to `module`. Flags that are redundant on the target
/// platform are skipped (e.g. `CoreFoundation` and `intl` on macOS).
fn applyLinkerFlags(
    module: *std.Build.Module,
    flags: []const u8,
    os_tag: std.Target.Os.Tag,
) void {
    var it = std.mem.tokenizeScalar(u8, flags, ' ');
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-L")) {
            const lib_path = std.mem.trim(u8, flag[2..], " \t\n\r");
            module.addLibraryPath(.{ .cwd_relative = lib_path });
        } else if (std.mem.eql(u8, flag, "-framework")) {
            const framework_raw = it.next() orelse continue;
            const framework = std.mem.trim(u8, framework_raw, " \t\n\r");
            if (os_tag == .macos and std.mem.eql(u8, framework, "CoreFoundation")) continue;
            module.linkFramework(framework, .{});
        } else if (std.mem.startsWith(u8, flag, "-l")) {
            const library = flag[2..];
            if (os_tag == .macos and std.mem.eql(u8, library, "intl")) continue;
            module.linkSystemLibrary(library, .{});
        }
    }
}

/// Add a Python extension shared library to the build.
pub fn addPythonExtension(
    b: *std.Build,
    options: ExtensionOptions,
) !*std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
    });
    module.addImport("pymz", options.pymz_module);

    const ext_name = try computeExtensionName(b.allocator, options.name, options.runtime, options.target, options.py);
    defer b.allocator.free(ext_name);

    const lib = b.addLibrary(.{
        .name = ext_name,
        .root_module = module,
        .linkage = .dynamic,
    });
    lib.root_module.link_libc = true;

    // Windows import library for linking against pythonXY.dll.
    if (options.windows_import_lib) |import_lib| {
        lib.root_module.addObjectFile(import_lib);
    }

    // Python include paths.
    var include_it = std.mem.tokenizeScalar(u8, options.py.includes, ' ');
    while (include_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const inc_path = std.mem.trim(u8, flag[2..], " \t\n\r");
            module.addIncludePath(.{ .cwd_relative = inc_path });
        }
    }

    // Python linker flags (both ldflags and libs use the same flag syntax).
    const os_tag = options.target.result.os.tag;
    applyLinkerFlags(module, options.py.ldflags, os_tag);
    applyLinkerFlags(module, options.py.libs, os_tag);

    // macOS framework Python: infer the Frameworks directory from the first
    // include path and link Python.framework directly when no explicit -l
    // library was provided.
    if (os_tag == .macos) {
        var it = std.mem.tokenizeScalar(u8, options.py.includes, ' ');
        if (it.next()) |first_flag| {
            if (std.mem.startsWith(u8, first_flag, "-I")) {
                const include_dir = first_flag[2..];
                if (std.mem.indexOf(u8, include_dir, ".framework") != null) {
                    var dir = include_dir;
                    for (0..4) |_| {
                        dir = std.fs.path.dirname(dir) orelse break;
                    }
                    if (std.fs.path.dirname(dir)) |frameworks_dir| {
                        module.addFrameworkPath(.{ .cwd_relative = frameworks_dir });
                        module.linkFramework("Python", .{});
                    }
                }
            }
        }
    }

    // Invoke project-supplied hooks so build.zig can add extra C sources,
    // link additional libraries, or attach install steps.
    const ctx: HookContext = .{
        .b = b,
        .target = options.target,
        .optimize = options.optimize,
        .py = options.py,
        .runtime = options.runtime,
    };
    if (options.hooks.configure_module) |hook| {
        hook(module, ctx);
    }
    if (options.hooks.configure_artifact) |hook| {
        hook(lib, ctx);
    }

    return lib;
}

/// Add the backend runtime option shared by all backend implementations.
pub fn configureBackendModule(module: *std.Build.Module, runtime: Runtime) void {
    const options = module.owner.addOptions();
    options.addOption([]const u8, "runtime", runtime.toString());
    // `is_limited_api` is delivered as a build option so the runtime's
    // `limiter.zig` can read it without importing the backend module or any
    // cross-module file (which would conflict under Zig 0.16's single-owner
    // file rule).
    options.addOption(bool, "is_limited_api", runtime.isLimitedApi());
    module.addOptions("pymz_options", options);
}

/// Configure the built-in CPython backend with translated C API headers.
///
/// `python_c_header` is the path to the C header used by `addTranslateC`.
/// `compat_include_dir` is an additional include directory for compatibility
/// shims. Both paths are supplied by the caller so that `pymz-tool/core` does not
/// need to know the `pymz` package's internal file layout.
pub fn configureCpythonBackendModule(
    module: *std.Build.Module,
    py: PythonConfig,
    runtime: Runtime,
    python_c_header: std.Build.LazyPath,
    compat_include_dir: std.Build.LazyPath,
) void {
    const b = module.owner;
    const target = module.resolved_target orelse b.graph.host;
    const optimize = module.optimize orelse .Debug;
    configureBackendModule(module, runtime);
    const translate_c = b.addTranslateC(.{
        .root_source_file = python_c_header,
        .target = target,
        .optimize = optimize,
    });
    translate_c.defineCMacro("PY_SSIZE_T_CLEAN", "1");
    const is_big_endian = target.result.cpu.arch.endian() == .big;
    translate_c.defineCMacro("PY_BIG_ENDIAN", if (is_big_endian) "1" else "0");
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

    translate_c.addIncludePath(compat_include_dir);
    module.addImport("python_c", translate_c.createModule());
}

/// Configure a custom backend module that does not need the CPython C API.
pub fn configureBackendModuleFromDependency(
    module: *std.Build.Module,
    runtime: Runtime,
) void {
    configureBackendModule(module, runtime);
}

/// Create the `pymz_backend` implementation module.
///
/// `contract_file` is the backend contract file (typically `pymz/src/contract.zig`).
/// It is passed as a `LazyPath` so that `pymz-tool/core` does not depend on the
/// `pymz` package's directory structure.
pub fn createBackendModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pymz_core_module: *std.Build.Module,
    contract_module: *std.Build.Module,
    source_file: std.Build.LazyPath,
    runtime: Runtime,
    py: PythonConfig,
    use_cpython_backend: bool,
    python_c_header: ?std.Build.LazyPath,
    compat_include_dir: ?std.Build.LazyPath,
) *std.Build.Module {
    const backend_impl = b.createModule(.{
        .root_source_file = source_file,
        .target = target,
        .optimize = optimize,
    });
    backend_impl.addImport("pymz_core", pymz_core_module);
    // Share the single `pymz_contract` module instance (rooted at
    // `contract.zig`) with the `pymz` module so `contract.zig` is owned by
    // exactly one module and can be referenced from both `pymz.zig` and
    // `backend.zig` without a multi-module file-ownership conflict.
    backend_impl.addImport("pymz_contract", contract_module);
    if (use_cpython_backend) {
        configureCpythonBackendModule(
            backend_impl,
            py,
            runtime,
            python_c_header.?, // caller must provide when CPython backend is used
            compat_include_dir.?,
        );
    } else {
        configureBackendModuleFromDependency(backend_impl, runtime);
    }
    return backend_impl;
}

/// Create the public `pymz` module.
///
/// `root_file` is the package root (typically `pymz/src/pymz.zig`). It is
/// passed as a `LazyPath` so that `pymz-tool/core` does not depend on the `pymz`
/// package's directory structure.
pub fn createPymzModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_file: std.Build.LazyPath,
    backend_module: *std.Build.Module,
    contract_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_file,
        .target = target,
        .optimize = optimize,
    });
    // The backend module already exports BackendSpec, backendSpec(), Backend(),
    // etc. via the selected backend source. Re-export it directly as
    // `pymz_backend` instead of generating an intermediate wrapper file.
    module.addImport("pymz_backend", backend_module);
    // `pymz.zig` references the contract types via the same `pymz_contract`
    // module instance shared with the backend module, so `contract.zig` is
    // owned by exactly one module.
    module.addImport("pymz_contract", contract_module);
    return module;
}
