const std = @import("std");
const pymz_tool = @import("pymz-tool");

fn showcaseConfigureModule(module: *std.Build.Module, ctx: pymz_tool.core.HookContext) void {
    _ = ctx;
    _ = module;
}

fn showcaseConfigureArtifact(artifact: *std.Build.Step.Compile, ctx: pymz_tool.core.HookContext) void {
    _ = ctx;
    _ = artifact;
}

pub fn build(b: *std.Build) !void {
    const artifact = try pymz_tool.core.buildProject(b, .{
        .module_name = "_showcase",
        .root_source_file = b.path("src/showcase.zig"),
        .step_name = "pymz",
        .multi_step_name = "pymz-multi",
        .hooks = .{
            .configure_module = showcaseConfigureModule,
            .configure_artifact = showcaseConfigureArtifact,
        },
    });

    const test_step = b.step("test", "Build the showcase extension for integration tests");
    if (artifact) |a| test_step.dependOn(&a.step);
    test_step.dependOn(b.getInstallStep());
}
