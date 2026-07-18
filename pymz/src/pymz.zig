//! pymz: runtime-neutral Zig bindings for Python-family runtimes.
//!
//! User code should depend on the declarations exported from this file. Runtime
//! details live under `pymz.runtime.*` backend namespaces.

const std = @import("std");

pub const api = @import("api.zig");
pub const ir = @import("ir.zig");
pub const runtime = @import("runtime.zig");

pub const Runtime = api.Runtime;

pub const Error = api.Error;
pub const Result = api.Result;
pub const Value = api.Value;
pub const Args = api.Args;

pub const ExceptionBase = api.ExceptionBase;
pub const Exception = api.Exception;
pub const Repr = api.Repr;
pub const Str = api.Str;

pub const FnMode = api.FnMode;
pub const function = api.function;
pub const kwFunction = api.kwFunction;
pub const class = api.class;
pub const exception = api.exception;
pub const module = api.module;

pub const none = api.none;
pub const boolean = api.boolean;
pub const integer = api.integer;
pub const floating = api.floating;
pub const string = api.string;
pub const list = api.list;
pub const dict = api.dict;

comptime {
    _ = std;
}
