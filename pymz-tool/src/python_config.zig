//! Python 解释器检测和运行环境标识符辅助工具。

const std = @import("std");
const pymz = @import("pymz");

/// 受支持的 Python 家族运行环境的强类型标识符。
///
/// 从 `pymz` 重新导出，使运行环境契约和构建逻辑共享单一真相源。
pub const RuntimeId = pymz.RuntimeId;

/// 强类型运行环境标识符的向后兼容别名。
pub const Runtime = RuntimeId;

/// 检测到的用于配置编译的 Python 解释器配置。
pub const PythonConfig = struct {
    version: []const u8,
    major: u32,
    minor: u32,
    implementation: []const u8,
    includes: []const u8,
    ldflags: []const u8,
    libs: []const u8,
    ext_suffix: []const u8,
};

/// 检测到的 Python 版本元组。
pub const PythonVersion = struct {
    version: []const u8,
    major: u32,
    minor: u32,
};

/// 构建选项驱动的 Python 配置覆盖。
///
/// 工具通过 `-D` 构建选项传递这些值；`build.zig` 作者可以直接设置它们。
/// 当字段非 null 时，它优先于环境变量和 `python-config` 发现。
pub const PythonOverrides = struct {
    /// `python-config` 脚本的路径。
    config: ?[]const u8 = null,
    /// 原始包含标志，例如 `-I/usr/include/python3.12`。
    includes: ?[]const u8 = null,
    /// 原始链接器标志，例如 `-L/usr/lib -lpython3.12`。
    ldflags: ?[]const u8 = null,
    /// 原始库标志。
    libs: ?[]const u8 = null,
    /// 扩展后缀，例如 `.cpython-312-darwin.so`。
    ext_suffix: ?[]const u8 = null,
    /// Python 版本字符串（例如 `3.12`），用于从原始标志合成配置时使用。
    version: ?[]const u8 = null,

    /// 从对应的 `PYMZ_PYTHON_*` 环境变量填充任何 null 字段。
    /// 实现文档中记录的优先级 `-D 选项 > 环境变量 > python-config`：
    /// 调用者先填充来自 `-D` 选项的字段，然后调用此方法为任何未在命令行上固定的字段拾取环境变量回退。
    /// 仅读取仍为 `null` 的字段的环境变量，因此显式的 `-Dpymz-python-includes` 始终优先于 `PYMZ_PYTHON_INCLUDES`。
    ///
    /// 通过 `b.graph.environ_map` 读取环境变量，避免在 Windows 构建脚本上引入 libc
    /// 依赖（`std.c.getenv` 要求显式链接 libc，而构建脚本默认不链接）。
    pub fn fillFromEnv(self: PythonOverrides, b: *std.Build) PythonOverrides {
        var out = self;
        if (out.config == null) out.config = envOpt(b, "PYMZ_PYTHON_CONFIG");
        if (out.includes == null) out.includes = envOpt(b, "PYMZ_PYTHON_INCLUDES");
        if (out.ldflags == null) out.ldflags = envOpt(b, "PYMZ_PYTHON_LDFLAGS");
        if (out.libs == null) out.libs = envOpt(b, "PYMZ_PYTHON_LIBS");
        if (out.ext_suffix == null) out.ext_suffix = envOpt(b, "PYMZ_PYTHON_EXT_SUFFIX");
        if (out.version == null) out.version = envOpt(b, "PYMZ_PYTHON_VERSION");
        return out;
    }
};

