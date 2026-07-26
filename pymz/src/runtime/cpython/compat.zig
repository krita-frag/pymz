//! Python 2 / 3 compatibility layer.
//!
//! All version-specific C API differences should be centralized here so that
//! higher-level wrappers in `object.zig` and `types.zig` remain version-agnostic.
//! Functions are intentionally `inline`: they are thin shims around the C API
//! and produce no runtime overhead.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");

// ============================================================================
// C API predicate helpers
// ============================================================================

/// Convert a C API predicate that returns exactly `1` (true) or `0` (false)
/// into a Zig `bool`. Type-check macros such as `PyLong_Check` and
/// `PyTuple_Check` fall into this category.
pub inline fn cApiBool(value: anytype) bool {
    if (@TypeOf(value) == bool) return value;
    return value == 1;
}

/// Convert a C API tri-state predicate (`1` true / `0` false / `-1` error)
/// into a Zig `bool`. Functions such as `PyObject_IsInstance` and
/// `PySet_Contains` use this convention. When `-1` is returned the Python
/// exception state is already set, so this function propagates it as
/// `error.PyError`.
pub inline fn cApiTriState(value: c_int) !bool {
    if (value == 1) return true;
    if (value == 0) return false;
    return error.PyError;
}

// ============================================================================
// Integer creation and extraction
// ============================================================================

/// Create a new Python int object from a signed integer.
pub inline fn intFromSigned(value: isize) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyLong_FromSsize_t(@as(c.Py_ssize_t, value));
    }
    const min_long = std.math.minInt(c_long);
    const max_long = std.math.maxInt(c_long);
    if (value >= min_long and value <= max_long) {
        return c.PyInt_FromLong(@as(c_long, @intCast(value)));
    }
    return c.PyLong_FromLongLong(@as(c_longlong, value));
}

/// Create a new Python int object from an unsigned integer.
pub inline fn intFromUnsigned(value: usize) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyLong_FromSize_t(value);
    }
    const max_long = std.math.maxInt(c_long);
    if (value <= max_long) {
        return c.PyInt_FromLong(@as(c_long, @intCast(value)));
    }
    return c.PyLong_FromUnsignedLongLong(@as(c_ulonglong, value));
}

/// Extract a signed integer from a Python int-compatible object.
/// The caller must ensure `obj` is an int or long; otherwise a Python
/// exception may be set and `error.PyError` is returned.
pub inline fn intAsSigned(obj: *c.PyObject) !i64 {
    const v = if (version.is_py3)
        c.PyLong_AsLongLong(obj)
    else
        c.PyLong_AsLongLong(obj);
    if (v == -1 and c.PyErr_Occurred() != null) return error.PyError;
    return @intCast(v);
}

/// Extract an unsigned integer from a Python int-compatible object.
/// Uses `PyLong_AsUnsignedLongLong` on both Python 2 and 3 so that large
/// positive `long` values on Python 2 are handled correctly.
pub inline fn intAsUnsigned(obj: *c.PyObject) !u64 {
    const v = c.PyLong_AsUnsignedLongLong(obj);
    const sentinel = @as(c_ulonglong, @bitCast(@as(c_longlong, -1)));
    if (v == sentinel and c.PyErr_Occurred() != null) return error.PyError;
    return @intCast(v);
}

// ============================================================================
// String / bytes creation and extraction
// ============================================================================

/// Return true if `obj` is a text string. On Python 3 this is `str`; on
/// Python 2 `str` is the native bytes type, so we accept `PyString` as the
/// text representation for Python 2 compatibility.
pub inline fn strCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyUnicode_Check(obj));
    }
    return cApiBool(c.PyString_Check(obj));
}

/// Create a new text string object from a UTF-8 byte slice.
/// On Python 2 this creates a `str` (native bytes string); on Python 3 a `str`.
pub inline fn strFromSlice(s: []const u8) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyUnicode_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
    }
    return c.PyString_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// Create a new Unicode text object from a UTF-8 byte slice.
/// On both Python 2 and 3 this returns the Unicode text type
/// (`unicode` on Python 2, `str` on Python 3).
pub inline fn unicodeFromSlice(s: []const u8) ?*c.PyObject {
    return c.PyUnicode_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// Borrow the UTF-8 bytes backing a text string. The returned slice is valid
/// as long as `obj` is alive. Returns `null` on failure (Python exception set).
pub inline fn strAsString(obj: *c.PyObject) ?[:0]const u8 {
    if (version.is_py3) {
        var size: c.Py_ssize_t = 0;
        const ptr = c.PyUnicode_AsUTF8AndSize(obj, &size);
        if (ptr == null) return null;
        return ptr[0..@as(usize, @intCast(size)) :0];
    }
    const ptr = c.PyString_AsString(obj);
    if (ptr == null) return null;
    return std.mem.span(ptr);
}

/// Return true if `obj` is a binary bytes object. On Python 3 this is `bytes`;
/// on Python 2 it is also `str`.
pub inline fn bytesCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyBytes_Check(obj));
    }
    return cApiBool(c.PyString_Check(obj));
}

/// Create a new bytes object from a byte slice.
pub inline fn bytesFromSlice(s: []const u8) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyBytes_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
    }
    return c.PyString_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// Borrow the buffer backing a bytes object. `size` is written with the buffer
/// length. Returns `null` on failure (Python exception set).
pub inline fn bytesAsSlice(obj: *c.PyObject, size: *c.Py_ssize_t) ?[*c]u8 {
    var ptr: [*c]u8 = null;
    const rc = if (version.is_py3)
        c.PyBytes_AsStringAndSize(obj, &ptr, size)
    else
        c.PyString_AsStringAndSize(obj, &ptr, size);
    if (rc < 0) return null;
    return ptr;
}

// ============================================================================
// Bytearray helpers
// ============================================================================

/// Return true if `obj` is a `bytearray`. On Python 2 `bytearray` exists but
/// is not commonly used, so we fall back to a `str` check.
pub inline fn byteArrayCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyByteArray_Check(obj));
    }
    return cApiBool(c.PyString_Check(obj));
}

/// Create a new `bytearray` from a byte slice.
pub inline fn byteArrayFromSlice(s: []const u8) ?*c.PyObject {
    return c.PyByteArray_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// Borrow the mutable buffer backing a `bytearray`. `size` is written with the
/// buffer length. Returns `null` on failure (Python exception set).
pub inline fn byteArrayAsSlice(obj: *c.PyObject, size: *c.Py_ssize_t) ?[*c]u8 {
    const ptr = c.PyByteArray_AsString(obj);
    if (ptr == null) return null;
    size.* = c.PyByteArray_Size(obj);
    return ptr;
}
