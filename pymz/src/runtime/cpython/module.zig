//! Method definition and module initialization helpers.
//!
//! This module provides both raw (`pyfn`, `RawArgs`) and typed
//! (`pyfn_typed`, `pyfn_kw`, `Args(T)`) wrappers for turning Zig functions
//! into Python-callable C callbacks. The typed wrappers automatically convert
//! arguments and return values via the `convert` module, mirroring the ergonomics
//! of PyO3 / PyOZ.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const stubs = @import("stubs.zig");
const Object = object.Object;
const Error = errors.Error;

// ============================================================================
// Method definition helpers
// ============================================================================

pub const MethodFlags = enum {
    varargs,
    keywords,
    noargs,
    o,
    fastcall,
    fastcall_keywords,

    pub inline fn toC(self: MethodFlags) c_int {
        return switch (self) {
            .varargs => c.METH_VARARGS,
            .keywords => c.METH_KEYWORDS,
            .noargs => c.METH_NOARGS,
            .o => c.METH_O,
            .fastcall => if (@hasDecl(c, "METH_FASTCALL")) c.METH_FASTCALL else c.METH_VARARGS,
            .fastcall_keywords => if (@hasDecl(c, "METH_FASTCALL"))
                c.METH_FASTCALL | c.METH_KEYWORDS
            else
                c.METH_VARARGS | c.METH_KEYWORDS,
        };
    }
};

pub const MethodDef = c.PyMethodDef;

pub inline fn sentinel() MethodDef {
    return .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
}

/// Build a PyMethodDef entry from a raw C-callback. The callback must match the
/// selected flags (e.g. `fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject`).
pub inline fn method(
    name: [:0]const u8,
    func: anytype,
    flags: MethodFlags,
    doc: ?[:0]const u8,
) MethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&func),
        .ml_flags = flags.toC(),
        .ml_doc = if (doc) |d| d else null,
    };
}

/// Convenience wrapper around `method` for typed (auto-converting) functions.
/// `func` must be a plain Zig function with positional parameters and an
/// optional `Error!T` return type. The wrapper reads its arguments from a
/// Python VARARGS tuple and converts each via `convert.fromPy`.
pub inline fn method_typed(
    comptime name: [:0]const u8,
    comptime func: anytype,
    comptime doc: ?[:0]const u8,
) MethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&pyfn_typed(func)),
        .ml_flags = MethodFlags.varargs.toC(),
        .ml_doc = if (doc) |d| d else null,
    };
}

/// Convenience wrapper around `method` for typed functions that accept keyword
/// arguments via `Args(T)`. `func` must take a single `Args(T)` parameter.
pub inline fn method_kw(
    comptime name: [:0]const u8,
    comptime func: anytype,
    comptime doc: ?[:0]const u8,
) MethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&pyfn_kw(func)),
        .ml_flags = (MethodFlags.varargs.toC() | MethodFlags.keywords.toC()),
        .ml_doc = if (doc) |d| d else null,
    };
}

// ============================================================================
// Raw (manual) function wrapper
// ============================================================================

/// PyO3-style wrapper: turns a Zig function `fn (RawArgs) Error!*c.PyObject`
/// into a Python C-callback. Use with `method("add", pyfn(add), .varargs, "...")`.
///
/// The returned callback accepts only positional arguments.  For a callback
/// that also receives keyword arguments, use `pyfn_varargs`.
pub inline fn pyfn(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const S = struct {
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args = RawArgs.fromTuple(@ptrCast(py_args), null);
            const result = func(args) catch return null;
            return result;
        }
    };
    return S.wrapper;
}

/// Wrapper for functions that need the full positional and keyword argument
/// payload.  The Zig function receives a `RawArgs` where `kwargs` is non-null
/// when the caller passed keyword arguments.
pub inline fn pyfn_varargs(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const S = struct {
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject, py_kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args = RawArgs.fromTuple(@ptrCast(py_args), @ptrCast(py_kwargs));
            const result = func(args) catch return null;
            return result;
        }
    };
    return S.wrapper;
}

// ============================================================================
// Typed function wrapper (pyfn_typed) — auto argument / return conversion
// ============================================================================

