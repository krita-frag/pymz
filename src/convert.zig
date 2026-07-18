//! Conversion helpers between Zig values and Python objects.

const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
const Object = object.Object;
const Error = errors.Error;

/// Convert common Zig values into Python objects.
pub inline fn toObject(value: anytype) Error!*Object {
    const T = @TypeOf(value);
    if (traits.isObjectPtr(T)) return @ptrCast(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => return @ptrCast(try types.Int.from(value)),
        .bool => return object.returnBool(value),
        .pointer => |info| switch (info.size) {
            .Slice => return @ptrCast(try object.Str.fromSlice(value)),
            else => {},
        },
        else => {},
    }
    @compileError(std.fmt.comptimePrint("cannot convert {s} to Python object", .{@typeName(T)}));
}
