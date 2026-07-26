//! Type traits for Python object wrappers and conversions.
//!
//! Only the predicates actually consumed by the runtime live here. Adding a
//! predicate that has no call site is a KISS violation: it either advertises
//! an API surface that does nothing, or invites speculative callers that the
//! runtime does not actually support.

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
