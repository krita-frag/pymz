const std = @import("std");

pub const SchemaVersion: u32 = 1;

pub const Runtime = enum {
    auto,
    cpython2,
    cpython3,
};

pub const ArtifactKind = enum {
    extension,
    stub,
};

pub const Artifact = struct {
    filename: []const u8,
    kind: ArtifactKind,
};

pub const BuildManifest = struct {
    schema_version: u32 = SchemaVersion,
    module: []const u8,
    version: []const u8,
    zig_target: []const u8,
    runtime: Runtime = .auto,
    release: bool = false,
    lib_dir: []const u8,
    python_version: ?[]const u8 = null,
    python_versions: []const []const u8 = &.{},
    artifacts: []const Artifact = &.{},
    /// Distribution name written into the wheel filename and METADATA.
    /// Defaults to `module` when null. Useful when the C extension file
    /// uses a different prefix (e.g. `_jsonz`) than the PyPI distribution
    /// name (`jsonz`).
    distribution: ?[]const u8 = null,
    /// Optional Python source directory (e.g. "python"). When set, files
    /// under `<package_dir>/<distribution>/` are packaged into the wheel
    /// under `<distribution>/`, alongside the compiled extension and stubs.
    /// When null, the extension and stubs are placed at the wheel root.
    package_dir: ?[]const u8 = null,

    /// Return the distribution name to use for wheel filename / METADATA.
    pub fn distributionName(self: BuildManifest) []const u8 {
        return self.distribution orelse self.module;
    }
};

pub fn manifestPathFor(
    allocator: std.mem.Allocator,
    lib_dir: []const u8,
    module_name: []const u8,
) ![]u8 {
    const file_name = try std.fmt.allocPrint(
        allocator,
        "{s}.pymz-manifest.json",
        .{module_name},
    );
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ lib_dir, file_name });
}

pub fn read(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(BuildManifest) {
    const cwd = std.Io.Dir.cwd();
    const contents = try cwd.readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .unlimited,
    );
    defer allocator.free(contents);
    return std.json.parseFromSlice(BuildManifest, allocator, contents, .{});
}

fn writeJsonString(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    try file.writeStreamingAll(io, "\"");
    for (bytes) |byte| {
        switch (byte) {
            '"' => try file.writeStreamingAll(io, "\\\""),
            '\\' => try file.writeStreamingAll(io, "\\\\"),
            '\n' => try file.writeStreamingAll(io, "\\n"),
            '\r' => try file.writeStreamingAll(io, "\\r"),
            '\t' => try file.writeStreamingAll(io, "\\t"),
            else => if (byte < 0x20) {
                const hex = "0123456789abcdef";
                var escape: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
                escape[4] = hex[byte >> 4];
                escape[5] = hex[byte & 0x0f];
                try file.writeStreamingAll(io, &escape);
            } else {
                var one: [1]u8 = .{byte};
                try file.writeStreamingAll(io, &one);
            },
        }
    }
    try file.writeStreamingAll(io, "\"");
}

fn writeStringArray(
    file: std.Io.File,
    io: std.Io,
    values: []const []const u8,
) !void {
    try file.writeStreamingAll(io, "[");
    for (values, 0..) |value, index| {
        if (index != 0) {
            try file.writeStreamingAll(io, ", ");
        }
        try writeJsonString(file, io, value);
    }
    try file.writeStreamingAll(io, "]");
}

fn writeArtifacts(
    file: std.Io.File,
    io: std.Io,
    artifacts: []const Artifact,
) !void {
    try file.writeStreamingAll(io, "[");
    for (artifacts, 0..) |artifact, index| {
        if (index != 0) {
            try file.writeStreamingAll(io, ", ");
        }
        try file.writeStreamingAll(io, "{");
        try file.writeStreamingAll(io, "\"filename\": ");
        try writeJsonString(file, io, artifact.filename);
        try file.writeStreamingAll(io, ", \"kind\": ");
        try writeJsonString(file, io, @tagName(artifact.kind));
        try file.writeStreamingAll(io, "}");
    }
    try file.writeStreamingAll(io, "]");
}

