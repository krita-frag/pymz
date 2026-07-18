//! Numeric and collection type wrappers.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const Object = object.Object;
const Error = errors.Error;
const class_mod = @import("class.zig");

inline fn cApiCheck(value: anytype) bool {
    if (@TypeOf(value) == bool) {
        return value;
    }
    return value == 1;
}

// ============================================================================
// Integer wrapper
// ============================================================================

pub const Int = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Int) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Int) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Int) *Int {
        return @as(*Int, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        if (version.is_py3) {
            return cApiCheck(c.PyLong_Check(@as(*c.PyObject, @ptrCast(obj))));
        } else {
            return cApiCheck(c.PyInt_Check(@as(*c.PyObject, @ptrCast(obj))));
        }
    }

    pub inline fn from(value: anytype) Error!*Int {
        return switch (@typeInfo(@TypeOf(value))) {
            .int => |info| if (info.signedness == .signed)
                fromSigned(value)
            else
                fromUnsigned(value),
            .comptime_int => fromSigned(value),
            else => @compileError("Int.from expects an integer"),
        };
    }

    pub inline fn fromSigned(value: isize) Error!*Int {
        if (version.is_py3) {
            if (c.PyLong_FromSsize_t(@as(c.Py_ssize_t, value))) |r| return @as(*Int, @ptrCast(r));
        } else {
            if (c.PyInt_FromLong(@as(c_long, @intCast(value)))) |r| return @as(*Int, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn fromUnsigned(value: usize) Error!*Int {
        if (version.is_py3) {
            if (c.PyLong_FromSize_t(@as(c.size_t, value))) |r| return @as(*Int, @ptrCast(r));
        } else {
            if (c.PyInt_FromLong(@intCast(value))) |r| return @as(*Int, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn as(self: *Int, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.signedness == .signed) {
                    const v = if (version.is_py3)
                        c.PyLong_AsLongLong(@as(*c.PyObject, @ptrCast(self)))
                    else
                        c.PyInt_AsLong(@as(*c.PyObject, @ptrCast(self)));
                    if (v == -1 and errors.errorOccurred() != null) return error.PyError;
                    return @intCast(v);
                } else {
                    const v = if (version.is_py3)
                        c.PyLong_AsUnsignedLongLong(@as(*c.PyObject, @ptrCast(self)))
                    else
                        @as(c_ulonglong, @intCast(c.PyInt_AsLong(@as(*c.PyObject, @ptrCast(self)))));
                    if (v == @as(c_ulonglong, @bitCast(@as(c_longlong, -1))) and errors.errorOccurred() != null) return error.PyError;
                    return @intCast(v);
                }
            },
            else => @compileError("Int.as expects an integer type"),
        }
    }
};

// ============================================================================
// Float wrapper
// ============================================================================

pub const Float = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Float) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Float) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Float) *Float {
        return @as(*Float, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return cApiCheck(c.PyFloat_Check(@as(*c.PyObject, @ptrCast(obj))));
    }

    pub inline fn from(value: anytype) Error!*Float {
        const v: f64 = switch (@typeInfo(@TypeOf(value))) {
            .float, .comptime_float => @floatCast(value),
            else => @compileError("Float.from expects a float"),
        };
        if (c.PyFloat_FromDouble(v)) |r| return @as(*Float, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn as(self: *Float, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .float => {
                const v = c.PyFloat_AsDouble(@as(*c.PyObject, @ptrCast(self)));
                if (v == -1.0 and errors.errorOccurred() != null) return error.PyError;
                return @floatCast(v);
            },
            else => @compileError("Float.as expects a float type"),
        }
    }
};

// ============================================================================
// Bool wrapper
// ============================================================================

pub const Bool = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Bool) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Bool) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Bool) *Bool {
        return @as(*Bool, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return cApiCheck(c.PyBool_Check(@as(*c.PyObject, @ptrCast(obj))));
    }

    pub inline fn from(value: bool) *Bool {
        return @ptrCast(if (value) c.Py_True else c.Py_False);
    }

    pub inline fn as(self: *Bool) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_True);
    }
};

// ============================================================================
// Tuple wrapper
// ============================================================================

