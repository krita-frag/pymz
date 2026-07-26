//! Shared helpers for declarative Python export descriptors.

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
    /// Comma-separated positional parameter names as a single string.
    signature: ?[]const u8 = null,
    /// Array of parameter names. Takes precedence over `signature` when both are provided.
    param_names: ?[]const []const u8 = null,
    /// Platform filter. `null` = include on all platforms; `true` = limited ABI only;
    /// `false` = full ABI only.
    limited: ?bool = null,
};

/// Join an array of parameter names into a comma-separated string used by the
/// signature pipeline. Evaluated at comptime.
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

/// Resolve the effective comma-separated parameter names from function options.
/// Prefers the `param_names` array; falls back to the `signature` string.
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
