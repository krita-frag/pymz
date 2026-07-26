//! Python protocol slot generation for Zig-backed classes.

const std = @import("std");
const c = @import("python_c");
const convert = @import("../convert.zig");
const marshal = @import("../marshal.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const types = @import("../types.zig");
const core = @import("class_builder.zig");

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

fn returnIntegerSlot(comptime RT: type, result: RT, comptime name: []const u8, comptime ReturnT: type) ReturnT {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| return returnIntegerSlot(@TypeOf(value), value, name, ReturnT);
            return -1;
        },
        .int => return @intCast(result),
        else => @compileError(name ++ " must return an integer"),
    }
}

fn convertLenReturn(comptime RT: type, result: RT) c.Py_ssize_t {
    return returnIntegerSlot(RT, result, "__len__", c.Py_ssize_t);
}

fn convertHashReturn(comptime RT: type, result: RT) c.Py_hash_t {
    return returnIntegerSlot(RT, result, "__hash__", c.Py_hash_t);
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
        pub const has_getattr = @hasDecl(T, "__getattr__");
        pub const has_setattr = @hasDecl(T, "__setattr__");
        pub const has_enter = @hasDecl(T, "__enter__");
        pub const has_exit = @hasDecl(T, "__exit__");

        pub const has_richcompare = has_eq or has_ne or has_lt or has_le or has_gt or has_ge;

        /// Dunder names this builder handles when declared on T. This is the
        /// single source of truth consumed by `dunders.isReservedDunder`.
        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_len) names = names ++ .{"__len__"};
            if (has_getitem) names = names ++ .{"__getitem__"};
            if (has_setitem) names = names ++ .{"__setitem__"};
            if (@hasDecl(T, "__delitem__")) names = names ++ .{"__delitem__"};
            if (has_contains) names = names ++ .{"__contains__"};
            if (has_call) names = names ++ .{"__call__"};
            if (has_hash) names = names ++ .{"__hash__"};
            if (has_eq) names = names ++ .{"__eq__"};
            if (has_ne) names = names ++ .{"__ne__"};
            if (has_lt) names = names ++ .{"__lt__"};
            if (has_le) names = names ++ .{"__le__"};
            if (has_gt) names = names ++ .{"__gt__"};
            if (has_ge) names = names ++ .{"__ge__"};
            if (has_getattr) names = names ++ .{"__getattr__"};
            if (has_setattr) names = names ++ .{"__setattr__"};
            break :blk names;
        };

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
                errors.typeError("__call__() takes exactly {d} positional argument(s) ({d} given)", .{ N, num_pos });
                return null;
            }
            var zig_args: std.meta.ArgsTuple(F) = undefined;
            zig_args[0] = data;
            var converted_count: usize = 0;
            inline for (params[Skip..], 0..) |param, i| {
                const PT = param.type orelse {
                    errors.typeError("missing argument {d}", .{i + 1});
                    marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                    return null;
                };
                const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                const converted = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label);
                if (converted) |value| {
                    zig_args[i + Skip] = value;
                } else {
                    marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                    return null;
                }
                converted_count += 1;
            }
            const result = @call(.auto, @field(T, "__call__"), zig_args);
            marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
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

            // Comptime table mapping each CPython rich-comparison opcode to the
            // corresponding Zig dunder method name. Using `inline for` keeps the
            // per-arm specialization (so absent methods are elided at compile
            // time) while collapsing the six near-identical bodies into one.
            return richcompareDispatch(T, data, other, op);
        }

        fn richcompareDispatch(comptime TT: type, data: *TT, other: *c.PyObject, op: c_int) ?*c.PyObject {
            const Ops = struct {
                op: c_int,
                name: []const u8,
            };
            const ops = [_]Ops{
                .{ .op = c.Py_LT, .name = "__lt__" },
                .{ .op = c.Py_LE, .name = "__le__" },
                .{ .op = c.Py_EQ, .name = "__eq__" },
                .{ .op = c.Py_NE, .name = "__ne__" },
                .{ .op = c.Py_GT, .name = "__gt__" },
                .{ .op = c.Py_GE, .name = "__ge__" },
            };

            inline for (ops) |entry| {
                if (comptime @hasDecl(TT, entry.name)) {
                    if (op == entry.op) {
                        const F = @TypeOf(@field(TT, entry.name));
                        const params = @typeInfo(F).@"fn".params;
                        const OtherType = if (params.len > 1) params[1].type.? else *object.Object;
                        const zig_other = convert.fromPy(OtherType, @ptrCast(other)) catch return null;
                        const result = @field(TT, entry.name)(data, zig_other);
                        return convertProtocolReturn(@TypeOf(result), result);
                    }
                }
            }

            return @ptrCast(c.Py_NotImplemented());
        }

        test "ProtocolBuilder detects supported dunder methods" {
            const TestType = struct {
                pub fn __len__(self: *@This()) usize {
                    _ = self;
                    return 0;
                }
                pub fn __getattr__(self: *@This(), name: []const u8) ?*object.Object {
                    _ = self;
                    _ = name;
                    return null;
                }
                pub fn __setattr__(self: *@This(), name: []const u8, value: *object.Object) void {
                    _ = self;
                    _ = name;
                    _ = value;
                }
                pub fn __enter__(self: *@This()) *@This() {
                    return self;
                }
                pub fn __exit__(self: *@This(), exc_type: ?*object.Object, exc_val: ?*object.Object, exc_tb: ?*object.Object) bool {
                    _ = self;
                    _ = exc_type;
                    _ = exc_val;
                    _ = exc_tb;
                    return false;
                }
            };
            const P = ProtocolBuilder(TestType);
            try std.testing.expect(P.has_len);
            try std.testing.expect(P.has_getattr);
            try std.testing.expect(P.has_setattr);
            try std.testing.expect(P.has_enter);
            try std.testing.expect(P.has_exit);
            try std.testing.expect(!P.has_hash);
        }

        pub fn py_getattr(py_self: ?*c.PyObject, py_name: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const name = py_name orelse return null;
            const data = core.unwrap(T, py);
            const zig_name = convert.fromPy([]const u8, @ptrCast(name)) catch return null;
            const result = @field(T, "__getattr__")(data, zig_name);
            return convertProtocolReturn(@TypeOf(result), result);
        }

        pub fn py_setattr(py_self: ?*c.PyObject, py_name: ?*c.PyObject, py_value: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const name = py_name orelse return -1;
            const data = core.unwrap(T, py);
            const zig_name = convert.fromPy([]const u8, @ptrCast(name)) catch return -1;
            const F = @TypeOf(@field(T, "__setattr__"));
            const params = @typeInfo(F).@"fn".params;
            if (params.len == 2) {
                // Deletion-style setter: __setattr__(self, name) -> void
                const result = @field(T, "__setattr__")(data, zig_name);
                return convertSetitemReturn(@TypeOf(result), result);
            } else {
                const val = py_value orelse return -1;
                const ValueType = params[2].type.?;
                const zig_value = convert.fromPy(ValueType, @ptrCast(val)) catch return -1;
                const result = @field(T, "__setattr__")(data, zig_name, zig_value);
                return convertSetitemReturn(@TypeOf(result), result);
            }
        }
    };
}
