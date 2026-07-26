//! Error handling helpers and custom exception support.

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const mem = @import("../../mem.zig");
const Object = object.Object;

/// Errors that can originate in Zig code and are propagated to Python.
///
/// `PyError` is preserved as a catch-all meaning "a Python exception is already
/// set".  The richer variants let Zig code surface a native failure without
/// manually setting a Python exception before returning, and they map to the
/// corresponding Python exception type in `mapError`.
pub const Error = error{
    PyError,
    OutOfMemory,
    InvalidArgument,
    InvalidUtf8,
    SystemError,
    TypeError,
    ValueError,
    AttributeError,
    KeyError,
    IndexError,
    OverflowError,
    RuntimeError,
    NotImplementedError,
    BufferError,
    StopIteration,
    ZeroDivisionError,
};

/// Runtime-neutral public result type alias.
pub inline fn Result(comptime T: type) type {
    return Error!T;
}

/// Map a Zig error to an appropriate Python exception.
///
/// Callers should use this when a Zig function returns a non-`PyError` error and
/// they want Python to see a meaningful exception type.  If a Python exception is
/// already set, the existing exception is preserved. The Python exception is
/// always set before returning, so callers only need to return a failure indicator
/// to Python.
pub fn mapError(err: anyerror) void {
    if (err == error.PyError) {
        return;
    }

    switch (err) {
        error.OutOfMemory,
        error.MemoryError,
        => c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory")),
        error.OverflowError => c.PyErr_SetString(c.PyExc_OverflowError, @ptrCast("integer overflow")),
        error.InvalidArgument => c.PyErr_SetString(c.PyExc_ValueError, @ptrCast("invalid argument")),
        error.IndexError => c.PyErr_SetString(c.PyExc_IndexError, @ptrCast("index out of bounds")),
        error.KeyError => c.PyErr_SetString(c.PyExc_KeyError, @ptrCast("key not found")),
        error.InvalidUtf8 => c.PyErr_SetString(c.PyExc_UnicodeDecodeError, @ptrCast("invalid UTF-8")),
        error.SystemError => c.PyErr_SetString(c.PyExc_SystemError, @ptrCast("system error")),
        error.TypeError => c.PyErr_SetString(c.PyExc_TypeError, @ptrCast("type error")),
        error.ValueError => c.PyErr_SetString(c.PyExc_ValueError, @ptrCast("value error")),
        error.AttributeError => c.PyErr_SetString(c.PyExc_AttributeError, @ptrCast("attribute error")),
        error.RuntimeError => c.PyErr_SetString(c.PyExc_RuntimeError, @ptrCast("runtime error")),
        error.NotImplementedError => c.PyErr_SetString(c.PyExc_NotImplementedError, @ptrCast("not implemented")),
        error.BufferError => c.PyErr_SetString(c.PyExc_BufferError, @ptrCast("buffer error")),
        error.StopIteration => c.PyErr_SetString(c.PyExc_StopIteration, @ptrCast("")),
        error.ZeroDivisionError => c.PyErr_SetString(c.PyExc_ZeroDivisionError, @ptrCast("division by zero")),
        else => {
            const printed = std.fmt.allocPrint(mem.allocator, "zig error: {s}", .{@errorName(err)}) catch {
                c.PyErr_SetString(c.PyExc_RuntimeError, @ptrCast("zig function returned an error"));
                return;
            };
            defer mem.allocator.free(printed);
            const msg = mem.allocator.allocSentinel(u8, printed.len, 0) catch {
                c.PyErr_SetString(c.PyExc_RuntimeError, @ptrCast("zig function returned an error"));
                return;
            };
            defer mem.allocator.free(msg);
            @memcpy(msg, printed);
            c.PyErr_SetString(c.PyExc_RuntimeError, @ptrCast(msg));
        },
    }
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

/// Raise a Python exception with a formatted message. The exception class is
/// a comptime parameter, providing a generic alternative to the per-type
/// convenience wrappers below.
pub inline fn raise(comptime exc: ?*c.PyObject, comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(exc, msg, args);
}

// Per-type convenience wrappers (one-liners forwarding to errorFormat).
pub inline fn typeError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_TypeError, msg, args);
}
pub inline fn valueError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_ValueError, msg, args);
}
pub inline fn attributeError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_AttributeError, msg, args);
}
pub inline fn keyError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_KeyError, msg, args);
}
pub inline fn indexError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_IndexError, msg, args);
}
pub inline fn systemError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_SystemError, msg, args);
}
pub inline fn runtimeError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_RuntimeError, msg, args);
}
pub inline fn notImplementedError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_NotImplementedError, msg, args);
}
pub inline fn bufferError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_BufferError, msg, args);
}
pub inline fn zeroDivisionError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_ZeroDivisionError, msg, args);
}
pub inline fn overflowError(comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(c.PyExc_OverflowError, msg, args);
}

