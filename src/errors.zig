//! Error handling helpers.

const std = @import("std");
const c = @import("c.zig").c;

pub const Error = error{PyError};

/// PyO3-style result type alias.
pub inline fn PyResult(comptime T: type) type {
    return Error!T;
}

pub inline fn errorOccurred() ?*c.PyObject {
    return c.PyErr_Occurred();
}

pub inline fn errorClear() void {
    c.PyErr_Clear();
}

pub inline fn errorPrint() void {
    if (errorOccurred() != null) c.PyErr_Print();
}

pub inline fn typeError(comptime msg: [:0]const u8, args: anytype) Error!void {
    return errorFormat(c.PyExc_TypeError, msg, args);
}

pub inline fn valueError(comptime msg: [:0]const u8, args: anytype) Error!void {
    return errorFormat(c.PyExc_ValueError, msg, args);
}

pub inline fn systemError(comptime msg: [:0]const u8, args: anytype) Error!void {
    return errorFormat(c.PyExc_SystemError, msg, args);
}

pub inline fn errorFormat(exc: *c.PyObject, comptime format: []const u8, args: anytype) Error!void {
    if (comptime args.len == 0) {
        c.PyErr_SetString(exc, @ptrCast(format));
        return error.PyError;
    }
    const printed = std.fmt.allocPrint(std.heap.c_allocator, format, args) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    defer std.heap.c_allocator.free(printed);
    const buf = std.heap.c_allocator.allocSentinel(u8, printed.len, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    @memcpy(buf, printed);
    defer std.heap.c_allocator.free(buf);
    c.PyErr_SetString(exc, @ptrCast(buf));
    return error.PyError;
}

/// Helper to return a value and set a Python error at the same time.
pub inline fn typeErrorValue(comptime T: type, value: T, comptime msg: [:0]const u8, args: anytype) T {
    typeError(msg, args) catch {};
    return value;
}
