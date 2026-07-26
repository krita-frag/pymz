//! Repr/str and iterator protocol generation for Zig-backed classes.

const c = @import("../c.zig").c;
const convert = @import("../convert.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const core = @import("core.zig");

pub fn Repr(comptime func: anytype) type {
    return struct {
        pub const callback = func;
    };
}

pub fn Str(comptime func: anytype) type {
    return struct {
        pub const callback = func;
    };
}

pub fn ReprBuilder(comptime T: type) type {
    return struct {
        pub const has_repr = @hasDecl(T, "__repr__");
        pub const has_str = @hasDecl(T, "__str__");

        fn protocolString(comptime name: []const u8, py_self: ?*c.PyObject) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = core.unwrapConst(T, py);
            const decl = @field(T, name);
            const DeclType = @TypeOf(decl);
            if (@typeInfo(DeclType) == .@"fn") {
                const s = decl(data);
                const obj = object.Str.fromSlice(s) catch return null;
                return @ptrCast(obj);
            }
            if (@typeInfo(DeclType) == .type and @hasDecl(decl, "callback")) {
                const s = decl.callback(data);
                const obj = object.Str.fromSlice(s) catch return null;
                return @ptrCast(obj);
            }
            @compileError("protocol field must be a function or a py protocol descriptor");
        }

        pub fn py_repr(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            if (!has_repr) {
                const py = py_self orelse return null;
                return c.PyObject_Repr(py);
            }
            return protocolString("__repr__", py_self);
        }

        pub fn py_str(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
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

        pub fn py_iter(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = core.unwrap(T, py);
            const result = @field(T, "__iter__")(data);
            const RT = @TypeOf(result);
            if (RT == void or RT == *T or RT == *const T) {
                c.Py_INCREF(py);
                return py;
            }
            return convert.handleReturn(RT, result);
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
                    errors.typeError("iterator error: {s}", .{@errorName(err)}) catch {};
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
