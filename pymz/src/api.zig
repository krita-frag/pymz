//! Public runtime-neutral API surface.

const std = @import("std");
const options = @import("pymz_options");
const runtime = @import("runtime.zig");

pub const Runtime = runtime.Kind;

fn Backend() type {
    if (std.mem.eql(u8, options.runtime, "cpython2")) {
        return runtime.cpython2;
    }
    if (std.mem.eql(u8, options.runtime, "cpython3")) {
        return runtime.cpython3;
    }
    @compileError("unsupported pymz runtime: " ++ options.runtime);
}

pub const backend = Backend();

pub const Error = backend.Error;
pub const Result = backend.Result;
pub const Value = backend.Value;
pub const Args = backend.Args;

pub const ExceptionBase = backend.ExceptionBase;
pub const Exception = backend.Exception;
pub const Repr = backend.Repr;
pub const Str = backend.Str;

pub const FnMode = backend.FnMode;

pub const function = backend.function;
pub const kwFunction = backend.kwFunction;
pub const class = backend.class;
pub const exception = backend.exception;
pub const module = backend.module;

pub const none = backend.none;
pub const boolean = backend.boolean;

pub fn integer(value: anytype) Result(*Value) {
    return @ptrCast(try backend.Int.from(value));
}

pub fn floating(value: anytype) Result(*Value) {
    return @ptrCast(try backend.Float.from(value));
}

pub fn string(value: []const u8) Result(*Value) {
    return @ptrCast(try backend.Str.fromSlice(value));
}

pub fn list(size: usize) Result(*Value) {
    return @ptrCast(try backend.List.new(size));
}

pub fn dict() Result(*Value) {
    return @ptrCast(try backend.Dict.new());
}