pub fn writeFile(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    manifest: BuildManifest,
) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var writer_buffer: [256]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);

    try file.writeStreamingAll(io, "{\n");
    try file.writeStreamingAll(io, "  \"schema_version\": ");
    try writer.interface.print("{d}", .{manifest.schema_version});
    try file.writeStreamingAll(io, ",\n  \"module\": ");
    try writeJsonString(file, io, manifest.module);
    try file.writeStreamingAll(io, ",\n  \"version\": ");
    try writeJsonString(file, io, manifest.version);
    try file.writeStreamingAll(io, ",\n  \"zig_target\": ");
    try writeJsonString(file, io, manifest.zig_target);
    try file.writeStreamingAll(io, ",\n  \"runtime\": ");
    try writeJsonString(file, io, @tagName(manifest.runtime));
    try file.writeStreamingAll(io, ",\n  \"release\": ");
    try writer.interface.print("{}", .{manifest.release});
    try file.writeStreamingAll(io, ",\n  \"lib_dir\": ");
    try writeJsonString(file, io, manifest.lib_dir);
    try file.writeStreamingAll(io, ",\n  \"python_version\": ");
    if (manifest.python_version) |python_version| {
        try writeJsonString(file, io, python_version);
    } else {
        try file.writeStreamingAll(io, "null");
    }
    try file.writeStreamingAll(io, ",\n  \"python_versions\": ");
    try writeStringArray(file, io, manifest.python_versions);
    try file.writeStreamingAll(io, ",\n  \"artifacts\": ");
    try writeArtifacts(file, io, manifest.artifacts);
    try file.writeStreamingAll(io, ",\n  \"distribution\": ");
    if (manifest.distribution) |distribution| {
        try writeJsonString(file, io, distribution);
    } else {
        try file.writeStreamingAll(io, "null");
    }
    try file.writeStreamingAll(io, ",\n  \"package_dir\": ");
    if (manifest.package_dir) |package_dir| {
        try writeJsonString(file, io, package_dir);
    } else {
        try file.writeStreamingAll(io, "null");
    }
    try file.writeStreamingAll(io, "\n}\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "distributionName falls back to module when distribution is null" {
    const manifest = BuildManifest{
        .module = "_jsonz",
        .version = "0.1.0",
        .zig_target = "example",
        .lib_dir = "zig-out/lib",
    };
    try std.testing.expectEqualStrings("_jsonz", manifest.distributionName());
}

test "distributionName returns distribution when set" {
    const manifest = BuildManifest{
        .module = "_jsonz",
        .version = "0.1.0",
        .zig_target = "example",
        .lib_dir = "zig-out/lib",
        .distribution = "jsonz",
    };
    try std.testing.expectEqualStrings("jsonz", manifest.distributionName());
}

test "manifestPathFor prefixes module name" {
    const allocator = std.testing.allocator;
    const path = try manifestPathFor(allocator, "zig-out/lib", "_jsonz");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("zig-out/lib/_jsonz.pymz-manifest.json", path);
}

test "BuildManifest round-trips through JSON" {
    const allocator = std.testing.allocator;
    const artifacts = [_]Artifact{
        .{ .filename = "_jsonz.cpython-312-darwin.so", .kind = .extension },
        .{ .filename = "_jsonz.pyi", .kind = .stub },
    };
    const original = BuildManifest{
        .module = "_jsonz",
        .version = "0.1.0",
        .zig_target = "example",
        .runtime = .cpython3,
        .release = true,
        .lib_dir = "zig-out/lib",
        .python_version = "3.12",
        .python_versions = &.{ "3.11", "3.12" },
        .artifacts = &artifacts,
        .distribution = "jsonz",
        .package_dir = "python",
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Serialize to a file inside the tmp dir.
    const io = std.testing.io;
    try writeFile(tmp.dir, io, "manifest.json", original);

    // Read using the same dir handle to avoid cwd-relative lookups.
    var file = try tmp.dir.openFile(io, "manifest.json", .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const contents = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(
        BuildManifest,
        allocator,
        contents,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const roundtripped = parsed.value;

    try std.testing.expectEqualStrings("_jsonz", roundtripped.module);
    try std.testing.expectEqualStrings("0.1.0", roundtripped.version);
    try std.testing.expectEqualStrings("example", roundtripped.zig_target);
    try std.testing.expectEqual(Runtime.cpython3, roundtripped.runtime);
    try std.testing.expect(roundtripped.release);
    try std.testing.expectEqualStrings("zig-out/lib", roundtripped.lib_dir);
    try std.testing.expectEqualStrings("3.12", roundtripped.python_version.?);
    try std.testing.expectEqual(@as(usize, 2), roundtripped.python_versions.len);
    try std.testing.expectEqualStrings("3.11", roundtripped.python_versions[0]);
    try std.testing.expectEqualStrings("3.12", roundtripped.python_versions[1]);
    try std.testing.expectEqualStrings("jsonz", roundtripped.distribution.?);
    try std.testing.expectEqualStrings("python", roundtripped.package_dir.?);
    try std.testing.expectEqual(@as(usize, 2), roundtripped.artifacts.len);
    try std.testing.expectEqualStrings("_jsonz.cpython-312-darwin.so", roundtripped.artifacts[0].filename);
    try std.testing.expectEqual(ArtifactKind.extension, roundtripped.artifacts[0].kind);
    try std.testing.expectEqualStrings("_jsonz.pyi", roundtripped.artifacts[1].filename);
    try std.testing.expectEqual(ArtifactKind.stub, roundtripped.artifacts[1].kind);
}
