//! Registry of Python special method ("dunder") names used during class generation.
//!
//! Instead of maintaining a separate static list of "which dunders are handled
//! by protocol builders", this module queries each builder's ``handled_dunders``
//! constant at comptime. This eliminates the dual source of truth: the builders
//! are the single source of truth for which dunders they handle, and this
//! module just aggregates their answers.
//!
//! Users can still extend the registry per-class by declaring:
//!
//!   pub const __pymz_excluded_dunders__ = &.{"__await__", "__aiter__"};
//!   pub const __pymz_handled_dunders__  = &.{"__await__"};
//!
//! `__pymz_handled_dunders__` takes precedence: a handled dunder is routed to
//! the protocol subsystem, while an excluded dunder is simply dropped.

const std = @import("std");
const repr_mod = @import("repr.zig");
const protocol_mod = @import("protocol.zig");

pub const Category = enum {
    /// Handled by a dedicated protocol builder, not the generic method table.
    handled,
    /// Ignored entirely.
    excluded,
};

pub const Entry = struct {
    name: []const u8,
    category: Category,
};

/// Collect all dunder names handled by protocol builders for type T.
/// Single source of truth shared by `classEntries` and `isHandledByBuilder`.
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

/// Check if a dunder name is handled by any protocol builder for type T.
///
/// Delegates to `builderDunders` so the builder dunder registry is defined
/// exactly once. ``__new__`` and ``__del__`` are checked via ``@hasDecl``
/// directly to avoid a circular import through ``methods.zig`` →
/// ``class_builder.zig``.
fn isHandledByBuilder(comptime T: type, comptime name: []const u8) bool {
    // Lifecycle dunders (checked directly to avoid circular import).
    if (std.mem.eql(u8, name, "__new__")) return @hasDecl(T, "__new__");
    if (std.mem.eql(u8, name, "__del__")) return @hasDecl(T, "__del__");
    return for (builderDunders(T)) |dn| {
        if (std.mem.eql(u8, dn, name)) break true;
    } else false;
}

/// Build the combined entry list: builder-handled dunders + per-class overrides.
inline fn classEntries(comptime T: type) []const Entry {
    comptime {
        const handled = if (@hasDecl(T, "__pymz_handled_dunders__")) T.__pymz_handled_dunders__ else &[_][]const u8{};
        const excluded = if (@hasDecl(T, "__pymz_excluded_dunders__")) T.__pymz_excluded_dunders__ else &[_][]const u8{};

        const builder_list = builderDunders(T);
        var builder_count: usize = builder_list.len;
        // __new__ and __del__ if declared.
        if (@hasDecl(T, "__new__")) builder_count += 1;
        if (@hasDecl(T, "__del__")) builder_count += 1;

        const total = builder_count + handled.len + excluded.len;
        var buf: [total]Entry = undefined;
        var idx: usize = 0;

        // Builder-handled dunders.
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
        // Per-class handled overrides.
        for (handled) |dn| {
            buf[idx] = .{ .name = dn, .category = .handled };
            idx += 1;
        }
        // Per-class excluded overrides.
        for (excluded) |dn| {
            buf[idx] = .{ .name = dn, .category = .excluded };
            idx += 1;
        }

        const final = buf;
        return &final;
    }
}

/// Lookup a dunder entry for class `T`.
pub inline fn find(comptime T: type, comptime name: []const u8) ?Category {
    const entries = classEntries(T);
    inline for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.category;
        }
    }
    return null;
}

/// True if the dunder should not appear in the regular method table for class `T`.
/// This covers both "handled" dunders (routed to protocol builders) and
/// "excluded" dunders (dropped entirely).
pub inline fn isReservedDunder(comptime T: type, comptime name: []const u8) bool {
    return find(T, name) != null;
}

/// True if the dunder is handled by a protocol builder for class `T`.
pub inline fn isHandled(comptime T: type, comptime name: []const u8) bool {
    return find(T, name) == .handled;
}
