//! Minimal Python class support: turn a Zig struct into a Python class.
//!
//! Design (close to PyO3 / PyOZ ergonomics):
//!   - Each registered Zig struct `T` produces a singleton `PyTypeObject`.
//!   - The Python instance layout is `extern struct { ob_base: c.PyObject, data: T }`
//!     so a `*PyObject` can be cast to `*Wrapper(T)` and back.
//!   - Public struct fields become read/write Python properties (getset).
//!   - Fields starting with `_` are private (not exposed).
//!   - `pub fn __new__(...) T` overrides the auto-generated constructor.
//!   - `pub fn __del__(self: *T) void` runs on `tp_dealloc` before free.
//!   - `pub fn __repr__(self: *const T) []const u8` or
//!     `pub const __repr__ = py.Repr(...)` provides `tp_repr`.
//!   - Other `pub fn`s become methods: first param `*T`/`*const T` => instance
//!     method, otherwise static method.
//!
//! This is intentionally simpler than PyOZ: no GC visitor, no buffer protocol,
//! no inheritance. Just enough to expose a plain data struct with behaviour.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const module_mod = @import("module.zig");
const stubs = @import("stubs.zig");

const Object = object.Object;
const Error = errors.Error;
const MethodDef = module_mod.MethodDef;

// ============================================================================
// Public types
// ============================================================================

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

/// Opaque handle returned by `class()`. Pass it to `Module.addClass`.
pub const ClassDef = struct {
    name: [:0]const u8,
    /// Pointer to the static `PyTypeObject` generated for this class.
    /// Resolved lazily via `readyFn`.
    ready_fn: *const fn () *c.PyTypeObject,
    doc: ?[:0]const u8,

    pub inline fn getTypeObject(self: ClassDef) *c.PyTypeObject {
        return self.ready_fn();
    }
};

// ============================================================================
// Wrapper layout
// ============================================================================

/// Internal: the extern struct that backs a Python instance of class `T`.
/// `ob_base` is the `PyObject` header at offset 0 (required by Python C API).
/// The user's Zig value is stored in a byte array immediately after, with
/// proper alignment. We can't directly embed `T` in an `extern struct` unless
/// `T` itself has extern layout, so we use a typed byte buffer and cast.
pub fn Wrapper(comptime T: type) type {
    return extern struct {
        ob_base: c.PyObject,
        initialized: bool,
        // Padding to align `T` properly after the PyObject header.
        _pad: [0]u8 align(@alignOf(T)),
        // Backing storage for `T`. Accessed via `data()`/`dataConst()`.
        _storage: [@sizeOf(T)]u8 align(@alignOf(T)),

        pub inline fn fromPyObject(py: *c.PyObject) *Wrapper(T) {
            return @ptrCast(@alignCast(py));
        }

        pub inline fn asPyObject(self: *Wrapper(T)) *c.PyObject {
            return @ptrCast(self);
        }

        pub inline fn getData(self: *Wrapper(T)) *T {
            return @ptrCast(@alignCast(&self._storage));
        }

        pub inline fn getDataConst(self: *const Wrapper(T)) *const T {
            return @ptrCast(@alignCast(&self._storage));
        }
    };
}

/// Cast a `*PyObject` to `*T` (the user data pointer inside the wrapper).
pub inline fn unwrap(comptime T: type, py: *c.PyObject) *T {
    return Wrapper(T).fromPyObject(py).getData();
}

/// Cast a `*PyObject` to `*const T`.
pub inline fn unwrapConst(comptime T: type, py: *c.PyObject) *const T {
    return Wrapper(T).fromPyObject(py).getDataConst();
}

// ============================================================================
// Field helpers
// ============================================================================

fn isPrivateField(comptime name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

/// True if `T` is `*Self`, `*const Self`, or `Self` (instance method receiver).
fn isSelfParam(comptime T: type, comptime Self: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == Self,
        else => T == Self,
    };
}

/// Count public (non `_`-prefixed) fields of struct `T`.
fn countPublicFields(comptime T: type) usize {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".fields) |f| {
        if (!isPrivateField(f.name)) n += 1;
    }
    return n;
}