/// Wrap a typed Zig function into a Python VARARGS callback.
///
/// `func` may be e.g. `fn (i64, i64) Error!i64` or `fn (i64) i64` or
/// `fn () void`. Each parameter is converted with `convert.fromPy` and the
/// return value is converted with `convert.toPy` (or `null` on error).
pub fn pyfn_typed(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Params = fn_info.params;

    const S = struct {
        fn releaseConverted(args: *std.meta.ArgsTuple(Fn), count: usize) void {
            inline for (Params, 0..) |param, i| {
                if (i < count) {
                    if (param.type) |_| {
                        convert.releaseValue(&args[i]);
                    }
                }
            }
        }

        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;

            const required_count = comptime blk: {
                var count: usize = 0;
                for (Params) |param| {
                    const is_optional = if (param.type) |PT| @typeInfo(PT) == .optional else false;
                    if (!is_optional) count += 1;
                }
                break :blk count;
            };

            if (num_pos < required_count or num_pos > Params.len) {
                errors.typeError(
                    "function takes {d} to {d} positional argument(s) ({d} given)",
                    .{ required_count, Params.len, num_pos },
                ) catch {};
                return null;
            }

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_typed: parameter has unknown type");
                if (i < num_pos) {
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing argument {d}", .{i + 1}) catch {};
                        releaseConverted(&zig_args, converted_count);
                        return null;
                    };
                    zig_args[i] = convert.fromPy(PT, py_item) catch {
                        errors.typeError(
                            "argument {d} expects {s}, got {s}",
                            .{ i + 1, @typeName(PT), convert.pyTypeName(py_item) },
                        ) catch {};
                        releaseConverted(&zig_args, converted_count);
                        return null;
                    };
                    converted_count += 1;
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument {d}", .{i + 1}) catch {};
                    releaseConverted(&zig_args, converted_count);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            releaseConverted(&zig_args, converted_count);
            return convert.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

// ============================================================================
// Mixed positional/keyword wrapper (pyfn_mixed) — uses param names
// ============================================================================

/// Wrap a typed Zig function into a Python VARARGS|KEYWORDS callback.
/// Arguments may be passed positionally or by keyword using `param_names`.
pub fn pyfn_mixed(comptime func: anytype, comptime param_names: ?[]const u8) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Params = fn_info.params;

    const S = struct {
        const names = param_names;

        fn releaseConverted(args: *std.meta.ArgsTuple(Fn), count: usize) void {
            inline for (Params, 0..) |param, i| {
                if (i < count) {
                    if (param.type) |_| {
                        convert.releaseValue(&args[i]);
                    }
                }
            }
        }

        fn paramName(comptime index: usize) []const u8 {
            if (names) |n| {
                return stubs.getParamName(n, index);
            }
            return std.fmt.comptimePrint("arg{d}", .{index});
        }

        fn argIndex(keyword_name: []const u8) ?usize {
            inline for (Params, 0..) |_, i| {
                if (std.mem.eql(u8, keyword_name, comptime paramName(i))) {
                    return i;
                }
            }
            return null;
        }

        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject, py_kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const kwargs_dict: ?*types.Dict = if (py_kwargs) |k| @ptrCast(k) else null;
            const pos_count: usize = if (args_tuple) |t| t.length() else 0;

            if (pos_count > Params.len) {
                errors.typeError(
                    "function takes at most {d} positional argument(s) ({d} given)",
                    .{ Params.len, pos_count },
                ) catch {};
                return null;
            }

            if (kwargs_dict) |kw| {
                var pos: c.Py_ssize_t = 0;
                var key_obj: ?*c.PyObject = null;
                var value_obj: ?*c.PyObject = null;
                while (c.PyDict_Next(@ptrCast(kw), &pos, &key_obj, &value_obj) != 0) {
                    const keyword_obj: *Object = @ptrCast(key_obj orelse {
                        errors.typeError("keyword argument name must be str", .{}) catch {};
                        return null;
                    });
                    if (!object.Str.check(keyword_obj)) {
                        errors.typeError("keyword argument name must be str", .{}) catch {};
                        return null;
                    }

                    const keyword_name = object.Str.asString(@ptrCast(keyword_obj)) catch |err| {
                        errors.mapError(err) catch {};
                        return null;
                    };
                    const arg_idx = argIndex(keyword_name) orelse {
                        errors.typeError("got an unexpected keyword argument '{s}'", .{keyword_name}) catch {};
                        return null;
                    };
                    if (arg_idx < pos_count) {
                        errors.typeError("got multiple values for argument '{s}'", .{keyword_name}) catch {};
                        return null;
                    }
                }
            }

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_mixed: parameter has unknown type");
                if (i < pos_count) {
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing positional argument {d}", .{i + 1}) catch {};
                        releaseConverted(&zig_args, converted_count);
                        return null;
                    };
                    zig_args[i] = convert.fromPy(PT, py_item) catch {
                        errors.typeError(
                            "argument '{s}' expects {s}, got {s}",
                            .{ comptime paramName(i), @typeName(PT), convert.pyTypeName(py_item) },
                        ) catch {};
                        releaseConverted(&zig_args, converted_count);
                        return null;
                    };
                    converted_count += 1;
                } else if (kwargs_dict) |kw| {
                    const name_z = comptime paramName(i) ++ "\x00";
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    if (c.PyDict_GetItemString(@ptrCast(kw), name_ptr)) |item| {
                        const py_item: *Object = @ptrCast(item);
                        zig_args[i] = convert.fromPy(PT, py_item) catch {
                            errors.typeError(
                                "argument '{s}' expects {s}, got {s}",
                                .{ comptime paramName(i), @typeName(PT), convert.pyTypeName(py_item) },
                            ) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    } else if (comptime @typeInfo(PT) == .optional) {
                        zig_args[i] = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)}) catch {};
                        releaseConverted(&zig_args, converted_count);
                        return null;
                    }
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)}) catch {};
                    releaseConverted(&zig_args, converted_count);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            releaseConverted(&zig_args, converted_count);
            return convert.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

