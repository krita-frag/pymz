//! Public Python-facing namespace.
//!
//! Keep this module small. Value helpers live in `py/value.zig`, declaration
//! helpers live in `py/decl.zig`, and backend selection lives in the
//! `pymz_backend` module (imported directly by `py/*`).
//!
//! Note: class-related types (`ClassDef`, `Wrapper`, `unwrap*`, ...)
//! are deliberately NOT re-exported from a `py.class` submodule here. The
//! backend exposes them through the `Backend()` type, and `py.value` /
//! `py.decl` already re-export the subset that is part of the public API
//! (`ClassDef` via `backend.ClassDef`, the class declaration function via
//! `backend.class`). Reaching directly into `runtime/cpython/class.zig` would
//! bypass the backend abstraction and break the "one syntax, multiple
//! backends" contract.

pub const value = @import("py/value.zig");
pub const decl = @import("py/decl.zig");

pub const backend = value.backend;
