//! Conversion helpers between Zig values and Python objects.
//!
//! `toPy` converts a Zig value into a new Python object (stealing nothing).
//! `fromPy` extracts a Zig value from a Python object, type-checking and
//! raising a Python TypeError on mismatch.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
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
        .pointer => |ptr_info| {
            // *Object or *Str etc. — already a Python object pointer
            if (traits.isObjectPtr(T)) return @ptrCast(value);
            // *c.PyObject — raw C pointer
            if (ptr_info.child == c.PyObject) return @ptrCast(value);

            // String slices
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return @ptrCast(try object.Str.fromSlice(value));
            }
            // Null-terminated string
            if (ptr_info.size == .many and ptr_info.child == u8 and ptr_info.sentinel_ptr != null) {
                return @ptrCast(try object.Str.fromSlice(std.mem.span(value)));
            }
            // String literal *const [N:0]u8
            if (ptr_info.size == .one) {
                const child_info = @typeInfo(ptr_info.child);
                if (child_info == .array and child_info.array.child == u8 and child_info.array.sentinel_ptr != null) {
                    return @ptrCast(try object.Str.fromSlice(std.mem.span(value)));
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
        .@"struct" => {
            // std.ArrayList<T> -> Python list (consumes the ArrayList)
            if (traits.isArrayList(T)) {
                var mutable = value;
                defer mutable.deinit(std.heap.c_allocator);
                const list = try types.List.new(mutable.items.len);
                errdefer list.decref();
                for (0..mutable.items.len) |i| {
                    const item = try toPy(mutable.items[i]);
                    try list.set(i, item);
                }
                return @ptrCast(list);
            }
            @compileError(std.fmt.comptimePrint("toPy: cannot convert struct type {s}", .{@typeName(T)}));
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

/// Extract a Zig value from a Python object.
/// On type mismatch, sets a Python TypeError and returns error.PyError.
pub fn fromPy(comptime T: type, obj: *Object) Error!T {
    switch (@typeInfo(T)) {
        .int => {
            if (!types.Int.check(obj)) {
                try errors.typeError("expected int, got {s}", .{@typeName(T)});
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
            try errors.typeError("expected float, got {s}", .{@typeName(T)});
            return error.PyError;
        },
        .bool => {
            if (types.Bool.check(obj)) return @as(*types.Bool, @ptrCast(obj)).as();
            // Accept any truthy/falsy object
            return c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(obj))) != 0;
        },
        .pointer => |ptr_info| {
            // *Object or subtypes — passthrough with type check
            if (traits.isObjectPtr(T)) {
                if (ptr_info.child != Object) {
                    // For typed pointers like *Str, verify the type
                    // but we trust the caller for now
                }
                return @ptrCast(obj);
            }
            // *c.PyObject — raw passthrough
            if (ptr_info.child == c.PyObject) return @ptrCast(obj);

            // []const u8 — extract string bytes (borrowed from Python object)
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                if (!object.Str.check(obj)) {
                    try errors.typeError("expected str, got {s}", .{@typeName(T)});
                    return error.PyError;
                }
                return object.Str.asString(@ptrCast(obj));
            }
            @compileError(std.fmt.comptimePrint("fromPy: cannot convert to pointer type {s}", .{@typeName(T)}));
        },
        .optional => |opt_info| {
            // None → null
            if (obj.isNone()) return null;
            return try fromPy(opt_info.child, obj);
        },
        .@"struct" => {
            // std.ArrayList<Item> ← Python list
            if (traits.isArrayList(T)) {
                if (!types.List.check(obj)) {
                    try errors.typeError("expected list, got {s}", .{@typeName(T)});
                    return error.PyError;
                }
                const ItemType = traits.arrayListItemType(T);
                const list = @as(*types.List, @ptrCast(obj));
                const len = list.length();
                var result = T.initCapacity(std.heap.c_allocator, len) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
                    return error.PyError;
                };
                errdefer result.deinit(std.heap.c_allocator);
                for (0..len) |i| {
                    const item = list.get(i) orelse break;
                    const converted = try fromPy(ItemType, item);
                    result.append(std.heap.c_allocator, converted) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
                        return error.PyError;
                    };
                }
                return result;
            }
            @compileError(std.fmt.comptimePrint("fromPy: cannot convert to struct type {s}", .{@typeName(T)}));
        },
        else => @compileError(std.fmt.comptimePrint("fromPy: cannot convert to {s}", .{@typeName(T)})),
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
/// Returns null on error (Python exception is already set).
pub fn handleReturn(comptime RT: type, result: RT) ?*c.PyObject {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return handlePayload(@TypeOf(value), value);
            } else |_| {
                // If no Python exception is set yet, set a generic RuntimeError
                if (errors.errorOccurred() == null) {
                    c.PyErr_SetString(c.PyExc_RuntimeError, @ptrCast("zig function returned an error"));
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
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                std.heap.c_allocator.free(@constCast(value[0..value.len]));
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
pub fn releaseValue(value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .pointer) @compileError("releaseValue expects a pointer");
    const ChildT = @typeInfo(T).pointer.child;

    if (@typeInfo(ChildT) == .optional) {
        if (value.*) |*inner| {
            releaseValue(inner);
        }
        return;
    }

    if (@typeInfo(ChildT) == .@"struct" and traits.isArrayList(ChildT)) {
        value.*.deinit(std.heap.c_allocator);
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
    var result = std.ArrayList(T).initCapacity(std.heap.c_allocator, len) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    errdefer result.deinit(std.heap.c_allocator);
    for (0..len) |i| {
        const item = list.get(i) orelse break;
        const converted = try fromPy(T, item);
        result.append(std.heap.c_allocator, converted) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
    }
    return result;
}

/// Build a Python dict from a `std.StringHashMap(V)` or any struct with
/// `iterator()` yielding `.key_ptr`/`.value_ptr` entries where keys are strings.
pub fn dictFromStringMap(map: anytype) Error!*types.Dict {
    const dict = try types.Dict.new();
    errdefer dict.decref();
    var it = map.iterator();
    while (it.next()) |entry| {
        const key_z = std.heap.c_allocator.dupeZ(u8, entry.key_ptr.*) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
        defer std.heap.c_allocator.free(key_z);
        const value_obj = try toPy(entry.value_ptr.*);
        defer value_obj.decref();
        try dict.setItemString(key_z, value_obj);
    }
    return dict;
}

/// Convert a Python dict with string keys to a new `std.StringHashMap(V)`
/// allocated on the C allocator. Caller owns the result and must call `.deinit()`.
pub fn dictToStringHashMap(comptime V: type, dict: *types.Dict) Error!std.StringHashMap(V) {
    var result = std.StringHashMap(V).init(std.heap.c_allocator);
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
        const key_str = object.Str.asString(@ptrCast(key_obj));
        const value = try fromPy(V, @ptrCast(val_obj));
        result.put(key_str, value) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
    }
    return result;
}
