//! CPython 2 backend facade.

const common = @import("cpython.zig");

comptime {
    if (!common.is_py2) {
        @compileError("runtime cpython2 requires Python 2.x headers");
    }
}

pub const c = common.c;

pub const Error = common.Error;
pub const Result = common.Result;
pub const ExceptionBase = common.ExceptionBase;
pub const Exception = common.Exception;

pub const Value = common.Value;
pub const Object = common.Object;
pub const Type = common.Type;
pub const Str = common.Str;
pub const Bytes = common.Bytes;

pub const Int = common.Int;
pub const Float = common.Float;
pub const Bool = common.Bool;
pub const Tuple = common.Tuple;
pub const List = common.List;
pub const Dict = common.Dict;

pub const Repr = common.Repr;

pub const Args = common.Args;
pub const FnMode = common.FnMode;

pub const py_major = common.py_major;
pub const py_minor = common.py_minor;
pub const py_hex = common.py_hex;
pub const is_py3 = common.is_py3;
pub const is_py2 = common.is_py2;
pub const versionAtLeast = common.versionAtLeast;

pub const none = common.none;
pub const boolean = common.boolean;

pub const function = common.function;
pub const kwFunction = common.kwFunction;
pub const class = common.class;
pub const exception = common.exception;
pub const module = common.module;
