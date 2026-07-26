//! Public Python-facing namespace.
//!
//! Keep this module small. Value helpers live in `py/value.zig`, declaration
//! helpers live in `py/decl.zig`, and backend selection stays in `interface.zig`.

pub const value = @import("py/value.zig");
pub const decl = @import("py/decl.zig");

pub const backend = value.backend;