pub inline fn errorFormat(
    exc: ?*c.PyObject,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime args.len == 0) {
        c.PyErr_SetString(exc, @ptrCast(format));
        return;
    }
    const printed = std.fmt.allocPrint(mem.allocator, format, args) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return;
    };
    defer mem.allocator.free(printed);
    const buf = mem.allocator.allocSentinel(u8, printed.len, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return;
    };
    @memcpy(buf, printed);
    defer mem.allocator.free(buf);
    c.PyErr_SetString(exc, @ptrCast(buf));
}
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

    /// Resolve to the corresponding `?*c.PyObject` exception class.
    pub fn toPyObject(self: ExceptionBase) ?*c.PyObject {
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

/// A custom Python exception class created via `createException`.
///
/// `exc_type` is a borrowed reference owned by the module that the exception
/// was registered against. The module keeps the exception class alive for the
/// interpreter's lifetime, so callers may freely use `exc_type` without
/// managing its reference count.
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
/// `PyErr_NewException` is available on both Python 2.7 and Python 3, so the
/// same code path is used on both versions.
pub fn createException(
    mod: *types.Module,
    name: [:0]const u8,
    base: ExceptionBase,
    doc: ?[:0]const u8,
) Error!Exception {
    // Build the fully qualified name "modname.name" required by PyErr_NewException.
    const mod_name_str = mod.getName();
    const qual_name_noz = std.fmt.allocPrint(mem.allocator, "{s}.{s}", .{ mod_name_str, name }) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    defer mem.allocator.free(qual_name_noz);
    // Add sentinel terminator for the C API.
    const qual_name = mem.allocator.allocSentinel(u8, qual_name_noz.len, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, @ptrCast("out of memory"));
        return error.PyError;
    };
    defer mem.allocator.free(qual_name);
    @memcpy(qual_name[0..qual_name_noz.len], qual_name_noz);

    const base_obj = base.toPyObject();
    // `PyErr_NewException` is available on both Python 2.7 and Python 3, so
    // no version branch is needed. Pass NULL for dict; the docstring (if any)
    // is set below via the `__doc__` attribute.
    const exc = c.PyErr_NewException(qual_name.ptr, base_obj, null) orelse {
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
    // `addObjectRef` does not steal the reference on any Python version:
    //  - 3.10+ `PyModule_AddObjectRef` increfs internally.
    //  - <3.10 `PyModule_AddObject` steals the `newref()` produced inside
    //    `addObjectRef`, leaving the caller's original refcount unchanged.
    // Either way we still own the new reference returned by
    // `PyErr_NewException`, so we must decref it here to balance. The module
    // keeps the exception class alive, so `Exception.exc_type` becomes a
    // borrowed reference valid for the module's lifetime.
    try mod.addObjectRef(name, @ptrCast(exc));
    object.decrefRaw(exc);

    return .{ .exc_type = @ptrCast(exc) };
}
