//! CPython 运行时后端。

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

/// 表示当前线程持有 GIL 的令牌。
///
/// **状态：运行时约定，非编译期强制保证。** pymz 运行时 API（`Str.fromSlice`、`convert.toPy`、`Int.from` 等）
/// 当前*不*要求签名中包含 `Python` 令牌，因此类型系统无法阻止已释放 GIL 的线程调用。
/// 调用方有责任在调用任何涉及解释器的 pymz API 之前确保持有 GIL；
/// 使用 `GIL.acquire()` / `GIL.ensure()` 获取令牌，使用 `GIL.held()` /
/// `GIL.assertHeld()` / `GIL.assertHeldByCurrentThread()` 做运行时检查。
///
/// 该令牌的存在是为了让未来的 API 加固可以逐步将其注入签名，而无需改变令牌的形状。
/// 已经接受 `Python` 参数的代码在类型层面记录了其 GIL 要求；
/// 未接受的代码只要调用方持有 GIL 仍然正确。
///
/// ## 推荐用法
///
/// **场景 1：在 Zig 后台线程中调用 pymz API**
///
/// 后台线程默认不持有 GIL，必须显式 acquire：
///
///   var guard = py.GIL.acquire();
///   defer guard.deinit();
///   // 此处可安全调用 pymz API
///   const s = try py.string("hello");
///
/// **场景 2：在函数入口断言 GIL 已被持有（防御性检查）**
///
/// 对于不接收 `Python` 令牌但理论上应被 GIL 持有线程调用的函数：
///
///   fn my_helper() void {
///       py.GIL.assertHeldByCurrentThread();  // Debug 构建触发，Release 构建零开销
///       // ...
///   }
///
/// **场景 3：把 `Python` 令牌注入函数签名（编译期文档）**
///
/// 让函数签名本身记录 GIL 要求，并在 Debug 构建中双重检查：
///
///   fn my_strict_api(py: py.Python) void {
///       py.GIL.assertHeld();  // 令牌存在即证明 GIL 已持有，断言是双保险
///       // ...
///   }
///
/// 调用方需先 acquire 令牌再传入：
///
///   var guard = py.GIL.acquire();
///   defer guard.deinit();
///   my_strict_api(guard.python);
pub const Python = struct {
    // `PyGILState_Ensure` 保存的不透明 GIL 状态。用户代码无法构造此令牌，
    // 因此持有 `Python` 值即可证明（对那些选择要求它的代码而言）当前线程持有 GIL。
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

    /// 运行时断言 GIL 已被持有。适用于接受 `Python` 令牌的函数，在调试构建中增加额外检查。
    ///
    /// 令牌存在本身已证明 GIL 被持有，本断言是双保险：捕获令牌被错误复用
    /// （例如跨线程传递后原线程已释放 GIL）的边界情况。
    pub fn assertHeld(_: Python) void {
        std.debug.assert(held());
    }

    /// 运行时断言当前线程持有 GIL。适用于不接收 `Python` 令牌的函数，
    /// 在 Debug/ReleaseSafe 构建中触发断言，ReleaseFast 构建中仍有
    /// `PyGILState_Check` 调用开销但断言指令被移除。
    ///
    /// 与 `assertHeld(_: Python)` 的区别：本函数无需令牌参数，用于函数入口
    /// 的防御性检查；`assertHeld(_: Python)` 用于已持有令牌的双重保险。
    ///
    /// 实现委托给 `errors.assertGILHeldByCurrentThread`，这是 GIL 断言的
    /// 单一真相源。子模块（object.zig、convert.zig）的关键 API 入口也调用
    /// 同一函数，避免重复 `@hasDecl(c, "PyGILState_Check")` 检查和循环依赖。
    pub fn assertHeldByCurrentThread() void {
        errors.assertGILHeldByCurrentThread();
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

    /// 获取 GIL 并返回作用域守卫和 `Python` 令牌。
    /// 守卫在离开作用域时释放 GIL；令牌可传递给需要 GIL 持有证明的 API。
    pub fn acquire() Guard {
        return .{ .python = ensure() };
    }
};
