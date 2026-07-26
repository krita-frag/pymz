const std = @import("std");

pub const RuntimeId = @import("src/contract.zig").RuntimeId;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Register the `pymz` module so downstream packages (e.g. pymz-tool) can
    // consume it via `dep.module("pymz")`. The return value is not captured
    // because no further configuration is needed here.
    const pymz_module = b.addModule("pymz", .{
        .root_source_file = b.path("src/pymz.zig"),
        .target = target,
        .optimize = optimize,
    });
    // `pymz.zig` reaches the contract types (`RuntimeId`, ...) through the
    // `pymz_contract` anonymous module so `contract.zig` is owned by a single
    // module and can also be referenced from `backend.zig` without a
    // "file exists in two modules" conflict.
    pymz_module.addAnonymousImport("pymz_contract", .{
        .root_source_file = b.path("src/contract.zig"),
    });

    const test_step = b.step("test", "Run pymz unit tests");

    // The test module root points to `tests/tests.zig`, which is a thin
    // aggregator. Actual test-logic files live under `src/` where their
    // relative `@import` paths resolve correctly. Anonymous imports bridge
    // the two directories.
    const pymz_test_module = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Core test suite (src/tests.zig) — all comptime-safe tests live in a
    // single module.
    pymz_test_module.addAnonymousImport("core_tests", .{
        .root_source_file = b.path("src/tests.zig"),
    });
    // Contract (backend) tests (tests/backend_contract.zig).
    pymz_test_module.addAnonymousImport("pymz_contract", .{
        .root_source_file = b.path("src/contract.zig"),
    });
    // Inject the mock backend so test files and the declarative layer can
    // resolve the `pymz_backend` module import.
    const backend_mock = b.createModule(.{
        .root_source_file = b.path("tests/test_backend_mock.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mock.addAnonymousImport("contract", .{
        .root_source_file = b.path("src/contract.zig"),
    });
    pymz_test_module.addImport("pymz_backend", backend_mock);
    // `limiter.zig` (reached via the declarative descriptors and test
    // files) reads `is_limited_api` from the `pymz_options` build-options
    // module. The mock backend reports the full ABI, so pin `is_limited_api
    // = false`.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "runtime", "cpython3");
    test_options.addOption(bool, "is_limited_api", false);
    pymz_test_module.addOptions("pymz_options", test_options);

    const pymz_tests = b.addTest(.{
        .name = "pymz",
        .root_module = pymz_test_module,
    });
    const run_pymz_tests = b.addRunArtifact(pymz_tests);
    test_step.dependOn(&run_pymz_tests.step);
}
