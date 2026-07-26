//! Backend contract shared by pymz modules.
//!
//! This file stays backend-agnostic. Concrete runtimes provide a separate
//! `pymz_backend` module that exports `backendSpec()` and `Backend()`.

pub const Capabilities = struct {
    gil: bool = false,
    class_model: bool = false,
    stable_abi: bool = false,
    python2: bool = false,
    python3: bool = false,
};

pub const BackendSpec = struct {
    name: []const u8,
    capabilities: Capabilities,
};

pub fn validateBackend(
    comptime BackendType: type,
    comptime capabilities: Capabilities,
) void {
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
    validateCapabilityDecls(BackendType, capabilities.python2, &.{"is_py2"}, "Python 2");
    validateCapabilityDecls(BackendType, capabilities.python3, &.{"is_py3"}, "Python 3");
    validateCapabilityDecls(
        BackendType,
        capabilities.stable_abi,
        &.{"is_limited_api"},
        "stable ABI",
    );
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
