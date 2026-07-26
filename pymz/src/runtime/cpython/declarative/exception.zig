//! Exception export descriptors.

const common = @import("common.zig");
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const stubs = @import("../stubs.zig");

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

        pub var value: errors.Exception = undefined;

        pub fn registerWithName(mod: *types.Module, comptime export_name: [:0]const u8) Error!void {
            value = try errors.createException(mod, export_name, base, doc);
        }

        pub fn raise(msg: [:0]const u8) Error {
            return value.raise(msg);
        }

        pub fn raiseFormat(comptime fmt: []const u8, args: anytype) Error {
            return value.raiseFormat(fmt, args);
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubs.exceptionStub(export_name, if (doc) |d| d else "");
        }
    };
}