/// 读取可选的环境变量为借用的 `[]const u8` 切片，未设置或为空时返回 `null`。
///
/// 通过 `b.graph.environ_map` 读取（Zig 0.16 构建脚本的环境映射），而非
/// `std.c.getenv`。后者要求构建脚本显式链接 libc，在 Windows 上默认不链接，
/// 会导致 "dependency on libc must be explicitly specified" 错误。
/// `environ_map` 是构建运行器在启动时填充的进程级映射，返回的切片由映射拥有，
/// 生命周期与构建进程一致，因此可安全借用。
fn envOpt(b: *std.Build, name: []const u8) ?[]const u8 {
    const value = b.graph.environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

pub fn runtimeIsLimitedApi(runtime: RuntimeId) bool {
    return runtime.isLimitedApi();
}

/// 接受字符串的变体，供将运行环境作为清单字符串持有的调用者使用（例如 wheel 构建）。
/// 无效的运行环境名称被视为非 limited，与历史 `runtimeIsAbi3` 行为一致。
pub fn runtimeIsLimitedApiByName(runtime: []const u8) bool {
    const id = RuntimeId.fromString(runtime) catch return false;
    return runtimeIsLimitedApi(id);
}

pub fn resolveRuntime(requested: []const u8, py: PythonConfig) !Runtime {
    if (std.mem.eql(u8, requested, "auto")) {
        return RuntimeId.fromPythonMajor(py.major);
    }

    const runtime = RuntimeId.fromString(requested) catch |err| switch (err) {
        error.AutoRuntimeNotResolved => return error.InvalidRuntime,
        else => |e| return e,
    };

    const expected_major = if (runtime.isPython2()) @as(u32, 2) else if (runtime.isPython3()) @as(u32, 3) else null;
    if (expected_major) |major| {
        if (py.major != major) return error.RuntimePythonVersionMismatch;
    }

    return runtime;
}

/// 为主机环境定位默认的 python-config 可执行文件。
///
/// 当 `overrides` 提供了所有原始交叉编译字段（includes/ldflags/libs/ext_suffix/version）时，
/// 返回一个哨兵字符串，以便 `discoverPythonConfig` 可以合成配置而无需调用主机解释器。
pub fn resolveDefaultPythonConfig(
    b: *std.Build,
    overrides: PythonOverrides,
) ![]const u8 {
    if (synthesizeFromOverrides(b, overrides, "")) |_| {
        return b.dupe("python-config");
    }

    if (overrides.config) |cfg| {
        if (try resolvePythonConfigFromEnvCandidates(b, cfg, null)) |candidate| {
            return candidate;
        }
        return error.PythonConfigNotFound;
    }

    // 回退：当没有构建选项或配置文件提供 python-config 路径时，读取 `PYMZ_PYTHON_CONFIG` 环境变量。
    // 直接 `zig build` 调用使用它来定位脚本。
    if (b.graph.environ_map.get("PYMZ_PYTHON_CONFIG")) |cfg| {
        warnEnvVarFallback("PYMZ_PYTHON_CONFIG", "-Dpymz-python-config");
        if (try resolvePythonConfigFromEnvCandidates(b, cfg, null)) |candidate| {
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

pub fn resolvePythonConfigExact(
    b: *std.Build,
    version: []const u8,
    overrides: PythonOverrides,
) ![]const u8 {
    if (synthesizeFromOverrides(b, overrides, version)) |_| {
        return b.dupe("python-config");
    }

    if (overrides.config) |cfg| {
        if (try resolvePythonConfigFromEnvCandidates(b, cfg, version)) |ok| return ok;
        return error.PythonConfigNotFound;
    }

    // 回退：当没有构建选项或配置文件提供路径时，读取版本固定的 `PYMZ_PYTHON_CONFIG_{version}` 环境变量。
    const env_name = b.fmt("PYMZ_PYTHON_CONFIG_{s}", .{version});
    if (b.graph.environ_map.get(env_name)) |cfg| {
        warnEnvVarFallback(env_name, "-Dpymz-python-config");
        if (cfg.len == 0) return error.PythonConfigNotFound;
        if (try resolvePythonConfigFromEnvCandidates(b, cfg, version)) |ok| return ok;
        return error.PythonConfigNotFound;
    }

    const candidate = b.fmt("python{s}-config", .{version});
    if (std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ candidate, "--includes" },
    })) |result| {
        const ok = result.term == .exited and result.term.exited == 0;
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
        if (ok) return b.dupe(candidate);
    } else |_| {}

    return error.PythonConfigNotFound;
}

pub fn resolvePythonConfigMaybe(
    b: *std.Build,
    version: []const u8,
    overrides: PythonOverrides,
) ?[]const u8 {
    return resolvePythonConfigExact(b, version, overrides) catch null;
}

fn resolvePythonConfigFromEnvCandidates(
    b: *std.Build,
    value: []const u8,
    expected_version: ?[]const u8,
) !?[]const u8 {
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |raw| {
        const candidate = std.mem.trim(u8, raw, " \t");
        if (candidate.len == 0) continue;
        if (std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ candidate, "--includes" },
        })) |result| {
            const ok = result.term == .exited and result.term.exited == 0;
            b.allocator.free(result.stdout);
            b.allocator.free(result.stderr);
            if (ok) {
                if (expected_version) |ev| {
                    if (try checkPythonConfigVersion(b, candidate, ev)) {
                        return b.dupe(candidate);
                    }
                } else {
                    return b.dupe(candidate);
                }
            }
        } else |_| {}
    }
    return null;
}

