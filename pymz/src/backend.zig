//! Default backend entrypoint for `@import("pymz_backend")`.
//!
//! Projects can override this module with `-Dpymz-backend-source` to supply a
//! different backend implementation without changing the core build logic.
//!
//! Backend dispatch uses the canonical `RuntimeId` table from `contract.zig`
//! (the single source of truth for runtime identity) rather than an ad-hoc
//! string-prefix check, so only runtimes registered in that table can be
//! selected. Unknown runtimes produce a compile error pointing at the
//! offending value.
//!
//! The built-in CPython backend adapter is merged directly into this file:
//! it re-exports the CPython runtime declarations from `runtime/cpython.zig`
//! and exposes `backendSpec()`/`Backend()` so consumers can reach the
//! CPython object model through the `pymz_backend` module indirection.

const std = @import("std");
// The contract types come through the `pymz_contract` anonymous module whose
// root is `contract.zig`. Using this indirection (instead of a direct
// `@import("contract.zig")`) keeps `contract.zig` owned by a single module, so
// the `pymz` module (whose root `pymz.zig` also references `contract.zig`) and
// the `pymz_backend` module can coexist in one compilation.
const contract = @import("pymz_contract");
const options = @import("pymz_options");
const version = @import("runtime/cpython/version.zig");
const cpython = @import("runtime/cpython.zig");

pub const BackendSpec = contract.BackendSpec;
pub const Capabilities = contract.Capabilities;
pub const RuntimeModel = contract.RuntimeModel;
pub const ArtifactFormat = contract.ArtifactFormat;
pub const validateBackend = contract.validateBackend;
pub const RuntimeId = contract.RuntimeId;
pub const RuntimeInfo = contract.RuntimeInfo;
pub const runtimeInfo = contract.runtimeInfo;

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
pub const unicodeFromSlice = cpython.unicodeFromSlice;
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

const runtime_id = contract.RuntimeId.fromString(options.runtime) catch
    @compileError("unknown pymz runtime: " ++ options.runtime);

// The CPython backend handles every cpython* runtime. The `custom` runtime
// requires a separate backend module supplied via `-Dpymz-backend-source`.
comptime {
    switch (runtime_id) {
        .cpython2, .cpython3, .cpython3_limited => {},
        .custom => @compileError(
            "runtime 'custom' requires -Dpymz-backend-source to point at a custom backend module",
        ),
    }
}

pub fn backendSpec() BackendSpec {
    const info = contract.runtimeInfo(runtime_id);

    return .{
        .name = info.name,
        .runtime_model = .cpython_extension,
        .artifact_format = .python_extension,
        .capabilities = info.capabilities,
    };
}

pub fn Backend() type {
    // Validate the backend against its declared capabilities at compile time
    // before handing the type to callers. Performing the check here (rather
    // than in a separate shim) lets the declarative layer import this module
    // directly and keeps a single source of truth for backend readiness.
    const backend_type = @This();
    contract.validateBackend(backend_type, backendSpec().capabilities);
    return backend_type;
}
