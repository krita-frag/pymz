//! Backend capability interface.
//!
//! The public `pymz` surface imports `pymz_backend`, validates the selected
//! backend against this contract, and then re-exports the backend type.

const backend = @import("pymz_backend");

pub const BackendSpec = @TypeOf(backend.backendSpec());
pub const Capabilities = @TypeOf(backend.backendSpec().capabilities);

pub fn backendSpec() BackendSpec {
    return backend.backendSpec();
}

/// Resolve the active backend type at compile time.
pub fn Backend() type {
    const spec = backendSpec();
    const backend_type = backend.Backend();
    validateBackend(backend_type, spec.capabilities);
    return backend_type;
}

fn validateBackend(
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
