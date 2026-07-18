const builtin = @import("builtin");
const std = @import("std");

const archive = @import("archive.zig");
const manifest_mod = @import("manifest.zig");

pub const Metadata = struct {
    description: ?[]const u8 = null,
    requires_python: ?[]const u8 = null,
    license_text: ?[]const u8 = null,
};

pub fn buildWheel(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manifest_path: []const u8,
    out_dir: []const u8,
    metadata: Metadata,
) ![]u8 {
    var parsed = try manifest_mod.read(allocator, manifest_path);
    defer parsed.deinit();
    return buildWheelFromManifest(allocator, io, environ, parsed.value, out_dir, metadata);
}

pub fn buildWheels(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manifest_path: []const u8,
    out_dir: []const u8,
    metadata: Metadata,
) ![][]u8 {
    var parsed = try manifest_mod.read(allocator, manifest_path);
    defer parsed.deinit();
    return buildWheelsFromManifest(allocator, io, environ, parsed.value, out_dir, metadata);
}

pub fn buildWheelFromManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manifest: manifest_mod.BuildManifest,
    out_dir: []const u8,
    metadata: Metadata,
) ![]u8 {
    const extension_name = try selectCurrentExtension(allocator, manifest);
    return buildOneWheel(allocator, io, environ, manifest, extension_name, out_dir, metadata);
}

pub fn buildWheelsFromManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manifest: manifest_mod.BuildManifest,
    out_dir: []const u8,
    metadata: Metadata,
) ![][]u8 {
    const extensions = try selectMatrixExtensions(allocator, manifest);
    defer allocator.free(extensions);

    var wheel_paths = std.ArrayList([]u8).empty;
    errdefer wheel_paths.deinit(allocator);

    for (extensions) |extension_name| {
        const wheel_path = try buildOneWheel(allocator, io, environ, manifest, extension_name, out_dir, metadata);
        try wheel_paths.append(allocator, wheel_path);
    }

    return wheel_paths.toOwnedSlice(allocator);
}

