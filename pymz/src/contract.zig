//! pymz 模块共享的后端契约。
//!
//! 本文件保持后端无关性。具体运行时提供一个单独的 `pymz_backend` 模块，
//! 该模块导出 `backendSpec()` 和 `Backend()`。
//!
//! # 后端扩展机制
//!
//! pymz 支持两类后端扩展：
//!
//! 1. **内置后端**（cpython2 / cpython3 / cpython3-limited）：在 `RuntimeId`
//!    枚举和 `runtimeInfo()` 表中硬编码。新增内置后端需修改本文件，因为
//!    `RuntimeId` 是闭合枚举，所有 switch 都依赖其穷尽性来保证编译期安全。
//!    这是开闭原则的有限妥协：让内置后端的能力声明在编译期可静态验证，
//!    避免 custom 后端可能出现的运行时元数据缺失。
//!
//! 2. **custom 后端**：通过 `-Dpymz-backend-source` 构建选项指向用户提供的
//!    后端模块文件。custom 后端绕过 `runtimeInfo()` 表——它必须自行实现
//!    `backendSpec()` 返回的 `Capabilities`，且仍需通过 `validateBackend`
//!    的编译期契约检查。custom 后端的 `RuntimeId` 为 `.custom`，无法享受
//!    内置运行时的元数据查询（如 `requiresPython`、`minimumPython`），
//!    需在 wheel 元数据层自行处理。
//!
//! 选择 custom 后端的典型场景：实验性运行时（如 PyPy/graalpy 的 C 扩展层）、
//! 嵌入式 Python、或带项目特定优化的 CPython 分支。

const std = @import("std");

/// 受支持的 Python 系列运行时的强类型标识符。
///
/// 枚举是闭合的：新增内置运行时需修改此处的 switch 并在 `runtimeInfo()`
/// 表中登记元数据。`custom` 变体保留给经 `-Dpymz-backend-source` 接入的
/// 用户自定义后端——它们不进入 `runtimeInfo()` 表，自行实现 `backendSpec()`。
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

    /// `pymz.json`、CLI 标志和 wheel 元数据中使用的规范名称。
    /// 始终返回 kebab-case 形式（`cpython3-limited`），这是规范的公开拼写；
    /// `fromString` 也接受下划线别名。
    pub fn canonicalName(self: RuntimeId) []const u8 {
        return switch (self) {
            .cpython2 => "cpython2",
            .cpython3 => "cpython3",
            .cpython3_limited => "cpython3-limited",
            .custom => "custom",
        };
    }

    /// 此运行时所需的最低 Python 版本（如有）。
    pub fn minimumPython(self: RuntimeId) ?struct { major: u32, minor: u32 } {
        return switch (self) {
            .cpython3_limited => .{ .major = 3, .minor = 10 },
            else => null,
        };
    }

    /// wheel METADATA 中 `Requires-Python` 的 Python 版本约束字符串。
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

    /// 此运行时是否面向 Python 3.x（完整或有限 ABI）。
    pub fn matchesPython3(self: RuntimeId) bool {
        return self == .cpython3 or self == .cpython3_limited;
    }

    /// 此运行时是否与给定的 Python `major.minor` 版本字符串兼容（如 "2.7" 或 "3.12"）。
    pub fn matchesPythonVersion(self: RuntimeId, version: []const u8) bool {
        if (self == .cpython2 and std.mem.startsWith(u8, version, "2.")) return true;
        if (self.matchesPython3() and std.mem.startsWith(u8, version, "3.")) return true;
        return false;
    }
};

/// 所有内置运行时的集中式编译期元数据。
///
/// 这是运行时标识、ABI 标志、最低 Python 版本和能力集的唯一真相源。
/// 所有其他模块（`backend.zig`、`platform.zig`、`tool.zig`、`wheel.zig`、
/// `runtime/cpython/version.zig`）必须查询此表，而非重新解析运行时字符串。
pub const RuntimeInfo = struct {
    id: RuntimeId,
    name: []const u8,
    minimum_python: ?struct { major: u32, minor: u32 },
    capabilities: Capabilities,

    /// 此运行时是否面向 Python 2.x。从能力集中派生，以保持单一真相源。
    pub fn is_python2(self: RuntimeInfo) bool {
        return self.capabilities.python2;
    }

    /// 此运行时是否面向 Python 3.x（完整或有限 ABI）。
    pub fn is_python3(self: RuntimeInfo) bool {
        return self.capabilities.python3;
    }

    /// 此运行时是否使用 CPython limited API（稳定 ABI）。
    pub fn is_limited_api(self: RuntimeInfo) bool {
        return self.capabilities.stable_abi;
    }
};

/// 规范的运行时元数据表。
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

/// 内置运行时注册表：所有具有元数据的运行时 ID。
///
/// `.custom` 被有意排除——它是不透明哨兵，代表经 `-Dpymz-backend-source`
/// 接入的用户自定义后端，没有可枚举的内置元数据。CLI 工具和清单校验器
/// 应使用此列表枚举可选项，而非硬编码运行时名称字符串。
///
/// 顺序按"Python 主版本递增、ABI 完整性递减"排列，使 CLI 输出对用户友好：
/// cpython2（旧）→ cpython3（默认）→ cpython3-limited（受限 ABI）。
pub const builtin_runtime_ids = [_]RuntimeId{
    .cpython2,
    .cpython3,
    .cpython3_limited,
};

/// 返回所有内置运行时的 `RuntimeInfo`，顺序与 `builtin_runtime_ids` 一致。
///
/// 用于 CLI 列出可用运行时、生成文档、清单校验等枚举场景。
/// 单一真相源：本函数遍历 `builtin_runtime_ids` 并查询 `runtimeInfo`，
/// 新增内置运行时只需在 `RuntimeId` 枚举和 `runtimeInfo` 表中登记，
/// 本函数自动跟进。
pub fn allRuntimeInfos() [builtin_runtime_ids.len]RuntimeInfo {
    var result: [builtin_runtime_ids.len]RuntimeInfo = undefined;
    inline for (builtin_runtime_ids, 0..) |id, i| {
        result[i] = runtimeInfo(id);
    }
    return result;
}

/// 按名称查找内置运行时的元数据。
///
/// 接受 `RuntimeId.fromString` 支持的所有别名（如 `"cpython3-limited"` 和
/// `"cpython3_limited"` 等价）。返回 `null` 的情况：
///   - 未知名称（不匹配任何内置运行时别名）
///   - `"auto"`：构建时便利值，需先解析为具体运行时再查询
///   - `"custom"`：自定义后端哨兵，不在内置注册表中（如需空元数据，
///     直接调用 `runtimeInfo(.custom)`）
///
/// 与 `RuntimeId.fromString` 的区别：后者返回 `!RuntimeId`（错误联合），
/// 本函数返回 `?RuntimeInfo`（可选），把"未在内置注册表中"和"查找成功"
/// 合并为单一查询，省去调用方两步操作（先 `fromString` 再 `runtimeInfo`）。
pub fn runtimeInfoFromString(name: []const u8) ?RuntimeInfo {
    const id = RuntimeId.fromString(name) catch return null;
    if (id == .custom) return null;
    return runtimeInfo(id);
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

/// 后端使用的解释器集成模型。
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

/// 超越 `@hasDecl` 的结构化签名检查。确保关键声明实际上是函数（而非变量或类型），
/// 使不匹配的后端在后端定义处即失败，而非在遥远的调用点。
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
