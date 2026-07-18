const std = @import("std");
const main = @import("src/main.zig");

pub const PythonConfig = main.PythonConfig;
pub const PythonVersion = main.PythonVersion;
pub const Runtime = main.Runtime;
pub const ExtensionOptions = main.ExtensionOptions;
pub const ProjectOptions = main.ProjectOptions;
pub const addPythonExtension = main.addPythonExtension;
pub const configurePythonModule = main.configurePythonModule;
pub const configurePythonModuleFromDependency = main.configurePythonModuleFromDependency;
pub const resolveRuntime = main.resolveRuntime;
pub const resolveDefaultPythonConfig = main.resolveDefaultPythonConfig;
pub const resolvePythonConfigExact = main.resolvePythonConfigExact;
pub const resolvePythonConfigMaybe = main.resolvePythonConfigMaybe;
pub const discoverPythonConfig = main.discoverPythonConfig;
pub const discoverPythonConfigExpected = main.discoverPythonConfigExpected;
pub const computeExtensionName = main.computeExtensionName;
pub const parseVersions = main.parseVersions;
pub const parsePythonVersion = main.parsePythonVersion;
pub const buildProject = main.buildProject;

pub fn build(b: *std.Build) void {
    _ = b.addModule("pymz-build", .{
        .root_source_file = b.path("src/main.zig"),
    });
}