fn buildOneWheel(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manifest: manifest_mod.BuildManifest,
    extension_name: []const u8,
    out_dir: []const u8,
    metadata: Metadata,
) ![]u8 {
    const platform_suffix = try artifactPlatformSuffix(allocator);
    defer allocator.free(platform_suffix);

    const py_digits = try versionDigits(
        allocator,
        extensionDigitsWithSuffix(manifest.module, extension_name, platform_suffix) orelse
            return error.MissingExtensionVersion,
    );
    defer allocator.free(py_digits);

    const py_tag = try std.fmt.allocPrint(allocator, "cp{s}", .{py_digits});
    defer allocator.free(py_tag);

    const abi_tag = try std.fmt.allocPrint(allocator, "cp{s}", .{py_digits});
    defer allocator.free(abi_tag);

    const platform_tag = try wheelPlatformTag(allocator, io, environ);
    defer allocator.free(platform_tag);

    const distribution_name = manifest.distributionName();

    const wheel_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}-{s}-{s}.whl",
        .{
            distribution_name,
            manifest.version,
            py_tag,
            abi_tag,
            platform_tag,
        },
    );
    defer allocator.free(wheel_name);

    const wheel_path = try std.fs.path.join(allocator, &.{ out_dir, wheel_name });

    const source_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        manifest.lib_dir,
        .{},
    );

    const out_dir_handle = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        out_dir,
        .{},
    );

    const dist_info_dir = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}.dist-info",
        .{ distribution_name, manifest.version },
    );
    defer allocator.free(dist_info_dir);

    var record_writer: std.Io.Writer.Allocating = .init(allocator);
    defer record_writer.deinit();

    var zip_file = try out_dir_handle.createFile(io, wheel_name, .{});
    defer zip_file.close(io);

    var offset: u64 = 0;
    var entries = std.ArrayList(archive.ZipEntry).empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.filename);
        }
        entries.deinit(allocator);
    }

    const selected_entries = try selectWheelEntries(allocator, manifest, extension_name);
    defer allocator.free(selected_entries);

    // Determine the in-wheel prefix for extension/stub files. When a Python
    // package directory is configured, artifacts live under
    // `<distribution>/` so that `import <distribution>` resolves to the
    // package __init__.py. Otherwise they go to the wheel root.
    const artifact_prefix: []const u8 = if (manifest.package_dir != null) distribution_name else "";

    // Collect Python source files from <package_dir>/<distribution>/ when
    // configured. Each entry is (source_dir, source_name, archive_name).
    const PackageFile = struct {
        source_dir: std.Io.Dir,
        source_name: []const u8,
        archive_name: []u8,
    };
    var python_files = std.ArrayList(PackageFile).empty;
    defer {
        for (python_files.items) |pf| allocator.free(pf.archive_name);
        python_files.deinit(allocator);
    }
    if (manifest.package_dir) |pkg_dir| {
        const python_source_path = try std.fs.path.join(allocator, &.{ pkg_dir, distribution_name });
        defer allocator.free(python_source_path);
        const python_pkg_dir = std.Io.Dir.cwd().openDir(io, python_source_path, .{ .iterate = true }) catch null;
        if (python_pkg_dir) |pkg| {
            var iter = pkg.iterate();
            while (iter.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const archive_name = try std.fs.path.join(allocator, &.{ distribution_name, entry.name });
                try python_files.append(allocator, .{
                    .source_dir = pkg,
                    .source_name = try allocator.dupe(u8, entry.name),
                    .archive_name = archive_name,
                });
            }
        }
    }
    defer {
        for (python_files.items) |pf| allocator.free(pf.source_name);
    }

    for (selected_entries) |entry_name| {
        // Compute the archive path for this artifact.
        const archive_name = if (artifact_prefix.len > 0)
            try std.fs.path.join(allocator, &.{ artifact_prefix, entry_name })
        else
            try allocator.dupe(u8, entry_name);
        defer allocator.free(archive_name);

        if (std.mem.eql(u8, entry_name, "py.typed") and manifest.package_dir == null) {
            // Legacy: py.typed at wheel root when no package dir.
            const data: []const u8 = "";
            try archive.writeZipEntry(
                zip_file,
                io,
                archive_name,
                data,
                &offset,
                &entries,
                allocator,
            );
            const hash = try hashBytes(allocator, data);
            defer allocator.free(hash);
            try record_writer.writer.print(
                "{s},{s},{d}\n",
                .{ archive_name, hash, data.len },
            );
            continue;
        }

        // Skip py.typed here if it's in the python source dir (it'll be
        // picked up with the other python files below).
        if (std.mem.eql(u8, entry_name, "py.typed") and manifest.package_dir != null) {
            continue;
        }

        const file_bytes = try source_dir.readFileAlloc(
            io,
            entry_name,
            allocator,
            .unlimited,
        );
        defer allocator.free(file_bytes);

        try archive.writeZipEntry(
            zip_file,
            io,
            archive_name,
            file_bytes,
            &offset,
            &entries,
            allocator,
        );

        const hash = try hashBytes(allocator, file_bytes);
        defer allocator.free(hash);
        try record_writer.writer.print(
            "{s},{s},{d}\n",
            .{ archive_name, hash, file_bytes.len },
        );
    }

    // Now add Python source files (including __init__.py, py.typed, .pyi
    // stubs that live alongside the Python package).
    for (python_files.items) |pf| {
        const file_bytes = try pf.source_dir.readFileAlloc(
            io,
            pf.source_name,
            allocator,
            .unlimited,
        );
        defer allocator.free(file_bytes);

        try archive.writeZipEntry(
            zip_file,
            io,
            pf.archive_name,
            file_bytes,
            &offset,
            &entries,
            allocator,
        );

        const hash = try hashBytes(allocator, file_bytes);
        defer allocator.free(hash);
        try record_writer.writer.print(
            "{s},{s},{d}\n",
            .{ pf.archive_name, hash, file_bytes.len },
        );
    }

    const metadata_text = try buildMetadataText(allocator, manifest, metadata);
    defer allocator.free(metadata_text);
    const metadata_path = try std.fmt.allocPrint(
        allocator,
        "{s}/METADATA",
        .{dist_info_dir},
    );
    defer allocator.free(metadata_path);
    try archive.writeZipEntry(
        zip_file,
        io,
        metadata_path,
        metadata_text,
        &offset,
        &entries,
        allocator,
    );
    const metadata_hash = try hashBytes(allocator, metadata_text);
    defer allocator.free(metadata_hash);
    try record_writer.writer.print("{s},{s},{d}\n", .{ metadata_path, metadata_hash, metadata_text.len });

    const wheel_text = try buildWheelText(allocator, py_tag, abi_tag, platform_tag);
    defer allocator.free(wheel_text);
    const wheel_path_in_zip = try std.fmt.allocPrint(
        allocator,
        "{s}/WHEEL",
        .{dist_info_dir},
    );
    defer allocator.free(wheel_path_in_zip);
    try archive.writeZipEntry(
        zip_file,
        io,
        wheel_path_in_zip,
        wheel_text,
        &offset,
        &entries,
        allocator,
    );
    const wheel_hash = try hashBytes(allocator, wheel_text);
    defer allocator.free(wheel_hash);
    try record_writer.writer.print("{s},{s},{d}\n", .{ wheel_path_in_zip, wheel_hash, wheel_text.len });

    const record_path = try std.fmt.allocPrint(
        allocator,
        "{s}/RECORD",
        .{dist_info_dir},
    );
    defer allocator.free(record_path);
    try record_writer.writer.print("{s},,\n", .{record_path});
    const record_text = record_writer.writer.buffer[0..record_writer.writer.end];
    try archive.writeZipEntry(
        zip_file,
        io,
        record_path,
        record_text,
        &offset,
        &entries,
        allocator,
    );

    try archive.writeZipFooter(zip_file, io, entries.items, offset);

    for (entries.items) |entry| {
        allocator.free(entry.filename);
    }
    entries.deinit(allocator);

    return wheel_path;
}

