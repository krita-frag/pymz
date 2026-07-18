const std = @import("std");

const manifest_mod = @import("manifest.zig");
const wheel = @import("wheel.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    if (args.len < 2) {
        printUsage(io);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "build")) {
        try runBuildLikeCommand(allocator, io, environ, args, .build);
        return;
    }
    if (std.mem.eql(u8, command, "matrix")) {
        try runBuildLikeCommand(allocator, io, environ, args, .matrix);
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage(io);
        return;
    }

    printUsage(io);
    return error.InvalidCommand;
}

const BuildMode = enum {
    build,
    matrix,
};

const BuildOptions = struct {
    module_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    release: bool = false,
    python_version: ?[]const u8 = null,
    python_versions: ?[]const u8 = null,
    runtime: manifest_mod.Runtime = .auto,
    zig_target: []const u8 = "build",
    extension_dir: ?[]const u8 = null,
    out_dir: []const u8 = "dist",
    wheel_out_dir: ?[]const u8 = null,
    distribution: ?[]const u8 = null,
    package_dir: ?[]const u8 = null,
};

fn runBuildLikeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
    mode: BuildMode,
) !void {
    var parsed = try parseBuildOptions(allocator, io, args, mode);
    defer parsed.deinit(allocator);

    const project = try loadProjectInfo(allocator, io);
    defer project.deinit(allocator);

    const module_name = parsed.options.module_name orelse project.module_name;
    const version = parsed.options.version orelse project.version;

    const python_versions = if (parsed.options.python_versions) |raw|
        try splitVersions(allocator, raw)
    else
        null;
    defer if (python_versions) |versions| allocator.free(versions);

    if (mode == .matrix and python_versions == null) {
        return error.MissingPythonVersions;
    }

    try runZigBuild(allocator, io, .{
        .zig_target = parsed.options.zig_target,
        .release = parsed.options.release,
        .python_version = parsed.options.python_version,
        .python_versions = python_versions,
        .runtime = parsed.options.runtime,
    });

    const source_lib_dir = try std.fs.path.join(allocator, &.{ "zig-out", "lib" });
    defer allocator.free(source_lib_dir);
    const target_lib_dir = parsed.options.extension_dir orelse source_lib_dir;

    const source_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        source_lib_dir,
        .{},
    );
    const target_dir = if (std.mem.eql(u8, source_lib_dir, target_lib_dir))
        source_dir
    else
        try std.Io.Dir.cwd().createDirPathOpen(io, target_lib_dir, .{});

    const artifacts = try collectArtifacts(allocator, io, source_dir, module_name);
    defer freeArtifacts(allocator, artifacts);

    if (!std.mem.eql(u8, source_lib_dir, target_lib_dir)) {
        try syncArtifacts(source_dir, target_dir, io, artifacts);
    }

    const manifest = manifest_mod.BuildManifest{
        .module = module_name,
        .version = version,
        .zig_target = parsed.options.zig_target,
        .runtime = parsed.options.runtime,
        .release = parsed.options.release,
        .lib_dir = target_lib_dir,
        .python_version = parsed.options.python_version,
        .python_versions = if (python_versions) |versions| versions else &.{},
        .artifacts = artifacts,
        .distribution = parsed.options.distribution,
        .package_dir = parsed.options.package_dir,
    };

    const manifest_path = try manifest_mod.manifestPathFor(allocator, target_lib_dir, module_name);
    defer allocator.free(manifest_path);
    try manifest_mod.writeFile(target_dir, io, std.fs.path.basename(manifest_path), manifest);

    const metadata = wheel.Metadata{
        .description = "Zig-backed Python extension",
        .requires_python = ">=2.7",
        .license_text = "MIT",
    };

    if (mode == .build) {
        const wheel_path = try wheel.buildWheelFromManifest(allocator, io, environ, manifest, parsed.options.out_dir, metadata);
        defer allocator.free(wheel_path);
        std.debug.print("{s}\n", .{wheel_path});
    } else {
        const wheel_out_dir = parsed.options.wheel_out_dir orelse parsed.options.out_dir;
        const wheel_paths = try wheel.buildWheelsFromManifest(allocator, io, environ, manifest, wheel_out_dir, metadata);
        defer {
            for (wheel_paths) |wheel_path| allocator.free(wheel_path);
            allocator.free(wheel_paths);
        }
        std.debug.print("{s}\n", .{manifest_path});
        for (wheel_paths) |wheel_path| {
            std.debug.print("{s}\n", .{wheel_path});
        }
    }
}

