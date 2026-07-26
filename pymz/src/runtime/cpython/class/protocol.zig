//! Python protocol slot generation for Zig-backed classes.

const std = @import("std");
const c = @import("../c.zig").c;
const convert = @import("../convert.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const types = @import("../types.zig");
const core = @import("core.zig");

fn convertProtocolReturn(comptime RT: type, result: RT) ?*c.PyObject {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return convertProtocolReturn(@TypeOf(value), value);
            } else |_| {
                return null;
            }
        },
        else => {
            const obj = convert.toPy(result) catch return null;
            return @ptrCast(obj);
        },
    }
}

fn convertLenReturn(comptime RT: type, result: RT) c.Py_ssize_t {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return convertLenReturn(@TypeOf(value), value);
            } else |_| {
                return -1;
            }
        },
        .int => {
            return @intCast(result);
        },
        else => @compileError("__len__ must return an integer"),
    }
}

fn convertHashReturn(comptime RT: type, result: RT) c.Py_hash_t {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return convertHashReturn(@TypeOf(value), value);
            } else |_| {
                return -1;
            }
        },
        .int => {
            return @intCast(result);
        },
        else => @compileError("__hash__ must return an integer"),
    }
}

fn convertContainsReturn(comptime RT: type, result: RT) c_int {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return convertContainsReturn(@TypeOf(value), value);
            } else |_| {
                return -1;
            }
        },
        .bool => {
            return @intFromBool(result);
        },
        else => @compileError("__contains__ must return bool"),
    }
}

fn convertSetitemReturn(comptime RT: type, result: RT) c_int {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |_| {
                return 0;
            } else |_| {
                return -1;
            }
        },
        .void => return 0,
        else => @compileError("__setitem__ must return void or error union"),
    }
}

pub fn ProtocolBuilder(comptime T: type) type {
    return struct {
        pub const has_len = @hasDecl(T, "__len__");
        pub const has_getitem = @hasDecl(T, "__getitem__");
        pub const has_setitem = @hasDecl(T, "__setitem__");
        pub const has_contains = @hasDecl(T, "__contains__");
        pub const has_call = @hasDecl(T, "__call__");
        pub const has_hash = @hasDecl(T, "__hash__");
        pub const has_eq = @hasDecl(T, "__eq__");
        pub const has_ne = @hasDecl(T, "__ne__");
        pub const has_lt = @hasDecl(T, "__lt__");
        pub const has_le = @hasDecl(T, "__le__");
        pub const has_gt = @hasDecl(T, "__gt__");
        pub const has_ge = @hasDecl(T, "__ge__");

        pub const has_richcompare = has_eq or has_ne or has_lt or has_le or has_gt or has_ge;

        pub fn py_len(py_self: ?*c.PyObject) callconv(.c) c.Py_ssize_t {
            const py = py_self orelse return -1;
            const data = core.unwrap(T, py);
            const result = @field(T, "__len__")(data);
            return convertLenReturn(@TypeOf(result), result);
        }

        pub fn py_getitem(py_self: ?*c.PyObject, py_key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const key = py_key orelse return null;
            const data = core.unwrap(T, py);
            const KeyType = @typeInfo(@TypeOf(@field(T, "__getitem__"))).@"fn".params[1].type.?;
            const zig_key = convert.fromPy(KeyType, @ptrCast(key)) catch return null;
            const result = @field(T, "__getitem__")(data, zig_key);
            return convertProtocolReturn(@TypeOf(result), result);
        }

        pub fn py_setitem(py_self: ?*c.PyObject, py_key: ?*c.PyObject, py_value: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const key = py_key orelse return -1;
            const val = py_value orelse return -1;
            const data = core.unwrap(T, py);
            const F = @TypeOf(@field(T, "__setitem__"));
            const params = @typeInfo(F).@"fn".params;
            const KeyType = params[1].type.?;
            const ValueType = params[2].type.?;
            const zig_key = convert.fromPy(KeyType, @ptrCast(key)) catch return -1;
            const zig_value = convert.fromPy(ValueType, @ptrCast(val)) catch return -1;
            const result = @field(T, "__setitem__")(data, zig_key, zig_value);
            return convertSetitemReturn(@TypeOf(result), result);
        }

        pub fn py_contains(py_self: ?*c.PyObject, py_value: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const val = py_value orelse return -1;
            const data = core.unwrap(T, py);
            const F = @TypeOf(@field(T, "__contains__"));
            const ItemType = @typeInfo(F).@"fn".params[1].type.?;
            const zig_value = convert.fromPy(ItemType, @ptrCast(val)) catch return -1;
            const result = @field(T, "__contains__")(data, zig_value);
            return convertContainsReturn(@TypeOf(result), result);
        }

        pub fn py_call(py_self: ?*c.PyObject, py_args: ?*c.PyObject, _: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const data = core.unwrap(T, py);
            const F = @TypeOf(@field(T, "__call__"));
            const params = @typeInfo(F).@"fn".params;
            const Skip: usize = 1;
            const N = params.len - Skip;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;
            if (num_pos != N) {
                errors.typeError("__call__() takes exactly {d} positional argument(s) ({d} given)", .{ N, num_pos }) catch {};
                return null;
            }
            var zig_args: std.meta.ArgsTuple(F) = undefined;
            zig_args[0] = data;
            inline for (params[Skip..], 0..) |param, i| {
                const py_item = args_tuple.?.get(i) orelse {
                    errors.typeError("missing argument {d}", .{i + 1}) catch {};
                    return null;
                };
                const PT = param.type orelse return null;
                zig_args[i + Skip] = convert.fromPy(PT, py_item) catch return null;
            }
            const result = @call(.auto, @field(T, "__call__"), zig_args);
            return convertProtocolReturn(@TypeOf(result), result);
        }

        pub fn py_hash(py_self: ?*c.PyObject) callconv(.c) c.Py_hash_t {
            const py = py_self orelse return -1;
            const data = core.unwrap(T, py);
            const result = @field(T, "__hash__")(data);
            return convertHashReturn(@TypeOf(result), result);
        }

        pub fn py_richcompare(py_self: ?*c.PyObject, py_other: ?*c.PyObject, op: c_int) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const other = py_other orelse return null;
            const data = core.unwrap(T, py);
            switch (op) {
                c.Py_LT => {
                    if (comptime @hasDecl(T, "__lt__")) {
                        const F = @TypeOf(@field(T, "__lt__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__lt__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                c.Py_LE => {
                    if (comptime @hasDecl(T, "__le__")) {
                        const F = @TypeOf(@field(T, "__le__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__le__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                c.Py_EQ => {
                    if (comptime @hasDecl(T, "__eq__")) {
                        const F = @TypeOf(@field(T, "__eq__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__eq__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                c.Py_NE => {
                    if (comptime @hasDecl(T, "__ne__")) {
                        const F = @TypeOf(@field(T, "__ne__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__ne__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                c.Py_GT => {
                    if (comptime @hasDecl(T, "__gt__")) {
                        const F = @TypeOf(@field(T, "__gt__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__gt__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                c.Py_GE => {
                    if (comptime @hasDecl(T, "__ge__")) {
                        const F = @TypeOf(@field(T, "__ge__"));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(T, "__ge__")(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                },
                else => {},
            }
            return @ptrCast(c.Py_NotImplemented());
        }
    };
}
