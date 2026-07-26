//! CPython runtime backend.

const c_mod = @import("cpython/c.zig");
const errors = @import("cpython/errors.zig");
const object = @import("cpython/object.zig");
const types = @import("cpython/types.zig");
const module_mod = @import("cpython/module.zig");
const class_mod = @import("cpython/class.zig");
const version = @import("cpython/version.zig");
const declarative = @import("cpython/declarative.zig");
const convert_mod = @import("cpython/convert.zig");

pub const c = c_mod.c;

pub const Error = errors.Error;
pub const Result = errors.Result;
pub const ExceptionBase = errors.ExceptionBase;
pub const Exception = errors.Exception;

pub const Object = object.Object;
pub const Type = object.Type;
pub const Buffer = object.Buffer;
pub const Str = object.Str;
pub const Bytes = object.Bytes;
pub const ByteArray = object.ByteArray;
pub const none = object.returnNone;
pub const boolean = object.returnBool;

pub const Int = types.Int;
pub const Float = types.Float;
pub const Bool = types.Bool;
pub const Tuple = types.Tuple;
pub const List = types.List;
pub const Dict = types.Dict;
pub const Set = types.Set;
pub const FrozenSet = types.FrozenSet;
pub const Slice = types.Slice;

pub const Args = module_mod.Args;
pub const Module = module_mod.Module;
pub const ModuleInitFn = module_mod.ModuleInitFn;

pub const Repr = class_mod.Repr;
pub const ClassDef = class_mod.ClassDef;

pub const FnMode = declarative.FnMode;
pub const function = declarative.function;
pub const kwFunction = declarative.kwFunction;
pub const positionalFunction = declarative.positionalFunction;
pub const varargsFunction = declarative.varargsFunction;
pub const class = declarative.class;
pub const classWithBase = class_mod.classWithBase;
pub const exception = declarative.exception;
pub const constant = declarative.constant;
pub const module = declarative.module;

pub const RawArgs = module_mod.RawArgs;

pub const py_major = version.py_major;
pub const py_minor = version.py_minor;
pub const py_hex = version.py_hex;
pub const is_py3 = version.is_py3;
pub const is_py2 = version.is_py2;
pub const versionAtLeast = version.versionAtLeast;

pub const convert = convert_mod;

pub const ThreadState = c.PyThreadState;
pub const GILState = c.PyGILState_STATE;

pub fn isInitialized() bool {
    return c.Py_IsInitialized() != 0;
}

pub fn initialize() void {
    c.Py_Initialize();
}

pub fn finalize() void {
    c.Py_Finalize();
}

pub fn saveThread() ?*ThreadState {
    return c.PyEval_SaveThread();
}

pub fn restoreThread(state: ?*ThreadState) void {
    c.PyEval_RestoreThread(state);
}

pub fn threadStateGet() ?*ThreadState {
    if (@hasDecl(c, "PyGILState_Check")) {
        if (c.PyGILState_Check() == 0) return null;
    }
    if (@hasDecl(c, "PyThreadState_Get")) {
        return c.PyThreadState_Get();
    }
    return null;
}

pub const GIL = struct {
    pub fn ensure() GILState {
        return c.PyGILState_Ensure();
    }

    pub fn release(state: GILState) void {
        c.PyGILState_Release(state);
    }

    pub fn held() bool {
        return threadStateGet() != null;
    }

    pub const Guard = struct {
        state: GILState,
        released: bool = false,

        pub fn release(self: *Guard) void {
            if (self.released) return;
            GIL.release(self.state);
            self.* = undefined;
        }

        pub fn deinit(self: *Guard) void {
            self.release();
        }
    };

    pub fn acquire() Guard {
        return .{ .state = ensure() };
    }
};
