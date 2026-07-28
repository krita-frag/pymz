//! `datetime.datetime` 转换支持。
//!
//! 从 `convert.zig` 分离出来，使核心转换模块专注于基本类型和容器类型。
//! `DateTime` 实现了 `PymzConvert` trait，因此 `convert.toPy` / `convert.fromPy`
//! 会自动识别它。

const std = @import("std");
const c = @import("python_c");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");

const Object = object.Object;
const Error = errors.Error;

/// 一个简单的日期/时间值，映射到 Python 的 `datetime.datetime`。
///
/// 字段与 `datetime.datetime` 构造函数参数对应。可选字段默认为零，
/// 与 Python 的行为一致。
pub const DateTime = struct {
    pub const PymzConvert = struct {
        pub fn intoPy(value: DateTime) Error!*Object {
            const datetime_mod = c.PyImport_ImportModule("datetime") orelse return error.PyError;
            defer c.Py_DECREF(datetime_mod);
            const datetime_type = c.PyObject_GetAttrString(datetime_mod, "datetime") orelse return error.PyError;
            defer c.Py_DECREF(datetime_type);
            const args = c.Py_BuildValue(
                "iiiiiii",
                value.year,
                value.month,
                value.day,
                value.hour,
                value.minute,
                value.second,
                value.microsecond,
            ) orelse return error.PyError;
            defer c.Py_DECREF(args);
            const result = c.PyObject_CallObject(datetime_type, args) orelse return error.PyError;
            return @ptrCast(result);
        }

        pub fn fromPy(obj: *Object) Error!DateTime {
            const datetime_mod = c.PyImport_ImportModule("datetime") orelse return error.PyError;
            defer c.Py_DECREF(datetime_mod);
            const datetime_type = c.PyObject_GetAttrString(datetime_mod, "datetime") orelse return error.PyError;
            defer c.Py_DECREF(datetime_type);
            if (c.PyObject_IsInstance(@ptrCast(obj), datetime_type) != 1) {
                errors.typeError("expected datetime.datetime, got {s}", .{convert.pyTypeName(obj)});
                return error.PyError;
            }
            const getAttr = struct {
                fn call(o: *c.PyObject, name: [:0]const u8) Error!i32 {
                    const attr_obj = c.PyObject_GetAttrString(o, name) orelse return error.PyError;
                    defer c.Py_DECREF(attr_obj);
                    return try types.Int.as(@ptrCast(attr_obj), i32);
                }
            }.call;
            return .{
                .year = try getAttr(@ptrCast(obj), "year"),
                .month = try getAttr(@ptrCast(obj), "month"),
                .day = try getAttr(@ptrCast(obj), "day"),
                .hour = try getAttr(@ptrCast(obj), "hour"),
                .minute = try getAttr(@ptrCast(obj), "minute"),
                .second = try getAttr(@ptrCast(obj), "second"),
                .microsecond = try getAttr(@ptrCast(obj), "microsecond"),
            };
        }
    };

    year: i32,
    month: i32,
    day: i32,
    hour: i32 = 0,
    minute: i32 = 0,
    second: i32 = 0,
    microsecond: i32 = 0,
};

test "DateTime struct has PymzConvert trait" {
    const info = @typeInfo(DateTime).@"struct";
    var has_trait = false;
    inline for (info.decls) |decl| {
        if (std.mem.eql(u8, decl.name, "PymzConvert")) {
            has_trait = true;
        }
    }
    try std.testing.expect(has_trait);
    try std.testing.expect(convert.hasPymzConvert(DateTime));
}

test "DateTime default fields initialize correctly" {
    const dt = DateTime{ .year = 2026, .month = 7, .day = 25 };
    try std.testing.expectEqual(@as(i32, 2026), dt.year);
    try std.testing.expectEqual(@as(i32, 7), dt.month);
    try std.testing.expectEqual(@as(i32, 25), dt.day);
    try std.testing.expectEqual(@as(i32, 0), dt.hour);
    try std.testing.expectEqual(@as(i32, 0), dt.minute);
    try std.testing.expectEqual(@as(i32, 0), dt.second);
    try std.testing.expectEqual(@as(i32, 0), dt.microsecond);
}