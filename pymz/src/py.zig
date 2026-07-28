//! 面向 Python 的公共命名空间。
//!
//! 保持本模块小巧。值辅助函数位于 `py/value.zig`，声明辅助函数位于
//! `py/decl.zig`，后端选择位于 `pymz_backend` 模块（由 `py/*` 直接导入）。
//!
//! 注意：类相关类型（`ClassDef`、`Wrapper`、`unwrap*` 等）有意不在此处
//! 通过 `py.class` 子模块重新导出。后端通过 `Backend()` 类型暴露它们，
//! `py.value` / `py.decl` 已重新导出属于公共 API 的子集（`ClassDef` 通过
//! `backend.ClassDef`，类声明函数通过 `backend.class`）。直接进入
//! `runtime/cpython/class.zig` 会绕过后端抽象，破坏"一套语法，多个后端"的契约。
//!
//! # GIL 约定（重要）
//!
//! pymz 的所有运行时 API（`v.string`、`v.integer`、`d.class` 包装的方法、
//! `convert.toPy` / `fromPy`、对象包装器的 `incref` / `decref` / `asInt` 等）
//! 都必须在持有 CPython 全局解释器锁（GIL）的线程中调用。在未持有 GIL 时
//! 调用任何 pymz API 都是**未定义行为**，可能导致 CPython 内部状态损坏或
//! 进程崩溃。
//!
//! 这是定位妥协：完全在类型系统层面强制 GIL 持有（例如 pyo3 的 `Python<'py>`
//! 生命周期令牌）会显著增加 API 噪音，与 pymz 的轻量定位不符。pymz 通过
//! `py.Python` 令牌类型和 `py.GIL` 命名空间（`acquire` / `ensure` / `release` /
//! `held` / `assertHeld` / `assertHeldByCurrentThread`）提供运行时辅助，
//! 但当前 API 签名不强制要求令牌参数——这是**运行时约定，非编译期保证**。
//! 用户可按需把 `py.Python` 令牌注入自己的函数签名作为编译期文档，
//! 并在函数体首行调用 `py.GIL.assertHeldByCurrentThread()` 做防御性检查。
//!
//! 调用方负责在以下场景中显式管理 GIL：
//!
//!   - 在 Zig 后台线程中调用任何 pymz API 前，必须 `py.GIL.ensure()` 持有 GIL，
//!     完成后 `py.GIL.release(token)`。可用 `py.GIL.acquire()` 获取作用域守卫。
//!   - 在长时间运行的 Zig 计算中，可用 `py.GIL.release()` 临时释放 GIL 让
//!     Python 其他线程运行，但释放期间不得调用任何 pymz API。
//!   - 模块初始化函数（`ModuleInitFn`）由 CPython 在持有 GIL 时调用，
//!     无需手动 acquire。
//!   - `PyMethodDef` 回调（即被 `d.function` / `d.class` 等导出的函数）
//!     由 CPython 在持有 GIL 时调用，无需手动 acquire。
//!
//! 详见 `py.Python` 令牌类型和 `py.GIL` 命名空间的文档，其中包含三种
//! 推荐用法场景（后台线程 acquire、防御性 assertHeldByCurrentThread、
//! 令牌注入签名的 strict API 模式）。

pub const value = @import("py/value.zig");
pub const decl = @import("py/decl.zig");

pub const backend = value.backend;
