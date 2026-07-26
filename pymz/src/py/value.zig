//! Python value surface.
//!
//! This namespace holds the concrete Python object wrappers and value
//! constructors. Higher-level declaration helpers live in `py/decl.zig`.

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

/// Create a Unicode text object (`unicode` on Python 2, `str` on Python 3).
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
