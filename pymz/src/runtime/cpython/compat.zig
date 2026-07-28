//! Python 2 / 3 兼容层。
//!
//! 所有版本相关的 C API 差异集中在此，以便 `object.zig` 和 `types.zig` 中的
//! 上层封装保持版本无关。函数统一声明为 `inline`：它们是对 C API 的薄封装，
//! 不产生运行时开销。

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const mem = @import("../../mem.zig");

/// 将返回值为 `1`（真）或 `0`（假）的 C API 谓词转为 Zig `bool`。
/// 类型检查宏如 `PyLong_Check` 和 `PyTuple_Check` 属于此类。
pub inline fn cApiBool(value: anytype) bool {
    if (@TypeOf(value) == bool) return value;
    return value == 1;
}

/// 如果 `obj` 是 Python 整数（Py3 `int` / Py2 `int` 或 `long`）则返回真。
/// 集中在此以使 `Int.check` 和 `Object.isInt` 共享同一实现。
pub inline fn intCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyLong_Check(obj));
    }
    return cApiBool(c.PyInt_Check(obj)) or cApiBool(c.PyLong_Check(obj));
}

/// 将返回值为三态（`1` 真 / `0` 假 / `-1` 错误）的 C API 谓词转为 Zig `bool`。
/// `PyObject_IsInstance` 和 `PySet_Contains` 等函数使用此约定。返回 `-1` 时
/// Python 异常状态已设置，此函数将其传播为 `error.PyError`。
pub inline fn cApiTriState(value: c_int) !bool {
    if (value == 1) return true;
    if (value == 0) return false;
    return error.PyError;
}

/// 从有符号整数创建 Python 整数对象。
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

/// 从无符号整数创建 Python 整数对象。
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

/// 从 Python 整数兼容对象中提取有符号整数。
/// 调用方必须确保 `obj` 是 int 或 long；否则可能设置 Python 异常并返回
/// `error.PyError`。
///
/// `PyLong_AsLongLong` 在 Python 2 和 3 上都可用，无需版本分支。
pub inline fn intAsSigned(obj: *c.PyObject) !i64 {
    const v = c.PyLong_AsLongLong(obj);
    if (v == -1 and c.PyErr_Occurred() != null) return error.PyError;
    return @intCast(v);
}

/// 从 Python 整数兼容对象中提取无符号整数。
/// 在 Python 2 和 3 上都使用 `PyLong_AsUnsignedLongLong`，以便正确处理
/// Python 2 上的大正数 `long` 值。
pub inline fn intAsUnsigned(obj: *c.PyObject) !u64 {
    const v = c.PyLong_AsUnsignedLongLong(obj);
    const sentinel = @as(c_ulonglong, @bitCast(@as(c_longlong, -1)));
    if (v == sentinel and c.PyErr_Occurred() != null) return error.PyError;
    return @intCast(v);
}

/// 如果 `obj` 是文本字符串则返回真。Python 3 上为 `str`；Python 2 上同时接受
/// `str`（原生字节串）和 `unicode` 作为文本，以便 `Str.check` 正确处理
/// `unicode` 输入。`str` 对象与 `bytesCheck` 的重叠是 Python 2 双类型字符串
/// 模型的固有特性。
pub inline fn strCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyUnicode_Check(obj));
    }
    return cApiBool(c.PyString_Check(obj)) or cApiBool(c.PyUnicode_Check(obj));
}

/// 从 UTF-8 字节切片创建文本字符串对象。
/// Python 2 上创建 `str`（原生字节串）；Python 3 上创建 `str`。
pub inline fn strFromSlice(s: []const u8) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyUnicode_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
    }
    return c.PyString_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// 从 UTF-8 字节切片创建 Unicode 文本对象。