fn buildMetadataText(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.BuildManifest,
    metadata: Metadata,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Metadata-Version: 2.1\n", .{});
    try out.writer.print("Name: {s}\n", .{manifest.distributionName()});
    try out.writer.print("Version: {s}\n", .{manifest.version});
    if (metadata.description) |description| {
        try out.writer.print("Summary: {s}\n", .{description});
    }
    if (metadata.requires_python) |requires_python| {
        try out.writer.print("Requires-Python: {s}\n", .{requires_python});
    }
    if (metadata.license_text) |license_text| {
        try out.writer.print("License: {s}\n", .{license_text});
    }

    const bytes = try allocator.dupe(u8, out.writer.buffer[0..out.writer.end]);
    out.deinit();
    return bytes;
}

fn buildWheelText(
    allocator: std.mem.Allocator,
    py_tag: []const u8,
    abi_tag: []const u8,
    platform_tag: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Wheel-Version: 1.0\n", .{});
    try out.writer.print("Generator: pymz-tool\n", .{});
    try out.writer.print("Root-Is-Purelib: false\n", .{});
    try out.writer.print("Tag: {s}-{s}-{s}\n", .{ py_tag, abi_tag, platform_tag });

    const bytes = try allocator.dupe(u8, out.writer.buffer[0..out.writer.end]);
    out.deinit();
    return bytes;
}

fn hashBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    var encoded: [64]u8 = undefined;
    const result = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest);
    return std.fmt.allocPrint(allocator, "sha256={s}", .{result});
}

fn selectCurrentExtension(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.BuildManifest,
) ![]const u8 {
    const expected_digits = expectedPythonDigits(allocator, manifest) catch null;
    defer if (expected_digits) |digits| allocator.free(digits);

    const platform_suffix = try artifactPlatformSuffix(allocator);
    defer allocator.free(platform_suffix);

    var selected: ?[]const u8 = null;
    var matches: usize = 0;

    for (manifest.artifacts) |artifact| {
        if (artifact.kind != .extension) continue;
        if (extensionDigitsWithSuffix(manifest.module, artifact.filename, platform_suffix)) |digits| {
            if (expected_digits) |expected| {
                if (std.mem.eql(u8, digits, expected)) return artifact.filename;
                continue;
            }
            selected = artifact.filename;
            matches += 1;
        }
    }

    if (expected_digits != null) {
        return error.MissingExtensionArtifact;
    }

    if (matches == 1) {
        return selected.?;
    }

    if (matches == 0) {
        return error.MissingExtensionArtifact;
    }

    return error.AmbiguousExtensionSelection;
}

fn selectMatrixExtensions(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.BuildManifest,
) ![]const []const u8 {
    const platform_suffix = try artifactPlatformSuffix(allocator);
    defer allocator.free(platform_suffix);

    var selected = std.ArrayList([]const u8).empty;
    errdefer selected.deinit(allocator);

    for (manifest.artifacts) |artifact| {
        if (artifact.kind != .extension) continue;
        if (extensionDigitsWithSuffix(manifest.module, artifact.filename, platform_suffix) != null) {
            try selected.append(allocator, artifact.filename);
        }
    }

    if (selected.items.len == 0) {
        return error.MissingExtensionArtifact;
    }

    return selected.toOwnedSlice(allocator);
}

