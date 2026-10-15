//! 核心 Python 对象协议及基本类型（Str、Bytes）。

const std = @import("std");
const c = @import("python_c");
const errors = @import("errors.zig");
const mem = @import("../../mem.zig");
const compat = @import("compat.zig");
const version = @import("version.zig");
const Error = errors.Error;

/// 由类 `__buffer__` 方法导出的 Python 缓冲区描述。
/// 从 `__buffer__` 返回此结构可启用多维和/或带步幅的缓冲区视图。
/// 返回纯 `[]u8`/`[]const u8` 仍被支持，作为一维读/写字节缓冲区的简写。
pub const Buffer = struct {
    /// 指向第一个元素的指针。数据在缓冲区被释放前必须保持有效。
    ptr: [*]u8,

    /// 缓冲区的形状。`shape.len` 是维度数。
    shape: []const usize,

    /// 每个维度可选的字节步幅。如果为 `null`，缓冲区被认为是 C 连续的。
    strides: ?[]const isize = null,

    /// PEP-3118 格式字符串。如果为 `null`，memoryview 推断为无符号字节。
    /// 常见值："B"（u8）、"b"（i8）、"i"（i32）、"f"（f32）、"d"（f64）。
    format: ?[]const u8 = null,

    /// 如果缓冲区为只读，则为 true。
    readonly: bool = false,
};

pub const Object = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    /// 将此包装器转换为原始 `*c.PyObject`。所有 extern-struct 包装器
    ///（`Object`、`Str`、`Int`...）共享与 `PyObject` 相同的布局（偏移量为零），
    /// 因此转换是零成本的。使用此方法代替在每个 C-API 调用点写出
    /// `@as(*c.PyObject, @ptrCast(self))`。
    pub inline fn asPy(self: *const Object) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Object) void {
        c.Py_IncRef(self.asPy());
    }

    pub inline fn decref(self: *Object) void {
        c.Py_DecRef(self.asPy());
    }

    /// 返回此对象的新引用。调用方必须 decref 它。
    pub inline fn newref(self: *Object) *Object {
        self.incref();
        return self;
    }

    /// 可被其他类似 PyObject 的包装器结构体共享的引用计数辅助函数。
    /// `extern struct` 包装器不能使用 `usingnamespace`，因此每个包装器声明
    /// `incref`/`decref`/`newref` 并转发给这些静态辅助函数。实现仍然
    /// 统一在一个地方。
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
        return c.Py_REFCNT(self.asPy());
    }

    pub inline fn isNone(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.pymz_Py_None());
    }

    pub inline fn isTrue(self: *const Object) bool {
        return @intFromPtr(self) == @intFromPtr(c.pymz_Py_True());
    }

    pub inline fn isBool(self: *Object) bool {
        return compat.cApiBool(c.pymz_PyBool_Check(self.asPy()));
    }

    pub inline fn asBool(self: *Object) Error!bool {
        return compat.cApiTriState(c.PyObject_IsTrue(self.asPy()));
    }

    /// 当对象是 Python 整数（Py3 `int` / Py2 `int` 或 `long`）时为真。
    pub inline fn isInt(self: *Object) bool {
        return compat.intCheck(self.asPy());
    }

    /// 将 Python 整数对象转换为带范围检查的 Zig 整数类型。
    /// 溢出时设置 Python `OverflowError` 并返回 `error.PyError`。
    pub inline fn asInt(self: *Object, comptime T: type) Error!T {
        const py: *c.PyObject = self.asPy();
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

    /// 当对象是 Python `float` 时为真。
    pub inline fn isFloat(self: *Object) bool {
        return compat.cApiBool(c.PyFloat_Check(self.asPy()));
    }

    /// 将 Python float 对象转换为 Zig float 类型。`PyFloat_AsDouble` 在失败时
    /// 返回 `-1.0` 并设置异常，表现为 `error.PyError`。
    pub inline fn asFloat(self: *Object, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .float => {
                const v = c.PyFloat_AsDouble(self.asPy());
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
        return compat.cApiBool(c.PyList_Check(self.asPy()));
    }

    pub inline fn isTuple(self: *Object) bool {
        return compat.cApiBool(c.PyTuple_Check(self.asPy()));
    }

    pub inline fn isDict(self: *Object) bool {
        return compat.cApiBool(c.PyDict_Check(self.asPy()));
    }

    pub inline fn sequenceLength(self: *Object) Error!usize {
        errors.assertGILHeldByCurrentThread();
        const len = c.PyObject_Size(self.asPy());
        if (len < 0) return error.PyError;
        return @intCast(len);
    }

    /// 从列表或元组中借用元素。返回的引用由容器拥有，调用方除非显式 incref，
    /// 否则不得 decref。对非 list/tuple 对象返回 `null`；如需对任意实现了
    /// `__getitem__` 的对象取元素，请使用 `getItem`（返回新引用）。
    pub inline fn sequenceGet(self: *Object, index: usize) ?*Object {
        errors.assertGILHeldByCurrentThread();
        if (self.isList()) {
            const item = c.PyList_GetItem(
                self.asPy(),
                @as(c.Py_ssize_t, @intCast(index)),
            );
            return @as(?*Object, @ptrCast(item));
        }
        if (self.isTuple()) {
            const item = c.PyTuple_GetItem(
                self.asPy(),
                @as(c.Py_ssize_t, @intCast(index)),
            );
            return @as(?*Object, @ptrCast(item));
        }
        return null;
    }

    /// 对任意实现了 `__getitem__` 的对象按下标取元素。返回**新引用**，
    /// 调用方负责 `decref()`。失败时设置 Python 异常并返回 `error.PyError`。
    /// 与 `sequenceGet` 的区别：
    /// - `sequenceGet` 仅支持 list/tuple，返回借用引用（无需 decref）。
    /// - `getItem` 支持任意序列/映射类型，返回新引用（必须 decref）。
    pub inline fn getItem(self: *Object, index: isize) Error!*Object {
        errors.assertGILHeldByCurrentThread();
        const idx_obj = compat.intFromSigned(index) orelse return error.PyError;
        defer decrefRaw(idx_obj);
        if (c.PyObject_GetItem(self.asPy(), idx_obj)) |item| {
            return @ptrCast(item);
        }
        return error.PyError;
    }

    pub inline fn listSet(self: *Object, index: usize, item: *Object) Error!void {
        errors.assertGILHeldByCurrentThread();
        if (c.PyList_SetItem(
            self.asPy(),
            @as(c.Py_ssize_t, @intCast(index)),
            @ptrCast(item),
        ) < 0) {
            item.decref();
            return error.PyError;
        }
    }

    pub inline fn dictItems(self: *Object) Error!*Object {
        errors.assertGILHeldByCurrentThread();
        if (c.PyDict_Items(self.asPy())) |items| {
            return @ptrCast(items);
        }
        return error.PyError;
    }

    /// 从字典中借用与 `key` 关联的值。返回的引用由字典拥有，除非显式 incref，
    /// 否则不得 decref。
    pub inline fn dictGetString(self: *Object, key: []const u8) Error!?*Object {
        errors.assertGILHeldByCurrentThread();
        const key_object = try Str.fromSlice(key);
        defer key_object.decref();
        const item = c.PyDict_GetItem(
            self.asPy(),
            @as(*c.PyObject, @ptrCast(key_object)),
        );
        return @as(?*Object, @ptrCast(item));
    }

    pub inline fn dictSet(self: *Object, key: *Object, value: *Object) Error!void {
        errors.assertGILHeldByCurrentThread();
        if (c.PyDict_SetItem(
            self.asPy(),
            @as(*c.PyObject, @ptrCast(key)),
            @as(*c.PyObject, @ptrCast(value)),
        ) < 0) {
            return error.PyError;
        }
    }

    /// 调用 Python callable。`args_tuple` 必须是元组（可为空元组）。
    /// 返回**新引用**，调用方必须 `decref()`。失败时设置 Python 异常并返回
    /// `error.PyError`。
    pub inline fn call(self: *Object, args_tuple: *Object) Error!*Object {
        errors.assertGILHeldByCurrentThread();
        if (c.PyObject_CallObject(self.asPy(), args_tuple.asPy())) |result| {
            return @ptrCast(result);
        }
        return error.PyError;
    }

    pub inline fn getAttrString(self: *Object, name: [:0]const u8) Error!*Object {
        if (c.PyObject_GetAttrString(self.asPy(), name)) |r| {
            return @as(*Object, @ptrCast(r));
        }
        return error.PyError;
    }

    pub inline fn setAttrString(self: *Object, name: [:0]const u8, value: ?*Object) Error!void {
        if (c.PyObject_SetAttrString(self.asPy(), name, @ptrCast(value)) < 0) {
            return error.PyError;
        }
    }

    /// 借用字符串对象的 UTF-8 字节。切片仅在 `self` 存活期间有效。
    pub inline fn asString(self: *Object) Error![:0]const u8 {
        return Str.asString(@ptrCast(self));
    }

    pub inline fn isInstance(self: *Object, typ: *Type) Error!bool {
        const rc = c.PyObject_IsInstance(
            self.asPy(),
            @as(*c.PyObject, @ptrCast(typ)),
        );
        return compat.cApiTriState(rc);
    }
};

/// 将版本特定的宏保留在 C 中的原始引用计数辅助函数。
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

    pub inline fn asPy(self: *const Type) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

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

    pub inline fn asPy(self: *const Str) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

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
        const buf = try std.fmt.allocPrintSentinel(mem.allocator, fmt, args, 0);
        defer mem.allocator.free(buf);
        return fromSlice(buf);
    }

    /// 借用字符串的 UTF-8 字节。返回的切片仅在 `self` 存活期间有效。
    /// 如果对象不是有效字符串则返回 `error.PyError`（Python 异常已设置）。
    pub inline fn asString(self: *Str) Error![:0]const u8 {
        if (compat.strAsString(self.asPy())) |s| {
            return s;
        }
        return error.PyError;
    }
};

