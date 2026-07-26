//! Shared helpers for declarative Python export descriptors.

const std = @import("std");
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
    signature: ?[]const u8 = null,
};

pub fn sentinelName(comptime name: []const u8) [:0]const u8 {
    return (name ++ "\x00")[0..name.len :0];
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
        return opts;
    }
    return .{ .doc = desc, .signature = null };
}
