//! pymz 构建脚手架 - 跨 Python 版本和目标平台构建 Python 扩展的可复用辅助工具。
//!
//! 从项目的 `build.zig` 中导入此文件以获取：
//!   * Python 配置检测（python-config / sysconfig）
//!   * 自动的 Python 扩展文件命名（cpython-XY-platform.so 等）
//!   * 跨平台链接规则（Unix 运行时链接、Windows 导入库）
//!
//! 实现细节位于同级模块中；此文件是公共入口点，负责编排 `buildProject`。

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

/// 暴露给 `buildProject` 调用者的错误类型。
/// 用户可操作的选项问题与缺少依赖的错误区分开，以便调用者可以提供有帮助的消息而非 panic 堆栈。
/// `OutOfMemory` 被包含在内，因为构建图分配（例如交叉目标产物槽）通过构建分配器进行。
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
    /// 扩展模块的根源文件。**必需**——Zig 构建系统（build.zig）是配置 Zig 源文件布局的规范位置，而非 pyproject.toml。
    root_source_file: std.Build.LazyPath,
    /// 可选的默认步骤名称；默认为 `module_name`。
    step_name: ?[]const u8 = null,
    /// 可选的默认多步骤名称；默认为 `{module_name}-multi`。
    multi_step_name: ?[]const u8 = null,
    /// 可选的自定义链接、C 源文件或安装步骤的钩子。
    hooks: BuildHooks = .{},

    /// `pymz` 包根源文件的路径。默认为 `pymz` 依赖中的 `pymz/src/pymz.zig`。
    pymz_root_file: ?std.Build.LazyPath = null,
    /// 后端契约文件的路径。默认为 `pymz/src/contract.zig`。
    pymz_contract_file: ?std.Build.LazyPath = null,
    /// 默认后端实现的路径。默认为 `pymz/src/backend.zig`。
    pymz_backend_file: ?std.Build.LazyPath = null,
    /// CPython 后端使用的 C 头文件路径。默认为 `pymz/src/runtime/cpython/python_c.h`。
    pymz_python_c_header: ?std.Build.LazyPath = null,
    /// CPython 兼容性包含目录的路径。默认为 `pymz/src/runtime/cpython`。
    pymz_cpython_include_dir: ?std.Build.LazyPath = null,
};

