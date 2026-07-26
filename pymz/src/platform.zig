//! Public platform surface re-exported as `pymz.platform`.
//!
//! Exposes `is_limited()` / `is_limited_api` for end-user code (e.g. a project
//! gating behavior on whether pymz was built against the stable ABI). The
//! value is derived from the active backend's `backendSpec().capabilities`
//! via the `pymz_backend` module.
//!
//! The runtime-internal `isActiveForPlatform` and `is_limited_api` consumed by
//! the declarative descriptors live in `runtime/cpython/limiter.zig` instead,
//! driven by the `pymz_options` build flag. Keeping the two surfaces separate
//! avoids a cross-module file import that would conflict under Zig 0.16's
//! single-owner file rule (the runtime files belong to the `pymz_backend`
//! module; this file belongs to the `pymz` module).

const backend = @import("pymz_backend");

const spec = backend.backendSpec();

pub const is_limited_api: bool = spec.capabilities.stable_abi;

/// True when the active backend targets the stable (limited) CPython ABI.
pub fn is_limited() bool {
    return is_limited_api;
}