const ParsedBuild = struct {
    options: BuildOptions,
    allocated: []const []const u8,

    fn deinit(self: *ParsedBuild, allocator: std.mem.Allocator) void {
        for (self.allocated) |item| allocator.free(item);
        allocator.free(self.allocated);
    }
};

fn parseBuildOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    mode: BuildMode,
) !ParsedBuild {
    var options: BuildOptions = .{};
    var allocated = std.ArrayList([]const u8).empty;
    errdefer allocated.deinit(allocator);

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--release")) {
            options.release = true;
            continue;
        }
        if (flagValue(arg, "--module")) |value| {
            options.module_name = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--module")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.module_name = args[index];
            continue;
        }
        if (flagValue(arg, "--distribution")) |value| {
            options.distribution = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--distribution")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.distribution = args[index];
            continue;
        }
        if (flagValue(arg, "--package-dir")) |value| {
            options.package_dir = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--package-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.package_dir = args[index];
            continue;
        }
        if (flagValue(arg, "--version")) |value| {
            options.version = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.version = args[index];
            continue;
        }
        if (flagValue(arg, "--python-version")) |value| {
            options.python_version = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--python-version")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.python_version = args[index];
            continue;
        }
        if (flagValue(arg, "--python-versions")) |value| {
            options.python_versions = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--python-versions")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.python_versions = args[index];
            continue;
        }
        if (flagValue(arg, "--pymz-runtime")) |value| {
            options.runtime = try parseRuntime(value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--pymz-runtime")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.runtime = try parseRuntime(args[index]);
            continue;
        }
        if (flagValue(arg, "--zig-target")) |value| {
            options.zig_target = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--zig-target")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.zig_target = args[index];
            continue;
        }
        if (flagValue(arg, "--extension-dir")) |value| {
            options.extension_dir = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--extension-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.extension_dir = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.out_dir = args[index];
            continue;
        }
        if (flagValue(arg, "--out")) |value| {
            options.out_dir = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--wheel-out")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.wheel_out_dir = args[index];
            continue;
        }
        if (flagValue(arg, "--wheel-out")) |value| {
            options.wheel_out_dir = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            printBuildUsage(io, mode);
            return error.HelpRequested;
        }
        return error.InvalidArgument;
    }

    if (mode == .matrix and options.python_versions == null) {
        return error.MissingPythonVersions;
    }

    if (options.python_version != null and options.python_versions != null) {
        return error.ConflictingPythonVersions;
    }

    return .{ .options = options, .allocated = try allocated.toOwnedSlice(allocator) };
}

