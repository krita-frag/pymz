//! Build-time platform gating for the CPython runtime.
//!
//! `is_limited_api` is a *build-time selection* (whether pymz was configured
//! for the CPython stable ABI), not a C-header property. It is delivered
//! through the `pymz_options` build-options module so this file stays light:
//! it imports neither `python_c` (translated C headers) nor any file outside
//! the `pymz_backend` module tree. Keeping it light lets the declarative
//! descriptors and the version module reach `is_limited_api` /
//! `isActiveForPlatform` without a cross-module file import that would create
//! a "file exists in two modules" conflict under Zig 0.16.
//!
//! The public `pymz.platform` namespace (in the `pymz` module) still exports
//! `is_limited()` / `is_limited_api` for end users; it derives the value from
//! `backendSpec().capabilities.stable_abi` via the backend module. This file
//! is the path used *inside* the runtime.

const options = @import("pymz_options");

/// True when the selected runtime is the CPython stable ABI (limited API).
/// Driven by the build option so the value is a comptime constant everywhere
/// the runtime is compiled, with no runtime backends or C headers required.
pub const is_limited_api: bool = options.is_limited_api;

/// Returns true when a declaration with the given `limited` filter should be
/// active on the current platform.
///
/// `null` means "active on all platforms"; `true` means "limited ABI only";
/// `false` means "full ABI only". This is the single implementation used by
/// all declarative descriptors (class, function, constant, exception).
pub fn isActiveForPlatform(comptime limited: ?bool) bool {
    if (limited) |value| {
        return value == is_limited_api;
    }
    return true;
}
