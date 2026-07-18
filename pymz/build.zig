const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("pymz", .{
        .root_source_file = b.path("src/pymz.zig"),
    });
}
