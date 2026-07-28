//! Python 对象包装器和转换的类型 trait。
//!
//! 只有运行时实际消费的谓词在此存放。添加一个没有调用点的谓词是 KISS 违反：
//! 要么它广告了一个无用的 API 表面，要么会引诱运行时实际上不支持的投机调用者。

const std = @import("std");

/// 检查 T 是否是指向带有 IS_PYOBJECT 的结构体的指针（即 pymz 包装器）。
pub inline fn isObjectPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| @typeInfo(info.child) == .@"struct" and @hasDecl(info.child, "IS_PYOBJECT"),
        else => false,
    };
}

/// 检查 T 是否是对象指针的 Optional。
pub inline fn isObjectPtrOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| isObjectPtr(info.child),
        else => false,
    };
}

/// 检查 T 是否类似于 std.ArrayList：具有 `items`、`capacity` 字段和 `append` 方法的结构体。
pub inline fn isArrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasField(T, "items") and
        @hasField(T, "capacity") and
        @hasDecl(T, "append");
}

/// 返回类似 ArrayList 容器的元素类型。
pub inline fn arrayListItemType(comptime T: type) type {
    const items_field = @typeInfo(T).@"struct".fields;
    inline for (items_field) |f| {
        if (comptime std.mem.eql(u8, f.name, "items")) {
            return @typeInfo(f.type).pointer.child;
        }
    }
    @compileError("arrayListItemType: T has no 'items' field");
}