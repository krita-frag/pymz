//! Constant export descriptors.

const common = @import("common.zig");
const convert = @import("../convert.zig");
const object = @import("../object.zig");
const types = @import("../types.zig");
const stubs = @import("../stubs.zig");

pub const ExportKind = common.ExportKind;
pub const Error = @import("../errors.zig").Error;

pub fn constant(comptime init: anytype) type {
    return ConstantDescriptor(init);
}

fn ConstantDescriptor(comptime _init: anytype) type {
    return struct {
        pub const export_kind: ExportKind = .constant;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const init = _init;

        pub fn registerWithName(mod: *types.Module, comptime export_name: [:0]const u8) Error!void {
            const InitType = @TypeOf(init);
            const info = @typeInfo(InitType);
            const obj: *object.Object = blk: {
                if (info == .@"fn") {
                    const result = @call(.auto, init, .{});
                    const RT = @typeInfo(@TypeOf(result));
                    if (RT == .error_union) {
                        break :blk try result;
                    } else {
                        break :blk result;
                    }
                } else {
                    break :blk try convert.toPy(init);
                }
            };
            defer obj.decref();
            try mod.addObjectRef(export_name, obj);
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubs.constant(export_name, "Any", "");
        }
    };
}
