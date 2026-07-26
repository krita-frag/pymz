//! Memory allocation and ownership conventions for pymz.
//!
//! By default pymz uses the C allocator so that allocations made on the Zig
//! side can be freed by Python and vice versa.  Users may override this with
//! any allocator by calling `pymz.setAllocator` before creating Python objects.
//!
//! Ownership conventions used throughout pymz:
//!
//!   * `*Object` returned by a `pymz` helper (e.g. `pymz.string`,
//!     `pymz.integer`) is a **new reference**.  The caller owns it and must
//!     call `.decref()` when done, or transfer ownership back to Python.
//!
//!   * `*Object` returned by `Object.newref()` is a **new reference** created
//!     by incrementing the reference count of an existing object.
//!
//!   * `*Object` borrowed from a container (e.g. `Object.sequenceGet`,
//!     `Dict.get`) is a **borrowed reference**.  It remains valid only as long
//!     as the container is alive.  Do NOT call `.decref()` on a borrowed
//!     reference unless you have explicitly incremented its refcount.
//!
//!   * `[]const u8` extracted from a Python `str`/`bytes` by `fromPy` is a
//!     **borrowed buffer**.  It points into the Python object's internal storage
//!     and becomes invalid when that object is freed.  If the data must outlive
//!     the Python object, copy it with the configured allocator.
//!
//!   * `[]u8` extracted from Python `bytes`/`bytearray` by `fromPy` is an
//!     **owned copy**.  The caller must free it with `pymz.mem.allocator.free`
//!     when done.
//!
//!   * Zig struct fields that hold Python references must keep those objects
//!     alive (e.g. by storing `*Object` and incrementing the refcount) and must
//!     implement `__del__` or GC traversal to release them.

const std = @import("std");

/// The allocator used for all pymz-internal allocations.
pub var allocator: std.mem.Allocator = std.heap.c_allocator;

/// Zero-sized marker type for documentation: a new-reference `*Object`.
/// Functions accepting or returning this type transfer ownership to the caller.
pub const Owned = struct {};

/// Zero-sized marker type for documentation: a borrowed `*Object` or slice.
/// The resource remains owned by the source and is only valid while the source
/// is alive.
pub const Borrowed = struct {};

/// Replace the allocator used by pymz.  Must be called before any pymz
/// function that may allocate memory.  The allocator must remain valid for the
/// lifetime of the Python interpreter process.
pub fn setAllocator(new_allocator: std.mem.Allocator) void {
    allocator = new_allocator;
}
