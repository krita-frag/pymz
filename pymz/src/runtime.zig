//! Runtime backend registry.

pub const cpython2 = @import("runtime/cpython2.zig");
pub const cpython3 = @import("runtime/cpython3.zig");

pub const Kind = enum {
    cpython2,
    cpython3,
};
