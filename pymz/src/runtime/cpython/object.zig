//! Core Python object protocol and basic types (Str, Bytes).

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const errors = @import("errors.zig");
const mem = @import("../../mem.zig");
const compat = @import("compat.zig");
const Error = errors.Error;

// ============================================================================
// Buffer description
// ============================================================================

/// Description of a Python buffer exported by a class `__buffer__` method.
/// Returning this from `__buffer__` enables multi-dimensional and/or strided
/// buffer views.  Returning a plain `[]u8`/`[]const u8` is still supported as
/// a shorthand for a one-dimensional read/write byte buffer.
pub const Buffer = struct {
    /// Pointer to the first element. The data must remain valid until the
    /// buffer is released.
    ptr: [*]u8,

    /// Shape of the buffer. `shape.len` is the number of dimensions.
    shape: []const usize,

    /// Optional strides in bytes for each dimension. If `null`, the buffer is
    /// assumed to be C-contiguous.
    strides: ?[]const isize = null,

    /// PEP-3118 format string. If `null`, memoryview infers unsigned bytes.
    /// Common values: "B" (u8), "b" (i8), "i" (i32), "f" (f32), "d" (f64).
    format: ?[]const u8 = null,

    /// True if the buffer is read-only.
    readonly: bool = false,
};

// ============================================================================
// Core Object wrapper
// ============================================================================

