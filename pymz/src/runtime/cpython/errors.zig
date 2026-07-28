//! 错误处理辅助函数和自定义异常支持。

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const mem = @import("../../mem.zig");
const Object = object.Object;

/// 运行时断言当前线程持有 GIL。
///
/// 在 Debug/ReleaseSafe 构建中触发断言；ReleaseFast 构建中 `std.debug.assert`
/// 仍会求值条件但移除断言指令，因此 `PyGILState_Check` 调用开销不可避免。
/// 若需完全零开销的检查，请在调用方用 `comptime std.debug.runtime_safety`
/// 守卫。
///
/// 仅在 `PyGILState_Check` 可用（Python 3.4+）时执行实质检查；旧版本无操作，
/// 因 `PyThreadState_Get` 在未初始化的解释器上行为不可靠，且 pymz 不在
/// 解释器未初始化时调用任何 API。
///
/// 本函数是 GIL 断言的单一真相源：`cpython.zig` 的 `GIL.assertHeldByCurrentThread`
/// 与各子模块（object.zig、convert.zig）的关键 API 入口均调用它，
/// 避免在子模块中重复 `@hasDecl(c, "PyGILState_Check")` 检查、
/// 也避免子模块反向依赖 `cpython.zig` 形成循环。
pub fn assertGILHeldByCurrentThread() void {
    // Guard the entire check with runtime_safety so ReleaseFast builds
    // completely eliminate the PyGILState_Check() call for zero overhead.
    if (std.debug.runtime_safety) {
        if (@hasDecl(c, "PyGILState_Check")) {
            std.debug.assert(c.PyGILState_Check() != 0);
        }
    }
}

/// Zig 代码中产生并传播到 Python 的错误。
///
/// `PyError` 作为通用错误保留，表示"Python 异常已设置"。更丰富的变体使
/// Zig 代码无需在返回前手动设置 Python 异常即可表达原生失败，并通过
/// `mapError` 映射到对应的 Python 异常类型。
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

/// 运行时无关的公共结果类型别名。
pub inline fn Result(comptime T: type) type {
    return Error!T;
}

