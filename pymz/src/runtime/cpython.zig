//! CPython runtime backend.

const c_mod = @import("cpython/c.zig");
const errors = @import("cpython/errors.zig");
const object = @import("cpython/object.zig");
const types = @import("cpython/types.zig");
const module_mod = @import("cpython/module.zig");
const class_mod = @import("cpython/class.zig");
const version = @import("cpython/version.zig");
const declarative = @import("cpython/declarative.zig");

pub const c = c_mod.c;

pub const Error = errors.Error;
pub const Result = errors.Result;
pub const ExceptionBase = errors.ExceptionBase;
pub const Exception = errors.Exception;

pub const Value = object.Object;
pub const Object = object.Object;
pub const Type = object.Type;
pub const Str = object.Str;
pub const Bytes = object.Bytes;
pub const none = object.returnNone;
pub const boolean = object.returnBool;

pub const Int = types.Int;
pub const Float = types.Float;
pub const Bool = types.Bool;
pub const Tuple = types.Tuple;
pub const List = types.List;
pub const Dict = types.Dict;

pub const Args = module_mod.Args;

pub const Repr = class_mod.Repr;

pub const FnMode = declarative.FnMode;
pub const function = declarative.function;
pub const kwFunction = declarative.kwFunction;
pub const class = declarative.class;
pub const exception = declarative.exception;
pub const module = declarative.module;

pub const py_major = version.py_major;
pub const py_minor = version.py_minor;
pub const py_hex = version.py_hex;
pub const is_py3 = version.is_py3;
pub const is_py2 = version.is_py2;
pub const versionAtLeast = version.versionAtLeast;