/// 从 `python-config` 脚本路径推导 Python 解释器二进制路径，通过去掉 `-config` 后缀。
/// 如果输入不以 `-config` 结尾，则原样返回。
fn interpreterFromConfig(config: []const u8) []const u8 {
    if (std.mem.endsWith(u8, config, "-config"))
        return config[0 .. config.len - "-config".len];
    return config;
}

/// 通过从 `config` 派生的 Python 解释器运行一个小型探测脚本。
///
/// 这是 `python-config --version` / `--extension-suffix` 的通用替代方案，
/// 这两个标志在 CPython 2.7 上不可用（标志不存在）且在 3.14+ 上被移除（`--version`）。
/// 解释器探测在所有受支持的 CPython 上都能工作：`python -c` 是稳定的，且在 Python 2 和 3 上都写入 stdout，
/// 而 `python --version` 在 Python 2 上写入 stderr，因此无法统一捕获。
fn runInterpreterProbe(
    b: *std.Build,
    config: []const u8,
    script: []const u8,
) ![]const u8 {
    const py_bin = interpreterFromConfig(config);
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ py_bin, "-c", script },
    }) catch return error.PythonConfigFailed;
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        return error.PythonConfigFailed;
    }
    return result.stdout;
}

/// 验证 `config` 背后的解释器是否匹配 `expected_version`。
///
/// 使用通用的 `sys.version_info` 探测，而非 `python-config --version`，
/// 后者在 CPython 2.7 上不存在且在 3.14+ 上被移除。
fn checkPythonConfigVersion(
    b: *std.Build,
    config: []const u8,
    expected_version: []const u8,
) !bool {
    const vout = runInterpreterProbe(
        b,
        config,
        "import sys; print('{}.{}'.format(*sys.version_info[:2]))",
    ) catch return false;
    defer b.allocator.free(vout);
    const v = std.mem.trim(u8, vout, " \t\n\r");
    return std.mem.eql(u8, v, expected_version);
}

/// 从显式的覆盖值合成 `PythonConfig`。当覆盖值不包含足够的字段来绕过 `python-config` 时返回 `null`。
///
/// 必需的字段为：`includes`、`ldflags`、`ext_suffix` 和 `version`（或 `libs` 作为链接器集的回退）。
fn synthesizeFromOverrides(
    b: *std.Build,
    overrides: PythonOverrides,
    version: []const u8,
) ?PythonConfig {
    const includes = overrides.includes orelse return null;
    const ldflags = overrides.ldflags orelse return null;
    const ext_suffix = overrides.ext_suffix orelse return null;
    const version_str = overrides.version orelse return null;

    if (version.len != 0 and !std.mem.eql(u8, version, version_str)) return null;

    const parsed = parsePythonVersion(b, version_str) catch return null;

    return PythonConfig{
        .version = parsed.version,
        .major = parsed.major,
        .minor = parsed.minor,
        .implementation = "cpython",
        .includes = includes,
        .ldflags = ldflags,
        .libs = overrides.libs orelse "",
        .ext_suffix = ext_suffix,
    };
}

fn warnEnvVarFallback(name: []const u8, replacement: []const u8) void {
    std.log.warn(
        "environment variable {s} is read as fallback; prefer the {s} build option",
        .{ name, replacement },
    );
}

pub fn discoverPythonConfigExpected(
    b: *std.Build,
    config: []const u8,
    version: []const u8,
    overrides: PythonOverrides,
) !PythonConfig {
    const py = try discoverPythonConfig(b, config, overrides);
    const expected_major = try parsePythonMajor(version);
    if (py.major != expected_major) return error.PythonVersionMismatch;
    return py;
}

