//! Python 特殊方法（"dunder"）名称注册表，用于类生成过程。
//!
//! 本模块不维护独立的"哪些 dunder 被协议构建器处理"的静态列表，而是在编译期
//! 查询每个构建器的 ``handled_dunders`` 常量。这消除了双重真相源：构建器是
//! 其处理哪些 dunder 的唯一真相源，本模块仅聚合它们的答案。
//!
//! 用户可通过 ``pymz_meta`` 按类扩展注册表：
//!
//!   pub const pymz_meta = .{
//!       .excluded_dunders = &.{"__await__", "__aiter__"},
//!       .handled_dunders  = &.{"__await__"},
//!   };
//!
//! ``handled_dunders`` 优先级更高：被处理的 dunder 路由到协议子系统，
//! 而被排除的 dunder 则直接丢弃。

const std = @import("std");
const repr_mod = @import("repr.zig");
const protocol_mod = @import("protocol.zig");

pub const Category = enum {
    /// 由专门的协议构建器处理，而非通用方法表。
    handled,
    /// 完全忽略。
    excluded,
};

pub const Entry = struct {
    name: []const u8,
    category: Category,
};

/// 收集类型 T 的所有协议构建器处理的 dunder 名称。
/// 由 `classEntries` 和 `isHandledByBuilder` 共享的唯一真相源。
fn builderDunders(comptime T: type) []const []const u8 {
    comptime {
        var result: []const []const u8 = &.{};
        for (repr_mod.ReprBuilder(T).handled_dunders) |d| result = result ++ .{d};
        for (repr_mod.IteratorBuilder(T).handled_dunders) |d| result = result ++ .{d};
        for (protocol_mod.ProtocolBuilder(T).handled_dunders) |d| result = result ++ .{d};
        if (@hasDecl(T, "__buffer__")) result = result ++ .{"__buffer__"};
        if (@hasDecl(T, "__release_buffer__")) result = result ++ .{"__release_buffer__"};
        if (@hasDecl(T, "__traverse__")) result = result ++ .{"__traverse__"};
        if (@hasDecl(T, "__clear__")) result = result ++ .{"__clear__"};
        return result;
    }
}

/// 检查类型 T 的某个 dunder 名称是否被任何协议构建器处理。
///
/// 委托给 `builderDunders`，使构建器 dunder 注册表只定义一次。
/// ``__new__`` 和 ``__del__`` 通过 ``@hasDecl`` 直接检查，以避免经过
/// ``methods.zig`` → ``class_builder.zig`` 的循环导入。
fn isHandledByBuilder(comptime T: type, comptime name: []const u8) bool {
    // 生命周期特殊方法（直接检查以避免循环导入）。
    if (std.mem.eql(u8, name, "__new__")) return @hasDecl(T, "__new__");
    if (std.mem.eql(u8, name, "__del__")) return @hasDecl(T, "__del__");
    return for (builderDunders(T)) |dn| {
        if (std.mem.eql(u8, dn, name)) break true;
    } else false;
}

/// 构建合并的条目列表：构建器处理的 dunder + 按类的覆盖项。
inline fn classEntries(comptime T: type) []const Entry {
    comptime {
        @setEvalBranchQuota(2000);
        const handled = blk: {
            if (@hasDecl(T, "pymz_meta")) {
                const meta = T.pymz_meta;
                if (@hasField(@TypeOf(meta), "handled_dunders")) break :blk meta.handled_dunders;
            }
            break :blk &[_][]const u8{};
        };
        const excluded = blk: {
            if (@hasDecl(T, "pymz_meta")) {
                const meta = T.pymz_meta;
                if (@hasField(@TypeOf(meta), "excluded_dunders")) break :blk meta.excluded_dunders;
            }
            break :blk &[_][]const u8{};
        };

        const builder_list = builderDunders(T);
        var builder_count: usize = builder_list.len;
        // 如果声明了 __new__ 和 __del__，则计入。
        if (@hasDecl(T, "__new__")) builder_count += 1;
        if (@hasDecl(T, "__del__")) builder_count += 1;

        const total = builder_count + handled.len + excluded.len;
        var buf: [total]Entry = undefined;
        var idx: usize = 0;

        // 构建器处理的 dunder。
        for (builder_list) |dn| {
            buf[idx] = .{ .name = dn, .category = .handled };
            idx += 1;
        }
        if (@hasDecl(T, "__new__")) {
            buf[idx] = .{ .name = "__new__", .category = .handled };
            idx += 1;
        }
        if (@hasDecl(T, "__del__")) {
            buf[idx] = .{ .name = "__del__", .category = .handled };
            idx += 1;
        }
        // 按类处理的覆盖项。
        for (handled) |dn| {
            buf[idx] = .{ .name = dn, .category = .handled };
            idx += 1;
        }
        // 按类排除的覆盖项。
        for (excluded) |dn| {
            buf[idx] = .{ .name = dn, .category = .excluded };
            idx += 1;
        }

        const final = buf;
        return &final;
    }
}

/// 查找类 `T` 的 dunder 条目。
pub inline fn find(comptime T: type, comptime name: []const u8) ?Category {
    const entries = classEntries(T);
    inline for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.category;
        }
    }
    return null;
}

/// 如果 dunder 不应该出现在类 `T` 的常规方法表中，则返回 true。
/// 这包括"已处理"的 dunder（路由到协议构建器）和"已排除"的 dunder（直接丢弃）。
pub inline fn isReservedDunder(comptime T: type, comptime name: []const u8) bool {
    return find(T, name) != null;
}

/// 如果 dunder 由类 `T` 的协议构建器处理，则返回 true。
pub inline fn isHandled(comptime T: type, comptime name: []const u8) bool {
    return find(T, name) == .handled;
}
