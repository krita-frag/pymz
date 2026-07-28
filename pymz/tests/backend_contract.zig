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

test "builtin_runtime_ids excludes custom" {
    // `.custom` 是不透明哨兵，不在内置注册表中。
    for (contract.builtin_runtime_ids) |id| {
        try std.testing.expect(id != .custom);
    }
}

test "allRuntimeInfos matches builtin_runtime_ids" {
    const infos = contract.allRuntimeInfos();
    try std.testing.expectEqual(contract.builtin_runtime_ids.len, infos.len);
    // 顺序与 builtin_runtime_ids 一致，使 CLI 输出可预测。
    for (contract.builtin_runtime_ids, 0..) |id, i| {
        try std.testing.expectEqual(id, infos[i].id);
        // name 与 canonicalName 一致，单一真相源。
        try std.testing.expectEqualStrings(id.canonicalName(), infos[i].name);
    }
}

test "runtimeInfoFromString resolves known aliases" {
    // kebab-case（规范名）
    const cpython3 = contract.runtimeInfoFromString("cpython3");
    try std.testing.expect(cpython3 != null);
    try std.testing.expectEqualStrings("cpython3", cpython3.?.name);
    try std.testing.expect(cpython3.?.capabilities.python3);

    // 下划线别名（与 fromString 等价）
    const limited = contract.runtimeInfoFromString("cpython3_limited");
    try std.testing.expect(limited != null);
    try std.testing.expect(limited.?.capabilities.stable_abi);
    try std.testing.expect(limited.?.capabilities.class_model == false);

    // Python 2
    const py2 = contract.runtimeInfoFromString("cpython2");
    try std.testing.expect(py2 != null);
    try std.testing.expect(py2.?.capabilities.python2);
}

test "runtimeInfoFromString returns null for unknown and sentinel values" {
    // 未知名称
    try std.testing.expect(contract.runtimeInfoFromString("pypy") == null);
    try std.testing.expect(contract.runtimeInfoFromString("") == null);

    // "auto" 是构建时便利值，需先解析为具体运行时再查询
    try std.testing.expect(contract.runtimeInfoFromString("auto") == null);

    // "custom" 是哨兵，不在内置注册表中
    try std.testing.expect(contract.runtimeInfoFromString("custom") == null);
}
