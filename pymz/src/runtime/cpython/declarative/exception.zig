//! Exception export descriptors.

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

        // `null` until `registerWithName` runs. The module-init path always
        // registers descriptors before user code can reach `raise`, so the
        // `assert` in `get` catches descriptor misuse (e.g. raising an
        // exception whose owning module was never initialized) instead of
        // silently dereferencing `undefined`.
        pub var value: ?errors.Exception = null;

        inline fn get() errors.Exception {
            std.debug.assert(value != null);
            return value.?;
        }

        pub fn registerWithName(mod: *types.Module, comptime export_name: [:0]const u8) Error!void {
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
