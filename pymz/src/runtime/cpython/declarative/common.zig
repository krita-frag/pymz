//! 声明式 Python 导出描述符的共享辅助函数。

const std = @import("std");
const convert = @import("../convert.zig");
const module_mod = @import("../module.zig");

pub const MethodDef = module_mod.MethodDef;
pub const MethodFlags = module_mod.MethodFlags;

pub const ExportKind = enum {
    function,
    class,
    exception,
    constant,
};

pub const FnMode = enum {
    positional,
    kwargs,
    mixed,
    varargs,
};

pub const FunctionOptions = struct {
    doc: ?[]const u8 = null,
    /// 逗号分隔的位置参数名，以单个字符串形式提供。
    signature: ?[]const u8 = null,
    /// 参数名数组。当同时提供时，优先于 `signature`。
    param_names: ?[]const []const u8 = null,
    /// 平台过滤器。`null` = 包含所有平台；`true` = 仅限 limited ABI；`false` = 仅限完整 ABI。
    limited: ?bool = null,
};

/// 将参数名数组拼接为逗号分隔的字符串，供签名流水线使用。在编译期求值。
pub fn joinParamNames(comptime names: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (names, 0..) |name, i| {
            if (i > 0) result = result ++ ",";
            result = result ++ name;
        }
        return result;
    }
}

/// 从函数选项中解析有效的逗号分隔参数名。
/// 优先使用 `param_names` 数组；回退到 `signature` 字符串。
pub fn resolveParamNames(comptime opts: FunctionOptions) ?[]const u8 {
    if (opts.param_names) |names| {
        return joinParamNames(names);
    }
    return opts.signature;
}

pub fn sentinelName(comptime name: []const u8) [:0]const u8 {
    return convert.toSentinelStr(name);
}

pub fn isMetaDeclarationField(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__pymz_");
}

pub fn isMethodDefList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer_info| switch (@typeInfo(pointer_info.child)) {
            .array => |array_info| array_info.child == MethodDef,
            else => false,
        },
        else => false,
    };
}

pub fn extractFunctionOptions(comptime desc: anytype) FunctionOptions {
    const T = @TypeOf(desc);
    const info = @typeInfo(T);
    if (info == .@"struct") {
        var opts: FunctionOptions = .{};
        if (@hasField(T, "doc")) opts.doc = desc.doc;
        if (@hasField(T, "signature")) opts.signature = desc.signature;
        if (@hasField(T, "param_names")) opts.param_names = desc.param_names;
        if (@hasField(T, "limited")) opts.limited = desc.limited;
        return opts;
    }
    return .{ .doc = desc, .signature = null };
}
