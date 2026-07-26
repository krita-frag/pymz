//! Test aggregator for pymz-tool core modules.
//!
//! `core/cross.zig` and `core/python_config.zig` own comptime-safe test blocks
//! that run under `zig build test`. The CLI/wheel/config features are
//! implemented in pure Python and exercised by the `tests/` pytest suite.

const cross = @import("core/cross.zig");
const python_config = @import("core/python_config.zig");

comptime {
    _ = cross;
    _ = python_config;
}
