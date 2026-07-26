//! Python method table generation for Zig-backed classes.

const std = @import("std");
const c = @import("../c.zig").c;
const convert = @import("../convert.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const stubs = @import("../stubs.zig");
const types = @import("../types.zig");
const core = @import("core.zig");

pub fn MethodBuilder(comptime T: type) type {
    return struct {
        const Self = core.Wrapper(T);
        const decls = @typeInfo(T).@"struct".decls;
        const MethodKind = enum { instance, static, class };

        fn methodParamNames(comptime method_name: []const u8) ?[]const u8 {
            if (!@hasDecl(T, "__pymz_method_param_names__")) {
                return null;
            }

            const overrides = T.__pymz_method_param_names__;
            if (!@hasField(@TypeOf(overrides), method_name)) {
                return null;
            }
            return @field(overrides, method_name);
        }

        fn isClassMethod(comptime name: []const u8) bool {
            if (!@hasDecl(T, "__pymz_class_methods__")) return false;
            const cm = T.__pymz_class_methods__;
            if (!@hasField(@TypeOf(cm), name)) return false;
            return @field(cm, name);
        }

        fn isInstanceMethod(comptime name: []const u8) bool {
            if (!@hasDecl(T, name)) return false;
            const F = @TypeOf(@field(T, name));
            const info = @typeInfo(F);
            if (info != .@"fn") return false;
            const params = info.@"fn".params;
            if (params.len == 0) return false;
            const PT = params[0].type orelse return false;
            return core.isSelfParam(PT, T);
        }

        fn isFunctionDecl(comptime name: []const u8) bool {
            if (!@hasDecl(T, name)) return false;
            const F = @TypeOf(@field(T, name));
            return @typeInfo(F) == .@"fn";
        }

        fn methodKind(comptime name: []const u8) MethodKind {
            if (isClassMethod(name)) return .class;
            if (isInstanceMethod(name)) return .instance;
            return .static;
        }

        fn isExcludedDunder(comptime name: []const u8) bool {
            const excluded = [_][]const u8{
                "__new__",  "__del__",  "__repr__", "__str__",    "__hash__",           "__eq__",       "__ne__",      "__lt__",
                "__le__",   "__gt__",   "__ge__",   "__len__",    "__getitem__",        "__setitem__",  "__delitem__", "__contains__",
                "__iter__", "__next__", "__call__", "__buffer__", "__release_buffer__", "__traverse__", "__clear__",
            };
            for (excluded) |e| {
                if (std.mem.eql(u8, name, e)) return true;
            }
            return false;
        }

        fn countInstanceMethods() usize {
            var n: usize = 0;
            for (decls) |d| {
                if (methodKind(d.name) == .instance and !isExcludedDunder(d.name)) n += 1;
            }
            return n;
        }

        fn countStaticMethods() usize {
            var n: usize = 0;
            for (decls) |d| {
                if (isFunctionDecl(d.name) and methodKind(d.name) == .static) n += 1;
            }
            return n;
        }

        fn countClassMethods() usize {
            var n: usize = 0;
            for (decls) |d| {
                if (isFunctionDecl(d.name) and methodKind(d.name) == .class) n += 1;
            }
            return n;
        }

        const instance_method_count = countInstanceMethods();
        const static_method_count = countStaticMethods();
        const class_method_count = countClassMethods();
        pub const total_method_count = instance_method_count + static_method_count + class_method_count;

        pub fn buildMethodTable() [total_method_count + 1]c.PyMethodDef {
            var table: [total_method_count + 1]c.PyMethodDef = undefined;
            var idx: usize = 0;
            inline for (decls) |d| {
                if (methodKind(d.name) == .instance and !isExcludedDunder(d.name)) {
                    table[idx] = makeMethodDef(d.name, .instance);
                    idx += 1;
                }
            }
            inline for (decls) |d| {
                if (isFunctionDecl(d.name) and methodKind(d.name) == .static) {
                    table[idx] = makeMethodDef(d.name, .static);
                    idx += 1;
                }
            }
            inline for (decls) |d| {
                if (isFunctionDecl(d.name) and methodKind(d.name) == .class) {
                    table[idx] = makeMethodDef(d.name, .class);
                    idx += 1;
                }
            }
            table[idx] = .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
            return table;
        }

        fn makeMethodDef(comptime name: [:0]const u8, comptime kind: MethodKind) c.PyMethodDef {
            const F = @TypeOf(@field(T, name));
            const sig = stubs.buildMlDocWithOptions(
                name,
                F,
                switch (kind) {
                    .instance => .instance_method,
                    .static => .static_method,
                    .class => .class_method,
                },
                .positional,
                null,
                methodParamNames(name),
            );
            const flags: c_int = c.METH_VARARGS | switch (kind) {
                .instance => 0,
                .static => c.METH_STATIC,
                .class => c.METH_CLASS,
            };
            return .{
                .ml_name = name,
                .ml_meth = switch (kind) {
                    .instance => @ptrCast(&wrapInstanceMethod(name)),
                    .static => @ptrCast(&wrapStaticMethod(name)),
                    .class => @ptrCast(&wrapClassMethod(name)),
                },
                .ml_flags = flags,
                .ml_doc = sig,
            };
        }

        fn wrapInstanceMethod(comptime name: []const u8) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;

            const S = struct {
                const Skip: usize = 1;

                fn releaseConverted(args: *std.meta.ArgsTuple(F), count: usize) void {
                    inline for (Params[Skip..], 0..) |param, i| {
                        if (i < count) {
                            if (param.type) |_| {
                                convert.releaseValue(&args[i + Skip]);
                            }
                        }
                    }
                }

                fn wrapper(py_self: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
                    const py = py_self orelse return null;
                    const data: *T = core.unwrap(T, py);
                    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
                    const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                    const N = Params.len - Skip;
                    if (num_pos != N) {
                        errors.typeError(
                            "{s}() takes exactly {d} positional argument(s) ({d} given)",
                            .{ name, N, num_pos },
                        ) catch {};
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    const FirstParam = Params[0].type orelse return null;
                    zig_args[0] = if (FirstParam == T) data.* else data;
                    var converted_count: usize = 0;
                    inline for (Params[Skip..], 0..) |param, i| {
                        const py_item = args_tuple.?.get(i) orelse {
                            errors.typeError("missing argument {d}", .{i + 1}) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        const PT = param.type orelse {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        zig_args[i + Skip] = convert.fromPy(PT, py_item) catch {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    releaseConverted(&zig_args, converted_count);
                    const RT = @TypeOf(result);
                    if (comptime std.mem.eql(u8, name, "__enter__")) {
                        if (RT == *T or RT == *const T) {
                            c.Py_INCREF(py);
                            return py;
                        }
                    }
                    return convert.handleReturn(RT, result);
                }
            };
            return S.wrapper;
        }

        fn wrapStaticMethod(comptime name: []const u8) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;

            const S = struct {
                fn releaseConverted(args: *std.meta.ArgsTuple(F), count: usize) void {
                    inline for (Params, 0..) |param, i| {
                        if (i < count) {
                            if (param.type) |_| {
                                convert.releaseValue(&args[i]);
                            }
                        }
                    }
                }

                fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
                    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
                    const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                    if (num_pos != Params.len) {
                        errors.typeError(
                            "{s}() takes exactly {d} positional argument(s) ({d} given)",
                            .{ name, Params.len, num_pos },
                        ) catch {};
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    var converted_count: usize = 0;
                    inline for (Params, 0..) |param, i| {
                        const py_item = args_tuple.?.get(i) orelse {
                            errors.typeError("missing argument {d}", .{i + 1}) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        const PT = param.type orelse {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        zig_args[i] = convert.fromPy(PT, py_item) catch {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    releaseConverted(&zig_args, converted_count);
                    return convert.handleReturn(@TypeOf(result), result);
                }
            };
            return S.wrapper;
        }

        fn wrapClassMethod(comptime name: []const u8) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;

            const S = struct {
                const Skip: usize = 1;

                fn releaseConverted(args: *std.meta.ArgsTuple(F), count: usize) void {
                    inline for (Params[Skip..], 0..) |param, i| {
                        if (i < count) {
                            if (param.type) |_| {
                                convert.releaseValue(&args[i + Skip]);
                            }
                        }
                    }
                }

                fn wrapper(py_self: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
                    const cls = py_self orelse return null;
                    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
                    const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                    const N = Params.len - Skip;
                    if (num_pos != N) {
                        errors.typeError(
                            "{s}() takes exactly {d} positional argument(s) ({d} given)",
                            .{ name, N, num_pos },
                        ) catch {};
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    const FirstParam = Params[0].type orelse return null;
                    if (FirstParam == *object.Object) {
                        zig_args[0] = @ptrCast(cls);
                    } else if (FirstParam == *c.PyObject) {
                        zig_args[0] = cls;
                    } else {
                        @compileError("class method '" ++ name ++ "' first parameter must be *Object or *c.PyObject");
                    }

                    var converted_count: usize = 0;
                    inline for (Params[Skip..], 0..) |param, i| {
                        const py_item = args_tuple.?.get(i) orelse {
                            errors.typeError("missing argument {d}", .{i + 1}) catch {};
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        const PT = param.type orelse {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        zig_args[i + Skip] = convert.fromPy(PT, py_item) catch {
                            releaseConverted(&zig_args, converted_count);
                            return null;
                        };
                        converted_count += 1;
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    releaseConverted(&zig_args, converted_count);
                    return convert.handleReturn(@TypeOf(result), result);
                }
            };
            return S.wrapper;
        }
    };
}
