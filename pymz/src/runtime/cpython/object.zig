//! Core Python object protocol and basic types (Str, Bytes).

const std = @import("std");
const c = @import("python_c");
const errors = @import("errors.zig");
const mem = @import("../../mem.zig");
const compat = @import("compat.zig");
const version = @import("version.zig");
const Error = errors.Error;

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

pub const Object = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Object) void {
        c.Py_IncRef(@as(*c.PyObject, @ptrCast(self)));
    }

    pub inline fn decref(self: *Object) void {
        c.Py_DecRef(@as(*c.PyObject, @ptrCast(self)));
    }

    /// Return a new reference to this object. The caller must decref it.
    pub inline fn newref(self: *Object) *Object {
        self.incref();
        return self;
    }

    /// Reference-counting helpers that can be shared by other PyObject-like
    /// wrapper structs.  `extern struct` wrappers cannot use `usingnamespace`,
    /// so each wrapper declares `incref`/`decref`/`newref` and forwards to these
    /// static helpers.  The implementation is still unified in one place.
    pub const RefCount = struct {
        pub inline fn incref(comptime Self: type, self: *Self) void {
            @as(*Object, @ptrCast(self)).incref();
        }
        pub inline fn decref(comptime Self: type, self: *Self) void {
            @as(*Object, @ptrCast(self)).decref();
        }
        pub inline fn newref(comptime Self: type, self: *Self) *Self {
            return @as(*Self, @ptrCast(@as(*Object, @ptrCast(self)).newref()));
        }
    };

    pub inline fn refcnt(self: *const Object) isize {
        return c.Py_REFCNT(@as(*c.PyObject, @ptrCast(@constCast(self))));
    }

    pub inline fn isNone(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.pymz_Py_None());
    }

    pub inline fn isTrue(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.pymz_Py_True());
    }

    pub inline fn isBool(self: *Object) bool {
        return compat.cApiBool(c.pymz_PyBool_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    pub inline fn asBool(self: *Object) bool {
        return c.PyObject_IsTrue(@as(*c.PyObject, @ptrCast(self))) != 0;
    }

    /// True when the object is a Python int (Py3 `int` / Py2 `int` or `long`).
    pub inline fn isInt(self: *Object) bool {
        const py: *c.PyObject = @as(*c.PyObject, @ptrCast(self));
        if (version.is_py3) {
            return compat.cApiBool(c.PyLong_Check(py));
        }
        // Python 2 distinguishes int and long; both are integers.
        return compat.cApiBool(c.pymz_PyInt_Check(py)) or
            compat.cApiBool(c.PyLong_Check(py));
    }

    /// Convert a Python int object to a Zig integer type with range checking.
    /// On overflow a Python `OverflowError` is set and `error.PyError` returned.
    pub inline fn asInt(self: *Object, comptime T: type) Error!T {
        const py: *c.PyObject = @as(*c.PyObject, @ptrCast(self));
        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.signedness == .signed) {
                    const v = try compat.intAsSigned(py);
                    if (v < std.math.minInt(T) or v > std.math.maxInt(T)) {
                        errors.overflowError("int too large to convert to {s}", .{@typeName(T)});
                        return error.PyError;
                    }
                    return @intCast(v);
                } else {
                    const v = try compat.intAsUnsigned(py);
                    if (v > std.math.maxInt(T)) {
                        errors.overflowError("int too large to convert to {s}", .{@typeName(T)});
                        return error.PyError;
                    }
                    return @intCast(v);
                }
            },
            else => @compileError("Object.asInt expects an integer type"),
        }
    }

    /// True when the object is a Python `float`.
    pub inline fn isFloat(self: *Object) bool {
        return compat.cApiBool(c.PyFloat_Check(@as(*c.PyObject, @ptrCast(self))));
    }

    /// Convert a Python float object to a Zig float type. `PyFloat_AsDouble`
    /// returns `-1.0` on failure and sets an exception, which is surfaced as
    /// `error.PyError`.
    pub inline fn asFloat(self: *Object, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .float => {
                const v = c.PyFloat_AsDouble(@as(*c.PyObject, @ptrCast(self)));
                if (v == -1.0 and errors.errorOccurred() != null) return error.PyError;
                return @floatCast(v);
            },
            else => @compileError("Object.asFloat expects a float type"),
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
        const len = c.PyObject_Size(@as(*c.PyObject, @ptrCast(self)));
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

    /// Borrow the UTF-8 bytes backing a string object. The slice is valid only
    /// while `self` is alive.
    pub inline fn asString(self: *Object) Error![:0]const u8 {
        return Str.asString(@ptrCast(self));
    }

    pub inline fn isInstance(self: *Object, typ: *Type) Error!bool {
        const rc = c.PyObject_IsInstance(
            @as(*c.PyObject, @ptrCast(self)),
            @as(*c.PyObject, @ptrCast(typ)),
        );
        return compat.cApiTriState(rc);
    }
};

/// Raw reference counting helpers that keep version-specific macros in C.
pub inline fn increfRaw(op: *c.PyObject) void {
    c.pymz_Py_INCREF(op);
}

pub inline fn decrefRaw(op: *c.PyObject) void {
    c.pymz_Py_DECREF(op);
}

pub inline fn None() *Object {
    return @ptrCast(c.pymz_Py_None());
}

pub inline fn True() *Object {
    return @ptrCast(c.pymz_Py_True());
}

pub inline fn False() *Object {
    return @ptrCast(c.pymz_Py_False());
}

pub inline fn returnNone() *Object {
    return None().newref();
}

pub inline fn returnBool(value: bool) *Object {
    return (if (value) True() else False()).newref();
}

pub const Type = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Type) void {
        Object.RefCount.incref(Type, self);
    }
    pub inline fn decref(self: *Type) void {
        Object.RefCount.decref(Type, self);
    }
    pub inline fn newref(self: *Type) *Type {
        return Object.RefCount.newref(Type, self);
    }
};

pub const Str = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Str) void {
        Object.RefCount.incref(Str, self);
    }
    pub inline fn decref(self: *Str) void {
        Object.RefCount.decref(Str, self);
    }
    pub inline fn newref(self: *Str) *Str {
        return Object.RefCount.newref(Str, self);
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

/// Create a new Unicode text object (`unicode` on Python 2, `str` on Python 3).
/// On Python 3 this is identical to `Str.fromSlice`; on Python 2 it always
/// produces a `unicode` object regardless of the `str` type.
pub fn unicodeFromSlice(s: []const u8) Error!*Object {
    if (compat.unicodeFromSlice(s)) |r| return @as(*Object, @ptrCast(r));
    return error.PyError;
}

pub const Bytes = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Bytes) void {
        Object.RefCount.incref(Bytes, self);
    }
    pub inline fn decref(self: *Bytes) void {
        Object.RefCount.decref(Bytes, self);
    }
    pub inline fn newref(self: *Bytes) *Bytes {
        return Object.RefCount.newref(Bytes, self);
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

pub const ByteArray = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *ByteArray) void {
        Object.RefCount.incref(ByteArray, self);
    }
    pub inline fn decref(self: *ByteArray) void {
        Object.RefCount.decref(ByteArray, self);
    }
    pub inline fn newref(self: *ByteArray) *ByteArray {
        return Object.RefCount.newref(ByteArray, self);
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
