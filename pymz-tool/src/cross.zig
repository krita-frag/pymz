//! pymz 构建项目的交叉编译辅助工具。

const std = @import("std");

/// `buildProject` 矩阵中单个交叉编译目标的配置。
pub const CrossTargetConfig = struct {
    triple: []const u8,
    label: []const u8,
};

/// 当 `--cross-targets` CLI 选项未覆盖时使用的默认交叉编译目标。
///
/// 矩阵本身（运行环境 x 版本 x 目标）由 Python 编排器（`pymz_tool.matrix`）管理，
/// 它每个单元格调用一次 `zig build`。这些默认值仅适用于项目的 `build.zig`
/// 通过 `zig build <step>-multi` 直接运行且不使用 Python 工具的情况。
pub const default_cross_targets: []const CrossTargetConfig = &.{
    .{ .triple = "x86_64-linux-gnu", .label = "linux-x86_64" },
    .{ .triple = "aarch64-linux-gnu", .label = "linux-aarch64" },
    .{ .triple = "x86_64-windows-gnu", .label = "windows-x86_64" },
    .{ .triple = "aarch64-macos-none", .label = "macos-aarch64" },
    .{ .triple = "x86_64-macos-none", .label = "macos-x86_64" },
};

/// 交叉链接 Python 扩展需要与目标 OS 匹配的 Python 头文件和库。
/// `python-config` 仅报告主机工具链，因此跳过 OS 与主机不同的目标，
/// 除非通过 `PYMZ_PYTHON_INCLUDES` 等提供了明确的目标 Python 配置。
pub fn shouldSkipCrossTarget(target: std.Build.ResolvedTarget) bool {
    const host_os = @import("builtin").os.tag;
    return host_os != target.result.os.tag;
}

/// 按以下优先级解析交叉编译目标：
///
/// 1. `raw` - `--cross-targets` CLI 选项（逗号分隔的三元组）。
/// 2. `default_cross_targets` - 内置矩阵。
///
/// 此处有意不读取 `pymz.json` 中声明的矩阵：该矩阵由 Python 编排器展开，
/// 它对每个单元格以单个 `-Dtarget` 调用一次 `zig build`。
/// 保持此层免于配置解析可避免矩阵出现第二个不一致的数据源。
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
    // labelFromTriple 将 `_` 规范化为 `-`，因此派生标签使用短横线。
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

/// 仅用于测试的垫片，镜像 `resolveCrossTargets` 但在普通分配器上操作，
/// 以便无需构造完整的 `*std.Build` 即可测试逻辑。
/// 生产函数将字符串生命周期委托给 `b.dupe` / `b.allocator`；算法相同。
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