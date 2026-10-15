//! Python 值表层。
//!
//! 本命名空间存放具体的 Python 对象包装器和值构造器。
//! 更高层的声明辅助函数位于 `py/decl.zig`。

const interface = @import("pymz_backend");

pub const backend = interface.Backend();

pub const Error = backend.Error;
pub const Result = backend.Result;
pub const Object = backend.Object;
pub const Args = backend.Args;
pub const RawArgs = backend.RawArgs;

pub const ExceptionBase = backend.ExceptionBase;
pub const Exception = backend.Exception;
pub const Str = backend.Str;
pub const Bytes = backend.Bytes;
pub const ByteArray = backend.ByteArray;
pub const Int = backend.Int;
pub const Float = backend.Float;
pub const Bool = backend.Bool;
pub const Tuple = backend.Tuple;
pub const List = backend.List;
pub const Dict = backend.Dict;
pub const Set = backend.Set;
pub const FrozenSet = backend.FrozenSet;
pub const Slice = backend.Slice;
pub const Buffer = backend.Buffer;

/// GIL 令牌类型，表示当前线程持有 CPython 全局解释器锁。
///
/// 见 `py.zig` 顶部的 "GIL 约定" 章节和 `GIL` 命名空间的文档了解使用模式。
pub const Python = backend.Python;

/// GIL 管理命名空间：`acquire`/`ensure`/`release`/`held`/`assertHeld`/
/// `assertHeldByCurrentThread`。
///
/// 详见 `py.zig` 顶部的 "GIL 约定" 章节和 `Python` 令牌类型的推荐用法文档。
pub const GIL = backend.GIL;

/// 转换原语命名空间（`convert.zig`）：`toPy`/`fromPy`/`instantiate`/`PyClass` 等。
/// `instantiate` 用于跨类返回——把另一个 class 的 impl 值物化为对应 class 的
/// Python 实例（见 `py/decl.zig` 中 `class` 的文档）。最常用的方式是声明式
/// `py_class`：在 impl 类型上声明 `pub const py_class: PyClass = .{
/// .descriptor = SomeClass, .name = "SomeClass" }`，返回该 impl 值的 method
/// 即自动获得 `SomeClass` 实例，无需手写 `toPy`。
pub const convert = backend.convert;

pub fn none() *Object {
    return @ptrCast(backend.none());
}

pub fn boolean(value: bool) *Object {
    return @ptrCast(backend.boolean(value));
}

pub fn integer(value: anytype) Result(*Object) {
    return @ptrCast(try backend.Int.from(value));
}

pub fn floating(value: anytype) Result(*Object) {
    return @ptrCast(try backend.Float.from(value));
}

pub fn string(value: []const u8) Result(*Object) {
    return @ptrCast(try backend.Str.fromSlice(value));
}

/// 创建一个 Unicode 文本对象（Python 2 上为 `unicode`，Python 3 上为 `str`）。
pub fn unicode(value: []const u8) Result(*Object) {
    return @ptrCast(try backend.unicodeFromSlice(value));
}

pub fn list(size: usize) Result(*Object) {
    return @ptrCast(try backend.List.new(size));
}

pub fn dict() Result(*Object) {
    return @ptrCast(try backend.Dict.new());
}

pub fn tuple(size: usize) Result(*Object) {
    return @ptrCast(try backend.Tuple.new(size));
}

pub fn bytes(value: []const u8) Result(*Object) {
    return @ptrCast(try backend.Bytes.fromSlice(value));
}

pub fn bytearray(value: []const u8) Result(*Object) {
    return @ptrCast(try backend.ByteArray.fromSlice(value));
}

pub fn set(items: []const *Object) Result(*Object) {
    comptime if (!interface.backendSpec().capabilities.set_model)
        @compileError("selected backend does not implement set values");
    return @ptrCast(try backend.Set.fromSlice(items));
}

pub fn frozenset(items: []const *Object) Result(*Object) {
    comptime if (!interface.backendSpec().capabilities.set_model)
        @compileError("selected backend does not implement frozenset values");
    return @ptrCast(try backend.FrozenSet.fromSlice(items));
}

pub fn slice(start: ?isize, stop: ?isize, step: ?isize) Result(*Object) {
    comptime if (!interface.backendSpec().capabilities.slice_model)
        @compileError("selected backend does not implement slice values");
    return @ptrCast(try backend.Slice.new(start, stop, step));
}
