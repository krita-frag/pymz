//! pymz：面向 Python 系列运行时的 Zig 绑定库，支持多后端感知。

pub const py = @import("py.zig");
pub const platform = @import("platform.zig");

/// 从 `pymz_contract` 模块（其根文件为 `contract.zig`，即契约文件）重新导出，
/// 使下游工具（如 `pymz-tool`）可在不导入完整 `pymz_backend` 模块的情况下访问
/// `RuntimeId`。`contract.zig` 是自包含的（仅导入 `std`），通过 `pymz_contract`
/// 间接引用保持其被单个模块拥有，使 `pymz` 和 `pymz_backend` 模块可在同一编译中
/// 共存。
pub const RuntimeId = @import("pymz_contract").RuntimeId;
pub const RuntimeInfo = @import("pymz_contract").RuntimeInfo;
pub const runtimeInfo = @import("pymz_contract").runtimeInfo;
pub const builtin_runtime_ids = @import("pymz_contract").builtin_runtime_ids;
pub const allRuntimeInfos = @import("pymz_contract").allRuntimeInfos;
pub const runtimeInfoFromString = @import("pymz_contract").runtimeInfoFromString;