pub fn discoverPythonConfig(
    b: *std.Build,
    config: []const u8,
    overrides: PythonOverrides,
) !PythonConfig {
    if (synthesizeFromOverrides(b, overrides, "")) |py| return py;

    // 通过通用的解释器探测确定版本（见 `runInterpreterProbe`），
    // 它在 CPython 2.7 和 3.x（包括 3.14+，其中 `python-config --version` 已被移除）上都能工作。
    const version = blk: {
        const vout = runInterpreterProbe(
            b,
            config,
            "import sys; print('{}.{}'.format(*sys.version_info[:2]))",
        ) catch return error.PythonConfigFailed;
        defer b.allocator.free(vout);
        break :blk b.dupe(std.mem.trim(u8, vout, " \t\n\r"));
    };

    const parsed = try parsePythonVersion(b, version);

    const argv_includes = &.{ config, "--includes" };
    const includes = try runPythonConfig(b, argv_includes);
    errdefer b.allocator.free(includes);

    // Python 3.8+ 弃用了在普通 `--ldflags` 中嵌入模块链接。
    // Python 3.14 完全从 `--ldflags` 输出中移除了 `-lpython`，
    // 因此我们首先尝试 `--embed`（Python 3.8+），对于较旧的解释器回退到普通 `--ldflags`。
    const argv_ldflags: []const []const u8 = if (parsed.major > 3 or (parsed.major == 3 and parsed.minor >= 8))
        &.{ config, "--ldflags", "--embed" }
    else
        &.{ config, "--ldflags" };
    const ldflags = blk: {
        if (runPythonConfig(b, argv_ldflags)) |out| {
            break :blk out;
        } else |_| {
            // 回退：--embed 不受支持（Python < 3.8）。
            break :blk try runPythonConfig(b, &.{ config, "--ldflags" });
        }
    };
    errdefer b.allocator.free(ldflags);

    const argv_libs = &.{ config, "--libs" };
    const libs = try runPythonConfig(b, argv_libs);
    errdefer b.allocator.free(libs);

    // `python-config --extension-suffix` 在 CPython 2.7 上不可用。
    // 直接查询解释器（3.x 上用 EXT_SUFFIX，2.7 上用 SO），
    // 在无法运行解释器的环境中（例如只有配置脚本可用的交叉编译）回退到 `--extension-suffix`。
    const ext_suffix = blk: {
        const sout = runInterpreterProbe(
            b,
            config,
            "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or sysconfig.get_config_var('SO') or '')",
        ) catch {
            break :blk runPythonConfig(b, &.{ config, "--extension-suffix" }) catch return error.PythonConfigFailed;
        };
        defer b.allocator.free(sout);
        break :blk b.dupe(std.mem.trim(u8, sout, " \t\n\r"));
    };
    errdefer b.allocator.free(ext_suffix);

    return PythonConfig{
        .version = parsed.version,
        .major = parsed.major,
        .minor = parsed.minor,
        .implementation = "cpython",
        .includes = includes,
        .ldflags = ldflags,
        .libs = libs,
        .ext_suffix = ext_suffix,
    };
}

fn runPythonConfig(b: *std.Build, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
    });
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
        return error.PythonConfigFailed;
    }
    b.allocator.free(result.stderr);
    return result.stdout;
}

pub fn parseVersions(b: *std.Build, raw: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| b.allocator.free(item);
        list.deinit(b.allocator);
    }
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(b.allocator, b.dupe(trimmed));
    }
    return list.toOwnedSlice(b.allocator);
}

pub fn parsePythonVersion(b: *std.Build, version: []const u8) !PythonVersion {
    const trimmed = std.mem.trim(u8, version, " \t\n\r");
    var it = std.mem.splitScalar(u8, trimmed, '.');
    const major_str = it.next() orelse return error.InvalidPythonVersion;
    const minor_str = it.next() orelse return error.InvalidPythonVersion;
    const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidPythonVersion;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidPythonVersion;
    return PythonVersion{
        .version = b.fmt("{d}.{d}", .{ major, minor }),
        .major = major,
        .minor = minor,
    };
}

fn parsePythonMajor(version: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, version, " \t\n\r");
    var it = std.mem.splitScalar(u8, trimmed, '.');
    const major_str = it.next() orelse return error.InvalidPythonVersion;
    return std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidPythonVersion;
}

test "limited API is restricted to CPython 3.10 and newer" {
    try std.testing.expect(runtimeIsLimitedApi(RuntimeId.cpython3_limited));
    try std.testing.expect(!runtimeIsLimitedApi(RuntimeId.cpython3));
}

test "runtime id parses canonical and alias names" {
    try std.testing.expectEqual(RuntimeId.cpython2, try RuntimeId.fromString("cpython2"));
    try std.testing.expectEqual(RuntimeId.cpython3, try RuntimeId.fromString("cpython3"));
    try std.testing.expectEqual(RuntimeId.cpython3_limited, try RuntimeId.fromString("cpython3-limited"));
    try std.testing.expectEqual(RuntimeId.cpython3_limited, try RuntimeId.fromString("cpython3_limited"));
    try std.testing.expectError(error.InvalidRuntime, RuntimeId.fromString("unknown"));
    try std.testing.expectError(error.AutoRuntimeNotResolved, RuntimeId.fromString("auto"));
}

test "PythonOverrides defaults to all-null" {
    const overrides: PythonOverrides = .{};
    try std.testing.expect(overrides.config == null);
    try std.testing.expect(overrides.includes == null);
    try std.testing.expect(overrides.ldflags == null);
    try std.testing.expect(overrides.libs == null);
    try std.testing.expect(overrides.ext_suffix == null);
    try std.testing.expect(overrides.version == null);
}
