//! Conversion helpers between Zig values and Python objects.
//!
//! `toPy` converts a Zig value into a new Python object (stealing nothing).
//! `fromPy` extracts a Zig value from a Python object, type-checking and
//! raising a Python TypeError on mismatch.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const compat = @import("compat.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
const mem = @import("../../mem.zig");
const Object = object.Object;
const Error = errors.Error;

// ============================================================================
// Zig → Python  (toPy)
// ============================================================================

/// Convert a Zig value into a Python object.
/// Returns a new (or borrowed singleton) reference.
pub fn toPy(value: anytype) Error!*Object {
    const T = @TypeOf(value);
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
        .pointer => |ptr_info| {
            // *Object or *Str etc. — already a Python object pointer
            if (traits.isObjectPtr(T)) return @ptrCast(value);
            // *c.PyObject — raw C pointer
            if (ptr_info.child == c.PyObject) return @ptrCast(value);

            // String / bytes slices. 常量切片视为文本字符串，可变切片视为二进制 bytes。
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                if (ptr_info.is_const) {
                    return @ptrCast(try object.Str.fromSlice(value));
                } else {
                    return @ptrCast(try object.Bytes.fromSlice(value));
                }
            }
            // Null-terminated string
            if (ptr_info.size == .many and ptr_info.child == u8 and ptr_info.sentinel_ptr != null) {
                return @ptrCast(try object.Str.fromSlice(std.mem.span(value)));
            }
            // String literal *const [N:0]u8
            if (ptr_info.size == .one) {
                const child_info = @typeInfo(ptr_info.child);
                if (child_info == .array and child_info.array.child == u8 and child_info.array.sentinel_ptr != null) {
                    return @ptrCast(try object.Str.fromSlice(std.mem.sliceTo(value, 0)));
                }
            }
            // Generic slices ([]T / []const T) -> Python list
            if (ptr_info.size == .slice) {
                const list = try types.List.new(value.len);
                errdefer list.decref();
                for (0..value.len) |i| {
                    const item = try toPy(value[i]);
                    try list.set(i, item);
                }
                return @ptrCast(list);
            }
            @compileError(std.fmt.comptimePrint("toPy: cannot convert pointer type {s}", .{@typeName(T)}));
        },
        .array => |arr| {
            // Fixed-size arrays -> Python list
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
        .@"struct" => |struct_info| {
            // User-defined custom conversion takes precedence over generic struct->dict.
            if (comptime @hasDecl(T, "intoPy")) {
                return @as(*Object, @ptrCast(try T.intoPy(value)));
            }

            // Zig tuple -> Python tuple.
            if (struct_info.is_tuple) {
                const tuple = try types.Tuple.new(struct_info.fields.len);
                errdefer tuple.decref();
                inline for (struct_info.fields, 0..) |field, i| {
                    const item = try toPy(@field(value, field.name));
                    tuple.setUnsafe(i, item);
                }
                return @ptrCast(tuple);
            }

            // std.ArrayList<T> -> Python list (consumes the ArrayList)
            if (traits.isArrayList(T)) {
                var mutable = value;
                defer mutable.deinit(mem.allocator);
                const list = try types.List.new(mutable.items.len);
                errdefer list.decref();
                for (0..mutable.items.len) |i| {
                    const item = try toPy(mutable.items[i]);
                    try list.set(i, item);
                }
                return @ptrCast(list);
            }

            // Generic struct -> Python dict.
            const dict = try types.Dict.new();
            errdefer dict.decref();
            inline for (struct_info.fields) |field| {
                const key_z: [:0]const u8 = comptime (field.name ++ "\x00")[0..field.name.len :0];
                const field_obj = try toPy(@field(value, field.name));
                defer field_obj.decref();
                try dict.setItemString(key_z, field_obj);
            }
            return @ptrCast(dict);
        },
        .optional => {
            if (value) |inner| return try toPy(inner);
            return object.returnNone();
        },
        .error_union => {
            if (value) |inner| return try toPy(inner);
            return error.PyError; // error already set by caller
        },
        else => @compileError(std.fmt.comptimePrint("toPy: cannot convert {s}", .{@typeName(T)})),
    }
}

// ============================================================================
// Python → Zig  (fromPy)
// ============================================================================

