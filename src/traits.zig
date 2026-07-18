//! Type traits for Python object wrappers.

pub inline fn isObjectPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| @hasDecl(info.child, "IS_PYOBJECT"),
        else => false,
    };
}

pub inline fn isObjectPtrOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| isObjectPtr(info.child),
        else => false,
    };
}