fn selectWheelEntries(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.BuildManifest,
    extension_name: []const u8,
) ![]const []const u8 {
    var selected = std.ArrayList([]const u8).empty;
    errdefer selected.deinit(allocator);

    try selected.append(allocator, extension_name);
    for (manifest.artifacts) |artifact| {
        if (artifact.kind == .stub) {
            try selected.append(allocator, artifact.filename);
        }
    }
    try selected.append(allocator, "py.typed");
    return selected.toOwnedSlice(allocator);
}

fn expectedPythonDigits(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.BuildManifest,
) !?[]u8 {
    if (manifest.python_version) |python_version| {
        const digits = try versionDigits(allocator, python_version);
        return digits;
    }
    if (manifest.python_versions.len == 1) {
        const digits = try versionDigits(allocator, manifest.python_versions[0]);
        return digits;
    }
    return null;
}

fn versionDigits(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    var digits = try allocator.alloc(u8, version.len);
    var count: usize = 0;
    for (version) |byte| {
        if (byte == '.') continue;
        digits[count] = byte;
        count += 1;
    }
    return digits[0..count];
}

fn extensionDigitsWithSuffix(
    module_name: []const u8,
    extension_name: []const u8,
    platform_suffix: []const u8,
) ?[]const u8 {
    if (!std.mem.startsWith(u8, extension_name, module_name)) return null;
    const rest = extension_name[module_name.len..];
    if (rest.len < 1 or rest[0] != '.') return null;
    const body = rest[1..];

    if (builtin.os.tag == .windows) {
        if (!std.mem.startsWith(u8, body, "cp")) return null;
        const after_cp = body[2..];
        const dash = std.mem.indexOfScalar(u8, after_cp, '-') orelse return null;
        const tail = after_cp[dash + 1 ..];
        if (tail.len != platform_suffix.len + 4) return null;
        if (!std.mem.eql(u8, tail[0..platform_suffix.len], platform_suffix)) return null;
        if (!std.mem.eql(u8, tail[platform_suffix.len..], ".pyd")) return null;
        return after_cp[0..dash];
    }

    if (!std.mem.startsWith(u8, body, "cpython-")) return null;
    const after_prefix = body["cpython-".len..];
    const dash = std.mem.indexOfScalar(u8, after_prefix, '-') orelse return null;
    const tail = after_prefix[dash + 1 ..];
    if (tail.len != platform_suffix.len + 3) return null;
    if (!std.mem.eql(u8, tail[0..platform_suffix.len], platform_suffix)) return null;
    if (!std.mem.eql(u8, tail[platform_suffix.len..], ".so")) return null;
    return after_prefix[0..dash];
}

fn artifactPlatformSuffix(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "win_amd64"),
            .aarch64 => allocator.dupe(u8, "win_arm64"),
            .x86 => allocator.dupe(u8, "win32"),
            else => std.fmt.allocPrint(allocator, "{s}", .{@tagName(builtin.cpu.arch)}),
        },
        .macos => allocator.dupe(u8, "darwin"),
        .linux => std.fmt.allocPrint(
            allocator,
            "{s}-linux-{s}",
            .{ @tagName(builtin.cpu.arch), linuxAbiTag() },
        ),
        else => std.fmt.allocPrint(allocator, "{s}", .{@tagName(builtin.os.tag)}),
    };
}

fn wheelPlatformTag(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    // Prefer the value reported by the target Python interpreter itself — this
    // matches what pip will accept at install time and accounts for SDK
    // deploy-target rounding (macosx_14_0_arm64) and arch name spelling
    // (arm64 vs aarch64) that builtin.target cannot observe at build time.
    if (queryPythonPlatform(allocator, io, environ)) |tag| {
        return tag;
    } else |_| {}
    return fallbackWheelPlatformTag(allocator);
}

fn queryPythonPlatform(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    // Resolve the target Python interpreter. Prefer $PYMZ_PYTHON, then fall
    // back to `python3`. On Python 2-only hosts this lookup will simply fail
    // and the caller falls back to the static platform tag.
    const python = environ.getPosix("PYMZ_PYTHON");
    const interpreter: []const u8 = if (python) |p| p else "python3";

    const argv = [_][]const u8{
        interpreter,
        "-c",
        "import sysconfig;print(sysconfig.get_platform())",
    };
    const result = std.process.run(allocator, io, .{ .argv = &argv }) catch return error.PythonUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.PythonUnavailable;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return normalizePlatformTag(allocator, trimmed);
}