/// 将 Zig 错误映射到适当的 Python 异常。
///
/// 调用方应在 Zig 函数返回非 `PyError` 错误时使用此函数，以便 Python 看到
/// 有意义的异常类型。如果 Python 异常已设置，则保留现有异常。Python 异常
/// 总是在返回前设置，因此调用方只需向 Python 返回失败指示。
pub fn mapError(err: anyerror) void {
    if (err == error.PyError) {
        return;
    }

    switch (err) {
        error.OutOfMemory,
        error.MemoryError,
        => c.PyErr_SetString(c.PyExc_MemoryError, "out of memory"),
        error.OverflowError => c.PyErr_SetString(c.PyExc_OverflowError, "integer overflow"),
        error.InvalidArgument => c.PyErr_SetString(c.PyExc_ValueError, "invalid argument"),
        error.IndexError => c.PyErr_SetString(c.PyExc_IndexError, "index out of bounds"),
        error.KeyError => c.PyErr_SetString(c.PyExc_KeyError, "key not found"),
        error.InvalidUtf8 => c.PyErr_SetString(c.PyExc_UnicodeDecodeError, "invalid UTF-8"),
        error.SystemError => c.PyErr_SetString(c.PyExc_SystemError, "system error"),
        error.TypeError => c.PyErr_SetString(c.PyExc_TypeError, "type error"),
        error.ValueError => c.PyErr_SetString(c.PyExc_ValueError, "value error"),
        error.AttributeError => c.PyErr_SetString(c.PyExc_AttributeError, "attribute error"),
        error.RuntimeError => c.PyErr_SetString(c.PyExc_RuntimeError, "runtime error"),
        error.NotImplementedError => c.PyErr_SetString(c.PyExc_NotImplementedError, "not implemented"),
        error.BufferError => c.PyErr_SetString(c.PyExc_BufferError, "buffer error"),
        error.StopIteration => c.PyErr_SetString(c.PyExc_StopIteration, ""),
        error.ZeroDivisionError => c.PyErr_SetString(c.PyExc_ZeroDivisionError, "division by zero"),
        else => {
            const msg = std.fmt.allocPrintSentinel(mem.allocator, "zig error: {s}", .{@errorName(err)}, 0) catch {
                c.PyErr_SetString(c.PyExc_RuntimeError, "zig function returned an error");
                return;
            };
            defer mem.allocator.free(msg);
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

/// 抛出带有格式化消息的 Python 异常。异常类为编译期参数，作为下面各类型
/// 便捷包装器的通用替代。
pub inline fn raise(comptime exc: ?*c.PyObject, comptime msg: [:0]const u8, args: anytype) void {
    errorFormat(exc, msg, args);
}

// 各类型的便捷包装器（单行转发到 errorFormat）。
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
    const buf = std.fmt.allocPrintSentinel(mem.allocator, format, args, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
        return;
    };
    defer mem.allocator.free(buf);
    c.PyErr_SetString(exc, @ptrCast(buf));
}
/// 可作为 `createException` 基类的标准 Python 异常类别。对应 PyOZ 的
/// `ExcBase` 枚举。
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

    /// 解析为对应的 `?*c.PyObject` 异常类。
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

/// 通过 `createException` 创建的自定义 Python 异常类。
///
/// `exc_type` 是一个借用引用，由注册该异常的模块持有。模块在解释器生命周期
/// 内保持异常类存活，因此调用方可自由使用 `exc_type` 而无需管理其引用计数。
pub const Exception = struct {
    exc_type: *Object,

    /// 使用静态消息抛出此异常。设置 Python 错误状态并返回 `error.PyError`，
    /// 以便调用方可以从 `Result(T)` 函数中 `return raise(...)`。
    pub inline fn raise(self: *const Exception, msg: [:0]const u8) Error {
        c.PyErr_SetString(@ptrCast(self.exc_type), msg);
        return error.PyError;
    }

    /// 使用格式化消息抛出此异常。
    pub inline fn raiseFormat(self: *const Exception, comptime fmt: []const u8, args: anytype) Error {
        errorFormat(@ptrCast(self.exc_type), fmt, args);
        return error.PyError;
    }

    /// 获取底层的 Python 异常类作为 `*Object`。
    pub inline fn asObject(self: *const Exception) *Object {
        return self.exc_type;
    }
};

/// 从标准基类派生创建新的 Python 异常类。
/// 该异常会自动注册为 `mod` 的属性，名称为 `name`，因此用户可以从 Python
/// 端编写 `mymodule.MyError("msg")`。
///
/// `PyErr_NewException` 在 Python 2.7 和 Python 3 上均可用，因此两个版本
/// 使用相同的代码路径。
pub fn createException(
    mod: *types.Module,
    name: [:0]const u8,
    base: ExceptionBase,
    doc: ?[:0]const u8,
) Error!Exception {
    // 构建 `PyErr_NewException` 所需的全限定名 "modname.name"。
    const mod_name_str = mod.getName();
    const qual_name = std.fmt.allocPrintSentinel(mem.allocator, "{s}.{s}", .{ mod_name_str, name }, 0) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
        return error.PyError;
    };
    defer mem.allocator.free(qual_name);

    const base_obj = base.toPyObject();
    // `PyErr_NewException` 在 Python 2.7 和 Python 3 上均可用，无需版本分支。
    // 为 dict 传入 NULL；文档字符串（如果有）通过 `__doc__` 属性设置。
    const exc = c.PyErr_NewException(qual_name.ptr, base_obj, null) orelse {
        return error.PyError;
    };

    // 可选：通过 __doc__ 属性附加文档字符串（必须为 str）。
    if (version.is_py3) if (doc) |d| {
        const doc_obj = object.Str.fromSlice(d) catch null;
        if (doc_obj) |str_obj| {
            // 故意忽略返回值：异常类的 `__doc__` 属性设置失败不影响异常的创建、
            // 抛出与捕获功能——异常类本身已由 `PyErr_NewException` 成功构造，
            // `__doc__` 仅是辅助说明。`str_obj` 的新引用在下方 `decref` 释放。
            if (c.PyObject_SetAttrString(exc, "__doc__", @ptrCast(str_obj)) < 0) {
                c.PyErr_Clear();
            }
            str_obj.decref();
        }
    };

    // 将新异常注册为模块属性。
    // `addObjectRef` 在任何 Python 版本上都不会窃取引用：
    //   - 3.10+ `PyModule_AddObjectRef` 内部 incref。
    //   - <3.10 `PyModule_AddObject` 窃取 `addObjectRef` 内部产生的 `newref()`，
    //     使调用方的原始引用计数不变。
    // 无论哪种方式，我们仍然拥有 `PyErr_NewException` 返回的新引用，
    // 因此必须在此 decref 以平衡。模块保持异常类存活，因此 `Exception.exc_type`
    // 成为在模块生命周期内有效的借用引用。
    try mod.addObjectRef(name, @ptrCast(exc));
    object.decrefRaw(exc);

    return .{ .exc_type = @ptrCast(exc) };
}