/// 构建独立的扩展项目，附带多版本烟雾测试步骤。
///
/// 返回主要的（主机目标）扩展产物，当构建仅响应元数据查询（例如 `--help` 或 `--list-steps`）
/// 且未产生任何产物时返回 `null`。
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

    // 解析 pymz 文件路径。调用者可以覆盖其中任何一个，以将项目与默认的 pymz 包布局解耦。
    const pymz_root_file = options.pymz_root_file orelse pymz_dep.path("src/pymz.zig");
    const pymz_contract_file = options.pymz_contract_file orelse pymz_dep.path("src/contract.zig");
    const pymz_backend_file = options.pymz_backend_file orelse pymz_dep.path("src/backend.zig");
    const pymz_python_c_header = options.pymz_python_c_header orelse pymz_dep.path("src/runtime/cpython/python_c.h");
    const pymz_cpython_include_dir = options.pymz_cpython_include_dir orelse pymz_dep.path("src/runtime/cpython");
    const pymz_tool_dep = b.lazyDependency("pymz-tool", .{}) orelse return error.MissingPymzToolDependency;
    const pymz_core_module = b.createModule(.{
        .root_source_file = pymz_tool_dep.path("src/main.zig"),
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

    // 构建选项驱动的 Python 配置覆盖。`build.zig` 作者通过 `-D` 选项直接设置它们；
    // 当字段非 null 时，它优先于环境变量和 python-config。
    // `fillFromEnv` 为任何未在命令行上固定的字段拾取 `PYMZ_PYTHON_*` 环境变量，
    // 实现文档中记录的 `-D 选项 > 环境变量 > python-config` 优先级。
    const python_overrides: PythonOverrides = blk: {
        const from_options: PythonOverrides = .{
            .config = b.option([]const u8, "pymz-python-config", "Path to python-config script"),
            .includes = b.option([]const u8, "pymz-python-includes", "Raw Python include flags (cross-compile)"),
            .ldflags = b.option([]const u8, "pymz-python-ldflags", "Raw Python linker flags (cross-compile)"),
            .libs = b.option([]const u8, "pymz-python-libs", "Raw Python library flags (cross-compile)"),
            .ext_suffix = b.option([]const u8, "pymz-python-ext-suffix", "Python extension suffix (cross-compile)"),
            .version = b.option([]const u8, "pymz-python-version", "Python version for synthesised config (e.g. 3.12)"),
        };
        break :blk from_options.fillFromEnv(b);
    };

    const windows_import_lib: ?std.Build.LazyPath = blk: {
        const import_lib_opt = b.option(
            []const u8,
            "pymz-windows-import-lib",
            "Path to the Python import library for Windows cross-linking",
        );
        if (import_lib_opt) |raw| break :blk b.path(raw);

        // 回退：当未提供 `-Dpymz-windows-import-lib` 构建选项时，读取 `PYMZ_WINDOWS_IMPORT_LIB` 环境变量。
        // 通过 `b.graph.environ_map` 读取，避免 `std.c.getenv` 在 Windows 构建脚本上的 libc 依赖。
        if (b.graph.environ_map.get("PYMZ_WINDOWS_IMPORT_LIB")) |env_value| {
            std.log.warn("PYMZ_WINDOWS_IMPORT_LIB env var read as fallback; prefer -Dpymz-windows-import-lib", .{});
            break :blk b.path(env_value);
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

    // 在主机构建和每个交叉目标中保持不变的输入一次性捕获到 `ext_ctx` 中，
    // 以便每个目标构建辅助函数只需要实际变化的参数：目标、Python 配置、运行环境。
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
    // 将主机产物安装到 `<prefix>/lib` 下，使用精确的 Python 扩展文件名
    // （例如 `_jsonz.cpython-314-darwin.so`）。不使用 `installArtifact`，
    // 因为库的 `name` 携带完整的扩展后缀，Zig 会将其变形为 `lib<name>.dylib`；
    // 使用产物的 `name` 作为目标名称安装发出的二进制文件，
    // 保留 Python 导入机制和 `collect_artifacts` 期望的后缀。
    const install_host = b.addInstallFileWithDir(
        project_artifact.getEmittedBin(),
        .lib,
        project_artifact.name,
    );
    build_step.dependOn(&install_host.step);
    build_step.dependOn(&project_artifact.step);

    // 预先构建主机 OS 的交叉产物一次，以便多步骤可以依赖它们，
    // 在迭代 Python 版本时无需重新构建。
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
        // 按版本矩阵：对于每个 Python 版本，构建本地产物以及每个
        // OS 与主机匹配的交叉目标。
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
        // 没有显式版本：多步骤就是主机构建加上
        // 预先构建的主机 OS 交叉产物。
        multi_step.dependOn(build_step);
        built_count += 1;
        for (cross_targets, 0..) |cross_target_config, index| {
            if (skip_cross) break;
            const triple = cross_target_config.triple;
            const cross_target = resolveCrossTarget(b, triple) catch return error.InvalidOption;
            if (crossTargetShouldSkip(primary_py, cross_target, triple, "default host Python")) {
                skipped_count += 1;
                continue;
            }
            multi_step.dependOn(&primary_cross_artifacts[index].?.step);
            built_count += 1;
        }
    }
    std.log.info("{s} plan: {d} build artifact(s), {d} skipped variant(s)", .{
        multi_step_name,
        built_count,
        skipped_count,
    });

    return project_artifact;
}

/// 解析构建单元格的后端运行环境。
///
/// 当未提供自定义后端源时，运行环境从 Python 主版本号自动解析
///（或显式的 `requested_runtime`）。
/// 自定义后端源需要显式指定运行环境，因为自动解析依赖于 CPython 的 `python-config` 发现。
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

/// 检查给定 Python 配置的交叉编译目标是否应跳过。
/// 记录原因并在目标无法构建时返回 `true`；
/// 调用者应继续时返回 `false`。
///
/// 由 `wireCrossTargetsForVersion`（按版本矩阵）和默认主机 Python 的 else 分支共享，
/// 使跳过策略保持在同一位置。
fn crossTargetShouldSkip(
    py: PythonConfig,
    cross_target: std.Build.ResolvedTarget,
    triple: []const u8,
    context_label: []const u8,
) bool {
    if (py.major < 3) {
        std.log.warn(
            "skip target {s} for {s}: Python 2 import loaders do not support tagged multi-platform suffixes",
            .{ triple, context_label },
        );
        return true;
    }
    if (cross.shouldSkipCrossTarget(cross_target)) {
        std.log.warn(
            "skip target {s} for {s}: cross-linking requires a target Python toolchain",
            .{ triple, context_label },
        );
        return true;
    }
    return false;
}

/// 为一个 Python 版本连接交叉目标产物到 `multi_step`。
///
/// 返回实际构建的交叉产物数量。跳过策略：
/// Python 2 无法发出带标签的多平台后缀，且交叉链接到非主机 OS 需要主机没有的目标 Python 工具链。
/// 两种情况均被记录并计为跳过，而非使构建失败。
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
        const context = b.fmt("python {s}", .{version});
        if (crossTargetShouldSkip(py, cross_target, triple, context)) {
            skipped_count.* += 1;
            continue;
        }
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
    return built;
}

/// 在单个 `buildProject` 调用中，主机目标和每个交叉目标变体构建 Python 扩展产物的共享输入。
///
/// 一次性捕获这些输入，使 `buildExtensionArtifact` 仅需变化每个产物实际不同的部分：
/// `target`、`py` 和 `runtime`。
const ExtensionBuildContext = struct {
    optimize: std.builtin.OptimizeMode,
    pymz_core_module: *std.Build.Module,
    pymz_contract_file: std.Build.LazyPath,
    pymz_root_file: std.Build.LazyPath,
    backend_source_file: std.Build.LazyPath,
    /// 预解析的可选 CPython 后端输入：使用默认后端时两者均非 null，
    /// 自定义后端源覆盖时两者均为 null。`use_cpython_backend` 由此派生。
    backend_python_c_header: ?std.Build.LazyPath,
    backend_cpython_include_dir: ?std.Build.LazyPath,
    pymz_dep: *std.Build.Dependency,
    project_source: std.Build.LazyPath,
    module_name: []const u8,
    windows_import_lib: ?std.Build.LazyPath,
    hooks: BuildHooks,
};

/// 为给定目标、Python 配置和运行环境构建单个 Python 扩展产物
///（后端模块 + pymz 模块 + 扩展共享库）。
///
/// 封装 `createBackendModule` -> `createPymzModule` -> `addPythonExtension` 序列，
/// 用于主机构建和每个交叉目标变体。
/// 调用者将返回的产物连接到适当的构建步骤（`build_step`、`multi_step` 或每个目标的 `cross_step`）。
fn buildExtensionArtifact(
    b: *std.Build,
    ctx: ExtensionBuildContext,
    target: std.Build.ResolvedTarget,
    py: PythonConfig,
    runtime: Runtime,
) !*std.Build.Step.Compile {
    const use_cpython_backend = ctx.backend_python_c_header != null;
    // 契约模块（`contract.zig`）创建一次，由后端模块和 pymz 模块共享，
    // 使文件恰好被一个模块拥有。`contract.zig` 仅导入 `std`，因此不需要目标或 Python 配置。
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

/// 将交叉编译三元组解析为 `ResolvedTarget`。
///
/// 每个交叉目标循环共享此函数，使解析调用点保持一致，且循环专注于跳过策略和步骤连接。
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
