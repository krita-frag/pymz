//! CPython runtime backend.

const std = @import("std");
const errors = @import("cpython/errors.zig");
const object = @import("cpython/object.zig");
const types = @import("cpython/types.zig");
const module_mod = @import("cpython/module.zig");
const class_mod = @import("cpython/class/class_builder.zig");
const version = @import("cpython/version.zig");
const convert_mod = @import("cpython/convert.zig");
const decl_common = @import("cpython/declarative/common.zig");
const decl_function = @import("cpython/declarative/function.zig");
const decl_class = @import("cpython/declarative/class.zig");
const decl_exception = @import("cpython/declarative/exception.zig");
const decl_constant = @import("cpython/declarative/constant.zig");
const decl_module = @import("cpython/declarative/module.zig");

pub const c = @import("python_c");

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
pub const unicodeFromSlice = object.unicodeFromSlice;
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

pub const ClassDef = class_mod.ClassDef;

pub const FnMode = decl_common.FnMode;
pub const function = decl_function.function;
pub const kwFunction = decl_function.kwFunction;
pub const positionalFunction = decl_function.positionalFunction;
pub const varargsFunction = decl_function.varargsFunction;
pub const class = decl_class.class;
pub const classWithBase = decl_class.classWithBase;
pub const exception = decl_exception.exception;
pub const constant = decl_constant.constant;
pub const module = decl_module.module;

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

/// Token representing that the current thread holds the GIL.
///
/// **Status: runtime convention, not a compile-time-enforced guarantee.** The
/// pymz runtime APIs (`Str.fromSlice`, `convert.toPy`, `Int.from`, etc.) do
/// *not* currently require a `Python` token in their signatures, so the type
/// system does not prevent calls from a thread that has released the GIL.
/// Callers are responsible for ensuring the GIL is held before invoking any
/// pymz API that touches the interpreter; use `GIL.acquire()` /
/// `GIL.ensure()` to obtain the token and `GIL.held()` / `GIL.assertHeld()`
/// for runtime checks.
///
/// The token exists so that future API hardening can thread it through
/// signatures incrementally without changing the token's shape. Code that
/// already takes a `Python` parameter documents its GIL requirement at the
/// type level; code that does not is still correct as long as the caller
/// holds the GIL.
pub const Python = struct {
    // The opaque GIL state saved by `PyGILState_Ensure`. The token cannot be
    // constructed by user code, so possession of a `Python` value proves (to
    // code that chooses to require it) that the thread currently holds the GIL.
    _gil_state: GILState,
};

pub const GIL = struct {
    pub fn ensure() Python {
        return .{ ._gil_state = c.PyGILState_Ensure() };
    }

    pub fn release(token: Python) void {
        c.PyGILState_Release(token._gil_state);
    }

    pub fn held() bool {
        return threadStateGet() != null;
    }

    /// Assert at runtime that the GIL is held. Useful inside functions that
    /// accept a `Python` token but want an extra sanity check in debug builds.
    pub fn assertHeld(_: Python) void {
        std.debug.assert(held());
    }

    pub const Guard = struct {
        python: Python,
        released: bool = false,

        pub fn release(self: *Guard) void {
            if (self.released) return;
            GIL.release(self.python);
            self.* = undefined;
        }

        pub fn deinit(self: *Guard) void {
            self.release();
        }
    };

    /// Acquire the GIL and return both a scoped guard and a `Python` token.
    /// The guard releases the GIL when it goes out of scope; the token can be
    /// passed to APIs that require proof of GIL ownership.
    pub fn acquire() Guard {
        return .{ .python = ensure() };
    }
};
