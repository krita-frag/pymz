//! Zig 值与 Python 对象之间的转换辅助函数。
//!
//! 本模块只负责转换层：`toPy` / `fromPy`、`PymzConvert` trait、值清理
//!（`releaseValue`、`releaseStructFields`）以及列表辅助函数。参数提取和
//! 返回值管道（`extractPositionalArg`、`handleReturn`、`releaseArgsTuple`...）
//! 在 `marshal.zig` 中，后者导入本模块使用转换原语。将两个职责分开使各模块
//! 保持专注；依赖关系是单向的（`marshal` -> `convert`）。

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const compat = @import("compat.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
const mem = @import("../../mem.zig");
const Object = object.Object;
const Error = errors.Error;

/// 正式转换 trait。类型可声明：
///
///   pub const PymzConvert = struct {
///       pub fn intoPy(value: T) Error!*Object { ... }
///       pub fn fromPy(obj: *Object) Error!T { ... }
///   };
///
/// 或者使用简化的直接声明约定：
///
///   pub fn toPy(self: T) Error!*Object { ... }
///   pub fn fromPy(obj: *Object) Error!T { ... }
///
/// 然后 `toPy`/`fromPy` 会自动使用它。两种约定可共存，`PymzConvert` 优先。
/// Check if type T has a user-defined conversion, either via `PymzConvert`
/// or via direct `toPy`/`fromPy` declarations. Only container types can
/// have declarations; non-container types always return false.
pub fn hasUserToPy(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "PymzConvert") or @hasDecl(T, "toPy"),
        else => false,
    };
}

pub fn hasUserFromPy(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "PymzConvert") or @hasDecl(T, "fromPy"),
        else => false,
    };
}

/// Dispatch to the user's toPy conversion. PymzConvert.intoPy takes precedence
/// over direct `pub fn toPy`.
pub inline fn userToPy(value: anytype) Error!*Object {
    const T = @TypeOf(value);
    if (comptime @hasDecl(T, "PymzConvert")) {
        return T.PymzConvert.intoPy(value);
    }
    return @field(T, "toPy")(value);
}

/// Dispatch to the user's fromPy conversion. PymzConvert.fromPy takes precedence
/// over direct `pub fn fromPy`.
pub inline fn userFromPy(comptime T: type, obj: *Object) Error!T {
    if (comptime @hasDecl(T, "PymzConvert")) {
        return T.PymzConvert.fromPy(obj);
    }
    return @field(T, "fromPy")(obj);
}

pub fn isOwnedBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8 and !p.is_const,
        else => false,
    };
}

/// 将编译期已知的字节切片转换为哨兵终止的 `[:0]const u8`，无需拷贝。
/// 哨兵字节在编译期追加。
pub fn toSentinelStr(comptime s: []const u8) [:0]const u8 {
    return (s ++ "\x00")[0..s.len :0];
}

/// 释放转换后的值所拥有的临时资源。
/// `value` 必须是指向参数/字段的指针。
pub fn releaseValue(value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .pointer) @compileError("releaseValue expects a pointer");
    const ChildT = @typeInfo(T).pointer.child;

    if (comptime isOwnedBytes(ChildT)) {
        mem.allocator.free(value.*);
        return;
    }

    if (@typeInfo(ChildT) == .optional) {
        if (value.*) |*inner| {
            const InnerT = @TypeOf(inner.*);
            if (@typeInfo(InnerT) == .pointer) return;
            if (comptime isOwnedBytes(InnerT)) {
                mem.allocator.free(inner.*);
                return;
            }
            if (@typeInfo(InnerT) == .@"struct" and traits.isArrayList(InnerT)) {
                inner.deinit(mem.allocator);
                inner.* = .empty;
                return;
            }
            // StringHashMap 在此处故意不处理：toPyStruct / fromPyStruct 不转换
            // StringHashMap，因此转换后的值不可能是 StringHashMap，无需释放。
        }
        return;
    }

    if (@typeInfo(ChildT) == .@"struct" and traits.isArrayList(ChildT)) {
        value.*.deinit(mem.allocator);
        value.* = .empty;
        return;
    }
    // StringHashMap 在此处故意不处理，理由同上：没有转换路径会产生它，
    // 因此此分支不可达。
}

