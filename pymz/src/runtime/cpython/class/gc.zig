//! Python GC protocol generation for Zig-backed classes.

const c = @import("../c.zig").c;
const object = @import("../object.zig");
const core = @import("core.zig");

pub fn GCBuilder(comptime T: type) type {
    return struct {
        pub const has_traverse = @hasDecl(T, "__traverse__");
        pub const has_clear = @hasDecl(T, "__clear__");

        pub fn py_traverse(py_self: ?*c.PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = core.unwrapConst(T, py);
            if (comptime has_traverse) {
                const UserVisit = *const fn (*object.Object, ?*anyopaque) callconv(.c) c_int;
                const user_visit: UserVisit = @ptrCast(visit);
                @field(T, "__traverse__")(data, user_visit, arg) catch return -1;
            }
            return 0;
        }

        pub fn py_clear(py_self: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = core.unwrap(T, py);
            if (comptime has_clear) {
                @field(T, "__clear__")(data) catch return -1;
            }
            return 0;
        }
    };
}