/// Return the Python type name of `obj` (e.g. "str", "int"). Borrows from `obj`.
/// Works on both stable and limited CPython APIs.
pub fn pyTypeName(obj: *Object) [:0]const u8 {
    const typ = c.PyObject_Type(@as(*c.PyObject, @ptrCast(obj))) orelse return "unknown";
    defer c.Py_DECREF(typ);
    if (!version.is_limited_api) {
        return std.mem.span(@as(*c.PyTypeObject, @ptrCast(typ)).*.tp_name);
    }
    const name_obj = c.PyObject_GetAttrString(typ, "__name__") orelse {
        c.PyErr_Clear();
        return "unknown";
    };
    defer c.Py_DECREF(name_obj);
    return compat.strAsString(name_obj) orelse "unknown";
}

/// Extract a Zig value from a Python object.
/// On type mismatch, sets a Python TypeError and returns error.PyError.
pub fn fromPy(comptime T: type, obj: *Object) Error!T {
    switch (@typeInfo(T)) {
        .int => {
            if (!types.Int.check(obj)) {
                try errors.typeError("expected int, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            return types.Int.as(@ptrCast(obj), T);
        },
        .float => {
            // Accept int or float for float types
            if (types.Float.check(obj)) {
                return types.Float.as(@ptrCast(obj), T);
            }
            if (types.Int.check(obj)) {
                const v = types.Int.as(@ptrCast(obj), i64) catch return error.PyError;
                return @floatFromInt(v);
            }
            try errors.typeError("expected float, got {s}", .{pyTypeName(obj)});
            return error.PyError;
        },
        .bool => {
            if (types.Bool.check(obj)) return @as(*types.Bool, @ptrCast(obj)).as();
            // Accept any truthy/falsy object
            return c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(obj))) != 0;
        },
        .@"enum" => |enum_info| {
            if (!types.Int.check(obj)) {
                try errors.typeError("expected int, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            const tag_value = try types.Int.as(@ptrCast(obj), enum_info.tag_type);
            inline for (enum_info.fields) |field| {
                if (field.value == tag_value) {
                    return @enumFromInt(tag_value);
                }
            }
            try errors.valueError("{d} is not a valid {s}", .{ tag_value, @typeName(T) });
            return error.PyError;
        },
        .pointer => |ptr_info| {
            // *Object 或子类型（*Str、*Int 等）透传，按 wrapper 的 check 做类型校验。
            if (traits.isObjectPtr(T)) {
                if (ptr_info.child != Object) {
                    const Child = ptr_info.child;
                    if (@hasDecl(Child, "check")) {
                        if (!Child.check(obj)) {
                            try errors.typeError("expected {s}, got {s}", .{ @typeName(Child), pyTypeName(obj) });
                            return error.PyError;
                        }
                    } else {
                        @compileError("fromPy: cannot type-check pointer to " ++ @typeName(Child));
                    }
                }
                return @ptrCast(obj);
            }
            // *c.PyObject — raw passthrough
            if (ptr_info.child == c.PyObject) return @ptrCast(obj);

            // []const u8 — 借用 Python str/bytes/bytearray 的 UTF-8 字节（不拷贝）。
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
                try errors.typeError("expected str, bytes or bytearray, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            // []u8 — 从 Python bytes/bytearray 拷贝出一份可变缓冲区，由调用方释放。
            if (ptr_info.size == .slice and ptr_info.child == u8 and !ptr_info.is_const) {
                const src = blk: {
                    if (object.Bytes.check(obj)) {
                        break :blk try @as(*object.Bytes, @ptrCast(obj)).asSlice();
                    }
                    if (object.ByteArray.check(obj)) {
                        break :blk try @as(*object.ByteArray, @ptrCast(obj)).asSlice();
                    }
                    try errors.typeError("expected bytes or bytearray, got {s}", .{pyTypeName(obj)});
                    return error.PyError;
                };
                return mem.allocator.dupe(u8, src) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
                    return error.PyError;
                };
            }
            @compileError(std.fmt.comptimePrint("fromPy: cannot convert to pointer type {s}", .{@typeName(T)}));
        },
        .optional => |opt_info| {
            // None → null
            if (obj.isNone()) return null;
            return try fromPy(opt_info.child, obj);
        },
        .@"struct" => |struct_info| {
            // User-defined custom conversion takes precedence over generic dict->struct.
            // The preferred trait is `fromPyObject`; `fromPy` is kept for backwards compatibility.
            if (comptime @hasDecl(T, "fromPyObject")) {
                return try T.fromPyObject(obj);
            }
            if (comptime @hasDecl(T, "fromPy")) {
                return @field(T, "fromPy")(obj);
            }

            // Zig tuple <- Python tuple.
            if (struct_info.is_tuple) {
                if (!types.Tuple.check(obj)) {
                    try errors.typeError("expected tuple, got {s}", .{pyTypeName(obj)});
                    return error.PyError;
                }
                const tuple = @as(*types.Tuple, @ptrCast(obj));
                if (tuple.length() != struct_info.fields.len) {
                    try errors.typeError("expected tuple of length {d}, got {d}", .{ struct_info.fields.len, tuple.length() });
                    return error.PyError;
                }
                var result: T = undefined;
                inline for (struct_info.fields, 0..) |field, i| {
                    const py_item = tuple.get(i) orelse {
                        try errors.typeError("tuple index {d} out of range", .{i});
                        return error.PyError;
                    };
                    @field(result, field.name) = try fromPy(field.type, py_item);
                }
                return result;
            }

            // std.ArrayList<Item> <- Python list
            if (traits.isArrayList(T)) {
                if (!types.List.check(obj)) {
                    try errors.typeError("expected list, got {s}", .{pyTypeName(obj)});
                    return error.PyError;
                }
                const ItemType = traits.arrayListItemType(T);
                const list = @as(*types.List, @ptrCast(obj));
                const len = list.length();
                var result = T.initCapacity(mem.allocator, len) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
                    return error.PyError;
                };
                errdefer result.deinit(mem.allocator);
                for (0..len) |i| {
                    const item = list.get(i) orelse break;
                    const converted = try fromPy(ItemType, item);
                    result.append(mem.allocator, converted) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
                        return error.PyError;
                    };
                }
                return result;
            }

            // Python dict -> generic struct.
            if (!types.Dict.check(obj)) {
                try errors.typeError("expected dict, got {s}", .{pyTypeName(obj)});
                return error.PyError;
            }
            const dict = @as(*types.Dict, @ptrCast(obj));
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                const key_z: [:0]const u8 = comptime (field.name ++ "\x00")[0..field.name.len :0];
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
                    try errors.typeError("missing required key '{s}' for {s}", .{ field.name, @typeName(T) });
                    return error.PyError;
                }
            }
            return result;
        },
        else => @compileError(std.fmt.comptimePrint("fromPy: cannot convert to {s}", .{@typeName(T)})),
    }
}

