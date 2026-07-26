//! pymz: backend-aware Zig bindings for Python-family runtimes.

pub const py = @import("py.zig");
pub const platform = @import("platform.zig");

/// Re-exported from the `pymz_contract` module (whose root is `contract.zig`,
/// the contract file) so downstream tooling such as `pymz-tool` can access
/// `RuntimeId` without importing the full `pymz_backend` module. `contract.zig`
/// is standalone (only imports `std`), and routing through the `pymz_contract`
/// indirection keeps it owned by a single module so the `pymz` and
/// `pymz_backend` modules can coexist in one compilation.
pub const RuntimeId = @import("pymz_contract").RuntimeId;
pub const RuntimeInfo = @import("pymz_contract").RuntimeInfo;
pub const runtimeInfo = @import("pymz_contract").runtimeInfo;