fn runZigBuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: struct {
        zig_target: []const u8,
        release: bool,
        python_version: ?[]const u8,
        python_versions: ?[]const []const u8,
        runtime: manifest_mod.Runtime,
    },
) !void {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(allocator);

    var python_version_flag: ?[]const u8 = null;
    defer if (python_version_flag) |flag| allocator.free(flag);
    var python_versions_flag: ?[]const u8 = null;
    defer if (python_versions_flag) |flag| allocator.free(flag);
    var runtime_flag: ?[]const u8 = null;
    defer if (runtime_flag) |flag| allocator.free(flag);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "build");
    try argv.append(allocator, options.zig_target);

    if (options.python_version) |python_version| {
        python_version_flag = try std.fmt.allocPrint(
            allocator,
            "-Dpython-version={s}",
            .{python_version},
        );
        try argv.append(allocator, python_version_flag.?);
    }
    if (options.python_versions) |python_versions| {
        python_versions_flag = try joinCommaSeparated(allocator, python_versions);
        const prefixed = try std.fmt.allocPrint(
            allocator,
            "-Dpython-versions={s}",
            .{python_versions_flag.?},
        );
        allocator.free(python_versions_flag.?);
        python_versions_flag = prefixed;
        try argv.append(allocator, python_versions_flag.?);
    }
    runtime_flag = try std.fmt.allocPrint(
        allocator,
        "-Dpymz-runtime={s}",
        .{@tagName(options.runtime)},
    );
    try argv.append(allocator, runtime_flag.?);
    if (options.release) {
        try argv.append(allocator, "-Doptimize=ReleaseFast");
    }

    const argv_slice = try argv.toOwnedSlice(allocator);
    defer allocator.free(argv_slice);
    const run_result = try std.process.run(allocator, io, .{
        .argv = argv_slice,
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (run_result.term != .exited or run_result.term.exited != 0) {
        try std.Io.File.stderr().writeStreamingAll(io, run_result.stderr);
        return error.ZigBuildFailed;
    }
}

fn collectArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    module_name: []const u8,
) ![]const manifest_mod.Artifact {
    var iter = dir.iterate();
    var artifacts = std.ArrayList(manifest_mod.Artifact).empty;
    errdefer artifacts.deinit(allocator);

    const module_prefix = try std.fmt.allocPrint(allocator, "{s}.", .{module_name});
    defer allocator.free(module_prefix);

    const manifest_name = try std.fmt.allocPrint(
        allocator,
        "{s}.pymz-manifest.json",
        .{module_name},
    );
    defer allocator.free(manifest_name);

    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, manifest_name)) continue;
        if (std.mem.eql(u8, entry.name, "py.typed")) {
            try artifacts.append(allocator, .{ .filename = try allocator.dupe(u8, entry.name), .kind = .stub });
            continue;
        }
        if (std.mem.startsWith(u8, entry.name, module_prefix)) {
            const kind: manifest_mod.ArtifactKind = if (std.mem.endsWith(u8, entry.name, ".pyi")) .stub else .extension;
            try artifacts.append(allocator, .{ .filename = try allocator.dupe(u8, entry.name), .kind = kind });
        }
    }

    if (artifacts.items.len == 0) {
        return error.MissingBuildArtifacts;
    }

    return artifacts.toOwnedSlice(allocator);
}

fn syncArtifacts(
    source_dir: std.Io.Dir,
    target_dir: std.Io.Dir,
    io: std.Io,
    artifacts: []const manifest_mod.Artifact,
) !void {
    for (artifacts) |artifact| {
        try source_dir.copyFile(
            artifact.filename,
            target_dir,
            artifact.filename,
            io,
            .{ .make_path = true, .replace = true },
        );
    }
}

fn freeArtifacts(allocator: std.mem.Allocator, artifacts: []const manifest_mod.Artifact) void {
    for (artifacts) |artifact| {
        allocator.free(artifact.filename);
    }
    allocator.free(artifacts);
}

fn loadProjectInfo(allocator: std.mem.Allocator, io: std.Io) !ProjectInfo {
    const cwd = std.Io.Dir.cwd();
    const contents = cwd.readFileAlloc(
        io,
        "build.zig.zon",
        allocator,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .module_name = try allocator.dupe(u8, "extension"),
                .version = try allocator.dupe(u8, "0.0.0"),
            };
        },
        else => return err,
    };
    defer allocator.free(contents);

    const maybe_module_name = try extractZonFieldName(allocator, contents, "name");
    const maybe_version = try extractZonFieldString(allocator, contents, "version");
    const module_name = maybe_module_name orelse try allocator.dupe(u8, "extension");
    const version = maybe_version orelse try allocator.dupe(u8, "0.0.0");
    return .{
        .module_name = module_name,
        .version = version,
    };
}

const ProjectInfo = struct {
    module_name: []const u8,
    version: []const u8,

    fn deinit(self: ProjectInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.module_name);
        allocator.free(self.version);
    }
};

fn extractZonFieldName(
    allocator: std.mem.Allocator,
    source: []const u8,
    field: []const u8,
) !?[]u8 {
    const raw_value = extractZonFieldRaw(source, field) orelse return null;
    const trimmed = std.mem.trimStart(u8, raw_value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] != '.') return null;
    const value = trimmed[1..];
    if (std.mem.startsWith(u8, value, "@\"")) {
        const literal = value[1..];
        const end = findStringLiteralEnd(literal) orelse return null;
        const parsed = try std.zig.string_literal.parseAlloc(allocator, literal[0 .. end + 1]);
        return parsed;
    }

    const end = indexOfFieldTerminator(value) orelse value.len;
    const parsed = try allocator.dupe(u8, value[0..end]);
    return parsed;
}