/// 创建新的 Unicode 文本对象（Python 2 上为 `unicode`，Python 3 上为 `str`）。
/// Python 3 上与 `Str.fromSlice` 相同；Python 2 上无论 `str` 类型如何，
/// 始终产生 `unicode` 对象。
pub fn unicodeFromSlice(s: []const u8) Error!*Object {
    if (compat.unicodeFromSlice(s)) |r| return @as(*Object, @ptrCast(r));
    return error.PyError;
}

pub const Bytes = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Bytes) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

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

    /// 返回对象背后的字节。返回的切片从 `self` 借用。
    /// 失败时返回 `error.PyError`（Python 异常已设置）。
    pub inline fn asSlice(self: *Bytes) Error![]const u8 {
        var size: c.Py_ssize_t = 0;
        const ptr = compat.bytesAsSlice(self.asPy(), &size) orelse return error.PyError;
        return ptr[0..@as(usize, @intCast(size))];
    }
};

pub const ByteArray = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const ByteArray) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

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

    /// 返回 bytearray 背后的字节。返回的切片从 `self` 借用。
    pub inline fn asSlice(self: *ByteArray) Error![]u8 {
        var size: c.Py_ssize_t = 0;
        const ptr = compat.byteArrayAsSlice(self.asPy(), &size) orelse return error.PyError;
        return ptr[0..@as(usize, @intCast(size))];
    }
};