// ============================================================================
// Keyword-argument wrapper (pyfn_kw) — uses Args(T) struct
// ============================================================================

/// Typed wrapper for a function taking `Args(T)` where `T` is a struct.
/// Fields of `T` become keyword argument names; optional fields default to
/// `null`, and fields with `= value` defaults use those defaults.
pub fn pyfn_kw(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const params = fn_info.params;
    if (params.len != 1) {
        @compileError("pyfn_kw: function must take a single Args(T) parameter");
    }
    const ArgsWrapper = params[0].type orelse @compileError("pyfn_kw: cannot infer Args type");
    if (@typeInfo(ArgsWrapper) != .@"struct" or !@hasDecl(ArgsWrapper, "ArgsStruct")) {
        @compileError(
            "pyfn_kw: parameter must be Args(T). Change `fn(" ++
                @typeName(ArgsWrapper) ++
                ")` to `fn(pymz.Args(YourStruct))`",
        );
    }
    const InnerT = ArgsWrapper.ArgsStruct;
    const InnerInfo = @typeInfo(InnerT);
    if (InnerInfo != .@"struct") {
        @compileError("pyfn_kw: Args(T) expects T to be a struct, got " ++ @typeName(InnerT));
    }
    const Fields = InnerInfo.@"struct".fields;

    const S = struct {
        // Per-field initialization flags. Tracking a contiguous prefix via a
        // single counter is insufficient when fields are filled out of order
        // (e.g. a default at index 0 followed by a keyword arg at index 1):
        // doing so would skip releasing fields that were actually converted
        // via `convert.fromPy`. We instead record exactly which fields have
        // been assigned so the cleanup path can release precisely those.
        const InitFlags = [Fields.len]bool;

        fn releaseFields(value: *InnerT, init: *const InitFlags) void {
            inline for (Fields, 0..) |field, i| {
                if (init[i]) {
                    convert.releaseValue(&@field(value, field.name));
                }
            }
        }

        fn fieldIndex(keyword_name: []const u8) ?usize {
            inline for (Fields, 0..) |field, i| {
                if (std.mem.eql(u8, keyword_name, field.name)) {
                    return i;
                }
            }
            return null;
        }

        fn wrapper(
            _: ?*c.PyObject,
            py_args: ?*c.PyObject,
            py_kwargs: ?*c.PyObject,
        ) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const kwargs_dict: ?*types.Dict = if (py_kwargs) |k| @ptrCast(k) else null;
            const pos_count: usize = if (args_tuple) |t| t.length() else 0;

            if (pos_count > Fields.len) {
                errors.typeError(
                    "function takes at most {d} positional argument(s) ({d} given)",
                    .{ Fields.len, pos_count },
                ) catch {};
                return null;
            }

            if (kwargs_dict) |kw| {
                var pos: c.Py_ssize_t = 0;
                var key_obj: ?*c.PyObject = null;
                var value_obj: ?*c.PyObject = null;
                while (c.PyDict_Next(@ptrCast(kw), &pos, &key_obj, &value_obj) != 0) {
                    const keyword_obj: *Object = @ptrCast(key_obj orelse {
                        errors.typeError("keyword argument name must be str", .{}) catch {};
                        return null;
                    });
                    if (!object.Str.check(keyword_obj)) {
                        errors.typeError("keyword argument name must be str", .{}) catch {};
                        return null;
                    }

                    const keyword_name = object.Str.asString(@ptrCast(keyword_obj)) catch |err| {
                        errors.mapError(err) catch {};
                        return null;
                    };
                    const field_idx = fieldIndex(keyword_name) orelse {
                        errors.typeError("got an unexpected keyword argument '{s}'", .{keyword_name}) catch {};
                        return null;
                    };
                    if (field_idx < pos_count) {
                        errors.typeError("got multiple values for argument '{s}'", .{keyword_name}) catch {};
                        return null;
                    }
                }
            }

            var value: InnerT = undefined;
            var initialized: InitFlags = [_]bool{false} ** Fields.len;

            inline for (Fields, 0..) |field, i| {
                const is_optional = @typeInfo(field.type) == .optional;
                const has_default = field.default_value_ptr != null;

                if (i < pos_count) {
                    // Positional argument
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing positional argument {d}", .{i + 1}) catch {};
                        releaseFields(&value, &initialized);
                        return null;
                    };
                    if (is_optional and py_item.isNone()) {
                        @field(value, field.name) = null;
                    } else if (is_optional) {
                        const inner_type = @typeInfo(field.type).optional.child;
                        @field(value, field.name) = convert.fromPy(inner_type, py_item) catch {
                            errors.typeError(
                                "argument '{s}' expects {s}, got {s}",
                                .{ field.name, @typeName(inner_type), convert.pyTypeName(py_item) },
                            ) catch {};
                            releaseFields(&value, &initialized);
                            return null;
                        };
                    } else {
                        @field(value, field.name) = convert.fromPy(field.type, py_item) catch {
                            errors.typeError(
                                "argument '{s}' expects {s}, got {s}",
                                .{ field.name, @typeName(field.type), convert.pyTypeName(py_item) },
                            ) catch {};
                            releaseFields(&value, &initialized);
                            return null;
                        };
                    }
                    initialized[i] = true;
                } else if (kwargs_dict) |kw| {
                    // Try keyword argument by name
                    const name_z = field.name ++ "\x00";
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    const py_item_opt: ?*Object = @ptrCast(c.PyDict_GetItemString(@ptrCast(kw), name_ptr));
                    if (py_item_opt) |py_item| {
                        if (is_optional and py_item.isNone()) {
                            @field(value, field.name) = null;
                        } else if (is_optional) {
                            const inner_type = @typeInfo(field.type).optional.child;
                            @field(value, field.name) = convert.fromPy(inner_type, py_item) catch {
                                errors.typeError(
                                    "argument '{s}' expects {s}, got {s}",
                                    .{ field.name, @typeName(inner_type), convert.pyTypeName(py_item) },
                                ) catch {};
                                releaseFields(&value, &initialized);
                                return null;
                            };
                        } else {
                            @field(value, field.name) = convert.fromPy(field.type, py_item) catch {
                                errors.typeError(
                                    "argument '{s}' expects {s}, got {s}",
                                    .{ field.name, @typeName(field.type), convert.pyTypeName(py_item) },
                                ) catch {};
                                releaseFields(&value, &initialized);
                                return null;
                            };
                        }
                    } else if (has_default) {
                        @field(value, field.name) = field.defaultValue().?;
                    } else if (is_optional) {
                        @field(value, field.name) = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{field.name}) catch {};
                        releaseFields(&value, &initialized);
                        return null;
                    }
                    initialized[i] = true;
                } else if (has_default) {
                    @field(value, field.name) = field.defaultValue().?;
                    initialized[i] = true;
                } else if (is_optional) {
                    @field(value, field.name) = null;
                    initialized[i] = true;
                } else {
                    errors.typeError("missing required argument: '{s}'", .{field.name}) catch {};
                    releaseFields(&value, &initialized);
                    return null;
                }
            }

            const wrapped = ArgsWrapper{ .value = value };
            const result = func(wrapped);
            releaseFields(&value, &initialized);
            return convert.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