fn extractZonFieldString(
    allocator: std.mem.Allocator,
    source: []const u8,
    field: []const u8,
) !?[]u8 {
    const raw_value = extractZonFieldRaw(source, field) orelse return null;
    const trimmed = std.mem.trimStart(u8, raw_value, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '"') return null;
    const end = findStringLiteralEnd(trimmed) orelse return null;
    const parsed = try std.zig.string_literal.parseAlloc(allocator, trimmed[0 .. end + 1]);
    return parsed;
}

fn extractZonFieldRaw(source: []const u8, field: []const u8) ?[]const u8 {
    const marker = std.fmt.allocPrint(std.heap.page_allocator, ".{s}", .{field}) catch return null;
    defer std.heap.page_allocator.free(marker);
    const start = std.mem.indexOf(u8, source, marker) orelse return null;
    const after_field = source[start + marker.len ..];
    const eq_index = std.mem.indexOfScalar(u8, after_field, '=') orelse return null;
    return after_field[eq_index + 1 ..];
}

fn indexOfFieldTerminator(value: []const u8) ?usize {
    return std.mem.indexOfAny(u8, value, ", \t\r\n}");
}

fn findStringLiteralEnd(source: []const u8) ?usize {
    var index: usize = 1;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            '\\' => {
                index += 1;
                continue;
            },
            '"' => return index,
            else => {},
        }
    }
    return null;
}

fn parseRuntime(value: []const u8) !manifest_mod.Runtime {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "cpython2")) return .cpython2;
    if (std.mem.eql(u8, value, "cpython3")) return .cpython3;
    return error.InvalidRuntime;
}

fn splitVersions(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return list.toOwnedSlice(allocator);
}

fn joinCommaSeparated(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const u8 {
    if (values.len == 0) return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn flagValue(arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, flag)) return null;
    if (arg.len <= flag.len or arg[flag.len] != '=') return null;
    return arg[flag.len + 1 ..];
}

fn printUsage(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(io,
        \\pymz-tool — build Zig-backed Python extension wheels
        \\
        \\Usage:
        \\  pymz-tool <command> [options]
        \\
        \\Commands:
        \\  build     Build a wheel for the current Python interpreter.
        \\  matrix    Build one wheel per Python version in --python-versions.
        \\  help      Show this message.
        \\
        \\Common options (see `pymz-tool build --help` / `pymz-tool matrix --help`
        \\for the full list):
        \\  --module <name>         Extension file prefix (e.g. `_jsonz`).
        \\  --distribution <name>   PyPI distribution name (defaults to --module).
        \\  --package-dir <dir>     Python source root (e.g. `python`); files
        \\                          under <dir>/<distribution>/ are packaged
        \\                          into the wheel so `import <distribution>`
        \\                          resolves to the package __init__.py.
        \\  --version <ver>         Package version (default: read from build.zig.zon).
        \\  --release               Build in ReleaseFast mode.
        \\  -o, --out <dir>         Output directory for wheels (default: dist).
        \\
        \\Environment:
        \\  PYMZ_PYTHON             Path to the python executable to target.
        \\  PYMZ_PYTHON_CONFIG      Path to its python-config script.
        \\
    ) catch {};
}

