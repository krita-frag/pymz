//! 为 Zig 支持的类生成 Python 协议插槽。

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
        else => @compileError("__setitem__/__delitem__ must return void or error union"),
    }
}

pub fn ProtocolBuilder(comptime T: type) type {
    return struct {
        pub const has_len = @hasDecl(T, "__len__");
        pub const has_getitem = @hasDecl(T, "__getitem__");
        pub const has_setitem = @hasDecl(T, "__setitem__");
        pub const has_delitem = @hasDecl(T, "__delitem__");
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

        pub const has_richcompare = has_eq or has_ne or has_lt or has_le or has_gt or has_ge;

        /// 当在 T 上声明时，本构建器处理的 dunder 名称。这是
        /// `dunders.isReservedDunder` 消费的唯一真相源。
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

        /// `mp_ass_subscript` 插槽的统一入口，同时承担赋值与删除语义。
        ///
        /// CPython 调用约定：`py_value` 非 NULL 表示赋值（`obj[k] = v`），
        /// `py_value` 为 NULL 表示删除（`del obj[k]`）。本函数按 `py_value`
        /// 是否为 NULL 分流到 `T.__setitem__` 或 `T.__delitem__`。
        ///
        /// 若 `T` 仅声明了两者之一，则未实现的方向会进入 `unreachableAssSubscript`，
        /// 在 Debug 构建中触发断言、在 Release 构建中抛出 `TypeError`，
        /// 而非静默返回 -1（先前的实现会让 `del vec[i]` 在仅有 `__setitem__`
        /// 时静默失败，违反 Python 语义）。
        pub fn py_setitem(py_self: ?*c.PyObject, py_key: ?*c.PyObject, py_value: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const key = py_key orelse return -1;
            const data = core.unwrap(T, py);

            if (py_value == null) {
                // 删除语义：del obj[key]
                if (has_delitem) {
                    return py_delitem_impl(data, key);
                }
                errors.typeError("'{s}' object does not support item deletion", .{@typeName(T)});
                return -1;
            }

            // 赋值语义：obj[key] = value
            if (!has_setitem) {
                errors.typeError("'{s}' object does not support item assignment", .{@typeName(T)});
                return -1;
            }
            const F = @TypeOf(@field(T, "__setitem__"));
            const params = @typeInfo(F).@"fn".params;
            const KeyType = params[1].type.?;
            const ValueType = params[2].type.?;
            const zig_key = convert.fromPy(KeyType, @ptrCast(key)) catch return -1;
            const zig_value = convert.fromPy(ValueType, @ptrCast(py_value.?)) catch return -1;
            const result = @field(T, "__setitem__")(data, zig_key, zig_value);
            return convertSetitemReturn(@TypeOf(result), result);
        }

        /// `__delitem__` 的实际调用逻辑。由 `py_setitem` 在 `py_value == null`
        /// 时调用。签名 `fn(self, key) -> void|error union` 与 `__setitem__`
        /// 一致（仅少一个 value 参数），复用 `convertSetitemReturn` 转换返回值。
        fn py_delitem_impl(data: *T, py_key: *c.PyObject) c_int {
            const F = @TypeOf(@field(T, "__delitem__"));
            const params = @typeInfo(F).@"fn".params;
            const KeyType = params[1].type.?;
            const zig_key = convert.fromPy(KeyType, @ptrCast(py_key)) catch return -1;
            const result = @field(T, "__delitem__")(data, zig_key);
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
            // 与 pyfn_typed 一致：可选参数可省略，仅检查必需参数下界和总参数上界。
            const required_count = comptime marshal.requiredParamCount(F, Skip);
            if (num_pos < required_count or num_pos > N) {
                errors.typeError(
                    "__call__() takes {d} to {d} positional argument(s) ({d} given)",
                    .{ required_count, N, num_pos },
                );
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
                if (i < num_pos) {
                    const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                    zig_args[i + Skip] = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label) catch {
                        marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                        return null;
                    };
                    converted_count += 1;
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i + Skip] = null;
                } else {
                    errors.typeError("missing required argument {d}", .{i + 1});
                    marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                    return null;
                }
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

            // 编译期表格，将每个 CPython 丰富比较操作码映射到对应的 Zig dunder 方法名。
            // 使用 `inline for` 保持逐臂特化（未实现的方法在编译期被消除），
            // 同时将六个几乎相同的函数体合并为一个。
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

            // CPython 对 `tp_richcompare` 返回 `Py_NotImplemented` 有特殊处理：
            // 解释器识别此单例后会尝试反向比较或回退到默认行为，且不会对返回值
            // decref。因此这里返回 `Py_NotImplemented` 的**借用引用**而非新引用，
            // 偏离了 pymz "辅助函数统一返回新引用"的契约。若此处 incref 后再返回，
            // 反而会导致引用计数泄漏。
            return @ptrCast(c.Py_NotImplemented());
        }

        test "ProtocolBuilder 检测支持的 dunder 方法" {
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
            };
            const P = ProtocolBuilder(TestType);
            try std.testing.expect(P.has_len);
            try std.testing.expect(P.has_getattr);
            try std.testing.expect(P.has_setattr);
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

        /// `tp_setattro` 插槽回调，处理属性赋值与删除。
        ///
        /// CPython 调用约定：`py_value` 非 NULL 表示赋值（`obj.attr = v`），
        /// `py_value` 为 NULL 表示删除（`del obj.attr`）。
        ///
        /// `__setattr__` 可声明为两种形式：
        ///   - 3 参数：`fn(self, name: []const u8, value: T) void|Error!void`
        ///     —— 仅处理赋值。删除操作会返回 `AttributeError`。
        ///   - 2 参数：`fn(self, name: []const u8) void|Error!void`
        ///     —— "删除风格" setter，同时处理赋值和删除：调用方在赋值时
        ///     传入 name，在删除时也传入 name（不传 value）。此形式适用于
        ///     需要统一处理两种操作的类型。
        ///
        /// 当使用 3 参数形式且 Python 发起 `del` 操作时，CPython 传入
        /// `py_value = NULL`，本函数返回 `AttributeError`，因为 3 参数形式
        /// 无法表达删除语义。
        pub fn py_setattr(py_self: ?*c.PyObject, py_name: ?*c.PyObject, py_value: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const name = py_name orelse return -1;
            const data = core.unwrap(T, py);
            const zig_name = convert.fromPy([]const u8, @ptrCast(name)) catch return -1;
            const F = @TypeOf(@field(T, "__setattr__"));
            const params = @typeInfo(F).@"fn".params;
            if (params.len == 2) {
                // 2 参数形式：__setattr__(self, name) -> void
                // 仅支持删除操作。3 参数形式需要接收值。
                if (py_value != null) {
                    errors.attributeError(
                        "cannot set attribute '{s}': __setattr__ with 2 arguments only supports deletion",
                        .{zig_name},
                    );
                    return -1;
                }
                const result = @field(T, "__setattr__")(data, zig_name);
                return convertSetitemReturn(@TypeOf(result), result);
            } else {
                // 3 参数形式：__setattr__(self, name, value)
                // 仅处理赋值；删除操作返回 AttributeError。
                const val = py_value orelse {
                    errors.attributeError("cannot delete attribute '{s}'", .{zig_name});
                    return -1;
                };
                const ValueType = params[2].type.?;
                const zig_value = convert.fromPy(ValueType, @ptrCast(val)) catch return -1;
                const result = @field(T, "__setattr__")(data, zig_name, zig_value);
                return convertSetitemReturn(@TypeOf(result), result);
            }
        }
    };
}
