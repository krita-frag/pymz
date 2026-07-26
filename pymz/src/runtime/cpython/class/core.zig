//! Core helpers for Python class generation.

const std = @import("std");
const c = @import("../c.zig").c;
const errors = @import("../errors.zig");
const object = @import("../object.zig");

pub const Object = object.Object;
pub const Error = errors.Error;

pub const ClassDef = struct {
    name: [:0]const u8,
    ready_fn: *const fn () *c.PyTypeObject,
    doc: ?[:0]const u8,
    base: ?*const ClassDef = null,

    pub inline fn getTypeObject(self: ClassDef) *c.PyTypeObject {
        return self.ready_fn();
    }
};

pub fn Wrapper(comptime T: type) type {
    return extern struct {
        ob_base: c.PyObject,
        initialized: bool,
        _pad: [0]u8 align(@alignOf(T)),
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

pub inline fn unwrap(comptime T: type, py: *c.PyObject) *T {
    if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
        if (@intFromPtr(py) == 0) @panic("unwrap: null PyObject");
        if (@intFromPtr(py.*.ob_type) == 0) @panic("unwrap: PyObject with null ob_type");
    }
    return Wrapper(T).fromPyObject(py).getData();
}

pub inline fn unwrapConst(comptime T: type, py: *c.PyObject) *const T {
    if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
        if (@intFromPtr(py) == 0) @panic("unwrapConst: null PyObject");
        if (@intFromPtr(py.*.ob_type) == 0) @panic("unwrapConst: PyObject with null ob_type");
    }
    return Wrapper(T).fromPyObject(py).getDataConst();
}

pub inline fn unwrapChecked(comptime T: type, py: *c.PyObject, typ: *c.PyTypeObject) ?*T {
    if (c.PyObject_TypeCheck(py, typ) == 0) {
        errors.typeError("expected {s}, got {s}", .{ typ.*.tp_name, @import("../convert.zig").pyTypeName(@ptrCast(py)) }) catch {};
        return null;
    }
    return unwrap(T, py);
}

pub inline fn unwrapCheckedConst(comptime T: type, py: *c.PyObject, typ: *c.PyTypeObject) ?*const T {
    if (c.PyObject_TypeCheck(py, typ) == 0) {
        errors.typeError("expected {s}, got {s}", .{ typ.*.tp_name, @import("../convert.zig").pyTypeName(@ptrCast(py)) }) catch {};
        return null;
    }
    return unwrapConst(T, py);
}

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

pub fn isPrivateField(comptime name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

pub fn isSelfParam(comptime T: type, comptime Self: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == Self,
        else => T == Self,
    };
}

pub fn countPublicFields(comptime T: type) usize {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".fields) |f| {
        if (!isPrivateField(f.name)) n += 1;
    }
    return n;
}
