//! Python property table generation for Zig-backed classes.

const std = @import("std");
const c = @import("../c.zig").c;
const convert = @import("../convert.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const core = @import("core.zig");

pub fn PropertiesBuilder(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".fields;
        const public_count = core.countPublicFields(T);

        fn isReadOnlyField(comptime field_name: []const u8) bool {
            if (!@hasDecl(T, "__pymz_readonly_fields__")) return false;
            const ro = T.__pymz_readonly_fields__;
            if (!@hasField(@TypeOf(ro), field_name)) return false;
            return @field(ro, field_name);
        }

        pub fn buildGetSetTable() [public_count + 1]c.PyGetSetDef {
            var table: [public_count + 1]c.PyGetSetDef = std.mem.zeroes([public_count + 1]c.PyGetSetDef);
            var idx: usize = 0;
            inline for (fields) |field| {
                if (!core.isPrivateField(field.name)) {
                    table[idx] = makeGetSetDef(field);
                    idx += 1;
                }
            }
            return table;
        }

        fn makeGetSetDef(comptime field: anytype) c.PyGetSetDef {
            const FieldType = field.type;
            const field_name = field.name;
            const name_z: [:0]const u8 = comptime (field_name ++ "\x00")[0..field_name.len :0];

            const Getter = struct {
                fn get(py_self: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
                    const py = py_self orelse return null;
                    const data = core.unwrapConst(T, py);
                    const value = @field(data, field_name);
                    const obj = convert.toPy(value) catch return null;
                    return @ptrCast(obj);
                }
            };

            const Setter = struct {
                fn set(py_self: ?*c.PyObject, py_value: ?*c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
                    const py = py_self orelse return -1;
                    const data = core.unwrap(T, py);
                    const v = py_value orelse {
                        errors.typeError("cannot delete attribute '{s}'", .{field_name}) catch {};
                        return -1;
                    };
                    const obj: *object.Object = @ptrCast(v);
                    const new_value = convert.fromPy(FieldType, obj) catch return -1;
                    convert.releaseValue(&@field(data, field_name));
                    @field(data, field_name) = new_value;
                    return 0;
                }
            };

            return .{
                .name = @constCast(name_z.ptr),
                .get = @ptrCast(&Getter.get),
                .set = if (comptime isReadOnlyField(field_name)) null else @ptrCast(&Setter.set),
                .doc = null,
                .closure = null,
            };
        }
    };
}
