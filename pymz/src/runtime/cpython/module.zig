//! Method definition and module initialization helpers.
//!
//! This module provides both raw (`pyfn_varargs`, `RawArgs`) and typed
//! (`pyfn_typed`, `pyfn_kw`, `Args(T)`) wrappers for turning Zig functions
//! into Python-callable C callbacks. The typed wrappers automatically convert
//! arguments and return values via the `convert` module, mirroring the ergonomics
//! of PyO3 / PyOZ.

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const marshal = @import("marshal.zig");
const signature = @import("signature.zig");
const Object = object.Object;
const Error = errors.Error;

pub const MethodFlags = enum {
    varargs,
    keywords,

    pub inline fn toC(self: MethodFlags) c_int {
        return switch (self) {
            .varargs => c.METH_VARARGS,
            .keywords => c.METH_KEYWORDS,
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
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;

            const required_count = comptime marshal.requiredParamCount(Fn, 0);

            if (num_pos < required_count or num_pos > Params.len) {
                errors.typeError(
                    "function takes {d} to {d} positional argument(s) ({d} given)",
                    .{ required_count, Params.len, num_pos },
                );
                return null;
            }

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_typed: parameter has unknown type");
                if (i < num_pos) {
                    const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                    const converted = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label);
                    if (converted) |value| {
                        zig_args[i] = value;
                    } else {
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    }
                    converted_count += 1;
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument {d}", .{i + 1});
                    marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}
/// Wrap a typed Zig function into a Python VARARGS|KEYWORDS callback.
/// Arguments may be passed positionally or by keyword using `param_names`.
pub fn pyfn_mixed(comptime func: anytype, comptime param_names: ?[]const u8) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Params = fn_info.params;

    const S = struct {
        const names = param_names;

        fn paramName(comptime index: usize) []const u8 {
            if (names) |n| {
                return signature.getParamName(n, index);
            }
            return std.fmt.comptimePrint("arg{d}", .{index});
        }

        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject, py_kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const preamble = (extractArgs(py_args, py_kwargs, paramName, Params.len) orelse return null);
            const args_tuple = preamble.args;
            const kwargs_dict = preamble.kwargs;
            const pos_count = preamble.pos;

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_mixed: parameter has unknown type");
                if (i < pos_count) {
                    const arg_label = comptime paramName(i);
                    const converted = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label);
                    if (converted) |value| {
                        zig_args[i] = value;
                    } else {
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    }
                    converted_count += 1;
                } else if (kwargs_dict) |kw| {
                    const name_z = comptime convert.toSentinelStr(paramName(i));
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    if (c.PyDict_GetItemString(@ptrCast(kw), name_ptr)) |item| {
                        const py_item: *Object = @ptrCast(item);
                        const converted = marshal.convertField(PT, py_item, comptime paramName(i));
                        if (converted) |value| {
                            zig_args[i] = value;
                        } else {
                            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                            return null;
                        }
                        converted_count += 1;
                    } else if (comptime @typeInfo(PT) == .optional) {
                        zig_args[i] = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)});
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    }
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)});
                    marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

/// Wrapper preamble shared by `pyfn_mixed` and `pyfn_kw`:
/// extract args tuple, kwargs dict, and positional count; validate count and
/// keyword names. Returns `null` on validation failure (Python error set).
fn extractArgs(
    py_args: ?*c.PyObject,
    py_kwargs: ?*c.PyObject,
    comptime FieldName: fn (comptime usize) []const u8,
    comptime max_count: usize,
) ?struct { args: ?*types.Tuple, kwargs: ?*types.Dict, pos: usize } {
    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
    const kwargs_dict: ?*types.Dict = if (py_kwargs) |k| @ptrCast(k) else null;
    const pos_count: usize = if (args_tuple) |t| t.length() else 0;

    if (pos_count > max_count) {
        errors.typeError(
            "function takes at most {d} positional argument(s) ({d} given)",
            .{ max_count, pos_count },
        );
        return null;
    }

    if (kwargs_dict) |kw| {
        if (!marshal.validateKeywordNames(kw, pos_count, FieldName, max_count)) {
            return null;
        }
    }

    return .{ .args = args_tuple, .kwargs = kwargs_dict, .pos = pos_count };
}

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

        fn fieldName(comptime index: usize) []const u8 {
            return Fields[index].name;
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
                );
                return null;
            }

            if (kwargs_dict) |kw| {
                if (!marshal.validateKeywordNames(kw, pos_count, fieldName, Fields.len)) {
                    return null;
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
                        errors.typeError("missing positional argument {d}", .{i + 1});
                        releaseFields(&value, &initialized);
                        return null;
                    };
                    const converted = marshal.convertField(field.type, py_item, field.name);
                    if (converted) |v| {
                        @field(value, field.name) = v;
                    } else {
                        releaseFields(&value, &initialized);
                        return null;
                    }
                    initialized[i] = true;
                } else if (kwargs_dict) |kw| {
                    // Try keyword argument by name
                    const name_z = comptime convert.toSentinelStr(field.name);
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    const py_item_opt: ?*Object = @ptrCast(c.PyDict_GetItemString(@ptrCast(kw), name_ptr));
                    if (py_item_opt) |py_item| {
                        const converted = marshal.convertField(field.type, py_item, field.name);
                        if (converted) |v| {
                            @field(value, field.name) = v;
                        } else {
                            releaseFields(&value, &initialized);
                            return null;
                        }
                    } else if (has_default) {
                        @field(value, field.name) = field.defaultValue().?;
                    } else if (is_optional) {
                        @field(value, field.name) = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{field.name});
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
                    errors.typeError("missing required argument: '{s}'", .{field.name});
                    releaseFields(&value, &initialized);
                    return null;
                }
            }

            const wrapped = ArgsWrapper{ .value = value };
            const result = func(wrapped);
            releaseFields(&value, &initialized);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

