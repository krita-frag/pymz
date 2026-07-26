//! Default backend entrypoint for `@import("pymz_backend")`.
//!
//! Projects can override this module with `-Dpymz-backend-source` to supply a
//! different backend implementation without changing the core build logic.

const std = @import("std");
const options = @import("pymz_options");
const contract = @import("backend.zig");

const backend = blk: {
    if (@hasDecl(options, "runtime")) {
        if (std.mem.eql(u8, options.runtime, "headless")) {
            break :blk @import("backends/headless.zig");
        }
    }
    break :blk @import("backends/cpython.zig");
};

pub fn backendSpec() contract.BackendSpec {
    return backend.backendSpec();
}

pub fn Backend() type {
    return backend.Backend();
}
