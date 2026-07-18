//! Error handling helpers and custom exception support.

const std = @import("std");
const c = @import("c.zig").c;
const version = @import("version.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const Object = object.Object;

pub const Error = error{PyError};

/// Runtime-neutral public result type alias.
pub inline fn Result(comptime T: type) type {
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

pub inline fn runtimeError(comptime msg: [:0]const u8, args: anytype) Error!void {
    return errorFormat(c.PyExc_RuntimeError, msg, args);
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

// ============================================================================
// Built-in exception base selector
// ============================================================================

/// Standard Python exception categories that can be used as a base for
/// `createException`. Mirrors PyOZ's `ExcBase` enum.
pub const ExceptionBase = enum {
    base_exception,
    exception,
    arithmetic_error,
    floating_point_error,
    overflow_error,
    zero_division_error,
    assertion_error,
    attribute_error,
    buffer_error,
    eof_error,
    import_error,
    module_not_found_error,
    lookup_error,
    index_error,
    key_error,
    memory_error,
    name_error,
    unbound_local_error,
    os_error,
    connection_error,
    broken_pipe_error,
    connection_aborted_error,
    connection_refused_error,
    connection_reset_error,
    file_exists_error,
    file_not_found_error,
    interrupted_error,
    is_a_directory_error,
    not_a_directory_error,
    permission_error,
    process_lookup_error,
    timeout_error,
    reference_error,
    runtime_error,
    not_implemented_error,
    recursion_error,
    stop_async_iteration,
    stop_iteration,
    syntax_error,
    indentation_error,
    tab_error,
    system_error,
    type_error,
    value_error,
    unicode_error,
    warning,
    bytes_warning,
    deprecation_warning,
    future_warning,
    import_warning,
    pending_deprecation_warning,
    resource_warning,
    runtime_warning,
    syntax_warning,
    unicode_warning,
    user_warning,

    /// Resolve to the corresponding `*c.PyObject` exception class.
    pub fn toPyObject(self: ExceptionBase) *c.PyObject {
        return switch (self) {
            .base_exception => c.PyExc_BaseException,
            .exception => c.PyExc_Exception,
            .arithmetic_error => c.PyExc_ArithmeticError,
            .floating_point_error => c.PyExc_FloatingPointError,
            .overflow_error => c.PyExc_OverflowError,
            .zero_division_error => c.PyExc_ZeroDivisionError,
            .assertion_error => c.PyExc_AssertionError,
            .attribute_error => c.PyExc_AttributeError,
            .buffer_error => c.PyExc_BufferError,
            .eof_error => c.PyExc_EOFError,
            .import_error => c.PyExc_ImportError,
            .module_not_found_error => if (@hasDecl(c, "PyExc_ModuleNotFoundError")) c.PyExc_ModuleNotFoundError else c.PyExc_ImportError,
            .lookup_error => c.PyExc_LookupError,
            .index_error => c.PyExc_IndexError,
            .key_error => c.PyExc_KeyError,
            .memory_error => c.PyExc_MemoryError,
            .name_error => c.PyExc_NameError,
            .unbound_local_error => c.PyExc_UnboundLocalError,
            .os_error => c.PyExc_OSError,
            .connection_error => if (@hasDecl(c, "PyExc_ConnectionError")) c.PyExc_ConnectionError else c.PyExc_OSError,
            .broken_pipe_error => if (@hasDecl(c, "PyExc_BrokenPipeError")) c.PyExc_BrokenPipeError else c.PyExc_OSError,
            .connection_aborted_error => if (@hasDecl(c, "PyExc_ConnectionAbortedError")) c.PyExc_ConnectionAbortedError else c.PyExc_OSError,
            .connection_refused_error => if (@hasDecl(c, "PyExc_ConnectionRefusedError")) c.PyExc_ConnectionRefusedError else c.PyExc_OSError,
            .connection_reset_error => if (@hasDecl(c, "PyExc_ConnectionResetError")) c.PyExc_ConnectionResetError else c.PyExc_OSError,
            .file_exists_error => if (@hasDecl(c, "PyExc_FileExistsError")) c.PyExc_FileExistsError else c.PyExc_OSError,
            .file_not_found_error => if (@hasDecl(c, "PyExc_FileNotFoundError")) c.PyExc_FileNotFoundError else c.PyExc_OSError,
            .interrupted_error => if (@hasDecl(c, "PyExc_InterruptedError")) c.PyExc_InterruptedError else c.PyExc_OSError,
            .is_a_directory_error => if (@hasDecl(c, "PyExc_IsADirectoryError")) c.PyExc_IsADirectoryError else c.PyExc_OSError,
            .not_a_directory_error => if (@hasDecl(c, "PyExc_NotADirectoryError")) c.PyExc_NotADirectoryError else c.PyExc_OSError,
            .permission_error => if (@hasDecl(c, "PyExc_PermissionError")) c.PyExc_PermissionError else c.PyExc_OSError,
            .process_lookup_error => if (@hasDecl(c, "PyExc_ProcessLookupError")) c.PyExc_ProcessLookupError else c.PyExc_OSError,
            .timeout_error => if (@hasDecl(c, "PyExc_TimeoutError")) c.PyExc_TimeoutError else c.PyExc_OSError,
            .reference_error => c.PyExc_ReferenceError,
            .runtime_error => c.PyExc_RuntimeError,
            .not_implemented_error => c.PyExc_NotImplementedError,
            .recursion_error => if (@hasDecl(c, "PyExc_RecursionError")) c.PyExc_RecursionError else c.PyExc_RuntimeError,
            .stop_async_iteration => if (@hasDecl(c, "PyExc_StopAsyncIteration")) c.PyExc_StopAsyncIteration else c.PyExc_Exception,
            .stop_iteration => c.PyExc_StopIteration,
            .syntax_error => c.PyExc_SyntaxError,
            .indentation_error => c.PyExc_IndentationError,
            .tab_error => c.PyExc_TabError,
            .system_error => c.PyExc_SystemError,
            .type_error => c.PyExc_TypeError,
            .value_error => c.PyExc_ValueError,
            .unicode_error => c.PyExc_UnicodeError,
            .warning => c.PyExc_Warning,
            .bytes_warning => c.PyExc_BytesWarning,
            .deprecation_warning => c.PyExc_DeprecationWarning,
            .future_warning => c.PyExc_FutureWarning,
            .import_warning => c.PyExc_ImportWarning,
            .pending_deprecation_warning => c.PyExc_PendingDeprecationWarning,
            .resource_warning => if (@hasDecl(c, "PyExc_ResourceWarning")) c.PyExc_ResourceWarning else c.PyExc_Warning,
            .runtime_warning => c.PyExc_RuntimeWarning,
            .syntax_warning => c.PyExc_SyntaxWarning,
            .unicode_warning => c.PyExc_UnicodeWarning,
            .user_warning => c.PyExc_UserWarning,
        };
    }
};

// ============================================================================
// Custom exception type
// ============================================================================

/// A custom Python exception class created via `createException`.
/// Holds a strong reference to the exception type for the lifetime of the module.
pub const Exception = struct {
    exc_type: *Object,

    /// Raise this exception with a static message. Sets Python error state and
    /// returns `error.PyError` so callers can `return raise(...)` from a
    /// `Result(T)` function.
    pub inline fn raise(self: *const Exception, msg: [:0]const u8) Error {
        c.PyErr_SetString(@ptrCast(self.exc_type), msg);
        return error.PyError;
    }

    /// Raise this exception with a formatted message.
    pub inline fn raiseFormat(self: *const Exception, comptime fmt: []const u8, args: anytype) Error {
        return errorFormat(@ptrCast(self.exc_type), fmt, args);
    }

    /// Get the underlying Python exception class as `*Object`.
    pub inline fn asObject(self: *const Exception) *Object {
        return self.exc_type;
    }
};

/// Create a new Python exception class derived from a standard base.
/// The exception is automatically registered as an attribute of `mod` under
/// `name`, so users can write `mymodule.MyError("msg")` from Python.
///
/// On Python 3 the exception is created via `PyErr_NewException` with a fully
/// qualified name like `"mymodule.MyError"`. On Python 2 we fall back to
/// creating a class derived from the base via the C API.
pub fn createException(
    mod: *types.Module,
    name: [:0]const u8,
    base: ExceptionBase,
    doc: ?[:0]const u8,
) Error!Exception {
    // Build the fully qualified name "modname.name" required by PyErr_NewException.
    const mod_name_str = mod.getName();
    const qual_name_noz = std.fmt.allocPrint(std.heap.c_allocator, "{s}.{s}", .{ mod_name_str, name }) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    defer std.heap.c_allocator.free(qual_name_noz);
    // Add sentinel terminator for the C API.
    const qual_name = std.heap.c_allocator.allocSentinel(u8, qual_name_noz.len, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    defer std.heap.c_allocator.free(qual_name);
    @memcpy(qual_name[0..qual_name_noz.len], qual_name_noz);

    const base_obj = base.toPyObject();
    const exc = blk: {
        if (version.is_py3) {
            // PyErr_NewException(name, base, dict) — base may be NULL for Exception.
            // Pass NULL for dict; docstring (if any) is set below via __doc__.
            const created = c.PyErr_NewException(qual_name.ptr, base_obj, null);
            if (created) |e| break :blk e;
        } else {
            // Python 2: create a class derived from base using a small dict.
            // PyErr_NewException is also available on Python 2.7, so use it.
            const created = c.PyErr_NewException(qual_name.ptr, base_obj, null);
            if (created) |e| break :blk e;
        }
        return error.PyError;
    };

    // Optionally attach a docstring via the __doc__ attribute (must be a str).
    if (version.is_py3) if (doc) |d| {
        const doc_obj = object.Str.fromSlice(d) catch null;
        if (doc_obj) |str_obj| {
            _ = c.PyObject_SetAttrString(exc, "__doc__", @ptrCast(str_obj));
            str_obj.decref();
        }
    };

    // Register the new exception as a module attribute.
    if (version.is_py3 and version.versionAtLeast(3, 10)) {
        try mod.addObjectRef(name, @ptrCast(exc));
        c.Py_DECREF(exc);
    } else {
        try mod.addObjectRef(name, @ptrCast(exc));
    }

    return .{ .exc_type = @ptrCast(exc) };
}
