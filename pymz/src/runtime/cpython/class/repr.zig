//! 为 Zig 支持的类生成 Repr/str 和迭代器协议。

const std = @import("std");
const c = @import("python_c");
const convert = @import("../convert.zig");
const marshal = @import("../marshal.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const core = @import("class_builder.zig");

pub fn ReprBuilder(comptime T: type) type {
    return struct {
        pub const has_repr = @hasDecl(T, "__repr__");
        pub const has_str = @hasDecl(T, "__str__");

        /// 当在 T 上声明时，本构建器处理的 dunder 名称。这是
        /// `dunders.isReservedDunder` 消费的唯一真相源。
        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_repr) names = names ++ .{"__repr__"};
            if (has_str) names = names ++ .{"__str__"};
            break :blk names;
        };

        fn protocolString(comptime name: []const u8, py_self: ?*c.PyObject) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = core.unwrapConst(T, py);
            const s = @field(T, name)(data);
            const obj = object.Str.fromSlice(s) catch return null;
            return @ptrCast(obj);
        }

        pub fn py_repr(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            // 不可达：py_repr 仅在 has_repr 为 true 时才会被安装为 tp_repr。
            // 如果此不变量被破坏，使用 @panic 而不是 PyObject_Repr 来防止无限递归
            // (PyObject_Repr 调用 tp_repr -> py_repr -> ...)。
            if (!has_repr) {
                @panic("py_repr called on type without __repr__");
            }
            return protocolString("__repr__", py_self);
        }

        pub fn py_str(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            if (!has_str) {
                @panic("py_str called on type without __str__");
            }
            return protocolString("__str__", py_self);
        }
    };
}

pub fn IteratorBuilder(comptime T: type) type {
    return struct {
        pub const has_iter = @hasDecl(T, "__iter__");
        pub const has_next = @hasDecl(T, "__next__");

        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_iter) names = names ++ .{"__iter__"};
            if (has_next) names = names ++ .{"__next__"};
            break :blk names;
        };

        pub fn py_iter(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = core.unwrap(T, py);
            const result = @field(T, "__iter__")(data);
            const RT = @TypeOf(result);
            if (RT == void or RT == *T or RT == *const T) {
                object.increfRaw(py);
                return py;
            }
            return marshal.handleReturn(RT, result);
        }

        pub fn py_iternext(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = core.unwrap(T, py);
            const result = @field(T, "__next__")(data);
            const RT = @TypeOf(result);
            const info = @typeInfo(RT);

            if (info == .optional) {
                if (result) |value| {
                    const obj = convert.toPy(value) catch return null;
                    return @ptrCast(obj);
                }
                return null;
            }

            if (info == .error_union) {
                const payload = result catch |err| {
                    if (err == error.PyError) return null;
                    errors.mapError(err);
                    return null;
                };
                const payload_info = @typeInfo(info.error_union.payload);
                if (payload_info == .optional) {
                    if (payload) |value| {
                        const obj = convert.toPy(value) catch return null;
                        return @ptrCast(obj);
                    }
                    return null;
                }
                const obj = convert.toPy(payload) catch return null;
                return @ptrCast(obj);
            }

            const obj = convert.toPy(result) catch return null;
            return @ptrCast(obj);
        }
    };
}
const testing = std.testing;

test "ReprBuilder 检测 __repr__ 声明" {
    const WithRepr = struct {
        pub fn __repr__(self: *const @This()) []const u8 {
            _ = self;
            return "WithRepr()";
        }
    };
    const WithoutRepr = struct {};
    try testing.expect(ReprBuilder(WithRepr).has_repr);
    try testing.expect(!ReprBuilder(WithoutRepr).has_repr);
}

test "ReprBuilder 检测 __str__ 声明" {
    const WithStr = struct {
        pub fn __str__(self: *const @This()) []const u8 {
            _ = self;
            return "str";
        }
    };
    const WithoutStr = struct {};
    try testing.expect(ReprBuilder(WithStr).has_str);
    try testing.expect(!ReprBuilder(WithoutStr).has_str);
}

test "ReprBuilder 独立检测 __repr__ 和 __str__" {
    const Both = struct {
        pub fn __repr__(self: *const @This()) []const u8 {
            _ = self;
            return "r";
        }
        pub fn __str__(self: *const @This()) []const u8 {
            _ = self;
            return "s";
        }
    };
    const R = ReprBuilder(Both);
    try testing.expect(R.has_repr);
    try testing.expect(R.has_str);
}

test "IteratorBuilder 检测 __iter__ 和 __next__" {
    const Iterable = struct {
        pub fn __iter__(self: *@This()) *@This() {
            return self;
        }
        pub fn __next__(self: *@This()) ?i32 {
            _ = self;
            return null;
        }
    };
    const NotIterable = struct {};
    const I = IteratorBuilder(Iterable);
    try testing.expect(I.has_iter);
    try testing.expect(I.has_next);
    const N = IteratorBuilder(NotIterable);
    try testing.expect(!N.has_iter);
    try testing.expect(!N.has_next);
}
