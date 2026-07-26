//! Lifecycle builder for Python-backed Zig classes.

const std = @import("std");
const c = @import("../c.zig").c;
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const convert = @import("../convert.zig");
const core = @import("core.zig");
const traits = @import("../traits.zig");

pub fn LifecycleBuilder(comptime T: type) type {
    return struct {
        const Self = core.Wrapper(T);
        const fields = @typeInfo(T).@"struct".fields;
        const has_custom_new = @hasDecl(T, "__new__");
        const has_del = @hasDecl(T, "__del__");
        const NewFn = if (has_custom_new) @TypeOf(T.__new__) else fn () void;

        pub fn py_new(
            type_obj: *c.PyTypeObject,
            args: ?*c.PyObject,
            kwargs: ?*c.PyObject,
        ) callconv(.c) ?*c.PyObject {
            const obj = c.PyType_GenericNew(type_obj, args, kwargs);
            if (obj == null) return null;
            const wrapper: *Self = @ptrCast(@alignCast(obj.?));
            wrapper.initialized = false;
            return obj;
        }

        pub fn py_init(
            py_self: ?*c.PyObject,
            args: ?*c.PyObject,
            kwargs: ?*c.PyObject,
        ) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const wrapper: *Self = @ptrCast(@alignCast(py));

            if (has_custom_new) {
                const Fn = @TypeOf(T.__new__);
                const fn_info = @typeInfo(Fn).@"fn";
                const Params = fn_info.params;

                const args_tuple: ?*types.Tuple = if (args) |a| @ptrCast(a) else null;
                const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                if (kwargs) |kw| {
                    if (c.PyDict_Size(kw) != 0) {
                        errors.typeError("this constructor does not accept keyword arguments", .{}) catch {};
                        return -1;
                    }
                }
                if (num_pos != Params.len) {
                    errors.typeError(
                        "__new__ takes exactly {d} positional argument(s) ({d} given)",
                        .{ Params.len, num_pos },
                    ) catch {};
                    return -1;
                }

                var zig_args: std.meta.ArgsTuple(Fn) = undefined;
                var converted_count: usize = 0;
                inline for (Params, 0..) |param, i| {
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing argument {d}", .{i + 1}) catch {};
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    const PT = param.type orelse {
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    zig_args[i] = convert.fromPy(PT, py_item) catch {
                        releaseConstructorArgs(&zig_args, converted_count);
                        return -1;
                    };
                    converted_count += 1;
                }
                const result = @call(.auto, T.__new__, zig_args);
                wrapper.getData().* = result;
                wrapper.initialized = true;
                releaseConstructorArgs(&zig_args, converted_count);
                return 0;
            }

            const args_tuple: ?*types.Tuple = if (args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;
            if (kwargs) |kw| {
                if (c.PyDict_Size(kw) != 0) {
                    errors.typeError("this constructor does not accept keyword arguments", .{}) catch {};
                    return -1;
                }
            }

            var idx: usize = 0;
            var initialized_count: usize = 0;
            const data_ptr = wrapper.getData();
            inline for (fields) |field| {
                if (comptime core.isPrivateField(field.name)) {
                    if (field.default_value_ptr) |dv| {
                        @field(data_ptr.*, field.name) = dv.*;
                    }
                } else if (idx < num_pos) {
                    const py_item = args_tuple.?.get(idx) orelse {
                        errors.typeError("missing argument '{s}'", .{field.name}) catch {};
                        cleanupFieldsPrefix(data_ptr, initialized_count);
                        return -1;
                    };
                    @field(data_ptr.*, field.name) = convert.fromPy(field.type, py_item) catch {
                        cleanupFieldsPrefix(data_ptr, initialized_count);
                        return -1;
                    };
                    idx += 1;
                } else if (field.default_value_ptr) |dv| {
                    @field(data_ptr.*, field.name) = dv.*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(data_ptr.*, field.name) = null;
                } else {
                    errors.typeError("missing required argument '{s}'", .{field.name}) catch {};
                    cleanupFieldsPrefix(data_ptr, initialized_count);
                    return -1;
                }
                initialized_count += 1;
            }
            wrapper.initialized = true;
            return 0;
        }

        fn releaseConstructorArgs(args: *std.meta.ArgsTuple(NewFn), count: usize) void {
            if (!has_custom_new) return;
            const Params = @typeInfo(NewFn).@"fn".params;
            inline for (Params, 0..) |param, i| {
                if (i < count) {
                    if (param.type) |_| {
                        convert.releaseValue(&args[i]);
                    }
                }
            }
        }

        fn cleanupFields(data: *T) void {
            inline for (fields) |field| {
                const FT = field.type;
                if (comptime traits.isObjectPtr(FT)) {
                    @field(data, field.name).decref();
                } else if (comptime traits.isObjectPtrOptional(FT)) {
                    if (@field(data, field.name)) |obj| obj.decref();
                } else if (!comptime core.isPrivateField(field.name)) {
                    convert.releaseValue(&@field(data, field.name));
                }
            }
        }

        fn cleanupFieldsPrefix(data: *T, count: usize) void {
            inline for (fields, 0..) |field, i| {
                if (i < count and !comptime core.isPrivateField(field.name)) {
                    convert.releaseValue(&@field(data, field.name));
                }
            }
        }

        pub fn py_dealloc(py_self: ?*c.PyObject) callconv(.c) void {
            const py = py_self orelse return;
            const wrapper: *Self = @ptrCast(@alignCast(py));

            var exc_type: ?*c.PyObject = null;
            var exc_value: ?*c.PyObject = null;
            var exc_traceback: ?*c.PyObject = null;
            const had_exception = errors.errorOccurred() != null;
            if (had_exception) {
                c.PyErr_Fetch(&exc_type, &exc_value, &exc_traceback);
            }

            if (wrapper.initialized and has_del) {
                T.__del__(wrapper.getData());
            }
            if (wrapper.initialized) {
                cleanupFields(wrapper.getData());
            }

            if (had_exception) {
                c.PyErr_Restore(exc_type, exc_value, exc_traceback);
            }

            const tp = c.Py_TYPE(py);
            if (tp) |t| {
                if (t.*.tp_free) |tp_free| {
                    tp_free(@ptrCast(py));
                } else {
                    c.PyObject_Free(@ptrCast(py));
                }
            } else {
                c.PyObject_Free(@ptrCast(py));
            }
        }
    };
}
