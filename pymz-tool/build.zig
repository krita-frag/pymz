const std = @import("std");

// The public build-helper API lives directly in `main.zig`. Importing it
// here re-exports `buildProject` and its option/struct types to consumers that
// reach pymz-tool through `b.dependency("pymz-tool", .{}).builder`.
pub const core = @import("src/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pymz_dep = b.dependency("pymz", .{});

    // Unit tests for core/ modules (cross-compilation, python-config).
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("pymz", pymz_dep.module("pymz"));

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests for pymz-tool core");
    test_step.dependOn(&run_tests.step);
}