/// 将 Zig 值转换为 Python 对象。
///
/// 始终返回一个新引用（NEW reference）。调用方拥有返回的引用，必须最终
/// decref（或转移所有权给会窃取引用的容器，如 `Tuple.setUnsafe` 或
/// `List.set`）。指针输入（如 `*Object`）在调用期间视为借用：`toPy` 在
/// 返回前会 incref，因此调用方的原始引用不受影响。
pub fn toPy(value: anytype) Error!*Object {
    // 防御性 GIL 检查：所有 toPy 路径最终都会调用 CPython C API 构造对象，
    // 调用方必须已持有 GIL。Debug/ReleaseSafe 构建触发断言；
    // ReleaseFast 中 PyGILState_Check 调用开销不可避免但断言指令被移除。
    errors.assertGILHeldByCurrentThread();
    const T = @TypeOf(value);
    // User-defined conversion (PymzConvert trait or direct toPy) takes
    // precedence over built-in conversions for all container types.
    if (comptime hasUserToPy(T)) {
        return userToPy(value);
    }
    switch (@typeInfo(T)) {
        .int => return @ptrCast(try types.Int.from(value)),
        .comptime_int => return @ptrCast(try types.Int.from(value)),
        .float => return @ptrCast(try types.Float.from(value)),
        .comptime_float => return @ptrCast(try types.Float.from(value)),
        .bool => return object.returnBool(value),
        .void => return object.returnNone(),
        .@"enum" => {
            return @ptrCast(try types.Int.from(@intFromEnum(value)));
        },
        .pointer => return try toPyPointer(T, value),
        .array => |arr| {
            const list = try types.List.new(arr.len);
            errdefer list.decref();
            for (0..arr.len) |i| {
                const item = try toPy(value[i]);
                try list.set(i, item);
            }
            return @ptrCast(list);
        },
        .vector => |v| {
            const list = try types.List.new(v.len);
            errdefer list.decref();
            for (0..v.len) |i| {
                const item = try toPy(value[i]);
                try list.set(i, item);
            }
            return @ptrCast(list);
        },
        .@"struct" => return try toPyStruct(T, value),
        .@"union" => return try toPyUnion(T, value),
        .optional => {
            if (value) |inner| return try toPy(inner);
            return object.returnNone();
        },
        .error_union => {
            if (value) |inner| {
                return try toPy(inner);
            } else |err| {
                errors.mapError(err);
                return error.PyError;
            }
        },
        else => @compileError(std.fmt.comptimePrint("toPy: cannot convert {s}", .{@typeName(T)})),
    }
}

/// `toPy` 的指针分支。处理借用的 PyObject 指针、字节切片、哨兵终止字符串
/// 和通用切片。
fn toPyPointer(comptime T: type, value: T) Error!*Object {
    const ptr_info = @typeInfo(T).pointer;
    // 借用的 PyObject 指针会被 incref，以便调用方始终收到新引用。
    // 这使得 `toPy` 可组合：调用方可以将结果传递给窃取引用的 API
    //（PyList_SetItem、PyTuple_SetItem）或借用引用的 API
    //（PyDict_SetItemString），而无需担心引用计数下溢。
    if (traits.isObjectPtr(T)) {
        value.incref();
        return @ptrCast(value);
    }
    if (ptr_info.child == c.PyObject) {
        @as(*object.Object, @ptrCast(value)).incref();
        return @ptrCast(value);
    }

    if (ptr_info.size == .slice and ptr_info.child == u8) {
        if (ptr_info.is_const) {
            return @ptrCast(try object.Str.fromSlice(value));
        } else {
            return @ptrCast(try object.Bytes.fromSlice(value));
        }
    }
    if (ptr_info.size == .many and ptr_info.child == u8 and ptr_info.sentinel_ptr != null) {
        return @ptrCast(try object.Str.fromSlice(std.mem.span(value)));
    }
    if (ptr_info.size == .one) {
        const child_info = @typeInfo(ptr_info.child);
        if (child_info == .array and child_info.array.child == u8 and child_info.array.sentinel_ptr != null) {
            return @ptrCast(try object.Str.fromSlice(std.mem.sliceTo(value, 0)));
        }
    }
    // 通用切片（非字节）→ Python 列表。
    if (ptr_info.size == .slice) {
        const list = try types.List.new(value.len);
        errdefer list.decref();
        for (0..value.len) |i| {
            const obj = try toPy(value[i]);
            try list.set(i, obj);
        }
        return @ptrCast(list);
    }
    @compileError(std.fmt.comptimePrint("toPy: cannot convert pointer type {s}", .{@typeName(T)}));
}

