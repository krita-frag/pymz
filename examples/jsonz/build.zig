const std = @import("std");
const pymz_tool = @import("pymz-tool");

/// `configure_module` is called after the extension root module is created and
/// Python include/link paths are wired, but before the shared library is
/// instantiated. Use it to add C sources, extra include paths, link external
/// libraries, or define compile macros.
///
/// `link_libc` is already enabled by `addPythonExtension`; you do NOT need to
/// call `module.link_libc = true` here. Link other libraries with
/// `module.linkSystemLibrary`, `module.linkFramework` (macOS), or
/// `module.addObjectFile` (pre-built .lib/.a).
fn jsonzConfigureModule(module: *std.Build.Module, ctx: pymz_tool.core.HookContext) void {
    _ = ctx;
    // Stamp a build-time C macro so the Zig source can detect it via
    // `@hasDecl` / `@import("builtin")`.
    module.addCMacro("JSONZ_BUILT_BY_PYMZ", "1");
}

/// `configure_artifact` is called after `addLibrary` returns the compiled
/// artifact. Use it to attach extra build steps, install headers, or reach the
/// module via `artifact.root_module` for last-minute adjustments.
///
/// Most cross-platform linking needs (libc, Python import lib on Windows,
/// framework linking on macOS) are already handled by `addPythonExtension`.
/// This hook is for project-specific extras.
fn jsonzConfigureArtifact(artifact: *std.Build.Step.Compile, ctx: pymz_tool.core.HookContext) void {
    _ = ctx;
    // Example: install a generated header alongside the extension.
    // artifact.installHeader(b.path("include/jsonz.h"), "jsonz.h");
    _ = artifact;
}

pub fn build(b: *std.Build) !void {
    const artifact = try pymz_tool.core.buildProject(b, .{
        .module_name = "_jsonz",
        .root_source_file = b.path("src/jsonz.zig"),
        .step_name = "pymz",
        .multi_step_name = "pymz-multi",
        .hooks = .{
            .configure_module = jsonzConfigureModule,
            .configure_artifact = jsonzConfigureArtifact,
        },
    });

    // The extension build is the executable integration test for this example.
    // Keep a conventional `zig build test` entry so CI and downstream users do
    // not silently skip the artifact compilation step.
    const test_step = b.step("test", "Build the jsonz extension for integration tests");
    if (artifact) |a| test_step.dependOn(&a.step);
    test_step.dependOn(b.getInstallStep());
}
