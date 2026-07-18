const std = @import("std");

const example_dep_names: []const []const u8 = &.{
    "jsonz",
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    for (example_dep_names) |example_dep_name| {
        const example_dep = b.dependency(example_dep_name, .{
            .optimize = optimize,
        });
        b.getInstallStep().dependOn(example_dep.builder.getInstallStep());
    }
}
