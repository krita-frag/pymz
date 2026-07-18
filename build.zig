const std = @import("std");

pub fn build(b: *std.Build) void {
    const check_step = b.step("check", "Validate the workspace packages");
    if (b.lazyDependency("examples", .{})) |examples_dep| {
        check_step.dependOn(examples_dep.builder.getInstallStep());
    }
    b.default_step.dependOn(check_step);
}
