//! pymz: backend-aware Zig bindings for Python-family runtimes.

const std = @import("std");

pub const backend = @import("interface.zig");
pub const py = @import("py.zig");

comptime {
    _ = std;
}