pub const Object = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Object) void {
        if (@hasDecl(c, "Py_IncRef")) {
            c.Py_IncRef(@as(*c.PyObject, @ptrCast(self)));
        } else {
            c._Py_IncRef(@as(*c.PyObject, @ptrCast(self)));
        }
    }

    pub inline fn decref(self: *Object) void {
        if (@hasDecl(c, "Py_DecRef")) {
            c.Py_DecRef(@as(*c.PyObject, @ptrCast(self)));
        } else {
            c._Py_DecRef(@as(*c.PyObject, @ptrCast(self)));
        }
    }

    /// Return a new reference to this object. The caller must decref it.
    pub inline fn newref(self: *Object) *Object {
        self.incref();
        return self;
    }

    pub inline fn refcnt(self: *const Object) isize {
        return c.Py_REFCNT(@as(*c.PyObject, @ptrCast(@constCast(self))));
    }

    pub inline fn isNone(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_None());
    }

    pub inline fn isTrue(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_True());
    }

    pub inline fn isBool(self: *Object) bool {
        return compat.cApiBool(c.PyBool_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn asBool(self: *Object) bool {
        return c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(self))) != 0;
    }

    pub inline fn isInt(self: *Object) bool {
        if (version.is_py3) {
            return compat.cApiBool(c.PyLong_Check(@as(*c.PyObject, @ptrCast(self))));
        }
        return compat.cApiBool(c.PyInt_Check(@as(*c.PyObject, @ptrCast(self)))) or
            compat.cApiBool(c.PyLong_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn asInt(self: *Object, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.signedness == .signed) {
                    const value = try compat.intAsSigned(@as(*c.PyObject, @ptrCast(self)));
                    const min = std.math.minInt(T);
                    const max = std.math.maxInt(T);
                    if (value < min or value > max) {
                        errors.overflowError("int too large to convert to {s}", .{@typeName(T)}) catch {};
                        return error.PyError;
                    }
                    return @intCast(value);
                }

                const value = try compat.intAsUnsigned(@as(*c.PyObject, @ptrCast(self)));
                const max = std.math.maxInt(T);
                if (value > max) {
                    errors.overflowError("int too large to convert to {s}", .{@typeName(T)}) catch {};
                    return error.PyError;
                }
                return @intCast(value);
            },
            else => @compileError("asInt expects an integer type"),
        }
    }

    pub inline fn isFloat(self: *Object) bool {
        return compat.cApiBool(c.PyFloat_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn asFloat(self: *Object, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .float => {
                const value = c.PyFloat_AsDouble(@as(*c.PyObject, @ptrCast(self)));
                if (value == -1.0 and errors.errorOccurred() != null) return error.PyError;
                return @floatCast(value);
            },
            else => @compileError("asFloat expects a float type"),
        }
    }

    pub inline fn isString(self: *Object) bool {
        return Str.check(self);
    }

    pub inline fn isList(self: *Object) bool {
        return compat.cApiBool(c.PyList_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn isTuple(self: *Object) bool {
        return compat.cApiBool(c.PyTuple_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn isDict(self: *Object) bool {
        return compat.cApiBool(c.PyDict_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn sequenceLength(self: *Object) Error!usize {
        const len = c.PyObject_Length(@as(*c.PyObject, @ptrCast(self)));
        if (len < 0) return error.PyError;
        return @intCast(len);
    }

    /// Borrow an item from a list or tuple. The returned reference is owned by
    /// the container and must not be decref'd by the caller unless explicitly
    /// incref'd.
    pub inline fn sequenceGet(self: *Object, index: usize) ?*Object {
        if (self.isList()) {
            const item = c.PyList_GetItem(
                @as(*c.PyObject, @ptrCast(self)),
                @as(c.Py_ssize_t, @intCast(index)),
            );
            return @as(?*Object, @ptrCast(item));
        }
        if (self.isTuple()) {
            const item = c.PyTuple_GetItem(
                @as(*c.PyObject, @ptrCast(self)),
                @as(c.Py_ssize_t, @intCast(index)),
            );
            return @as(?*Object, @ptrCast(item));
        }
        return null;
    }

    pub inline fn listSet(self: *Object, index: usize, item: *Object) Error!void {
        if (c.PyList_SetItem(
            @as(*c.PyObject, @ptrCast(self)),
            @as(c.Py_ssize_t, @intCast(index)),
            @ptrCast(item),
        ) < 0) {
            item.decref();
            return error.PyError;
        }
    }

    pub inline fn dictItems(self: *Object) Error!*Object {
        if (c.PyDict_Items(@as(*c.PyObject, @ptrCast(self)))) |items| {
            return @ptrCast(items);
        }
        return error.PyError;
    }

    /// Borrow the value associated with `key` from a dict. The returned
    /// reference is owned by the dict and must not be decref'd unless
    /// explicitly incref'd.
    pub inline fn dictGetString(self: *Object, key: []const u8) Error!?*Object {
        const key_object = try Str.fromSlice(key);
        defer key_object.decref();
        const item = c.PyDict_GetItem(
            @as(*c.PyObject, @ptrCast(self)),
            @as(*c.PyObject, @ptrCast(key_object)),
        );
        return @as(?*Object, @ptrCast(item));
    }

    pub inline fn dictSet(self: *Object, key: *Object, value: *Object) Error!void {
        if (c.PyDict_SetItem(
            @as(*c.PyObject, @ptrCast(self)),
            @as(*c.PyObject, @ptrCast(key)),
            @as(*c.PyObject, @ptrCast(value)),
        ) < 0) {
            return error.PyError;
        }
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

    /// Borrow the UTF-8 bytes backing a string object. The slice is valid only
    /// while `self` is alive.
    pub inline fn asString(self: *Object) Error![:0]const u8 {
        return Str.asString(@ptrCast(self));
    }

    pub inline fn length(self: *Object) Error!usize {
        const n = c.PyObject_Length(@as(*c.PyObject, @ptrCast(self)));
        if (n < 0) return error.PyError;
        return @intCast(n);
    }

    pub inline fn isInstance(self: *Object, typ: *Type) Error!bool {
        const rc = c.PyObject_IsInstance(
            @as(*c.PyObject, @ptrCast(self)),
            @as(*c.PyObject, @ptrCast(typ)),
        );
        return compat.cApiTriState(rc);
    }
};

// ============================================================================
// Singletons
// ============================================================================

pub inline fn None() *Object {
    return @ptrCast(c.Py_None());
}

pub inline fn True() *Object {
    return @ptrCast(c.Py_True());
}

pub inline fn False() *Object {
    return @ptrCast(c.Py_False());
}

pub inline fn returnNone() *Object {
    return None().newref();
}

pub inline fn returnBool(value: bool) *Object {
    return (if (value) True() else False()).newref();
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

    pub inline fn checkObject(self: *Type, obj: *Object) Error!bool {
        const rc = c.PyObject_TypeCheck(
            @as(*c.PyObject, @ptrCast(obj)),
            @as(*c.PyObject, @ptrCast(self)),
        );
        return compat.cApiTriState(rc);
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
        return compat.strCheck(@as(*c.PyObject, @ptrCast(obj)));
    }

    pub inline fn fromSlice(s: []const u8) Error!*Str {
        if (compat.strFromSlice(s)) |r| return @as(*Str, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn fromFormat(comptime fmt: []const u8, args: anytype) Error!*Str {
        const buf = try std.fmt.allocPrintZ(mem.allocator, fmt, args);
        defer mem.allocator.free(buf);
        return fromSlice(buf);
    }

    /// Borrow the UTF-8 bytes backing the string. The returned slice is valid
    /// only while `self` is alive. Returns `error.PyError` if the object is not
    /// a valid string (Python exception is already set).
    pub inline fn asString(self: *Str) Error![:0]const u8 {
        if (compat.strAsString(@as(*c.PyObject, @ptrCast(self)))) |s| {
            return s;
        }
        return error.PyError;
    }
};

// ============================================================================
// Unicode text wrapper (always Unicode: `unicode` on Python 2, `str` on Python 3)
// ============================================================================

pub const Unicode = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Unicode) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *Unicode) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *Unicode) *Unicode {
        return @as(*Unicode, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyUnicode_Check(@as(*c.PyObject, @ptrCast(obj))));
    }

    pub inline fn fromSlice(s: []const u8) Error!*Unicode {
        if (compat.unicodeFromSlice(s)) |r| return @as(*Unicode, @ptrCast(r));
        return error.PyError;
    }

    /// Return the UTF-8 bytes backing the unicode object. The returned slice
    /// borrows from `self`.
    pub inline fn asString(self: *Unicode) Error![:0]const u8 {
        if (compat.strAsString(@as(*c.PyObject, @ptrCast(self)))) |s| {
            return s;
        }
        return error.PyError;
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
        return compat.bytesCheck(@as(*c.PyObject, @ptrCast(obj)));
    }

    pub inline fn fromSlice(s: []const u8) Error!*Bytes {
        if (compat.bytesFromSlice(s)) |r| return @as(*Bytes, @ptrCast(r));
        return error.PyError;
    }

    /// Return the bytes backing the object. The returned slice borrows from `self`.
    /// Returns `error.PyError` on failure (Python exception is already set).
    pub inline fn asSlice(self: *Bytes) Error![]const u8 {
        var size: c.Py_ssize_t = 0;
        const ptr = compat.bytesAsSlice(@as(*c.PyObject, @ptrCast(self)), &size) orelse return error.PyError;
        return ptr[0..@as(usize, @intCast(size))];
    }
};

// ============================================================================
// Bytearray wrapper (mutable binary data)
// ============================================================================

pub const ByteArray = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *ByteArray) void {
        @as(*Object, @ptrCast(self)).incref();
    }
    pub inline fn decref(self: *ByteArray) void {
        @as(*Object, @ptrCast(self)).decref();
    }
    pub inline fn newref(self: *ByteArray) *ByteArray {
        return @as(*ByteArray, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
    }

    pub inline fn check(obj: *Object) bool {
        return compat.byteArrayCheck(@as(*c.PyObject, @ptrCast(obj)));
    }

    pub inline fn fromSlice(s: []const u8) Error!*ByteArray {
        if (compat.byteArrayFromSlice(s)) |r| {
            return @as(*ByteArray, @ptrCast(r));
        }
        return error.PyError;
    }

    /// Return the bytes backing the bytearray. The returned slice borrows from `self`.
    pub inline fn asSlice(self: *ByteArray) Error![]u8 {
        var size: c.Py_ssize_t = 0;
        const ptr = compat.byteArrayAsSlice(@as(*c.PyObject, @ptrCast(self)), &size) orelse return error.PyError;
        return ptr[0..@as(usize, @intCast(size))];
    }
};

const traits = @import("traits.zig");
const isObjectPtrOptional = traits.isObjectPtrOptional;
