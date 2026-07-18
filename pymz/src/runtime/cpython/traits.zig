//! Type traits for Python object wrappers and conversions.

const std = @import("std");

/// Check if T is a pointer to a struct with IS_PYOBJECT (i.e. a pymz wrapper).
pub inline fn isObjectPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| @typeInfo(info.child) == .@"struct" and @hasDecl(info.child, "IS_PYOBJECT"),
        else => false,
    };
}

/// Check if T is an optional of an object pointer.
pub inline fn isObjectPtrOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| isObjectPtr(info.child),
        else => false,
    };
}

/// Check if T is a signed or unsigned integer type (not comptime_int).
pub inline fn isInt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => false,
    };
}

/// Check if T is a float type (not comptime_float).
pub inline fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        else => false,
    };
}

/// Check if T is a string slice ([]const u8 or [:0]const u8).
pub inline fn isStringSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => info.child == u8,
            .many => info.child == u8 and info.sentinel_ptr != null,
            .one => blk: {
                const child_info = @typeInfo(info.child);
                if (child_info != .array) break :blk false;
                break :blk child_info.array.child == u8 and child_info.array.sentinel_ptr != null;
            },
            else => false,
        },
        else => false,
    };
}

/// Check if T is an optional type.
pub inline fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// Check if T is an error union.
pub inline fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Check if T is void.
pub inline fn isVoid(comptime T: type) bool {
    return T == void;
}

/// Check if a function type has any optional (?T) parameters.
pub fn hasOptionalParams(comptime Fn: type) bool {
    const info = @typeInfo(Fn);
    if (info != .@"fn") return false;
    for (info.@"fn".params) |param| {
        const ptype = param.type orelse continue;
        if (@typeInfo(ptype) == .optional) return true;
    }
    return false;
}

/// Check if T looks like an std.ArrayList: a struct with `items`, `capacity`
/// fields and an `append` method.
pub inline fn isArrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasField(T, "items") and
        @hasField(T, "capacity") and
        @hasDecl(T, "append");
}

/// Return the element type of an ArrayList-like container.
pub inline fn arrayListItemType(comptime T: type) type {
    const items_field = @typeInfo(T).@"struct".fields;
    inline for (items_field) |f| {
        if (comptime std.mem.eql(u8, f.name, "items")) {
            return @typeInfo(f.type).pointer.child;
        }
    }
    @compileError("arrayListItemType: T has no 'items' field");
}

/// Check if T is an std.StringHashMap(V): a struct wrapping an `unmanaged`
/// hash map with string keys.
pub inline fn isStringHashMap(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasField(T, "unmanaged")) return false;
    const Unmanaged = @TypeOf(@field(@as(T, undefined), "unmanaged"));
    if (@typeInfo(Unmanaged) != .@"struct") return false;
    return @hasDecl(Unmanaged, "deinit") and @hasField(Unmanaged, "metadata");
}