/// Runtime accessor for raw `*Tuple` / `*Dict` arguments. Used by `pyfn_varargs`.
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
        errors.typeError("expected at least {d} arguments", .{i + 1});
        return error.PyError;
    }

    pub inline fn getInt(self: RawArgs, i: usize) Error!isize {
        const obj = try self.getObject(i);
        if (!types.Int.check(obj)) {
            errors.typeError("argument {d} must be an integer", .{i + 1});
            return error.PyError;
        }
        return types.Int.as(@ptrCast(obj), isize);
    }

    pub inline fn getStr(self: RawArgs, i: usize) Error!*object.Str {
        const obj = try self.getObject(i);
        if (!object.Str.check(obj)) {
            errors.typeError("argument {d} must be a string", .{i + 1});
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
        errors.typeError("missing required keyword argument: '{s}'", .{name});
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

/// Module initialization callback signature accepted by `moduleInit`.
pub const ModuleInitFn = *const fn (mod: *types.Module) Error!void;

/// Define a Python extension module. This macro exports the correct entry point
/// for Python 2 (`init<name>`) or Python 3 (`PyInit_<name>`).
///
/// On Python 3 this uses PEP 489 multi-phase initialization (`m_slots` +
/// `PyModuleDef_Init`), giving proper sub-interpreter support. On Python 2
/// the legacy `Py_InitModule` path is used.
pub fn moduleInit(comptime name: [:0]const u8, methods: [*c]MethodDef, init_fn: ?ModuleInitFn, comptime doc: ?[:0]const u8) type {
    const Initializer = if (version.is_py3) struct {
        // PEP 489 multi-phase init: the module definition lives until the
        // interpreter shuts down (Python holds a reference to the def object).
        var module_def: c.PyModuleDef = .{
            .m_base = .{ .ob_base = std.mem.zeroes(c.PyObject), .m_init = null },
            .m_name = name,
            .m_doc = if (doc) |d| d else null,
            .m_size = -1,
            .m_methods = methods,
            .m_slots = &slots,
            .m_traverse = null,
            .m_clear = null,
            .m_free = null,
        };

        // Slots array: Py_mod_exec (slot=1) for the module population callback,
        // terminated by {0, NULL} sentinel.
        var slots = [_]c.PyModuleDef_Slot{
            .{ .slot = 1, .value = @ptrCast(@constCast(&execFn)) },
            .{ .slot = 0, .value = null },
        };

        /// PEP 489 `Py_mod_exec` slot handler. Called by CPython after the
        /// module object is created. Returns 0 on success, -1 on error (with
        /// an active Python exception).
        fn execFn(mod: ?*c.PyObject, _: c_int) callconv(.c) c_int {
            if (init_fn) |f| {
                f(@ptrCast(mod.?)) catch {
                    return -1;
                };
            }
            return 0;
        }

        /// PEP 489 init entry point: return the module definition via
        /// `PyModuleDef_Init` (as opposed to `PyModule_Create`).
        fn init() callconv(.c) [*c]c.PyObject {
            return c.pymz_PyModuleDef_Init(&module_def);
        }
    } else struct {
        fn init() callconv(.c) void {
            const mod = c.Py_InitModule(name, methods) orelse return;
            // Python 2's Py_InitModule does not take a docstring; set it as a
            // module attribute instead.
            if (doc) |d| {
                _ = c.PyModule_AddStringConstant(mod, "__doc__", d);
            }
            if (init_fn) |f| {
                f(@ptrCast(mod)) catch {
                    // Python 2 initializers return void, but the module is
                    // still owned by the interpreter after Py_InitModule.
                    // Leave the active exception intact and stop registration.
                    return;
                };
            }
        }
    };

    return struct {
        comptime {
            const fn_name = if (version.is_py3) "PyInit_" ++ name else "init" ++ name;
            @export(&Initializer.init, .{ .name = fn_name, .linkage = .strong });
        }
    };
}

test "method and sentinel produce well-formed MethodDef" {
    const S = struct {
        fn callback(_: ?*c.PyObject, _: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            return null;
        }
    };
    const def = method("test", S.callback, .varargs, "doc");
    try std.testing.expectEqualStrings("test", std.mem.span(def.ml_name.?));
    try std.testing.expectEqual(@as(c_int, c.METH_VARARGS), def.ml_flags);

    const end = sentinel();
    try std.testing.expect(end.ml_name == null);
    try std.testing.expectEqual(@as(c_int, 0), end.ml_flags);
}
