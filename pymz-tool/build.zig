const std = @import("std");
const builtin = @import("builtin");

// The public build-helper API lives directly in `main.zig`. Importing it
// here re-exports `buildProject` and its option/struct types to consumers that
// reach pymz-tool through `b.dependency("pymz-tool", .{}).builder`.
pub const core = @import("src/main.zig");

pub fn build(b: *std.Build) void {
    // Windows 默认 native 目标为 x86_64-windows-gnu（需 MinGW CRT），与部署的
    // CPython/Conan 构建不一致；默认用 msvc ABI，显式 `-Dtarget=...` 优先。
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .windows) .{ .abi = .msvc } else .{},
    });
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