pub const Tuple = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Tuple) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Tuple) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Tuple) *Tuple {
        return @as(*Tuple, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn new(size: usize) Error!*Tuple {
        if (c.PyTuple_New(@as(c.Py_ssize_t, @intCast(size)))) |r| return @as(*Tuple, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn pack(items: anytype) Error!*Tuple {
        const fields = @typeInfo(@TypeOf(items)).@"struct".fields;
        const tuple = try new(fields.len);
        errdefer tuple.decref();
        inline for (fields, 0..) |f, i| {
            const item = @field(items, f.name);
            const obj: *Object = @ptrCast(item);
            tuple.setUnsafe(i, obj);
        }
        return tuple;
    }

    pub inline fn setUnsafe(self: *Tuple, i: usize, obj: *Object) void {
        // PyTuple_SetItem steals a reference.
        _ = c.PyTuple_SetItem(@as(*c.PyObject, @ptrCast(self)), @as(c.Py_ssize_t, @intCast(i)), @ptrCast(obj));
    }

    pub inline fn get(self: *Tuple, i: usize) ?*Object {
        if (i >= self.length()) return null;
        const item = c.PyTuple_GetItem(@as(*c.PyObject, @ptrCast(self)), @as(c.Py_ssize_t, @intCast(i)));
        return @as(*Object, @ptrCast(item));
    }

    pub inline fn length(self: *Tuple) usize {
        return @intCast(c.PyTuple_Size(@as(*c.PyObject, @ptrCast(self))));
    }
};

// ============================================================================
// List wrapper
// ============================================================================

pub const List = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *List) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *List) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *List) *List {
        return @as(*List, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return cApiCheck(c.PyList_Check(@as(*c.PyObject, @ptrCast(obj))));
    }

    pub inline fn new(size: usize) Error!*List {
        if (c.PyList_New(@as(c.Py_ssize_t, @intCast(size)))) |r| return @as(*List, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn append(self: *List, obj: *Object) Error!void {
        if (c.PyList_Append(@as(*c.PyObject, @ptrCast(self)), @ptrCast(obj)) < 0) return error.PyError;
    }

    pub inline fn get(self: *List, i: usize) ?*Object {
        if (i >= self.length()) return null;
        const item = c.PyList_GetItem(@as(*c.PyObject, @ptrCast(self)), @as(c.Py_ssize_t, @intCast(i)));
        return @as(*Object, @ptrCast(item));
    }

    pub inline fn set(self: *List, i: usize, obj: *Object) Error!void {
        if (c.PyList_SetItem(@as(*c.PyObject, @ptrCast(self)), @as(c.Py_ssize_t, @intCast(i)), @ptrCast(obj)) < 0) {
            obj.decref();
            return error.PyError;
        }
    }

    pub inline fn length(self: *List) usize {
        return @intCast(c.PyList_Size(@as(*c.PyObject, @ptrCast(self))));
    }
};

// ============================================================================
// Dict wrapper
// ============================================================================

pub const Dict = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Dict) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Dict) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Dict) *Dict {
        return @as(*Dict, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn new() Error!*Dict {
        if (c.PyDict_New()) |r| return @as(*Dict, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn setItemString(self: *Dict, key: [:0]const u8, value: *Object) Error!void {
        if (c.PyDict_SetItemString(@as(*c.PyObject, @ptrCast(self)), key, @ptrCast(value)) < 0) return error.PyError;
    }

    pub inline fn getItemString(self: *Dict, key: [:0]const u8) ?*Object {
        return @as(?*Object, @ptrCast(c.PyDict_GetItemString(@as(*c.PyObject, @ptrCast(self)), key)));
    }
};

// ============================================================================
// Module wrapper
// ============================================================================

pub const Module = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Module) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Module) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Module) *Module {
        return @as(*Module, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn addObjectRef(self: *Module, name: [:0]const u8, value: *Object) Error!void {
        if (version.is_py3 and version.versionAtLeast(3, 10)) {
            if (c.PyModule_AddObjectRef(@as(*c.PyObject, @ptrCast(self)), name, @ptrCast(value)) < 0) return error.PyError;
        } else {
            if (c.PyModule_AddObject(@as(*c.PyObject, @ptrCast(self)), name, @ptrCast(value.newref())) < 0) {
                value.decref();
                return error.PyError;
            }
        }
    }

    pub inline fn addIntConstant(self: *Module, name: [:0]const u8, value: isize) Error!void {
        if (c.PyModule_AddIntConstant(@as(*c.PyObject, @ptrCast(self)), name, @intCast(value)) < 0) return error.PyError;
    }

    pub inline fn addStringConstant(self: *Module, name: [:0]const u8, value: [:0]const u8) Error!void {
        if (c.PyModule_AddStringConstant(@as(*c.PyObject, @ptrCast(self)), name, value) < 0) return error.PyError;
    }

    /// Register a Python class (built via `pymz.class`) as a module attribute.
    /// Calls the class's `ready()` to invoke `PyType_Ready`, then adds the
    /// resulting `*PyTypeObject` to the module dict under `name`.
    pub inline fn addClass(self: *Module, name: [:0]const u8, class_def: class_mod.ClassDef) Error!void {
        _ = class_def.name;
        _ = class_def.doc;
        const type_obj = class_def.ready_fn();
        const py_type: *Object = @ptrCast(type_obj);
        try self.addObjectRef(name, py_type);
    }

    pub inline fn getDict(self: *Module) *Dict {
        return @ptrCast(c.PyModule_GetDict(@as(*c.PyObject, @ptrCast(self))));
    }

    /// Borrowed reference to the module name as a UTF-8 string.
    /// Returns an empty string on error (Python error is set).
    pub inline fn getName(self: *Module) [:0]const u8 {
        const ptr = c.PyModule_GetName(@as(*c.PyObject, @ptrCast(self)));
        if (ptr == null) return "";
        return std.mem.span(ptr);
    }
};
