const std = @import("std");
const pymz_build = @import("pymz-build");

pub fn build(b: *std.Build) !void {
    try pymz_build.buildProject(b, .{
        .module_name = "_jsonz",
        .root_source_file = b.path("src/jsonz.zig"),
    });
}
