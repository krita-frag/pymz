//! Repr/str and iterator protocol generation for Zig-backed classes.

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

        /// Dunder names this builder handles when declared on T. This is the
        /// single source of truth consumed by `dunders.isReservedDunder`.
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
            // Defensive: this branch is unreachable because `py_repr` is only
            // installed as `tp_repr` when `has_repr` is true. Kept as a safety
            // net in case the function is ever called directly.
            if (!has_repr) {
                const py = py_self orelse return null;
                return c.PyObject_Repr(py);
            }
            return protocolString("__repr__", py_self);
        }

        pub fn py_str(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            // Defensive: this branch is unreachable because `py_str` is only
            // installed as `tp_str` when `has_str` is true. Kept as a safety
            // net in case the function is ever called directly.
            if (!has_str) {
                const py = py_self orelse return null;
                return c.PyObject_Str(py);
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
                    errors.typeError("iterator error: {s}", .{@errorName(err)});
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

test "ReprBuilder detects __repr__ declaration" {
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

test "ReprBuilder detects __str__ declaration" {
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

test "ReprBuilder detects both __repr__ and __str__ independently" {
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

test "IteratorBuilder detects __iter__ and __next__" {
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