/// `toPy` 的结构体分支。处理元组结构体、
/// `ArrayList` 包装器和普通结构体（转换为字典）。
/// 注意：`PymzConvert` trait 和直接 `toPy` 声明的检查在 `toPy` 入口处完成，
/// 此处不再重复检查。
fn toPyStruct(comptime T: type, value: T) Error!*Object {
    const struct_info = @typeInfo(T).@"struct";

    if (struct_info.is_tuple) {
        const tuple = try types.Tuple.new(struct_info.fields.len);
        errdefer tuple.decref();
        inline for (struct_info.fields, 0..) |field, i| {
            const item = try toPy(@field(value, field.name));
            try tuple.setUnsafe(i, item);
        }
        return @ptrCast(tuple);
    }

    if (traits.isArrayList(T)) {
        // 不消费 ArrayList：toPy 仅读取 items 切片构造 Python 列表，
        // 不调用 deinit——调用方仍拥有原 ArrayList 并负责其生命周期。
        // 先前实现在此 deinit 一个 by-value 拷贝，但 ArrayList 是 fat-pointer
        // struct（items 切片共享 backing buffer），拷贝的 deinit 会释放调用方
        // 仍持有的 buffer，造成 use-after-free。
        const list = try types.List.new(value.items.len);
        errdefer list.decref();
        for (0..value.items.len) |i| {
            const item = try toPy(value.items[i]);
            try list.set(i, item);
        }
        return @ptrCast(list);
    }

    const dict = try types.Dict.new();
    errdefer dict.decref();
    inline for (struct_info.fields) |field| {
        const key_z: [:0]const u8 = comptime toSentinelStr(field.name);
        const field_obj = try toPy(@field(value, field.name));
        defer field_obj.decref();
        try dict.setItemString(key_z, field_obj);
    }
    return @ptrCast(dict);
}

/// `toPy` 的联合体分支。带标签的联合体转换为 `(tag_name, payload)` 元组；
/// 无标签的联合体是编译错误。
fn toPyUnion(comptime T: type, value: T) Error!*Object {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError(std.fmt.comptimePrint("toPy: cannot convert untagged union {s}", .{@typeName(T)}));
    }
    const Tag = union_info.tag_type.?;

    // switch + inline else 在编译期展开所有联合体分支，消除 unreachable。
    switch (value) {
        inline else => |payload| {
            const tag_name = @tagName(@as(Tag, value));
            const name_obj = try object.Str.fromSlice(tag_name);
            defer name_obj.decref();
            const payload_obj = try toPy(payload);
            defer payload_obj.decref();
            const tuple = try types.Tuple.new(2);
            errdefer tuple.decref();
            name_obj.incref();
            try tuple.setUnsafe(0, @ptrCast(name_obj));
            payload_obj.incref();
            try tuple.setUnsafe(1, payload_obj);
            return @ptrCast(tuple);
        },
    }
}

/// 返回 `obj` 的 Python 类型名（如 "str"、"int"）。从 `obj` 借用。
pub fn pyTypeName(obj: *Object) [:0]const u8 {
    const typ = c.PyObject_Type(@as(*c.PyObject, @ptrCast(obj))) orelse return "unknown";
    defer object.decrefRaw(typ);
    if (comptime !version.is_limited_api) {
        return std.mem.span(@as(*c.PyTypeObject, @ptrCast(typ)).*.tp_name);
    }
    const name_obj = c.PyObject_GetAttrString(typ, "__name__") orelse {
        c.PyErr_Clear();
        return "unknown";
    };
    defer object.decrefRaw(name_obj);
    return compat.strAsString(name_obj) orelse "unknown";
}

