//! 公共平台表层，作为 `pymz.platform` 重新导出。
//!
//! 为终端用户代码暴露 `is_limited()` / `is_limited_api`（例如项目根据 pymz
//! 是否针对稳定 ABI 构建来切换行为）。该值通过 `pymz_backend` 模块从活跃
//! 后端的 `backendSpec().capabilities` 派生。
//!
//! 声明式描述符内部使用的 `isActiveForPlatform` 和 `is_limited_api` 位于
//! `runtime/cpython/limiter.zig` 中，由 `pymz_options` 构建标志驱动。
//! 将两个表层分开可避免跨模块文件导入，这在 Zig 0.16 的单文件拥有者规则下
//! 会导致冲突（运行时文件属于 `pymz_backend` 模块，本文件属于 `pymz` 模块）。

const backend = @import("pymz_backend");

const spec = backend.backendSpec();

pub const is_limited_api: bool = spec.capabilities.stable_abi;

/// 活跃后端是否针对稳定（有限）CPython ABI。
pub fn is_limited() bool {
    return is_limited_api;
}
