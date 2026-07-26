//! Test aggregator entry point.
//!
//! Thin wrapper that imports the actual test modules via anonymous imports
//! configured in `build.zig`. This isolates `src/` internals from the test
//! module root so that relative imports within `src/` continue to work.

comptime {
    _ = @import("core_tests");
    _ = @import("backend_contract.zig");
}
