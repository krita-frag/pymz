//! Backend contract shared by pymz modules.
//!
//! This file stays backend-agnostic. Concrete runtimes provide a separate
//! `pymz_backend` module that exports `backendSpec()` and `Backend()`.

const std = @import("std");

/// Strongly-typed identifier for a supported Python-family runtime.
pub const RuntimeId = enum {
    cpython2,
    cpython3,
    cpython3_limited,
    custom,

    pub fn fromString(runtime_name: []const u8) !RuntimeId {
        if (std.mem.eql(u8, runtime_name, "cpython2")) return .cpython2;
        if (std.mem.eql(u8, runtime_name, "cpython3")) return .cpython3;
        if (std.mem.eql(u8, runtime_name, "cpython3-limited") or
            std.mem.eql(u8, runtime_name, "cpython3_limited")) return .cpython3_limited;
        if (std.mem.eql(u8, runtime_name, "auto")) return error.AutoRuntimeNotResolved;
        if (std.mem.eql(u8, runtime_name, "custom")) return .custom;
        return error.InvalidRuntime;
    }

    pub fn toString(self: RuntimeId) []const u8 {
        return self.canonicalName();
    }

    pub fn isLimitedApi(self: RuntimeId) bool {
        return runtimeInfo(self).is_limited_api();
    }

    pub fn isPython2(self: RuntimeId) bool {
        return runtimeInfo(self).is_python2();
    }

    pub fn isPython3(self: RuntimeId) bool {
        return runtimeInfo(self).is_python3();
    }

    pub fn fromPythonMajor(major: u32) !RuntimeId {
        return switch (major) {
            2 => .cpython2,
            3 => .cpython3,
            else => error.UnsupportedPythonMajor,
        };
    }

    /// Canonical name used in `pymz.json`, CLI flags, and wheel metadata.
    /// Always returns the kebab-case form (`cpython3-limited`), which is the
    /// canonical public spelling; `fromString` accepts the underscore alias.
    pub fn canonicalName(self: RuntimeId) []const u8 {
        return switch (self) {
            .cpython2 => "cpython2",
            .cpython3 => "cpython3",
            .cpython3_limited => "cpython3-limited",
            .custom => "custom",
        };
    }

    /// Minimum Python version required by this runtime, if any.
    pub fn minimumPython(self: RuntimeId) ?struct { major: u32, minor: u32 } {
        return switch (self) {
            .cpython3_limited => .{ .major = 3, .minor = 10 },
            else => null,
        };
    }

    /// Python version constraint string for wheel METADATA `Requires-Python`.
    pub fn requiresPython(self: RuntimeId, allocator: std.mem.Allocator, explicit_version: ?[]const u8) ![]const u8 {
        if (explicit_version) |version| {
            return switch (self) {
                .cpython2 => try std.fmt.allocPrint(allocator, ">={s},<3", .{version}),
                else => try std.fmt.allocPrint(allocator, ">={s}", .{version}),
            };
        }
        return switch (self) {
            .cpython2 => try allocator.dupe(u8, ">=2.7,<3"),
            .cpython3_limited => try allocator.dupe(u8, ">=3.10"),
            else => try allocator.dupe(u8, ">=3"),
        };
    }

    /// True when this runtime targets Python 3.x (full or limited ABI).
    pub fn matchesPython3(self: RuntimeId) bool {
        return self == .cpython3 or self == .cpython3_limited;
    }

    /// True when this runtime is compatible with a given Python `major.minor`
    /// version string (e.g. "2.7" or "3.12").
    pub fn matchesPythonVersion(self: RuntimeId, version: []const u8) bool {
        if (self == .cpython2 and std.mem.startsWith(u8, version, "2.")) return true;
        if (self.matchesPython3() and std.mem.startsWith(u8, version, "3.")) return true;
        return false;
    }
};

/// Centralized, compile-time-known metadata for every built-in runtime.
///
/// This is the single source of truth for runtime identity, ABI flags,
/// minimum Python version, and capability set. All other modules
/// (`backend.zig`, `platform.zig`, `tool.zig`, `wheel.zig`,
/// `runtime/cpython/version.zig`) must query this table instead of
/// re-parsing the runtime string.
pub const RuntimeInfo = struct {
    id: RuntimeId,
    name: []const u8,
    minimum_python: ?struct { major: u32, minor: u32 },
    capabilities: Capabilities,

    /// True when this runtime targets Python 2.x. Derived from capabilities
    /// so there is a single source of truth.
    pub fn is_python2(self: RuntimeInfo) bool {
        return self.capabilities.python2;
    }

    /// True when this runtime targets Python 3.x (full or limited ABI).
    pub fn is_python3(self: RuntimeInfo) bool {
        return self.capabilities.python3;
    }

    /// True when this runtime uses the CPython limited API (stable ABI).
    pub fn is_limited_api(self: RuntimeInfo) bool {
        return self.capabilities.stable_abi;
    }
};

/// The canonical runtime metadata table.
pub fn runtimeInfo(id: RuntimeId) RuntimeInfo {
    return switch (id) {
        .cpython2 => .{
            .id = .cpython2,
            .name = "cpython2",
            .minimum_python = null,
            .capabilities = .{
                .gil = true,
                .class_model = true,
                .function_model = true,
                .python2 = true,
                .object_model = true,
                .conversion = true,
                .module_model = true,
                .exceptions = true,
                .set_model = true,
                .slice_model = true,
                .argument_parser = true,
            },
        },
        .cpython3 => .{
            .id = .cpython3,
            .name = "cpython3",
            .minimum_python = null,
            .capabilities = .{
                .gil = true,
                .class_model = true,
                .function_model = true,
                .python3 = true,
                .object_model = true,
                .conversion = true,
                .module_model = true,
                .exceptions = true,
                .set_model = true,
                .slice_model = true,
                .argument_parser = true,
            },
        },
        .cpython3_limited => .{
            .id = .cpython3_limited,
            .name = "cpython3-limited",
            .minimum_python = .{ .major = 3, .minor = 10 },
            .capabilities = .{
                .gil = true,
                .class_model = false,
                .function_model = true,
                .stable_abi = true,
                .python3 = true,
                .object_model = true,
                .conversion = true,
                .module_model = true,
                .exceptions = true,
                .set_model = true,
                .slice_model = true,
                .argument_parser = true,
            },
        },
        .custom => .{
            .id = .custom,
            .name = "custom",
            .minimum_python = null,
            .capabilities = .{},
        },
    };
}

