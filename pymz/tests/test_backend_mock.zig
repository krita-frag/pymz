//! 编译期安全的单元测试运行器使用的最小后端模拟。
//!
//! 该模块满足 `@import("pymz_backend")`，供不链接真实 Python 解释器的测试使用。
//! 它报告稳定的 CPython 3.10 完整 ABI 规格，以便在测试时执行与平台无关的声明式代码。

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
