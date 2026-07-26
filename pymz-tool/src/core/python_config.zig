//! Python interpreter detection and runtime identifier helpers.

const std = @import("std");
const pymz = @import("pymz");

/// Strongly-typed identifier for a supported Python-family runtime.
///
/// Re-exported from `pymz` so the runtime contract and build logic share a
/// single source of truth.
pub const RuntimeId = pymz.RuntimeId;

/// Backward-compatible alias for the strongly-typed runtime identifier.
pub const Runtime = RuntimeId;

/// Detected Python interpreter configuration used to configure compilation.
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

/// Detected Python version tuple.
pub const PythonVersion = struct {
    version: []const u8,
    major: u32,
    minor: u32,
};

/// Build-option-driven overrides for Python configuration.
///
/// The tool passes these via ``-D`` build options; ``build.zig`` authors can
/// set them directly. When a field is non-null it takes precedence over both
/// environment variables and ``python-config`` discovery.
pub const PythonOverrides = struct {
    /// Path to the ``python-config`` script.
    config: ?[]const u8 = null,
    /// Raw include flags, e.g. ``-I/usr/include/python3.12``.
    includes: ?[]const u8 = null,
    /// Raw linker flags, e.g. ``-L/usr/lib -lpython3.12``.
    ldflags: ?[]const u8 = null,
    /// Raw library flags.
    libs: ?[]const u8 = null,
    /// Extension suffix, e.g. ``.cpython-312-darwin.so``.
    ext_suffix: ?[]const u8 = null,
    /// Python version string (e.g. ``3.12``) used when synthesising a config
    /// from raw flags.
    version: ?[]const u8 = null,

    /// Fill any null field from its corresponding ``PYMZ_PYTHON_*`` environment
    /// variable. This realises the documented precedence
    /// ``-D option > env var > python-config``: callers populate the struct
    /// from ``-D`` options first, then call this to pick up env-var fallbacks
    /// for any field the user did not pin on the command line. Only fields that
    /// are still ``null`` are read from the environment, so an explicit
    /// ``-Dpymz-python-includes`` always wins over ``PYMZ_PYTHON_INCLUDES``.
    pub fn fillFromEnv(self: PythonOverrides) PythonOverrides {
        var out = self;
        if (out.config == null) out.config = envOpt("PYMZ_PYTHON_CONFIG");
        if (out.includes == null) out.includes = envOpt("PYMZ_PYTHON_INCLUDES");
        if (out.ldflags == null) out.ldflags = envOpt("PYMZ_PYTHON_LDFLAGS");
        if (out.libs == null) out.libs = envOpt("PYMZ_PYTHON_LIBS");
        if (out.ext_suffix == null) out.ext_suffix = envOpt("PYMZ_PYTHON_EXT_SUFFIX");
        if (out.version == null) out.version = envOpt("PYMZ_PYTHON_VERSION");
        return out;
    }
};

/// Read an optional ``[*:0]const u8`` environment variable into an owned
/// ``[]const u8`` slice, returning ``null`` when unset. The pointer returned
/// by ``getenv`` is process-owned and stable, so no copy is needed.
fn envOpt(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const spanned = std.mem.span(value);
    if (spanned.len == 0) return null;
    return spanned;
}

pub fn runtimeIsLimitedApi(runtime: RuntimeId) bool {
    return runtime.isLimitedApi();
}

/// String-accepting variant for callers (e.g. wheel building) that hold the
/// runtime as a manifest string. Invalid runtime names are treated as
/// non-limited, matching the historical `runtimeIsAbi3` behavior.
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

