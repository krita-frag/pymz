//! Python version detection helpers.
//!
//! `py_major`, `py_minor`, `py_hex`, `is_py3`, `is_py2` and `versionAtLeast`
//! are derived from the CPython C headers (`PY_MAJOR_VERSION` etc.) and reflect
//! the interpreter actually being linked against.
//!
//! `is_limited_api` is a *runtime selection* (whether pymz was configured for
//! the CPython stable ABI), not a C-header property. It is re-exported here
//! from `limiter.zig`, which reads the build-time `pymz_options.is_limited_api`
//! flag. Routing through `limiter.zig` (same module tree) instead of
//! `../../platform.zig` (the `pymz` module's file) avoids a cross-module file
//! import that would conflict under Zig 0.16's single-owner file rule.

const std = @import("std");
const c = @import("python_c");
const limiter = @import("limiter.zig");

pub const py_major = c.PY_MAJOR_VERSION;
pub const py_minor = c.PY_MINOR_VERSION;
pub const py_hex = c.PY_VERSION_HEX;

pub const is_py3 = py_major >= 3;
pub const is_py2 = py_major == 2;

/// True when the selected runtime is the CPython stable ABI (limited API).
/// Re-exported from `limiter.is_limited_api`, which reads the build option.
pub const is_limited_api = limiter.is_limited_api;

/// PEP 489 multi-phase module initialization is available on all Python 3.x.
pub const has_pep489 = is_py3;

/// Python 3.12+: `PyType_FromMetaclass` allows creating types with custom
/// metaclasses via the PyType_Spec / PyType_Slot API path.
pub const has_pytype_from_metaclass = is_py3 and versionAtLeast(3, 12);

pub inline fn versionAtLeast(comptime major: u32, comptime minor: u32) bool {
    const need = (major << 24) | (minor << 16);
    return py_hex >= need;
}
