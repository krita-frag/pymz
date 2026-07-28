//! `@import("pymz_backend")` 的默认后端入口。
//!
//! 项目可通过 `-Dpymz-backend-source` 覆盖此模块，以提供不同的后端实现，
//! 无需修改核心构建逻辑。
//!
//! 后端分发使用 `contract.zig` 中的规范 `RuntimeId` 表（运行时标识的唯一
//! 真相源），而非临时字符串前缀检查，因此只有在该表中注册的运行时才能被
//! 选中。未知的运行时会在编译期报错，指向违规值。
//!
//! 内置的 CPython 后端适配器直接合并到此文件中：它从 `runtime/cpython.zig`
//! 重新导出 CPython 运行时声明，并暴露 `backendSpec()`/`Backend()`，使
//! 消费者可通过 `pymz_backend` 模块间接访问 CPython 对象模型。

const std = @import("std");
// 契约类型通过 `pymz_contract` 匿名模块传入（其根文件为 `contract.zig`）。
// 使用此间接引用（而非直接 `@import("contract.zig")`）保持 `contract.zig`
// 被单个模块拥有，使 `pymz` 模块（其根文件 `pymz.zig` 也引用 `contract.zig`）
// 和 `pymz_backend` 模块可在同一编译中共存。
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
pub const builtin_runtime_ids = contract.builtin_runtime_ids;
pub const allRuntimeInfos = contract.allRuntimeInfos;
pub const runtimeInfoFromString = contract.runtimeInfoFromString;

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

// CPython 后端处理所有 cpython* 运行时。`custom` 运行时需要通过
// `-Dpymz-backend-source` 提供单独的后端模块。
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
    // 在将后端类型交给调用方之前，在编译期验证其是否满足声明的能力。
    // 在此处（而非单独的 shim 中）执行检查，让声明层可直接导入本模块，
    // 并为后端就绪状态保持单一真相源。
    const backend_type = @This();
    contract.validateBackend(backend_type, backendSpec().capabilities);
    return backend_type;
}
