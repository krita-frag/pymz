//! Built-in CPython backend adapter.

const std = @import("std");
const contract = @import("../backend.zig");
const options = @import("pymz_options");
const version = @import("../runtime/cpython/version.zig");
const cpython = @import("../runtime/cpython.zig");

pub const c = cpython.c;
pub const Error = cpython.Error;
pub const Result = cpython.Result;
pub const ExceptionBase = cpython.ExceptionBase;
pub const Exception = cpython.Exception;
pub const Object = cpython.Object;
pub const Type = cpython.Type;
pub const Buffer = cpython.Buffer;
pub const Str = cpython.Str;
pub const Bytes = cpython.Bytes;
pub const ByteArray = cpython.ByteArray;
pub const none = cpython.none;
pub const boolean = cpython.boolean;
pub const Int = cpython.Int;
pub const Float = cpython.Float;
pub const Bool = cpython.Bool;
pub const Tuple = cpython.Tuple;
pub const List = cpython.List;
pub const Dict = cpython.Dict;
pub const Set = cpython.Set;
pub const FrozenSet = cpython.FrozenSet;
pub const Slice = cpython.Slice;
pub const Args = cpython.Args;
pub const Module = cpython.Module;
pub const ModuleInitFn = cpython.ModuleInitFn;
pub const Repr = cpython.Repr;
pub const ClassDef = cpython.ClassDef;
pub const FnMode = cpython.FnMode;
pub const function = cpython.function;
pub const kwFunction = cpython.kwFunction;
pub const positionalFunction = cpython.positionalFunction;
pub const varargsFunction = cpython.varargsFunction;
pub const class = cpython.class;
pub const classWithBase = cpython.classWithBase;
pub const exception = cpython.exception;
pub const constant = cpython.constant;
pub const module = cpython.module;
pub const RawArgs = cpython.RawArgs;
pub const py_major = cpython.py_major;
pub const py_minor = cpython.py_minor;
pub const py_hex = cpython.py_hex;
pub const is_py3 = cpython.is_py3;
pub const is_py2 = cpython.is_py2;
pub const versionAtLeast = cpython.versionAtLeast;
pub const convert = cpython.convert;
pub const ThreadState = cpython.ThreadState;
pub const GILState = cpython.GILState;
pub const isInitialized = cpython.isInitialized;
pub const initialize = cpython.initialize;
pub const finalize = cpython.finalize;
pub const saveThread = cpython.saveThread;
pub const restoreThread = cpython.restoreThread;
pub const threadStateGet = cpython.threadStateGet;
pub const GIL = cpython.GIL;

pub const is_limited_api = version.is_limited_api;

fn runtimeName() []const u8 {
    if (std.mem.startsWith(u8, options.runtime, "cpython2")) return "cpython2";
    if (std.mem.startsWith(u8, options.runtime, "cpython3-limited")) return "cpython3-limited";
    if (std.mem.startsWith(u8, options.runtime, "cpython3_limited")) return "cpython3-limited";
    if (std.mem.startsWith(u8, options.runtime, "cpython3")) return "cpython3";
    return "cpython3";
}

pub fn backendSpec() contract.BackendSpec {
    const runtime_name = runtimeName();
    var capabilities: contract.Capabilities = .{};
    if (std.mem.startsWith(u8, runtime_name, "cpython2")) {
        capabilities = .{
            .gil = true,
            .class_model = true,
            .python2 = true,
        };
    } else if (std.mem.startsWith(u8, runtime_name, "cpython3-limited")) {
        capabilities = .{
            .gil = true,
            .stable_abi = true,
            .python3 = true,
        };
    } else if (std.mem.startsWith(u8, runtime_name, "cpython3")) {
        capabilities = .{
            .gil = true,
            .class_model = true,
            .python3 = true,
        };
    } else {
        capabilities = .{
            .gil = true,
            .class_model = true,
            .python3 = true,
        };
    }

    return .{
        .name = runtime_name,
        .capabilities = capabilities,
    };
}

pub fn Backend() type {
    return @This();
}
