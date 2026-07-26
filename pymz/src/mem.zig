//! Memory allocation and ownership conventions for pymz.
//!
//! By default pymz uses the C allocator so that allocations made on the Zig
//! side can be freed by Python and vice versa.  Tests may override this via
//! `setAllocator()` before creating Python objects.
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
///
/// Defaults to `std.heap.c_allocator`, which is required for CPython extension
/// code because allocations made on the Zig side may be freed by Python (via
/// `free()` from libc) and vice versa.
///
/// Tests can override this with a debug allocator (e.g.
/// `std.heap.GeneralPurposeAllocator`) by calling `setAllocator()` at the
/// start of the test runner. The allocator MUST be set before any Python
/// objects are created and MUST NOT be changed afterwards.
pub var allocator: std.mem.Allocator = std.heap.c_allocator;

/// Override the global allocator. Only makes sense at startup (e.g. in a test
/// runner) before any pymz objects have been allocated.
pub fn setAllocator(alloc: std.mem.Allocator) void {
    allocator = alloc;
}