pub const Capabilities = struct {
    gil: bool = false,
    class_model: bool = false,
    function_model: bool = false,
    stable_abi: bool = false,
    python2: bool = false,
    python3: bool = false,
    object_model: bool = false,
    conversion: bool = false,
    module_model: bool = false,
    exceptions: bool = false,
    set_model: bool = false,
    slice_model: bool = false,
    argument_parser: bool = false,
};

/// The interpreter integration model used by a backend.
pub const RuntimeModel = enum {
    cpython_extension,
    custom,
};

pub const ArtifactFormat = enum {
    python_extension,
    static_object,
};

pub const ContractVersion: u32 = 2;

pub const BackendSpec = struct {
    contract_version: u32 = ContractVersion,
    name: []const u8,
    runtime_model: RuntimeModel,
    artifact_format: ArtifactFormat,
    capabilities: Capabilities,
};

pub fn validateBackend(
    comptime BackendType: type,
    comptime capabilities: Capabilities,
) void {
    comptime {
        const spec = BackendType.backendSpec();
        if (spec.contract_version != ContractVersion) {
            @compileError("selected backend uses an incompatible pymz backend contract");
        }
    }
    validateCapabilityDecls(
        BackendType,
        capabilities.gil,
        &.{ "GIL", "initialize", "finalize" },
        "GIL/runtime",
    );
    validateCapabilityDecls(
        BackendType,
        capabilities.class_model,
        &.{ "class", "classWithBase" },
        "class model",
    );
    validateCapabilityDecls(
        BackendType,
        capabilities.function_model,
        &.{ "function", "positionalFunction", "kwFunction", "varargsFunction" },
        "function model",
    );
    validateCapabilityDecls(BackendType, capabilities.python2, &.{"is_py2"}, "Python 2");
    validateCapabilityDecls(BackendType, capabilities.python3, &.{"is_py3"}, "Python 3");
    validateCapabilityDecls(
        BackendType,
        capabilities.stable_abi,
        &.{"is_limited_api"},
        "stable ABI",
    );
    validateCapabilityDecls(
        BackendType,
        capabilities.object_model,
        &.{ "Object", "none", "boolean", "Int", "Float", "Bool", "Str", "Bytes", "List", "Dict" },
        "object model",
    );
    validateCapabilityDecls(BackendType, capabilities.conversion, &.{"convert"}, "conversion");
    validateCapabilityDecls(
        BackendType,
        capabilities.module_model,
        &.{ "Module", "ModuleInitFn", "module" },
        "module model",
    );
    validateCapabilityDecls(
        BackendType,
        capabilities.exceptions,
        &.{ "ExceptionBase", "Exception" },
        "exceptions",
    );
    validateCapabilityDecls(BackendType, capabilities.set_model, &.{ "Set", "FrozenSet" }, "set model");
    validateCapabilityDecls(BackendType, capabilities.slice_model, &.{"Slice"}, "slice model");
    validateCapabilityDecls(
        BackendType,
        capabilities.argument_parser,
        &.{ "Args", "RawArgs" },
        "argument parser",
    );
    validateBackendSignatures(BackendType, capabilities);
}

/// Structural signature checks that go beyond `@hasDecl`. Ensures key
/// declarations are actually functions (not variables or types), so a
/// mismatched backend fails at the backend definition site rather than at
/// a distant call site.
fn validateBackendSignatures(comptime BackendType: type, comptime capabilities: Capabilities) void {
    comptime {
        if (capabilities.object_model) {
            assertIsFunction(BackendType, "none", "object model");
            assertIsFunction(BackendType, "boolean", "object model");
        }
        if (capabilities.function_model) {
            assertIsFunction(BackendType, "function", "function model");
            assertIsFunction(BackendType, "positionalFunction", "function model");
            assertIsFunction(BackendType, "kwFunction", "function model");
            assertIsFunction(BackendType, "varargsFunction", "function model");
        }
        if (capabilities.module_model) {
            assertIsFunction(BackendType, "module", "module model");
        }
        if (capabilities.class_model) {
            assertIsFunction(BackendType, "class", "class model");
            assertIsFunction(BackendType, "classWithBase", "class model");
        }
    }
}

fn assertIsFunction(comptime BackendType: type, comptime name: []const u8, comptime feature: []const u8) void {
    comptime {
        const T = @TypeOf(@field(BackendType, name));
        if (@typeInfo(T) != .@"fn") {
            @compileError("backend." ++ name ++ " for " ++ feature ++ " must be a function, got " ++ @typeName(T));
        }
    }
}

fn validateCapabilityDecls(
    comptime BackendType: type,
    comptime enabled: bool,
    comptime decls: []const []const u8,
    comptime feature_name: []const u8,
) void {
    if (!enabled) return;
    comptime {
        for (decls) |decl| {
            if (!@hasDecl(BackendType, decl)) {
                @compileError(
                    "selected backend is missing " ++ decl ++ " for " ++ feature_name,
                );
            }
        }
    }
}