/// Release the first `count` fields of a struct. Used for cleanup on partial failure.
fn releaseStructFields(value: anytype, count: usize) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, idx| {
        if (idx < count) {
            releaseValue(&@field(value, field.name));
        }
    }
}

/// Convenience: convert a Python `*Object` to a Zig value, like PyO3's `extract`.
pub fn extract(comptime T: type, obj: *Object) Error!T {
    return fromPy(T, obj);
}

// ============================================================================
// Return value handling (used by pyfn_typed / pyfn_kw / method_fn)
// ============================================================================

/// Handle a function return value: unwrap error unions, convert to *Object.
/// Returns null on error.  If the error is not already a Python exception,
/// it is mapped to an appropriate Python exception via `errors.mapError`.
pub fn handleReturn(comptime RT: type, result: RT) ?*c.PyObject {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return handlePayload(@TypeOf(value), value);
            } else |err| {
                if (errors.errorOccurred() == null) {
                    errors.mapError(err) catch {};
                }
                return null;
            }
        },
        else => return handlePayload(RT, result),
    }
}

fn releaseReturnedValue(value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (value) |inner| {
                releaseReturnedValue(inner);
            }
            _ = optional_info;
        },
        .pointer => |pointer_info| {
            // 仅释放 Zig 函数返回的、由 toPy 分配的可变字节切片。
            // []const u8 通常来自借用对象，不可释放。
            if (pointer_info.size == .slice and pointer_info.child == u8 and !pointer_info.is_const) {
                mem.allocator.free(value[0..value.len]);
            }
        },
        else => {},
    }
}

fn handlePayload(comptime T: type, value: T) ?*c.PyObject {
    defer releaseReturnedValue(value);
    const obj = toPy(value) catch return null;
    return @ptrCast(obj);
}

// ============================================================================
// Explicit collection helpers (safe alternative to automatic conversion for
// cases where memory ownership needs to be explicit).
// ============================================================================

/// Build a Python list from any Zig slice/array/ArrayList. The Python list
/// owns new references to the converted items.
pub fn listFromSlice(items: anytype) Error!*types.List {
    const T = @TypeOf(items);
    const info = @typeInfo(T);

    if (info == .pointer and info.pointer.size == .slice) {
        const list = try types.List.new(items.len);
        errdefer list.decref();
        for (0..items.len) |i| {
            const obj = try toPy(items[i]);
            try list.set(i, obj);
        }
        return list;
    }

    if (info == .array) {
        const list = try types.List.new(info.array.len);
        errdefer list.decref();
        for (0..info.array.len) |i| {
            const obj = try toPy(items[i]);
            try list.set(i, obj);
        }
        return list;
    }

    if (info == .@"struct" and traits.isArrayList(T)) {
        const list = try types.List.new(items.items.len);
        errdefer list.decref();
        for (0..items.items.len) |i| {
            const obj = try toPy(items.items[i]);
            try list.set(i, obj);
        }
        return list;
    }

    @compileError(std.fmt.comptimePrint("listFromSlice: unsupported type {s}", .{@typeName(T)}));
}