pub fn fromPy(comptime T: type, obj: *Object) Error!T {
    // 防御性 GIL 检查：fromPy 通过 CPython C API 读取对象状态（PyLong_AsLong、
    // PyUnicode_AsUTF8 等），调用方必须已持有 GIL。
    errors.assertGILHeldByCurrentThread();
    // User-defined conversion (PymzConvert trait or direct fromPy) takes
    // precedence over built-in conversions for all container types.
    if (comptime hasUserFromPy(T)) {
        return userFromPy(T, obj);
    }
    switch (@typeInfo(T)) {
        .int => {
            if (!types.Int.check(obj)) {
                errors.typeError("expected int, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            return types.Int.as(@ptrCast(obj), T);
        },
        .float => {
            if (types.Float.check(obj)) {
                return types.Float.as(@ptrCast(obj), T);
            }
            // Use PyFloat_AsDouble for any object supporting __float__ (including int),
            // avoiding overflow when converting large Python ints to i64 first.
            const val = c.PyFloat_AsDouble(@as(*c.PyObject, @ptrCast(obj)));
            if (val == -1.0 and c.PyErr_Occurred() != null) return error.PyError;
            return @as(T, @floatCast(val));
        },
        .bool => {
            if (types.Bool.check(obj)) return @as(*types.Bool, @ptrCast(obj)).as();
            return compat.cApiTriState(c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(obj))));
        },
        .@"enum" => |enum_info| {
            if (!types.Int.check(obj)) {
                errors.typeError("expected int, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            const tag_value = try types.Int.as(@ptrCast(obj), enum_info.tag_type);
            inline for (enum_info.fields) |field| {
                if (field.value == tag_value) {
                    return @enumFromInt(tag_value);
                }
            }
            errors.valueError("{d} is not a valid {s}", .{ tag_value, @typeName(T) });
            return error.PyError;
        },
        .pointer => return try fromPyPointer(T, obj),
        .optional => |opt_info| {
            if (obj.isNone()) return null;
            return try fromPy(opt_info.child, obj);
        },
        .@"struct" => return try fromPyStruct(T, obj),
        .@"union" => return try fromPyUnion(T, obj),
        else => @compileError(std.fmt.comptimePrint("fromPy: cannot convert to {s}", .{@typeName(T)})),
    }
}

/// `fromPy` 的指针分支。处理 PyObject 指针、字节切片（const 和 mutable）
/// 以及哨兵终止字符串。
fn fromPyPointer(comptime T: type, obj: *Object) Error!T {
    const ptr_info = @typeInfo(T).pointer;
    if (traits.isObjectPtr(T)) {
        if (ptr_info.child != Object) {
            const Child = ptr_info.child;
            if (@hasDecl(Child, "check")) {
                if (!Child.check(obj)) {
                    errors.typeError("expected {s}, got {s}", .{ @typeName(Child), pyTypeName(obj) });
                    return error.PyError;
                }
            } else {
                @compileError("fromPy: cannot type-check pointer to " ++ @typeName(Child));
            }
        }
        return @ptrCast(obj);
    }
    if (ptr_info.child == c.PyObject) return @ptrCast(obj);

    if (ptr_info.size == .slice and ptr_info.child == u8 and ptr_info.is_const) {
        if (object.Str.check(obj)) {
            return try object.Str.asString(@ptrCast(obj));
        }
        if (object.Bytes.check(obj)) {
            return try @as(*object.Bytes, @ptrCast(obj)).asSlice();
        }
        if (object.ByteArray.check(obj)) {
            return try @as(*object.ByteArray, @ptrCast(obj)).asSlice();
        }
        errors.typeError("expected str, bytes or bytearray, got {s}", .{pyTypeName(obj)});
        return error.PyError;
    }
    if (ptr_info.size == .slice and ptr_info.child == u8 and !ptr_info.is_const) {
        const src = blk: {
            if (object.Bytes.check(obj)) {
                break :blk try @as(*object.Bytes, @ptrCast(obj)).asSlice();
            }
            if (object.ByteArray.check(obj)) {
                break :blk try @as(*object.ByteArray, @ptrCast(obj)).asSlice();
            }
            errors.typeError("expected bytes or bytearray, got {s}", .{pyTypeName(obj)});
            return error.PyError;
        };
        return mem.allocator.dupe(u8, src) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
            return error.PyError;
        };
    }
    @compileError(std.fmt.comptimePrint("fromPy: cannot convert to pointer type {s}", .{@typeName(T)}));
}

/// `fromPy` 的结构体分支。处理元组结构体、
/// `ArrayList` 包装器和普通结构体（从字典转换）。
/// 注意：`PymzConvert` trait 和直接 `fromPy` 声明的检查在 `fromPy` 入口处完成，
/// 此处不再重复检查。
fn fromPyStruct(comptime T: type, obj: *Object) Error!T {
    const struct_info = @typeInfo(T).@"struct";

    if (struct_info.is_tuple) {
        if (!types.Tuple.check(obj)) {
            errors.typeError("expected tuple, got {s}", .{pyTypeName(obj)});
            return error.PyError;
        }
        const tuple = @as(*types.Tuple, @ptrCast(obj));
        if (tuple.length() != struct_info.fields.len) {
            errors.typeError("expected tuple of length {d}, got {d}", .{ struct_info.fields.len, tuple.length() });
            return error.PyError;
        }
        var result: T = undefined;
        inline for (struct_info.fields, 0..) |field, i| {
            const py_item = tuple.get(i) orelse {
                errors.typeError("tuple index {d} out of range", .{i});
                releaseStructFields(&result, i);
                return error.PyError;
            };
            @field(result, field.name) = fromPy(field.type, py_item) catch {
                releaseStructFields(&result, i);
                return error.PyError;
            };
        }
        return result;
    }

    if (traits.isArrayList(T)) {
        if (!types.List.check(obj)) {
            errors.typeError("expected list, got {s}", .{pyTypeName(obj)});
            return error.PyError;
        }
        return try listToArrayList(traits.arrayListItemType(T), @ptrCast(obj));
    }

    if (!types.Dict.check(obj)) {
        errors.typeError("expected dict, got {s}", .{pyTypeName(obj)});
        return error.PyError;
    }
    const dict = @as(*types.Dict, @ptrCast(obj));
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        const key_z: [:0]const u8 = comptime toSentinelStr(field.name);
        const py_item = c.PyDict_GetItemString(@as(*c.PyObject, @ptrCast(dict)), key_z.ptr);
        if (py_item) |item| {
            @field(result, field.name) = fromPy(field.type, @ptrCast(item)) catch {
                releaseStructFields(&result, i);
                return error.PyError;
            };
        } else if (field.default_value_ptr) |dv| {
            @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(dv))).*;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            errors.typeError("missing required key '{s}' for {s}", .{ field.name, @typeName(T) });
            releaseStructFields(&result, i);
            return error.PyError;
        }
    }
    return result;
}

