//! Method definition and module initialization helpers.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const Object = object.Object;
const Error = errors.Error;

// ============================================================================
// Method definition helpers
// ============================================================================

pub const MethodFlags = enum(c_int) {
    varargs = c.METH_VARARGS,
    keywords = c.METH_KEYWORDS,
    noargs = c.METH_NOARGS,
    o = c.METH_O,
    fastcall = if (@hasDecl(c, "METH_FASTCALL")) c.METH_FASTCALL else c.METH_VARARGS,
    fastcall_keywords = if (@hasDecl(c, "METH_FASTCALL")) c.METH_FASTCALL | c.METH_KEYWORDS else c.METH_VARARGS | c.METH_KEYWORDS,

    pub inline fn toC(self: MethodFlags) c_int {
        return @intFromEnum(self);
    }
};

pub const MethodDef = c.PyMethodDef;

pub inline fn sentinel() MethodDef {
    return .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
}

/// Build a PyMethodDef entry from a raw C-callback. The callback must match the
/// selected flags (e.g. `fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject`).
pub inline fn method(name: [:0]const u8, func: anytype, flags: MethodFlags, doc: ?[:0]const u8) MethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&func),
        .ml_flags = flags.toC(),
        .ml_doc = doc orelse null,
    };
}

/// PyO3-style wrapper: turns a Zig function `fn (Args) Error!*c.PyObject` into a
/// Python C-callback. Use with `method("add", pyfn(add), .varargs, "...")`.
pub inline fn pyfn(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const S = struct {
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args = Args.fromTuple(@ptrCast(py_args), null);
            const result = func(args) catch return null;
            return result;
        }
    };
    return S.wrapper;
}

// ============================================================================
// Argument parsing abstraction
// ============================================================================

pub const Args = struct {
    args: *types.Tuple,
    kwargs: ?*types.Dict,

    pub inline fn fromTuple(args: *types.Tuple, kwargs: ?*types.Dict) Args {
        return .{ .args = args, .kwargs = kwargs };
    }

    pub inline fn len(self: Args) usize {
        return self.args.length();
    }

    pub inline fn get(self: Args, i: usize) ?*Object {
        return self.args.get(i);
    }

    pub inline fn getObject(self: Args, i: usize) Error!*Object {
        if (self.get(i)) |o| return o;
        try errors.typeError("expected at least {d} arguments", .{i + 1});
        return error.PyError;
    }

    pub inline fn getInt(self: Args, i: usize) Error!isize {
        const obj = try self.getObject(i);
        if (!types.Int.check(obj)) {
            try errors.typeError("argument {d} must be an integer", .{i + 1});
            return error.PyError;
        }
        return types.Int.as(@ptrCast(obj), isize);
    }

    pub inline fn getStr(self: Args, i: usize) Error!*object.Str {
        const obj = try self.getObject(i);
        if (!object.Str.check(obj)) {
            try errors.typeError("argument {d} must be a string", .{i + 1});
            return error.PyError;
        }
        return @ptrCast(obj);
    }
};

// ============================================================================
// Module initialization abstraction
// ============================================================================

/// Module initialization callback signature accepted by `moduleInit`.
pub const ModuleInitFn = *const fn (mod: *types.Module) Error!void;

/// Define a Python extension module. This macro exports the correct entry point
/// for Python 2 (`init<name>`) or Python 3 (`PyInit_<name>`).
pub fn moduleInit(comptime name: [:0]const u8, methods: [*c]MethodDef, init_fn: ?ModuleInitFn) type {
    return struct {
        // Python keeps a pointer to the PyModuleDef inside the module object,
        // so it must outlive the init function.
        var module_def: c.PyModuleDef = .{
            .m_base = .{ .ob_base = std.mem.zeroes(c.PyObject), .m_init = null },
            .m_name = name,
            .m_doc = null,
            .m_size = -1,
            .m_methods = methods,
            .m_slots = null,
            .m_traverse = null,
            .m_clear = null,
            .m_free = null,
        };

        fn py3Init() callconv(.c) [*c]c.PyObject {
            const mod = c.PyModule_Create(&module_def) orelse return null;
            if (init_fn) |f| {
                f(@ptrCast(mod)) catch return null;
            }
            return mod;
        }

        fn py2Init() callconv(.c) void {
            const mod = c.Py_InitModule(name, methods) orelse return;
            if (init_fn) |f| {
                f(@ptrCast(mod)) catch return;
            }
        }

        comptime {
            const fn_name = if (version.is_py3) "PyInit_" ++ name else "init" ++ name;
            const fn_ptr = if (version.is_py3) &py3Init else &py2Init;
            @export(fn_ptr, .{ .name = fn_name, .linkage = .strong });
        }
    };
}