/// Release temporary resources owned by a converted value. This is called by
/// the typed wrappers after the Zig function returns, for container types
/// that were allocated during `fromPy`.
/// `value` must be a pointer to the argument / field.
fn isOwnedBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8 and !p.is_const,
        else => false,
    };
}

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
            // Borrowed references (*Object, []const u8, etc.) and scalar types
            // own nothing, so there is nothing to release.
            if (@typeInfo(InnerT) == .pointer) return;
            if (comptime isOwnedBytes(InnerT)) {
                mem.allocator.free(inner.*);
                return;
            }
            if (@typeInfo(InnerT) == .@"struct" and traits.isArrayList(InnerT)) {
                inner.deinit(mem.allocator);
                return;
            }
            if (@typeInfo(InnerT) == .@"struct" and traits.isStringHashMap(InnerT)) {
                inner.deinit();
            }
        }
        return;
    }

    if (@typeInfo(ChildT) == .@"struct" and traits.isArrayList(ChildT)) {
        value.*.deinit(mem.allocator);
        return;
    }
    if (@typeInfo(ChildT) == .@"struct" and traits.isStringHashMap(ChildT)) {
        value.*.deinit();
    }
}

/// Convert a Python list to a new `std.ArrayList(T)` allocated on the C
/// allocator. Caller owns the returned ArrayList and must call `.deinit(allocator)`.
pub fn listToArrayList(comptime T: type, list: *types.List) Error!std.ArrayList(T) {
    const len = list.length();
    var result = std.ArrayList(T).initCapacity(mem.allocator, len) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    errdefer result.deinit(mem.allocator);
    for (0..len) |i| {
        const item = list.get(i) orelse break;
        const converted = try fromPy(T, item);
        result.append(mem.allocator, converted) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "releaseValue handles null optional borrowed types safely" {
    var maybe_obj: ?*Object = null;
    releaseValue(&maybe_obj);

    var maybe_slice: ?[]const u8 = null;
    releaseValue(&maybe_slice);
}

test "releaseValue deinits optional ArrayList on configured allocator" {
    const allocator = mem.allocator;
    var maybe_list: ?std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    try maybe_list.?.append(1);
    try std.testing.expect(maybe_list.?.capacity > 0);
    releaseValue(&maybe_list);
    try std.testing.expectEqual(@as(usize, 0), maybe_list.?.capacity);
}

/// Build a Python dict from a `std.StringHashMap(V)` or any struct with
/// `iterator()` yielding `.key_ptr`/`.value_ptr` entries where keys are strings.
pub fn dictFromStringMap(map: anytype) Error!*types.Dict {
    const dict = try types.Dict.new();
    errdefer dict.decref();
    var it = map.iterator();
    while (it.next()) |entry| {
        const key_z = mem.allocator.dupeZ(u8, entry.key_ptr.*) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
        defer mem.allocator.free(key_z);
        const value_obj = try toPy(entry.value_ptr.*);
        defer value_obj.decref();
        try dict.setItemString(key_z, value_obj);
    }
    return dict;
}

/// Convert a Python dict with string keys to a new `std.StringHashMap(V)`
/// allocated on the C allocator. Caller owns the result and must call `.deinit()`.
pub fn dictToStringHashMap(comptime V: type, dict: *types.Dict) Error!std.StringHashMap(V) {
    var result = std.StringHashMap(V).init(mem.allocator);
    errdefer result.deinit();

    const items = c.PyDict_Items(@as(*c.PyObject, @ptrCast(dict)));
    if (items == null) return error.PyError;
    defer c.Py_DECREF(items);

    const size = c.PyList_Size(items);
    var i: c.Py_ssize_t = 0;
    while (i < size) : (i += 1) {
        const pair = c.PyList_GetItem(items, i);
        const key_obj = c.PyTuple_GetItem(pair, 0);
        const val_obj = c.PyTuple_GetItem(pair, 1);
        const key_str = try object.Str.asString(@ptrCast(key_obj));
        const value = try fromPy(V, @ptrCast(val_obj));
        result.put(key_str, value) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
    }
    return result;
}
