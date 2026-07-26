//! Python version detection helpers.

const std = @import("std");
const c = @import("c.zig").c;
const options = @import("pymz_options");

pub const py_major = c.PY_MAJOR_VERSION;
pub const py_minor = c.PY_MINOR_VERSION;
pub const py_hex = c.PY_VERSION_HEX;

pub const is_py3 = py_major >= 3;
pub const is_py2 = py_major == 2;

/// True when the selected runtime is the CPython stable ABI (limited API).
pub const is_limited_api = std.mem.eql(u8, options.runtime, "cpython3-limited");

pub inline fn versionAtLeast(comptime major: u32, comptime minor: u32) bool {
    const need = (major << 24) | (minor << 16);
    return py_hex >= need;
}