// ============================================================================
// Lifecycle: tp_new / tp_init / tp_dealloc
// ============================================================================

fn LifecycleBuilder(comptime T: type) type {
    return struct {
        const Self = Wrapper(T);
        const fields = @typeInfo(T).@"struct".fields;
        const has_custom_new = @hasDecl(T, "__new__");
        const has_del = @hasDecl(T, "__del__");
        const NewFn = if (has_custom_new) @TypeOf(T.__new__) else fn () void;

        /// Default `tp_new`: allocate via `PyType_GenericNew`, then if no
        /// custom `__new__` is provided, zero-initialise the data and apply
        /// field defaults where available.
        fn py_new(
            type_obj: *c.PyTypeObject,
            args: ?*c.PyObject,
            kwargs: ?*c.PyObject,
        ) callconv(.c) ?*c.PyObject {
            const obj = c.PyType_GenericNew(type_obj, args, kwargs);
            if (obj == null) return null;
            const wrapper: *Self = @ptrCast(@alignCast(obj.?));
            wrapper.initialized = false;
            return obj;
        }

        /// Default `tp_init`: if user provides `__new__`, call it with the
        /// Python args (auto-converted); otherwise populate fields from
        /// positional args in declaration order.
        fn py_init(
            py_self: ?*c.PyObject,
            args: ?*c.PyObject,
            kwargs: ?*c.PyObject,
        ) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const wrapper: *Self = @ptrCast(@alignCast(py));

            if (has_custom_new) {
                // Re-initialise via user __new__. We call the Zig function
                // directly with converted args (positional only, for now).
                const Fn = @TypeOf(T.__new__);
                const fn_info = @typeInfo(Fn).@"fn";
                const Params = fn_info.params;

                const args_tuple: ?*types.Tuple = if (args) |a| @ptrCast(a) else null;
                const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                if (kwargs) |kw| {
                    if (c.PyDict_Size(kw) != 0) {
                        errors.typeError("this constructor does not accept keyword arguments", .{}) catch {};
                        return -1;
                    }
                }
                if (num_pos != Params.len) {
                    errors.typeError(
                        "__new__ takes exactly {d} positional argument(s) ({d} given)",
                        .{ Params.len, num_pos },
                    ) catch {};
                    return -1;
                }

                var zig_args: std.meta.ArgsTuple(Fn) = undefined;
                var converted_count: usize = 0;
                inline for (Params, 0..) |param, i| {
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing argument {d}", .{i + 1}) catch {};
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    const PT = param.type orelse {
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    zig_args[i] = convert.fromPy(PT, py_item) catch {
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    converted_count += 1;
                }
                const result = @call(.auto, T.__new__, zig_args);
                wrapper.getData().* = result;
                wrapper.initialized = true;

                // Release temporary container arguments allocated by fromPy.
                releaseConstructorArgs(&zig_args, converted_count);
                return 0;
            }

            // Auto-init from positional args by public field order.
            const args_tuple: ?*types.Tuple = if (args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;
            if (kwargs) |kw| {
                if (c.PyDict_Size(kw) != 0) {
                    errors.typeError("this constructor does not accept keyword arguments", .{}) catch {};
                    return -1;
                }
            }

            var idx: usize = 0;
            var initialized_count: usize = 0;
            const data_ptr = wrapper.getData();
            inline for (fields) |field| {
                if (comptime isPrivateField(field.name)) {
                    // Use default value if available; otherwise leave undefined.
                    if (field.default_value_ptr) |dv| {
                        @field(data_ptr.*, field.name) = dv.*;
                    }
                } else if (idx < num_pos) {
                    const py_item = args_tuple.?.get(idx) orelse {
                        errors.typeError("missing argument '{s}'", .{field.name}) catch {};
                        cleanupFieldsPrefix(data_ptr, initialized_count);
                        return -1;
                    };
                    @field(data_ptr.*, field.name) = convert.fromPy(field.type, py_item) catch {
                        cleanupFieldsPrefix(data_ptr, initialized_count);
                        return -1;
                    };
                    idx += 1;
                } else if (field.default_value_ptr) |dv| {
                    @field(data_ptr.*, field.name) = dv.*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(data_ptr.*, field.name) = null;
                } else {
                    errors.typeError("missing required argument '{s}'", .{field.name}) catch {};
                    cleanupFieldsPrefix(data_ptr, initialized_count);
                    return -1;
                }
                initialized_count += 1;
            }
            wrapper.initialized = true;
            return 0;
        }

        fn releaseConstructorArgs(args: *std.meta.ArgsTuple(NewFn), count: usize) void {
            if (!has_custom_new) return;
            const Params = @typeInfo(NewFn).@"fn".params;
            inline for (Params, 0..) |param, i| {
                if (i < count) {
                    if (param.type) |_| {
                        convert.releaseValue(&args[i]);
                    }
                }
            }
        }

        /// Release temporary/owned resources held by public struct fields
        /// (e.g. ArrayList allocated during __init__).
        fn cleanupFields(data: *T) void {
            inline for (fields) |field| {
                if (!comptime isPrivateField(field.name)) {
                    convert.releaseValue(&@field(data, field.name));
                }
            }
        }

        fn cleanupFieldsPrefix(data: *T, count: usize) void {
            inline for (fields, 0..) |field, i| {
                if (i < count and !comptime isPrivateField(field.name)) {
                    convert.releaseValue(&@field(data, field.name));
                }
            }
        }

        /// `tp_dealloc`: call `__del__` if defined, release fields, then free.
        fn py_dealloc(py_self: ?*c.PyObject) callconv(.c) void {
            const py = py_self orelse return;
            const wrapper: *Self = @ptrCast(@alignCast(py));
            if (wrapper.initialized and has_del) {
                T.__del__(wrapper.getData());
            }
            if (wrapper.initialized) {
                cleanupFields(wrapper.getData());
            }
            // PyType_GenericFree uses the type's tp_free; that's PyType_GenericAlloc's
            // counterpart and the correct choice for types that use tp_alloc.
            const tp = c.Py_TYPE(py);
            if (tp) |t| {
                if (t.*.tp_free) |tp_free| {
                    tp_free(@ptrCast(py));
                } else {
                    c.PyObject_Free(@ptrCast(py));
                }
            } else {
                c.PyObject_Free(@ptrCast(py));
            }
        }

        /// Produce a default `T`: use field defaults where present, else
        /// `std.mem.zeroes` for zero-able types, else `undefined`.
        fn defaultInit() T {
            var result: T = undefined;
            inline for (fields) |field| {
                if (field.default_value_ptr) |dv| {
                    @field(result, field.name) = dv.*;
                } else if (canZeroInit(field.type)) {
                    @field(result, field.name) = std.mem.zeroes(field.type);
                }
                // else: leave undefined — user must set via __init__ / __new__
            }
            return result;
        }

        fn canZeroInit(comptime FieldType: type) bool {
            return switch (@typeInfo(FieldType)) {
                .pointer => |p| p.is_allowzero,
                .optional => true,
                .@"struct" => |s| {
                    for (s.fields) |f| {
                        if (!canZeroInit(f.type)) return false;
                    }
                    return true;
                },
                .@"union" => |u| {
                    for (u.fields) |f| {
                        if (!canZeroInit(f.type)) return false;
                    }
                    return true;
                },
                .@"fn" => false,
                else => true,
            };
        }
    };
}

// ============================================================================
// Properties (getset)
// ============================================================================

/// Build a PyGetSetDef table that exposes public struct fields as read/write
/// Python properties. Fields whose name starts with `_` are considered private
/// and are not exposed.
fn PropertiesBuilder(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".fields;
        const public_count = countPublicFields(T);

        /// Generate a null-terminated sentinel table of getters/setters.
        pub fn buildGetSetTable() [public_count + 1]c.PyGetSetDef {
            var table: [public_count + 1]c.PyGetSetDef = std.mem.zeroes([public_count + 1]c.PyGetSetDef);
            var idx: usize = 0;
            inline for (fields) |field| {
                if (!isPrivateField(field.name)) {
                    table[idx] = makeGetSetDef(field);
                    idx += 1;
                }
            }
            return table;
        }

        fn makeGetSetDef(comptime field: anytype) c.PyGetSetDef {
            const FieldType = field.type;
            const field_name = field.name;
            const name_z: [:0]const u8 = comptime (field_name ++ "\x00")[0..field_name.len :0];

            const Getter = struct {
                fn get(py_self: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
                    const py = py_self orelse return null;
                    const data = unwrapConst(T, py);
                    const value = @field(data, field_name);
                    const obj = convert.toPy(value) catch return null;
                    return @ptrCast(obj);
                }
            };

            const Setter = struct {
                fn set(py_self: ?*c.PyObject, py_value: ?*c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
                    const py = py_self orelse return -1;
                    const data = unwrap(T, py);
                    const v = py_value orelse {
                        errors.typeError("cannot delete attribute '{s}'", .{field_name}) catch {};
                        return -1;
                    };
                    const obj: *Object = @ptrCast(v);
                    const new_value = convert.fromPy(FieldType, obj) catch return -1;
                    convert.releaseValue(&@field(data, field_name));
                    @field(data, field_name) = new_value;
                    return 0;
                }
            };

            return .{
                .name = @constCast(name_z.ptr),
                .get = @ptrCast(&Getter.get),
                .set = @ptrCast(&Setter.set),
                .doc = null,
                .closure = null,
            };
        }
    };
}

// ============================================================================
// Methods
// ============================================================================

fn MethodBuilder(comptime T: type) type {
    return struct {
        const Self = Wrapper(T);
        const decls = @typeInfo(T).@"struct".decls;

        fn methodParamNames(comptime method_name: []const u8) ?[]const u8 {
            if (!@hasDecl(T, "__pymz_method_param_names__")) {
                return null;
            }

            const overrides = T.__pymz_method_param_names__;
            if (!@hasField(@TypeOf(overrides), method_name)) {
                return null;
            }
            return @field(overrides, method_name);
        }

        /// True if decl is a `pub fn` whose first parameter is `*T`/`*const T`/`T`.
        fn isInstanceMethod(comptime name: []const u8) bool {
            if (!@hasDecl(T, name)) return false;
            const F = @TypeOf(@field(T, name));
            const info = @typeInfo(F);
            if (info != .@"fn") return false;
            const params = info.@"fn".params;
            if (params.len == 0) return false;
            const PT = params[0].type orelse return false;
            return isSelfParam(PT, T);
        }

        /// True if decl is a `pub fn` that's not an instance method and not a
        /// dunder handled elsewhere.
        fn isStaticMethod(comptime name: []const u8) bool {
            if (!@hasDecl(T, name)) return false;
            const F = @TypeOf(@field(T, name));
            const info = @typeInfo(F);
            if (info != .@"fn") return false;
            if (isInstanceMethod(name)) return false;
            // Skip all dunders — they're either handled by slots or not exposed.
            if (name.len >= 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__")) return false;
            return true;
        }

        /// Count instance methods (excluding dunders already wired to slots).
        fn countInstanceMethods() usize {
            var n: usize = 0;
            for (decls) |d| {
                if (isInstanceMethod(d.name) and !isExcludedDunder(d.name)) n += 1;
            }
            return n;
        }

        fn countStaticMethods() usize {
            var n: usize = 0;
            for (decls) |d| {
                if (isStaticMethod(d.name)) n += 1;
            }
            return n;
        }

        /// Dunders that are handled by type slots rather than method table.
        fn isExcludedDunder(comptime name: []const u8) bool {
            const excluded = [_][]const u8{
                "__new__",      "__del__",  "__repr__",    "__str__",     "__hash__",
                "__eq__",       "__ne__",   "__lt__",      "__le__",      "__gt__",
                "__ge__",       "__len__",  "__getitem__", "__setitem__", "__delitem__",
                "__contains__", "__iter__", "__next__",    "__call__",
            };
            for (excluded) |e| {
                if (std.mem.eql(u8, name, e)) return true;
            }
            return false;
        }

        const instance_method_count = countInstanceMethods();
        const static_method_count = countStaticMethods();
        pub const total_method_count = instance_method_count + static_method_count;

        /// Generate a `PyMethodDef` table (instance + static + sentinel).
        pub fn buildMethodTable() [total_method_count + 1]c.PyMethodDef {
            var table: [total_method_count + 1]c.PyMethodDef = undefined;
            var idx: usize = 0;
            inline for (decls) |d| {
                if (isInstanceMethod(d.name) and !isExcludedDunder(d.name)) {
                    table[idx] = makeInstanceMethodDef(d.name);
                    idx += 1;
                }
            }
            inline for (decls) |d| {
                if (isStaticMethod(d.name)) {
                    table[idx] = makeStaticMethodDef(d.name);
                    idx += 1;
                }
            }
            // Sentinel
            table[idx] = .{
                .ml_name = null,
                .ml_meth = null,
                .ml_flags = 0,
                .ml_doc = null,
            };
            return table;
        }

        fn makeInstanceMethodDef(comptime name: [:0]const u8) c.PyMethodDef {
            const F = @TypeOf(@field(T, name));
            const sig = stubs.buildMlDocWithOptions(
                name,
                F,
                .instance_method,
                .positional,
                null,
                methodParamNames(name),
            );
            return .{
                .ml_name = name,
                .ml_meth = @ptrCast(&wrapInstanceMethod(name)),
                .ml_flags = c.METH_VARARGS,
                .ml_doc = sig,
            };
        }

        fn makeStaticMethodDef(comptime name: [:0]const u8) c.PyMethodDef {
            const F = @TypeOf(@field(T, name));
            const sig = stubs.buildMlDocWithOptions(
                name,
                F,
                .static_method,
                .positional,
                null,
                methodParamNames(name),
            );
            return .{
                .ml_name = name,
                .ml_meth = @ptrCast(&wrapStaticMethod(name)),
                .ml_flags = c.METH_VARARGS,
                .ml_doc = sig,
            };
        }

        /// Wrap an instance method as `fn (*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject`.
        fn wrapInstanceMethod(comptime name: []const u8) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;

            const S = struct {
                const Skip: usize = 1;

                fn releaseConverted(args: *std.meta.ArgsTuple(F), count: usize) void {
                    inline for (Params[Skip..], 0..) |param, i| {
                        if (i < count) {
                            if (param.type) |_| {
                                convert.releaseValue(&args[i + Skip]);
                            }
                        }
                    }
                }

                fn wrapper(py_self: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
                    const py = py_self orelse return null;
                    const data: *T = unwrap(T, py);
                    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
                    const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                    const N = Params.len - Skip;
                    if (num_pos != N) {
                        errors.typeError(
                            "{s}() takes exactly {d} positional argument(s) ({d} given)",
                            .{ name, N, num_pos },
                        ) catch {};
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    const FirstParam = Params[0].type orelse return null;
                    zig_args[0] = if (FirstParam == T) data.* else data;
                    var converted_count: usize = 0;
                    inline for (Params[Skip..], 0..) |param, i| {
                        const py_item = args_tuple.?.get(i) orelse {
                            errors.typeError("missing argument {d}", .{i + 1}) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        const PT = param.type orelse {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        zig_args[i + Skip] = convert.fromPy(PT, py_item) catch {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    releaseConverted(&zig_args, converted_count);
                    return convert.handleReturn(@TypeOf(result), result);
                }
            };
            return S.wrapper;
        }

        /// Wrap a static method.
        fn wrapStaticMethod(comptime name: []const u8) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;

            const S = struct {
                fn releaseConverted(args: *std.meta.ArgsTuple(F), count: usize) void {
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
                    if (num_pos != Params.len) {
                        errors.typeError(
                            "{s}() takes exactly {d} positional argument(s) ({d} given)",
                            .{ name, Params.len, num_pos },
                        ) catch {};
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    var converted_count: usize = 0;
                    inline for (Params, 0..) |param, i| {
                        const py_item = args_tuple.?.get(i) orelse {
                            errors.typeError("missing argument {d}", .{i + 1}) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        const PT = param.type orelse {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        zig_args[i] = convert.fromPy(PT, py_item) catch {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    releaseConverted(&zig_args, converted_count);
                    return convert.handleReturn(@TypeOf(result), result);
                }
            };
            return S.wrapper;
        }
    };
}

// ============================================================================
// Repr / str
// ============================================================================

fn ReprBuilder(comptime T: type) type {
    return struct {
        const has_repr = @hasDecl(T, "__repr__");
        const has_str = @hasDecl(T, "__str__");

        fn protocolString(comptime name: []const u8, py_self: ?*c.PyObject) ?*c.PyObject {
            const py = py_self orelse return null;
            const data = unwrapConst(T, py);
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

        fn py_repr(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            if (!has_repr) {
                const py = py_self orelse return null;
                return c.PyObject_Repr(py);
            }
            return protocolString("__repr__", py_self);
        }

        fn py_str(py_self: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            if (!has_str) {
                const py = py_self orelse return null;
                return c.PyObject_Str(py);
            }
            return protocolString("__str__", py_self);
        }
    };
}

// ============================================================================
// Class generator
// ============================================================================

/// Generate a complete Python class wrapper for struct `T`.
/// Returns an anonymous struct that exposes:
///   - `type_object`: the static `PyTypeObject`
///   - `ready()`: call `PyType_Ready` on the type object
///   - `classdef`: a `ClassDef` handle for module registration
pub fn generateClass(comptime name: [:0]const u8, comptime T: type, comptime doc: ?[:0]const u8) type {
    const Lifecycle = LifecycleBuilder(T);
    const Methods = MethodBuilder(T);
    const Properties = PropertiesBuilder(T);
    const ReprInfo = ReprBuilder(T);

    // Build method table and getset table as static module-level data.
    const method_table = Methods.buildMethodTable();
    const getset_table = Properties.buildGetSetTable();

    return struct {
        const Self = @This();
        pub const WrapperType = Wrapper(T);

        pub var method_table_storage: [method_table.len]c.PyMethodDef = method_table;
        pub var getset_table_storage: [getset_table.len]c.PyGetSetDef = getset_table;

        pub var type_object: c.PyTypeObject = blk: {
            var t: c.PyTypeObject = std.mem.zeroes(c.PyTypeObject);
            t.tp_name = name;
            t.tp_basicsize = @sizeOf(Wrapper(T));
            t.tp_itemsize = 0;
            t.tp_dealloc = @ptrCast(&Lifecycle.py_dealloc);
            t.tp_new = @ptrCast(&Lifecycle.py_new);
            t.tp_init = @ptrCast(&Lifecycle.py_init);
            t.tp_methods = &method_table_storage;
            t.tp_flags = c.Py_TPFLAGS_DEFAULT;
            t.tp_doc = if (doc) |d| d else null;
            if (ReprInfo.has_repr) {
                t.tp_repr = @ptrCast(&ReprInfo.py_repr);
            }
            if (ReprInfo.has_str) {
                t.tp_str = @ptrCast(&ReprInfo.py_str);
            }
            // tp_getset is set at runtime in ready() because it needs to
            // reference static storage that we populate lazily here.
            break :blk t;
        };

        /// Initialise the type: call `PyType_Ready`. Must run before use.
        pub fn ready() *c.PyTypeObject {
            type_object.tp_getset = &getset_table_storage;
            if (c.PyType_Ready(&type_object) < 0) {
                // On error, return the type anyway — Python will raise.
            }
            return &type_object;
        }

        pub fn classdef() ClassDef {
            return .{
                .name = name,
                .ready_fn = &ready,
                .doc = doc,
            };
        }

        pub fn stub() stubs.Stub {
            return stubs.classStubAuto(name, T, doc);
        }
    };
}

/// Public entry point: declare a Python class backed by struct `T`.
///
/// ```zig
/// const Point = struct { x: f64, y: f64 };
/// const PointClass = pymz.class(Point, "A 2D point.");
/// // In module init: try mod.addClass(PointClass.classdef());
/// ```
pub fn class(comptime name: [:0]const u8, comptime T: type, comptime doc: ?[:0]const u8) type {
    return generateClass(name, T, doc);
}
