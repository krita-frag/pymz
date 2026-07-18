const std = @import("std");
const tool = @import("tool.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try tool.run(init.gpa, init.io, init.minimal.environ, args);
}
