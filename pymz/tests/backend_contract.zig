const std = @import("std");
const contract = @import("pymz_contract");

const MinimalObjectBackend = struct {
    pub fn backendSpec() contract.BackendSpec {
        return .{
            .name = "test",
            .runtime_model = .custom,
            .artifact_format = .static_object,
            .capabilities = .{ .object_model = true },
        };
    }
    pub const Object = opaque {};
    pub const Int = opaque {};
    pub const Float = opaque {};
    pub const Bool = opaque {};
    pub const Str = opaque {};
    pub const Bytes = opaque {};
    pub const List = opaque {};
    pub const Dict = opaque {};

    pub fn none() void {}
    pub fn boolean() void {}
};

test "disabled capabilities require no backend declarations" {
    const EmptyBackend = struct {
        pub fn backendSpec() contract.BackendSpec {
            return .{
                .name = "empty",
                .runtime_model = .custom,
                .artifact_format = .static_object,
                .capabilities = .{},
            };
        }
    };
    contract.validateBackend(EmptyBackend, .{});
}

test "object model capability validates a complete backend" {
    contract.validateBackend(MinimalObjectBackend, .{ .object_model = true });
    try std.testing.expect(true);
}

test "backend metadata records the artifact model" {
    const spec = MinimalObjectBackend.backendSpec();
    try std.testing.expectEqualStrings("test", spec.name);
    try std.testing.expectEqual(contract.ContractVersion, spec.contract_version);
    try std.testing.expectEqual(contract.RuntimeModel.custom, spec.runtime_model);
    try std.testing.expectEqual(contract.ArtifactFormat.static_object, spec.artifact_format);
}
