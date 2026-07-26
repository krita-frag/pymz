//! Built-in MicroPython backend adapter (architecture skeleton).
//!
//! This is intentionally a thin re-export of the `runtime/micropython.zig`
//! placeholder. It lets `pymz_core` recognize `--runtime micropython` and
//! compile extension modules through the same multi-backend pipeline as
//! CPython and PyPy.
//!
//! A production MicroPython backend would replace the runtime implementation
//! with real `py/dynruntime.h` bindings and a `mpy_init` module entry point.

const contract = @import("../backend.zig");
const mp = @import("../runtime/micropython.zig");

pub const Error = mp.Error;
pub const Result = mp.Result;
pub const ExceptionBase = mp.ExceptionBase;
pub const Exception = mp.Exception;
pub const Object = mp.Object;
pub const Type = mp.Type;
pub const Buffer = mp.Buffer;
pub const Str = mp.Str;
pub const Bytes = mp.Bytes;
pub const ByteArray = mp.ByteArray;
pub const none = mp.none;
pub const boolean = mp.boolean;
pub const Int = mp.Int;
pub const Float = mp.Float;
pub const Bool = mp.Bool;
pub const Tuple = mp.Tuple;
pub const List = mp.List;
pub const Dict = mp.Dict;
pub const Set = mp.Set;
pub const FrozenSet = mp.FrozenSet;
pub const Slice = mp.Slice;
pub const Args = mp.Args;
pub const Module = mp.Module;
pub const ModuleInitFn = mp.ModuleInitFn;
pub const Repr = mp.Repr;
pub const ClassDef = mp.ClassDef;
pub const FnMode = mp.FnMode;
pub const function = mp.function;
pub const kwFunction = mp.kwFunction;
pub const positionalFunction = mp.positionalFunction;
pub const varargsFunction = mp.varargsFunction;
pub const class = mp.class;
pub const classWithBase = mp.classWithBase;
pub const exception = mp.exception;
pub const constant = mp.constant;
pub const module = mp.module;
pub const RawArgs = mp.RawArgs;
pub const py_major = mp.py_major;
pub const py_minor = mp.py_minor;
pub const py_hex = mp.py_hex;
pub const is_py3 = mp.is_py3;
pub const is_py2 = mp.is_py2;
pub const versionAtLeast = mp.versionAtLeast;
pub const convert = mp.convert;
pub const ThreadState = mp.ThreadState;
pub const GILState = mp.GILState;
pub const isInitialized = mp.isInitialized;
pub const initialize = mp.initialize;
pub const finalize = mp.finalize;
pub const saveThread = mp.saveThread;
pub const restoreThread = mp.restoreThread;
pub const threadStateGet = mp.threadStateGet;
pub const GIL = mp.GIL;

pub const is_limited_api = mp.is_limited_api;

pub fn backendSpec() contract.BackendSpec {
    return mp.backendSpec();
}

pub fn Backend() type {
    return @This();
}