// ============================================================================
// Argument container types
// ============================================================================

/// Runtime accessor for raw `*Tuple` / `*Dict` arguments. Used by `pyfn`.
pub const RawArgs = struct {
    args: *types.Tuple,
    kwargs: ?*types.Dict,

    pub inline fn fromTuple(args: *types.Tuple, kwargs: ?*types.Dict) RawArgs {
        return .{ .args = args, .kwargs = kwargs };
    }

    pub inline fn len(self: RawArgs) usize {
        return self.args.length();
    }

    pub inline fn get(self: RawArgs, i: usize) ?*Object {
        return self.args.get(i);
    }

    pub inline fn getObject(self: RawArgs, i: usize) Error!*Object {
        if (self.get(i)) |o| return o;
        try errors.typeError("expected at least {d} arguments", .{i + 1});
        return error.PyError;
    }

    pub inline fn getInt(self: RawArgs, i: usize) Error!isize {
        const obj = try self.getObject(i);
        if (!types.Int.check(obj)) {
            try errors.typeError("argument {d} must be an integer", .{i + 1});
            return error.PyError;
        }
        return types.Int.as(@ptrCast(obj), isize);
    }

    pub inline fn getStr(self: RawArgs, i: usize) Error!*object.Str {
        const obj = try self.getObject(i);
        if (!object.Str.check(obj)) {
            try errors.typeError("argument {d} must be a string", .{i + 1});
            return error.PyError;
        }
        return @ptrCast(obj);
    }

    /// Return true if any keyword arguments were supplied.
    pub inline fn hasKwargs(self: RawArgs) bool {
        return self.kwargs != null and self.kwargs.?.length() > 0;
    }

    /// Return the number of supplied keyword arguments.
    pub inline fn kwLen(self: RawArgs) usize {
        return if (self.kwargs) |kw| kw.length() else 0;
    }

    /// Borrowed reference to a keyword argument by name, or null if missing.
    pub inline fn getKw(self: RawArgs, name: [:0]const u8) ?*Object {
        const kw = self.kwargs orelse return null;
        return kw.getItemString(name);
    }

    /// Return a keyword argument by name, raising TypeError if it is missing.
    pub inline fn getKwObject(self: RawArgs, name: [:0]const u8) Error!*Object {
        if (self.getKw(name)) |o| return o;
        try errors.typeError("missing required keyword argument: '{s}'", .{name});
        return error.PyError;
    }
};

