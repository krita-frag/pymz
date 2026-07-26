const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_step = b.step("check", "Validate the workspace packages");
    if (b.lazyDependency("examples", .{})) |examples_dep| {
        check_step.dependOn(examples_dep.builder.getInstallStep());
    }
    b.default_step.dependOn(check_step);

    const test_step = b.step("test", "Run package checks, unit tests, and build examples");
    test_step.dependOn(check_step);
    if (b.lazyDependency("examples", .{})) |examples_dep| {
        test_step.dependOn(examples_dep.builder.getInstallStep());
    }

    const pymz_test_module = b.createModule(.{
        .root_source_file = b.path("pymz/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const backend_mock = b.createModule(.{
        .root_source_file = b.path("pymz/tests/test_backend_mock.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_mock.addAnonymousImport("contract", .{
        .root_source_file = b.path("pymz/src/contract.zig"),
    });
    pymz_test_module.addImport("pymz_backend", backend_mock);
    // `limiter.zig` (reached via the declarative descriptors and `tests.zig`)
    // reads `is_limited_api` from `pymz_options`. The mock reports full ABI.
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

    const contract_module = b.createModule(.{
        .root_source_file = b.path("pymz/src/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const contract_test_module = b.createModule(.{
        .root_source_file = b.path("pymz/tests/backend_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    contract_test_module.addImport("pymz_contract", contract_module);
    const contract_tests = b.addTest(.{
        .name = "pymz-contract",
        .root_module = contract_test_module,
    });
    const run_contract_tests = b.addRunArtifact(contract_tests);
    test_step.dependOn(&run_contract_tests.step);
}