fn printBuildUsage(io: std.Io, mode: BuildMode) void {
    const matrix_only =
        \\  --python-versions <a,b,c>  Comma-separated Python versions to build for
        \\                            (required, e.g. "3.9,3.10,3.11,3.12").
        \\  --wheel-out <dir>          Directory for per-version wheels
        \\                            (default: same as --out).
        \\
    ;
    const build_only =
        \\  --python-version <ver>     Single Python version to target
        \\                            (e.g. "3.12"). Inferred from the current
        \\                            interpreter when omitted.
        \\
    ;
    const extra = switch (mode) {
        .build => build_only,
        .matrix => matrix_only,
    };
    std.Io.File.stderr().writeStreamingAll(io,
        \\Usage:
        \\  pymz-tool build [options]
        \\
        \\Description:
        \\  Build a single wheel for the current Python interpreter, packaging
        \\  the compiled extension and its type stubs.
        \\
        \\Options:
        \\  --module <name>            Extension file prefix (e.g. `_jsonz`).
        \\                             Defaults to the `name` field of build.zig.zon.
        \\  --distribution <name>      PyPI distribution name written into the
        \\                             wheel filename and METADATA (defaults to
        \\                             --module). Use this when the C extension
        \\                             file is `_foo` but the package name is `foo`.
        \\  --package-dir <dir>        Python source root (e.g. `python`). When
        \\                             set, files under <dir>/<distribution>/
        \\                             are packaged into the wheel alongside the
        \\                             compiled extension, and the extension is
        \\                             placed under <distribution>/ so that
        \\                             `import <distribution>` works.
        \\  --version <ver>            Package version (default: from build.zig.zon).
        \\  --release                  Build in ReleaseFast mode.
        \\  --pymz-runtime <runtime>   Force runtime: auto | cpython2 | cpython3.
        \\  --zig-target <name>        Zig build target name (default: `build`).
        \\  --extension-dir <dir>      Directory containing the built .so/.pyd
        \\                             files (default: zig-out/lib).
        \\  -o, --out <dir>            Output directory for the wheel (default: dist).
        \\
    ) catch {};
    std.Io.File.stderr().writeStreamingAll(io, extra) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseRuntime accepts named runtimes" {
    try std.testing.expectEqual(manifest_mod.Runtime.auto, try parseRuntime("auto"));
    try std.testing.expectEqual(manifest_mod.Runtime.cpython2, try parseRuntime("cpython2"));
    try std.testing.expectEqual(manifest_mod.Runtime.cpython3, try parseRuntime("cpython3"));
}

test "parseRuntime rejects unknown values" {
    try std.testing.expectError(error.InvalidRuntime, parseRuntime("cpython4"));
    try std.testing.expectError(error.InvalidRuntime, parseRuntime(""));
}

test "flagValue returns value after equals sign" {
    try std.testing.expectEqualStrings("3.12", flagValue("--python-version=3.12", "--python-version").?);
    try std.testing.expectEqualStrings("jsonz", flagValue("--distribution=jsonz", "--distribution").?);
}

test "flagValue returns null when flag missing" {
    try std.testing.expect(flagValue("--release", "--python-version") == null);
}

test "flagValue returns null when no equals sign" {
    try std.testing.expect(flagValue("--python-version", "--python-version") == null);
    try std.testing.expect(flagValue("--python-version3.12", "--python-version") == null);
}

test "splitVersions parses comma-separated list" {
    const allocator = std.testing.allocator;
    const versions = try splitVersions(allocator, "3.9,3.10,3.11,3.12");
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }
    try std.testing.expectEqual(@as(usize, 4), versions.len);
    try std.testing.expectEqualStrings("3.9", versions[0]);
    try std.testing.expectEqualStrings("3.10", versions[1]);
    try std.testing.expectEqualStrings("3.11", versions[2]);
    try std.testing.expectEqualStrings("3.12", versions[3]);
}

test "splitVersions trims whitespace around entries" {
    const allocator = std.testing.allocator;
    const versions = try splitVersions(allocator, " 3.9 , 3.10 ,3.11");
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }
    try std.testing.expectEqual(@as(usize, 3), versions.len);
    try std.testing.expectEqualStrings("3.9", versions[0]);
    try std.testing.expectEqualStrings("3.10", versions[1]);
    try std.testing.expectEqualStrings("3.11", versions[2]);
}

test "splitVersions skips empty entries" {
    const allocator = std.testing.allocator;
    const versions = try splitVersions(allocator, "3.9,,3.10,");
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }
    try std.testing.expectEqual(@as(usize, 2), versions.len);
    try std.testing.expectEqualStrings("3.9", versions[0]);
    try std.testing.expectEqualStrings("3.10", versions[1]);
}

test "splitVersions returns empty slice for empty input" {
    const allocator = std.testing.allocator;
    const versions = try splitVersions(allocator, "");
    defer allocator.free(versions);
    try std.testing.expectEqual(@as(usize, 0), versions.len);
}

test "joinCommaSeparated joins with comma" {
    const allocator = std.testing.allocator;
    const parts = [_][]const u8{ "3.9", "3.10", "3.11" };
    const joined = try joinCommaSeparated(allocator, &parts);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("3.9,3.10,3.11", joined);
}

test "joinCommaSeparated returns empty string for empty input" {
    const allocator = std.testing.allocator;
    const joined = try joinCommaSeparated(allocator, &.{});
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("", joined);
}