/// `fromPy` 的联合体分支。期望 `(tag_name, payload)` 元组，并分发到
/// 匹配的联合体字段。
fn fromPyUnion(comptime T: type, obj: *Object) Error!T {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError(std.fmt.comptimePrint("fromPy: cannot convert to untagged union {s}", .{@typeName(T)}));
    }
    if (!types.Tuple.check(obj)) {
        errors.typeError("expected tuple for tagged union, got {s}", .{pyTypeName(obj)});
        return error.PyError;
    }
    const tuple = @as(*types.Tuple, @ptrCast(obj));
    if (tuple.length() != 2) {
        errors.typeError("expected union tuple of length 2, got {d}", .{tuple.length()});
        return error.PyError;
    }
    const tag_obj = tuple.get(0) orelse {
        errors.typeError("missing union tag", .{});
        return error.PyError;
    };
    const payload_obj = tuple.get(1) orelse {
        errors.typeError("missing union payload", .{});
        return error.PyError;
    };
    const tag_name = try fromPy([]const u8, tag_obj);
    defer releaseValue(&tag_name);

    inline for (union_info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, tag_name)) {
            const payload = try fromPy(field.type, payload_obj);
            return @unionInit(T, field.name, payload);
        }
    }
    errors.valueError("'{s}' is not a valid tag for {s}", .{ tag_name, @typeName(T) });
    return error.PyError;
}

pub fn releaseStructFields(value: anytype, count: usize) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, idx| {
        if (idx < count) {
            releaseValue(&@field(value, field.name));
        }
    }
}

pub fn listToArrayList(comptime T: type, list: *types.List) Error!std.ArrayList(T) {
    const len = list.length();
    var result = std.ArrayList(T).initCapacity(mem.allocator, len) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
        return error.PyError;
    };
    errdefer {
        // 释放已添加的元素，释放释放缓冲区。
        // 如果不这样做，从 mem.allocator.dupe 创建的 []u8 元素会泄漏。
        for (result.items) |*item| {
            releaseValue(item);
        }
        result.deinit(mem.allocator);
    }
    for (0..len) |i| {
        const item = list.get(i) orelse break;
        const converted = fromPy(T, item) catch |err| {
            return err;
        };
        result.append(mem.allocator, converted) catch {
            // append 失败；释放未添加的转换值。
            // 这样可以确保在失败时不会泄漏任何内存。
            releaseValue(&converted);
            c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
            return error.PyError;
        };
    }
    return result;
}

test "releaseValue handles null optional borrowed types safely" {
    var maybe_obj: ?*Object = null;
    releaseValue(&maybe_obj);

    var maybe_slice: ?[]const u8 = null;
    releaseValue(&maybe_slice);
}

test "releaseValue deinits optional ArrayList on configured allocator" {
    const allocator = mem.allocator;
    var maybe_list: ?std.ArrayList(u8) = .empty;
    try maybe_list.?.append(allocator, 1);
    try std.testing.expect(maybe_list.?.capacity > 0);
    releaseValue(&maybe_list);
    try std.testing.expectEqual(@as(usize, 0), maybe_list.?.capacity);
}
