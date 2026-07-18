//! pymz: multi-version Python C API bindings for Zig.
//!
//! This library uses Zig's comptime and @cImport to directly wrap the Python C API
//! and produces compatible code for Python 2.7 and Python 3.x from a single source.

const std = @import("std");

// Re-export the low-level C namespace.
pub const c = @import("c.zig").c;

// Version detection.
const version = @import("version.zig");
pub const py_major = version.py_major;
pub const py_minor = version.py_minor;
pub const py_hex = version.py_hex;
pub const is_py3 = version.is_py3;
pub const is_py2 = version.is_py2;
pub const versionAtLeast = version.versionAtLeast;

// Errors.
const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const PyResult = errors.PyResult;
pub const errorOccurred = errors.errorOccurred;
pub const errorClear = errors.errorClear;
pub const errorPrint = errors.errorPrint;
pub const typeError = errors.typeError;
pub const valueError = errors.valueError;
pub const systemError = errors.systemError;
pub const errorFormat = errors.errorFormat;
pub const typeErrorValue = errors.typeErrorValue;

// Core object protocol and basic types.
const object = @import("object.zig");
pub const Object = object.Object;
pub const Type = object.Type;
pub const Str = object.Str;
pub const Bytes = object.Bytes;
pub const None = object.None;
pub const True = object.True;
pub const False = object.False;
pub const returnNone = object.returnNone;
pub const returnBool = object.returnBool;
pub const returnOptional = object.returnOptional;

// Numeric and collection types.
const types = @import("types.zig");
pub const Int = types.Int;
pub const Tuple = types.Tuple;
pub const List = types.List;
pub const Dict = types.Dict;
pub const Module = types.Module;

// Method / module initialization.
const module = @import("module.zig");
pub const MethodFlags = module.MethodFlags;
pub const MethodDef = module.MethodDef;
pub const sentinel = module.sentinel;
pub const method = module.method;
pub const pyfn = module.pyfn;
pub const Args = module.Args;
pub const ModuleInitFn = module.ModuleInitFn;
pub const moduleInit = module.moduleInit;

// Conversion helpers.
const convert = @import("convert.zig");
pub const toObject = convert.toObject;

// Traits.
const traits = @import("traits.zig");
pub const isObjectPtr = traits.isObjectPtr;
pub const isObjectPtrOptional = traits.isObjectPtrOptional;

// Stub generation.
const stubs = @import("stubs.zig");
pub const Stub = stubs.Stub;
pub const generateStubs = stubs.generate;
pub const funcStub = stubs.func;
pub const constantStub = stubs.constant;

comptime {
    _ = std;
}
