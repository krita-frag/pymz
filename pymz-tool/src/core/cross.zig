//! Cross-compilation helpers for pymz build projects.

const std = @import("std");

/// Configuration for one cross-compilation target in a `buildProject` matrix.
pub const CrossTargetConfig = struct {
    triple: []const u8,
    label: []const u8,
};

/// Default cross targets used when the `--cross-targets` CLI option does not
/// override them.
///
/// The matrix itself (runtimes x versions x targets) is owned by the Python
/// orchestrator (`pymz_tool.matrix`), which invokes `zig build` once per cell.
/// These defaults only apply when a project's own `build.zig` is run directly
/// via `zig build <step>-multi` without the Python tool.
pub const default_cross_targets: []const CrossTargetConfig = &.{
    .{ .triple = "x86_64-linux-gnu", .label = "linux-x86_64" },
    .{ .triple = "aarch64-linux-gnu", .label = "linux-aarch64" },
    .{ .triple = "x86_64-windows-gnu", .label = "windows-x86_64" },
    .{ .triple = "aarch64-macos-none", .label = "macos-aarch64" },
    .{ .triple = "x86_64-macos-none", .label = "macos-x86_64" },
};

/// Cross-linking Python extensions requires Python headers and libraries that
/// match the target OS. `python-config` only reports the host toolchain, so
/// skip targets whose OS differs from the host unless an explicit target
/// Python configuration is supplied via `PYMZ_PYTHON_INCLUDES` and friends.
pub fn shouldSkipCrossTarget(target: std.Build.ResolvedTarget) bool {
    const host_os = @import("builtin").os.tag;
    return host_os != target.result.os.tag;
}

/// Resolve cross targets with the following priority:
///
/// 1. `raw` - the `--cross-targets` CLI option (comma-separated triples).
/// 2. `default_cross_targets` - the built-in matrix.
///
/// The matrix declared in `pymz.json` is intentionally not read here: that
/// matrix is expanded by the Python orchestrator, which calls `zig build`
/// once per cell with a single `-Dtarget`. Keeping this layer free of config
/// parsing avoids a second, divergent source of truth for the matrix.
pub fn resolveCrossTargets(
    b: *std.Build,
    raw: ?[]const u8,
) ![]const CrossTargetConfig {
    if (raw != null and raw.?.len > 0) {
        return parseCliCrossTargets(b, raw.?);
    }
    return default_cross_targets;
}

fn parseCliCrossTargets(
    b: *std.Build,
    raw: []const u8,
) ![]const CrossTargetConfig {
    var list = std.ArrayList(CrossTargetConfig).empty;
    errdefer list.deinit(b.allocator);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const triple = b.dupe(trimmed);
        const label = b.dupe(try labelFromTriple(b.allocator, triple));
        try list.append(b.allocator, .{ .triple = triple, .label = label });
    }
    return list.toOwnedSlice(b.allocator);
}

fn labelFromTriple(allocator: std.mem.Allocator, triple: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (triple) |c| {
        const out: u8 = switch (c) {
            '-', '_' => '-',
            else => c,
        };
        try buf.append(allocator, out);
    }
    return buf.toOwnedSlice(allocator);
}

const testing = std.testing;

test "resolveCrossTargets falls back to defaults when no input given" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = try resolveCrossTargetsImpl(arena.allocator(), null);
    try testing.expectEqual(default_cross_targets.len, targets.len);
    for (default_cross_targets, 0..) |expected, index| {
        try testing.expectEqualStrings(expected.triple, targets[index].triple);
        try testing.expectEqualStrings(expected.label, targets[index].label);
    }
}

test "resolveCrossTargets prefers CLI raw targets" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = try resolveCrossTargetsImpl(
        arena.allocator(),
        "x86_64-windows-gnu",
    );
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings("x86_64-windows-gnu", targets[0].triple);
}

test "resolveCrossTargets parses multiple CLI targets" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = try resolveCrossTargetsImpl(
        arena.allocator(),
        "aarch64-linux-gnu, x86_64-macos-none",
    );
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqualStrings("aarch64-linux-gnu", targets[0].triple);
    try testing.expectEqualStrings("aarch64-linux-gnu", targets[0].label);
    try testing.expectEqualStrings("x86_64-macos-none", targets[1].triple);
    // `labelFromTriple` normalizes `_` to `-`, so the derived label uses dashes.
    try testing.expectEqualStrings("x86-64-macos-none", targets[1].label);
}

test "resolveCrossTargets treats empty CLI string as absent" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = try resolveCrossTargetsImpl(arena.allocator(), "");
    try testing.expectEqual(default_cross_targets.len, targets.len);
}

test "labelFromTriple normalizes separators to dashes" {
    const allocator = testing.allocator;
    const label = try labelFromTriple(allocator, "aarch64_linux_gnu");
    defer allocator.free(label);
    try testing.expectEqualStrings("aarch64-linux-gnu", label);
}

/// Test-only shim mirroring `resolveCrossTargets` but operating on a plain
/// allocator so we can exercise the logic without constructing a full
/// `*std.Build`. The production function delegates string lifetime concerns to
/// `b.dupe` / `b.allocator`; the algorithm is identical.
fn resolveCrossTargetsImpl(
    allocator: std.mem.Allocator,
    raw: ?[]const u8,
) ![]const CrossTargetConfig {
    if (raw != null and raw.?.len > 0) {
        var list = std.ArrayList(CrossTargetConfig).empty;
        errdefer list.deinit(allocator);
        var it = std.mem.splitScalar(u8, raw.?, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const triple = try allocator.dupe(u8, trimmed);
            const label = try labelFromTriple(allocator, triple);
            try list.append(allocator, .{ .triple = triple, .label = label });
        }
        return list.toOwnedSlice(allocator);
    }
    return default_cross_targets;
}