/// Python 2 和 3 上都返回 Unicode 文本类型（Python 2 上为 `unicode`，
/// Python 3 上为 `str`）。
pub inline fn unicodeFromSlice(s: []const u8) ?*c.PyObject {
    return c.PyUnicode_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// `strAsString` 的 Python 2 `unicode` 分支使用的线程局部复用缓冲。
/// `unicode` 对象内部不保存 UTF-8 表示，需经临时 bytes 对象编码后拷贝至此
/// 缓冲，以便立即释放临时 bytes 对象。缓冲按需扩容、永不收缩；线程退出时
/// 其内存随 c_allocator 存续至进程结束（每线程最多一块，可忽略）。
threadlocal var tl_utf8_buf: []u8 = &.{};

/// 将 `src` 拷贝到 `tl_utf8_buf` 并返回哨兵终止切片。缓冲不足时按需扩容。
/// 失败时设置 `MemoryError` 并返回 `null`。
fn tlDupUtf8(src: [:0]const u8) ?[:0]const u8 {
    const need: usize = src.len + 1;
    if (need > tl_utf8_buf.len) {
        if (tl_utf8_buf.len > 0) mem.allocator.free(tl_utf8_buf);
        tl_utf8_buf = mem.allocator.alloc(u8, need) catch {
            tl_utf8_buf = &.{};
            c.PyErr_SetString(c.PyExc_MemoryError, "out of memory");
            return null;
        };
    }
    @memcpy(tl_utf8_buf[0..src.len], src);
    tl_utf8_buf[src.len] = 0;
    return tl_utf8_buf[0..src.len :0];
}

/// 借用文本字符串的 UTF-8 字节。失败时返回 `null`（Python 异常已设置）。
///
/// 生命周期：
///   - Python 3 / Python 2 `str`：切片指向对象内部存储，在 `obj` 存活期间
///     有效（标准借用语义）。
///   - Python 2 `unicode`：对象内部无 UTF-8 表示，需经 `PyUnicode_AsUTF8String`
///     临时编码。为避免高频路径（如 `validateKeywordNames`）每次调用泄漏一个
///     bytes 对象，此处将 UTF-8 字节拷贝到线程局部复用缓冲（`tl_utf8_buf`）
///     并立即 decref 临时 bytes 对象。返回切片指向该缓冲，**仅在下次调用
///     本函数的 `unicode` 分支之前有效**。
///
/// 当前所有调用方均在短时间内消费切片且不跨调用持有：关键字名校验、类型名
/// 提取（`pyTypeName`，仅在异常格式化中就地读取）、`fromPy([]const u8)` 参数
/// 转换。若调用方需要更长生命周期，应使用 `pymz.mem.allocator` 自行拷贝，这
/// 与 mem.zig 中"`[]const u8` 为借用缓冲"的总约定一致。
pub inline fn strAsString(obj: *c.PyObject) ?[:0]const u8 {
    if (version.is_py3) {
        var size: c.Py_ssize_t = 0;
        const ptr = c.PyUnicode_AsUTF8AndSize(obj, &size);
        if (ptr == null) return null;
        return ptr[0..@as(usize, @intCast(size)) :0];
    }
    // Python 2: str（bytes）对象直接暴露其内部缓冲区。
    if (cApiBool(c.PyString_Check(obj))) {
        const ptr = c.PyString_AsString(obj);
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }
    // Python 2: unicode 对象需 UTF-8 编码。拷贝到线程局部缓冲后立即 decref
    // 临时 bytes 对象，避免累积泄漏。返回切片仅在下次 unicode 分支调用前有效。
    if (cApiBool(c.PyUnicode_Check(obj))) {
        const utf8 = c.PyUnicode_AsUTF8String(obj) orelse return null;
        defer c.pymz_Py_DECREF(utf8);
        const ptr = c.PyString_AsString(utf8);
        if (ptr == null) return null;
        return tlDupUtf8(std.mem.span(ptr));
    }
    return null;
}

/// 如果 `obj` 是二进制 bytes 对象则返回真。Python 3 上为 `bytes`；
/// Python 2 上也为 `str`。
pub inline fn bytesCheck(obj: *c.PyObject) bool {
    if (version.is_py3) {
        return cApiBool(c.PyBytes_Check(obj));
    }
    return cApiBool(c.PyString_Check(obj));
}

/// 从字节切片创建 bytes 对象。
pub inline fn bytesFromSlice(s: []const u8) ?*c.PyObject {
    if (version.is_py3) {
        return c.PyBytes_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
    }
    return c.PyString_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// 借用 bytes 对象的缓冲区。`size` 写入缓冲区长度。
/// 失败时返回 `null`（Python 异常已设置）。
pub inline fn bytesAsSlice(obj: *c.PyObject, size: *c.Py_ssize_t) ?[*c]u8 {
    var ptr: [*c]u8 = null;
    const rc = if (version.is_py3)
        c.PyBytes_AsStringAndSize(obj, &ptr, size)
    else
        c.PyString_AsStringAndSize(obj, &ptr, size);
    if (rc < 0) return null;
    return ptr;
}
/// 如果 `obj` 在 Python 2 和 Python 3 上都是 `bytearray` 则返回真。
pub inline fn byteArrayCheck(obj: *c.PyObject) bool {
    return cApiBool(c.PyByteArray_Check(obj));
}

/// 从字节切片创建 `bytearray`。
pub inline fn byteArrayFromSlice(s: []const u8) ?*c.PyObject {
    return c.PyByteArray_FromStringAndSize(s.ptr, @as(c.Py_ssize_t, @intCast(s.len)));
}

/// 借用 `bytearray` 的可变缓冲区。`size` 写入缓冲区长度。
/// 失败时返回 `null`（Python 异常已设置）。
pub inline fn byteArrayAsSlice(obj: *c.PyObject, size: *c.Py_ssize_t) ?[*c]u8 {
    const ptr = c.PyByteArray_AsString(obj);
    if (ptr == null) return null;
    size.* = c.PyByteArray_Size(obj);
    return ptr;
}
