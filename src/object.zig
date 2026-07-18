//! Core Python object protocol and basic types (Str, Bytes).

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const Error = errors.Error;

// ============================================================================
// Core Object wrapper
// ============================================================================

pub const Object = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Object) void {
        c._Py_IncRef(@as(*c.PyObject, @ptrCast(self)));
    }

    pub inline fn decref(self: *Object) void {
        c._Py_DecRef(@as(*c.PyObject, @ptrCast(self)));
    }

    pub inline fn newref(self: *Object) *Object {
        self.incref();
        return self;
    }

    pub inline fn refcnt(self: *const Object) isize {
        return c.Py_REFCNT(@as(*c.PyObject, @ptrCast(@constCast(self))));
    }

    pub inline fn isNone(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_None);
    }

    pub inline fn isTrue(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_True);
    }

    pub inline fn getAttrString(self: *Object, name: [:0]const u8) Error!*Object {
        if (c.PyObject_GetAttrString(@as(*c.PyObject, @ptrCast(self)), name)) |r| {
            return @as(*Object, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn setAttrString(self: *Object, name: [:0]const u8, value: ?*Object) Error!void {
        if (c.PyObject_SetAttrString(@as(*c.PyObject, @ptrCast(self)), name, @ptrCast(value)) < 0) {
            return error.PyError;
        }
    }

    pub inline fn str(self: *Object) Error!*Str {
        if (c.PyObject_Str(@as(*c.PyObject, @ptrCast(self)))) |r| {
            return @as(*Str, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn repr(self: *Object) Error!*Str {
        if (c.PyObject_Repr(@as(*c.PyObject, @ptrCast(self)))) |r| {
            return @as(*Str, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn asString(self: *Object) [:0]const u8 {
        return Str.asString(@ptrCast(self));
    }

    pub inline fn length(self: *Object) Error!usize {
        const n = c.PyObject_Length(@as(*c.PyObject, @ptrCast(self)));
        if (n < 0) return error.PyError;
        return @intCast(n);
    }

    pub inline fn isInstance(self: *Object, typ: *Type) bool {
        return c.PyObject_IsInstance(@as(*c.PyObject, @ptrCast(self)), @ptrCast(typ)) == 1;
    }
};

// ============================================================================
// Singletons
// ============================================================================

pub inline fn None() *Object {
    return @ptrCast(c.Py_None);
}

pub inline fn True() *Object {
    return @ptrCast(c.Py_True);
}

pub inline fn False() *Object {
    return @ptrCast(c.Py_False);
}

pub inline fn returnNone() *Object {
    return if (version.is_py3 and version.versionAtLeast(3, 12))
        None()
    else
        None().newref();
}

pub inline fn returnBool(value: bool) *Object {
    return if (value) True() else False();
}

pub inline fn returnOptional(value: anytype) *Object {
    const T = @TypeOf(value);
    if (isObjectPtrOptional(T)) {
        if (value) |o| return o.newref();
        return returnNone();
    }
    @compileError("returnOptional expects ?*Object");
}

// ============================================================================
// Type wrapper
// ============================================================================

pub const Type = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Type) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Type) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Type) *Type {
        return @as(*Type, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn checkObject(self: *Type, obj: *Object) bool {
        return c.PyObject_TypeCheck(@as(*c.PyObject, @ptrCast(obj)), @as(*c.PyObject, @ptrCast(self))) == 1;
    }
};

// ============================================================================
// String / Unicode wrapper
// ============================================================================

pub const Str = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Str) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Str) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Str) *Str {
        return @as(*Str, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        if (version.is_py3) {
            return c.PyUnicode_Check(@as(*c.PyObject, @ptrCast(obj))) == 1;
        } else {
            return c.PyString_Check(@as(*c.PyObject, @ptrCast(obj))) == 1;
        }
    }

    pub inline fn fromSlice(s: []const u8) Error!*Str {
        if (version.is_py3) {
            if (c.PyUnicode_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)))) |r| return @as(*Str, @ptrCast(r));
        } else {
            if (c.PyString_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)))) |r| return @as(*Str, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn fromFormat(comptime fmt: []const u8, args: anytype) Error!*Str {
        const buf = try std.fmt.allocPrintZ(std.heap.c_allocator, fmt, args);
        defer std.heap.c_allocator.free(buf);
        return fromSlice(buf);
    }

    /// Return the bytes backing the string. The returned slice borrows from `self`.
    pub inline fn asString(self: *Str) [:0]const u8 {
        if (version.is_py3) {
            var size: c.Py_ssize_t = 0;
            const ptr = c.PyUnicode_AsUTF8AndSize(@as(*c.PyObject, @ptrCast(self)), &size);
            if (ptr == null) return "";
            return ptr[0..@as(usize, @intCast(size)) :0];
        } else {
            const ptr = c.PyString_AsString(@as(*c.PyObject, @ptrCast(self)));
            if (ptr == null) return "";
            return std.mem.span(ptr);
        }
    }
};

// ============================================================================
// Bytes wrapper (for binary data)
// ============================================================================

pub const Bytes = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Bytes) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Bytes) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Bytes) *Bytes {
        return @as(*Bytes, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return c.PyBytes_Check(@as(*c.PyObject, @ptrCast(obj))) == 1;
    }

    pub inline fn fromSlice(s: []const u8) Error!*Bytes {
        if (c.PyBytes_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)))) |r| return @as(*Bytes, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn asSlice(self: *Bytes) []const u8 {
        var size: c.Py_ssize_t = 0;
        const ptr = c.PyBytes_AsString(@as(*c.PyObject, @ptrCast(self)));
        _ = c.PyBytes_AsStringAndSize(@as(*c.PyObject, @ptrCast(self)), &size);
        return ptr[0..@as(usize, @intCast(size))];
    }
};

const traits = @import("traits.zig");
const isObjectPtrOptional = traits.isObjectPtrOptional;