/// Typed keyword-argument wrapper. Use with `pyfn_kw`:
///
/// ```zig
/// const AddArgs = struct { a: i64, b: i64, c: ?i64 = null };
/// fn add(args: pymz.Args(AddArgs)) pymz.Result(i64) { ... }
/// ```
pub fn Args(comptime T: type) type {
    return struct {
        value: T,
        pub const ArgsStruct = T;
    };
}

// ============================================================================
// Module initialization abstraction
// ============================================================================

/// Module initialization callback signature accepted by `moduleInit`.
pub const ModuleInitFn = *const fn (mod: *types.Module) Error!void;

/// Define a Python extension module. This macro exports the correct entry point
/// for Python 2 (`init<name>`) or Python 3 (`PyInit_<name>`).
pub fn moduleInit(comptime name: [:0]const u8, methods: [*c]MethodDef, init_fn: ?ModuleInitFn, comptime doc: ?[:0]const u8) type {
    return struct {
        // Python keeps a pointer to the PyModuleDef inside the module object,
        // so it must outlive the init function.
        var module_def: c.PyModuleDef = .{
            .m_base = .{ .ob_base = std.mem.zeroes(c.PyObject), .m_init = null },
            .m_name = name,
            .m_doc = if (doc) |d| d else null,
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
            // Python 2's Py_InitModule does not take a docstring; set it as a
            // module attribute instead.
            if (doc) |d| {
                _ = c.PyModule_AddStringConstant(mod, "__doc__", d);
            }
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