/// Convert a `sysconfig.get_platform()` string (e.g. "macosx-14.0-arm64",
/// "linux-x86_64", "win-amd64") into a PEP 425 wheel platform tag where
/// every `-` and `.` is replaced with `_`. The input is assumed to already
/// be trimmed of surrounding whitespace.
fn normalizePlatformTag(
    allocator: std.mem.Allocator,
    sysconfig_platform: []const u8,
) ![]u8 {
    const out = try allocator.alloc(u8, sysconfig_platform.len);
    var i: usize = 0;
    while (i < sysconfig_platform.len) : (i += 1) {
        const c = sysconfig_platform[i];
        out[i] = if (c == '-' or c == '.') '_' else c;
    }
    return out;
}

fn fallbackWheelPlatformTag(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => artifactPlatformSuffix(allocator),
        .macos => {
            const version = builtin.target.os.version_range.semver.min;
            return std.fmt.allocPrint(
                allocator,
                "macosx_{d}_{d}_{s}",
                .{ version.major, version.minor, macosArchName() },
            );
        },
        .linux => std.fmt.allocPrint(
            allocator,
            "linux_{s}",
            .{linuxArchName()},
        ),
        else => std.fmt.allocPrint(
            allocator,
            "{s}_{s}",
            .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
        ),
    };
}

fn macosArchName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn linuxArchName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn linuxAbiTag() []const u8 {
    return switch (builtin.target.abi) {
        .musl => "musl",
        .gnu, .gnuabin32, .gnuabi64, .gnueabi, .gnueabihf, .gnuf32, .gnusf, .gnux32 => "gnu",
        else => @tagName(builtin.target.abi),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "versionDigits strips dots" {
    const allocator = std.testing.allocator;
    const out = try versionDigits(allocator, "3.12");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("312", out);
}

test "versionDigits passes through digits" {
    const allocator = std.testing.allocator;
    const out = try versionDigits(allocator, "39");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("39", out);
}

test "normalizePlatformTag: macOS" {
    const allocator = std.testing.allocator;
    const out = try normalizePlatformTag(allocator, "macosx-14.0-arm64");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("macosx_14_0_arm64", out);
}

test "normalizePlatformTag: linux" {
    const allocator = std.testing.allocator;
    const out = try normalizePlatformTag(allocator, "linux-x86_64");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("linux_x86_64", out);
}

test "normalizePlatformTag: windows" {
    const allocator = std.testing.allocator;
    const out = try normalizePlatformTag(allocator, "win-amd64");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("win_amd64", out);
}

test "normalizePlatformTag: no separators to convert" {
    const allocator = std.testing.allocator;
    const out = try normalizePlatformTag(allocator, "any");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("any", out);
}

test "selectWheelEntries includes extension, stubs, and py.typed" {
    const allocator = std.testing.allocator;
    const artifacts = [_]manifest_mod.Artifact{
        .{ .filename = "_jsonz.pyi", .kind = .stub },
        .{ .filename = "_jsonz.cpython-312-darwin.so", .kind = .extension },
    };
    const manifest = manifest_mod.BuildManifest{
        .module = "_jsonz",
        .version = "0.1.0",
        .zig_target = "example",
        .lib_dir = "zig-out/lib",
        .artifacts = &artifacts,
    };
    const entries = try selectWheelEntries(allocator, manifest, "_jsonz.cpython-312-darwin.so");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("_jsonz.cpython-312-darwin.so", entries[0]);
    try std.testing.expectEqualStrings("_jsonz.pyi", entries[1]);
    try std.testing.expectEqualStrings("py.typed", entries[2]);
}

test "buildWheelText uses tags separated by hyphen" {
    const allocator = std.testing.allocator;
    const text = try buildWheelText(allocator, "cp312", "cp312", "macosx_14_0_arm64");
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        "Wheel-Version: 1.0\nGenerator: pymz-tool\nRoot-Is-Purelib: false\nTag: cp312-cp312-macosx_14_0_arm64\n",
        text,
    );
}

test "buildMetadataText emits core metadata fields" {
    const allocator = std.testing.allocator;
    const manifest = manifest_mod.BuildManifest{
        .module = "_jsonz",
        .version = "0.1.0",
        .zig_target = "example",
        .lib_dir = "zig-out/lib",
        .distribution = "jsonz",
    };
    const metadata = Metadata{
        .description = "Zig-backed Python extension",
        .requires_python = ">=2.7",
        .license_text = "MIT",
    };
    const text = try buildMetadataText(allocator, manifest, metadata);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Metadata-Version: 2.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Name: jsonz") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Version: 0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Requires-Python: >=2.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "License: MIT") != null);
}

test "hashBytes matches sha256 hex of empty input" {
    const allocator = std.testing.allocator;
    const hash = try hashBytes(allocator, "");
    defer allocator.free(hash);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hash,
    );
}