/// Locate the default python-config executable for the host environment.
///
/// When ``overrides`` supplies all raw cross-compilation fields
/// (includes/ldflags/libs/ext_suffix/version), a sentinel string is returned
/// so that `discoverPythonConfig` can synthesise the config without invoking
/// a host interpreter.
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

    // Fallback: read the ``PYMZ_PYTHON_CONFIG`` env var when no build option
    // or config file supplies a python-config path. Direct ``zig build``
    // invocations use it to locate a script.
    if (std.c.getenv("PYMZ_PYTHON_CONFIG")) |cfg| {
        warnEnvVarFallback("PYMZ_PYTHON_CONFIG", "-Dpymz-python-config");
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

    // Fallback: read the version-pinned ``PYMZ_PYTHON_CONFIG_{version}`` env
    // var when no build option or config file supplies a path.
    const env_name = b.fmt("PYMZ_PYTHON_CONFIG_{s}\x00", .{version});
    if (std.c.getenv(@ptrCast(env_name.ptr))) |cfg| {
        warnEnvVarFallback(env_name[0 .. env_name.len - 1], "-Dpymz-python-config");
        const candidate = std.mem.span(cfg);
        if (candidate.len == 0) return error.PythonConfigNotFound;
        if (try resolvePythonConfigFromEnvCandidates(b, candidate, version)) |ok| return ok;
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

/// Derive the Python interpreter binary path from a `python-config` script
/// path by stripping the `-config` suffix. If the input does not end with
/// `-config`, it is returned unchanged.
fn interpreterFromConfig(config: []const u8) []const u8 {
    if (std.mem.endsWith(u8, config, "-config"))
        return config[0 .. config.len - "-config".len];
    return config;
}

/// Run a small probe script via the Python interpreter derived from `config`.
///
/// This is the universal alternative to `python-config --version` /
/// `--extension-suffix`, both of which are unavailable on CPython 2.7 (the
/// flags do not exist) and 3.14+ (`--version` was removed). The interpreter
/// probe works on every supported CPython: `python -c` is stable and writes to
/// stdout on both Python 2 and 3, unlike `python --version` which goes to
/// stderr on Python 2 and so cannot be captured uniformly.
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

/// Verify that the interpreter backing `config` matches `expected_version`.
///
/// Uses the universal `sys.version_info` probe instead of `python-config
/// --version`, which is missing on CPython 2.7 and removed in 3.14+.
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

/// Synthesise a `PythonConfig` from explicit override values. Returns `null`
/// when the overrides do not include enough fields to bypass `python-config`.
///
/// The required fields are: `includes`, `ldflags`, `ext_suffix`, and
/// `version` (or `libs` as a fallback for the linker set).
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

    // Determine the version via the universal interpreter probe (see
    // `runInterpreterProbe`), which works across CPython 2.7 and 3.x
    // including 3.14+ where `python-config --version` was removed.
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

    // Python 3.8+ deprecated embedded module linking in plain `--ldflags`.
    // Python 3.14 completely removed `-lpython` from `--ldflags` output,
    // so we try `--embed` first (Python 3.8+) and fall back to plain
    // `--ldflags` for older interpreters.
    const argv_ldflags: []const []const u8 = if (parsed.major > 3 or (parsed.major == 3 and parsed.minor >= 8))
        &.{ config, "--ldflags", "--embed" }
    else
        &.{ config, "--ldflags" };
    const ldflags = blk: {
        if (runPythonConfig(b, argv_ldflags)) |out| {
            break :blk out;
        } else |_| {
            // Fallback: --embed not supported (Python < 3.8).
            break :blk try runPythonConfig(b, &.{ config, "--ldflags" });
        }
    };
    errdefer b.allocator.free(ldflags);

    const argv_libs = &.{ config, "--libs" };
    const libs = try runPythonConfig(b, argv_libs);
    errdefer b.allocator.free(libs);

    // `python-config --extension-suffix` is unavailable on CPython 2.7. Query
    // the interpreter directly (EXT_SUFFIX on 3.x, SO on 2.7) and fall back to
    // `--extension-suffix` for environments where the interpreter cannot run
    // (e.g. cross-compile with only the config script available).
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
