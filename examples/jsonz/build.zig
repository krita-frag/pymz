const std = @import("std");
const pymz_tool = @import("pymz-tool");

/// Example `configure_module` hook: stamps a build-time C macro into the
/// extension module so the Zig source can detect it via `@hasDecl` /
/// `@import("builtin").`. This demonstrates the `BuildHooks.configure_module`
/// extension point that `buildProject` exposes for custom linking, C sources,
/// or compile defines.
fn jsonzConfigureModule(module: *std.Build.Module, ctx: pymz_tool.core.HookContext) void {
    _ = ctx;
    module.addCMacro("JSONZ_BUILT_BY_PYMZ", "1");
}

pub fn build(b: *std.Build) !void {
    const artifact = try pymz_tool.core.buildProject(b, .{
        .module_name = "_jsonz",
        .root_source_file = b.path("src/jsonz.zig"),
        .step_name = "example",
        .multi_step_name = "example-multi",
        .hooks = .{
            .configure_module = jsonzConfigureModule,
        },
    });

    // The extension build is the executable integration test for this example.
    // Keep a conventional `zig build test` entry so CI and downstream users do
    // not silently skip the artifact compilation step.
    const test_step = b.step("test", "Build the jsonz extension for integration tests");
    if (artifact) |a| test_step.dependOn(&a.step);
    test_step.dependOn(b.getInstallStep());
}
