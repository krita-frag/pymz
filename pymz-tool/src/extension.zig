const std = @import("std");
const python_config = @import("python_config.zig");

pub const PythonConfig = python_config.PythonConfig;
pub const Runtime = python_config.Runtime;
pub const runtimeIsLimitedApi = python_config.runtimeIsLimitedApi;

/// 传递给 `BuildHooks` 回调的上下文。
///
/// 为项目的 `build.zig` 提供足够信息以执行自定义链接、添加 C 源文件或附加额外构建步骤，
/// 无需深入 pymz 内部。
pub const HookContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    py: PythonConfig,
    runtime: Runtime,
};

/// 钩子，允许项目的 `build.zig` 在 pymz 创建扩展模块和产物后进行自定义。
///
/// `configure_module` 在根模块创建且 Python 包含/链接路径已连接后调用，
/// 但在共享库实例化之前。用于调用 `module.linkSystemLibrary`、
/// `module.addCSourceFile`、`module.addIncludePath` 等。
///
/// `configure_artifact` 在 `addLibrary` 返回 `*std.Build.Step.Compile` 后调用。
/// 用于调用 `artifact.dependOn`、`artifact.installHeader` 等。
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

/// 添加 Python 扩展产物的选项。
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

/// 使用目标 Python 解释器发现的 `ext_suffix` 计算平台特定的扩展文件名。
///
/// 对于稳定 ABI（`cpython3-limited`）运行环境，后缀强制为 `.abi3.so`
///（Windows 上为 `.abi3.pyd`），无论主机解释器的 `ext_suffix` 是什么，
/// 后者通常报告带版本标签的名称，如 `.cpython-310-x86_64-linux-gnu.so`。
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

/// 解析以空白分隔的链接器标志字符串（`-L`、`-framework`、`-l`）并将其应用于 `module`。
/// 跳过目标平台上冗余的标志（例如 macOS 上的 `CoreFoundation` 和 `intl`）。
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

/// 向构建中添加 Python 扩展共享库。
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

    // 用于链接 pythonXY.dll 的 Windows 导入库。
    if (options.windows_import_lib) |import_lib| {
        lib.root_module.addObjectFile(import_lib);
    }

    // Python 包含路径。
    var include_it = std.mem.tokenizeScalar(u8, options.py.includes, ' ');
    while (include_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const inc_path = std.mem.trim(u8, flag[2..], " \t\n\r");
            module.addIncludePath(.{ .cwd_relative = inc_path });
        }
    }

    // Python 链接器标志（ldflags 和 libs 使用相同的标志语法）。
    const os_tag = options.target.result.os.tag;
    applyLinkerFlags(module, options.py.ldflags, os_tag);
    applyLinkerFlags(module, options.py.libs, os_tag);

    // macOS framework Python：从第一个包含路径推断 Frameworks 目录，
    // 并在未提供显式 -l 库时直接链接 Python.framework。
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

    // 调用项目提供的钩子，以便 build.zig 可以添加额外的 C 源文件、
    // 链接额外的库或附加安装步骤。
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

/// 添加所有后端实现共享的后端运行环境选项。
pub fn configureBackendModule(module: *std.Build.Module, runtime: Runtime) void {
    const options = module.owner.addOptions();
    options.addOption([]const u8, "runtime", runtime.toString());
    // `is_limited_api` 作为构建选项传递，以便运行环境的 `limiter.zig`
    // 可以读取它而无需导入后端模块或任何跨模块文件
    //（在 Zig 0.16 的单所有者文件规则下会导致冲突）。
    options.addOption(bool, "is_limited_api", runtime.isLimitedApi());
    module.addOptions("pymz_options", options);
}

/// 使用翻译后的 C API 头文件配置内置的 CPython 后端。
///
/// `python_c_header` 是 `addTranslateC` 使用的 C 头文件路径。
/// `compat_include_dir` 是兼容性垫片的额外包含目录。
/// 两个路径均由调用者提供，以便 `pymz-tool/core` 无需知道 `pymz` 包的内部文件布局。
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

/// 配置不需要 CPython C API 的自定义后端模块。
pub fn configureBackendModuleFromDependency(
    module: *std.Build.Module,
    runtime: Runtime,
) void {
    configureBackendModule(module, runtime);
}

/// 创建 `pymz_backend` 实现模块。
///
/// `contract_file` 是后端契约文件（通常为 `pymz/src/contract.zig`）。
/// 它以 `LazyPath` 形式传递，以便 `pymz-tool/core` 不依赖 `pymz` 包的目录结构。
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
    // 与 `pymz` 模块共享单个 `pymz_contract` 模块实例（根植于 `contract.zig`），
    // 使 `contract.zig` 恰好被一个模块拥有，
    // 且可以从 `pymz.zig` 和 `backend.zig` 两者引用而不会产生多模块文件所有权冲突。
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

/// 创建公共 `pymz` 模块。
///
/// `root_file` 是包的根文件（通常为 `pymz/src/pymz.zig`）。
/// 它以 `LazyPath` 形式传递，以便 `pymz-tool/core` 不依赖 `pymz` 包的目录结构。
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
    // 后端模块已通过所选后端源导出 BackendSpec、backendSpec()、Backend() 等。
    // 直接将其重新导出为 `pymz_backend`，而不是生成中间包装文件。
    module.addImport("pymz_backend", backend_module);
    // `pymz.zig` 通过与后端模块共享的同一个 `pymz_contract` 模块实例引用契约类型，
    // 因此 `contract.zig` 恰好被一个模块拥有。
    module.addImport("pymz_contract", contract_module);
    return module;
}