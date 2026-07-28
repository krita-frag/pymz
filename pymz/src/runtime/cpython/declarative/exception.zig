//! 异常导出描述符。

const std = @import("std");
const common = @import("common.zig");
const errors = @import("../errors.zig");
const types = @import("../types.zig");

pub const ExportKind = common.ExportKind;
pub const Error = errors.Error;

pub fn exception(
    comptime base: errors.ExceptionBase,
    comptime doc: ?[:0]const u8,
) type {
    return ExceptionDescriptor(base, doc);
}

fn ExceptionDescriptor(
    comptime _base: errors.ExceptionBase,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const export_kind: ExportKind = .exception;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const base = _base;
        pub const doc = _doc;

        // 在 registerWithName 运行之前为 null。模块初始化总是在用户代码调用 raise() 之前注册描述符，因此这里的 null 值表示编程错误（例如，抛出一个其所属模块从未初始化的异常）。
        pub var value: ?errors.Exception = null;

        inline fn get() errors.Exception {
            if (value) |v| return v;
            @panic("exception used before registration; ensure the owning module is initialized");
        }

        pub fn registerWithName(mod: *types.Module, comptime export_name: [:0]const u8) Error!void {
            // 忽略重复注册，防止泄漏之前的异常对象。
            if (value != null) return;
            const created = try errors.createException(mod, export_name, base, doc);
            value = created;
        }

        pub fn raise(msg: [:0]const u8) Error {
            return get().raise(msg);
        }

        pub fn raiseFormat(comptime fmt: []const u8, args: anytype) Error {
            return get().raiseFormat(fmt, args);
        }
    };
}
