//! Minimal backend mock used by the comptime-safe unit test runner.
//!
//! This module satisfies `@import("pymz_backend")` for tests that do not link
//! against a real Python interpreter. It reports a stable CPython 3.10 full-ABI
//! spec so platform-agnostic declarative code can be exercised at test time.

const contract = @import("contract");

pub const BackendSpec = contract.BackendSpec;
pub const Capabilities = contract.Capabilities;
pub const RuntimeModel = contract.RuntimeModel;
pub const ArtifactFormat = contract.ArtifactFormat;
pub const validateBackend = contract.validateBackend;

pub fn backendSpec() BackendSpec {
    return .{
        .name = "test-cpython",
        .runtime_model = .cpython_extension,
        .artifact_format = .python_extension,
        .capabilities = .{
            .gil = true,
            .class_model = true,
            .stable_abi = false,
            .python2 = false,
            .python3 = true,
            .object_model = true,
            .conversion = true,
            .module_model = true,
            .exceptions = true,
            .set_model = true,
            .slice_model = true,
            .argument_parser = true,
        },
    };
}

pub fn Backend() type {
    return struct {};
}
