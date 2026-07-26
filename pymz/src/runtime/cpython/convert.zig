//! Conversion helpers between Zig values and Python objects.
//!
//! This module owns the conversion surface only: `toPy` / `fromPy`, the
//! `PymzConvert` trait, value cleanup (`releaseValue`,
//! `releaseStructFields`), and the list helpers. The argument-extraction and
//! return-value pipeline that wraps a user function (`extractPositionalArg`,
//! `handleReturn`, `releaseArgsTuple`, ...) lives in `marshal.zig`, which
//! imports this module for the conversion primitives. Keeping the two
//! responsibilities separate lets each stay focused; the dependency is
//! one-way (`marshal` -> `convert`).

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

/// Formal conversion trait. Types can declare:
///
///   pub const PymzConvert = struct {
///       pub fn intoPy(value: T) Error!*Object { ... }
///       pub fn fromPy(obj: *Object) Error!T { ... }
///   };
///
/// and `toPy`/`fromPy` will use it automatically.
pub fn hasPymzConvert(comptime T: type) bool {
    return @hasDecl(T, "PymzConvert") and
        @hasDecl(T.PymzConvert, "intoPy") and
        @hasDecl(T.PymzConvert, "fromPy");
}

pub inline fn pymzIntoPy(value: anytype) Error!*Object {
    const T = @TypeOf(value);
    return T.PymzConvert.intoPy(value);
}

pub inline fn pymzFromPy(comptime T: type, obj: *Object) Error!T {
    return T.PymzConvert.fromPy(obj);
}

pub fn isOwnedBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8 and !p.is_const,
        else => false,
    };
}

/// Convert a comptime-known byte slice into a sentinel-terminated `[:0]const u8`
/// without copying. The sentinel byte is appended at compile time.
pub fn toSentinelStr(comptime s: []const u8) [:0]const u8 {
    return (s ++ "\x00")[0..s.len :0];
}

/// Release temporary resources owned by a converted value.
/// `value` must be a pointer to the argument / field.
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
            // StringHashMap is intentionally not handled here: toPyStruct /
            // fromPyStruct do not convert StringHashMap, so a converted value
            // can never be a StringHashMap and there is nothing to release.
        }
        return;
    }

    if (@typeInfo(ChildT) == .@"struct" and traits.isArrayList(ChildT)) {
        value.*.deinit(mem.allocator);
        value.* = .empty;
        return;
    }
    // StringHashMap is intentionally not handled here for the same reason as
    // above: no conversion path produces one, so this branch is unreachable.
}

/// Convert a Zig value into a Python object.
///
/// Always returns a NEW reference. Callers own the returned reference and must
/// eventually decref it (or transfer ownership to a container that steals it,
/// such as `Tuple.setUnsafe` or `List.set`). Pointer inputs (e.g. `*Object`)
/// are treated as borrowed for the duration of the call: `toPy` increfs them
/// before returning so the caller's original reference is unaffected.
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
            if (value) |inner| return try toPy(inner);
            return error.PyError;
        },
        else => @compileError(std.fmt.comptimePrint("toPy: cannot convert {s}", .{@typeName(T)})),
    }
}

/// Pointer arm of `toPy`. Handles borrowed PyObject pointers, byte slices,
/// sentinel-terminated strings, and general slices.
fn toPyPointer(comptime T: type, value: T) Error!*Object {
    const ptr_info = @typeInfo(T).pointer;
    // Borrowed PyObject pointers are incref'd so callers always receive
    // a new reference. This makes `toPy` compositional: callers can
    // pass the result to APIs that steal (PyList_SetItem,
    // PyTuple_SetItem) or that borrow (PyDict_SetItemString) without
    // worrying about underflow.
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
    // Generic slice (non-byte) → Python list.
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

/// Struct arm of `toPy`. Handles `PymzConvert` trait, tuple structs,
/// `ArrayList` wrappers, and plain structs (converted to dicts).
fn toPyStruct(comptime T: type, value: T) Error!*Object {
    const struct_info = @typeInfo(T).@"struct";
    if (comptime hasPymzConvert(T)) {
        return try pymzIntoPy(value);
    }

    if (struct_info.is_tuple) {
        const tuple = try types.Tuple.new(struct_info.fields.len);
        errdefer tuple.decref();
        inline for (struct_info.fields, 0..) |field, i| {
            const item = try toPy(@field(value, field.name));
            tuple.setUnsafe(i, item);
        }
        return @ptrCast(tuple);
    }

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

/// Union arm of `toPy`. Tagged unions are converted to a `(tag_name, payload)`
/// tuple; untagged unions are a compile error.
fn toPyUnion(comptime T: type, value: T) Error!*Object {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError(std.fmt.comptimePrint("toPy: cannot convert untagged union {s}", .{@typeName(T)}));
    }
    const Tag = union_info.tag_type.?;
    const tag_name = @tagName(@as(Tag, value));
    const name_obj = try object.Str.fromSlice(tag_name);
    defer name_obj.decref();

    inline for (union_info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, tag_name)) {
            const payload = @field(value, field.name);
            const payload_obj = try toPy(payload);
            defer payload_obj.decref();
            const tuple = try types.Tuple.new(2);
            errdefer tuple.decref();
            name_obj.incref();
            tuple.setUnsafe(0, @ptrCast(name_obj));
            payload_obj.incref();
            tuple.setUnsafe(1, payload_obj);
            return @ptrCast(tuple);
        }
    }
    unreachable;
}

/// Return the Python type name of `obj` (e.g. "str", "int"). Borrows from `obj`.
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
            if (types.Int.check(obj)) {
                const v = types.Int.as(@ptrCast(obj), i64) catch return error.PyError;
                return @floatFromInt(v);
            }
            errors.typeError("expected float, got {s}", .{pyTypeName(obj)});
            return error.PyError;
        },
        .bool => {
            if (types.Bool.check(obj)) return @as(*types.Bool, @ptrCast(obj)).as();
            return c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(obj))) != 0;
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

/// Pointer arm of `fromPy`. Handles PyObject pointers, byte slices (const and
/// mutable), and sentinel-terminated strings.
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
            c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
            return error.PyError;
        };
    }
    @compileError(std.fmt.comptimePrint("fromPy: cannot convert to pointer type {s}", .{@typeName(T)}));
}

/// Struct arm of `fromPy`. Handles `PymzConvert` trait, tuple structs,
/// `ArrayList` wrappers, and plain structs (converted from dicts).
fn fromPyStruct(comptime T: type, obj: *Object) Error!T {
    const struct_info = @typeInfo(T).@"struct";
    if (comptime hasPymzConvert(T)) {
        return try pymzFromPy(T, obj);
    }

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
                return error.PyError;
            };
            @field(result, field.name) = try fromPy(field.type, py_item);
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
            return error.PyError;
        }
    }
    return result;
}

/// Union arm of `fromPy`. Expects a `(tag_name, payload)` tuple and dispatches
/// to the matching union field.
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
