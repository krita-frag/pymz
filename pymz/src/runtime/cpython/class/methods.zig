//! Python method table generation for Zig-backed classes.

const std = @import("std");
const c = @import("python_c");
const common = @import("../declarative/common.zig");
const convert = @import("../convert.zig");
const marshal = @import("../marshal.zig");
const dunders = @import("dunders.zig");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const signature = @import("../signature.zig");
const types = @import("../types.zig");
const core = @import("class_builder.zig");

/// Comptime helper: true when ``ValueType`` is a (possibly const) byte slice,
/// i.e. a string literal or ``[]const u8``. Used to distinguish per-method
/// param-name overrides given as a single comma-separated string from those
/// given as an array of names.
fn isByteSlice(comptime ValueType: type) bool {
    const info = @typeInfo(ValueType);
    if (info != .pointer) return false;
    return switch (info.pointer.size) {
        .slice => info.pointer.child == u8,
        // String literals (`*const [N:0]u8` / `*const [N]u8`) are pointers to
        // u8 arrays; they coerce to `[]const u8` and are treated as a
        // comma-separated parameter-name string.
        .one => switch (@typeInfo(info.pointer.child)) {
            .array => |arr| arr.child == u8,
            else => false,
        },
        else => false,
    };
}

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
            const value = @field(overrides, method_name);
            const ValueType = @TypeOf(value);
            if (isByteSlice(ValueType)) {
                return value;
            }
            // Assume array of parameter names and join them.
            return common.joinParamNames(value);
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
            return dunders.isReservedDunder(T, name);
        }

        const Counts = struct {
            instance: usize,
            static: usize,
            class: usize,

            fn total(self: Counts) usize {
                return self.instance + self.static + self.class;
            }
        };

        /// Count instance/static/class methods in a single pass over `decls`.
        fn countMethods() Counts {
            var instance_n: usize = 0;
            var static_n: usize = 0;
            var class_n: usize = 0;
            for (decls) |d| {
                switch (methodKind(d.name)) {
                    .instance => {
                        if (!isExcludedDunder(d.name)) instance_n += 1;
                    },
                    .static => {
                        if (isFunctionDecl(d.name)) static_n += 1;
                    },
                    .class => {
                        if (isFunctionDecl(d.name)) class_n += 1;
                    },
                }
            }
            return .{ .instance = instance_n, .static = static_n, .class = class_n };
        }

        const method_counts = countMethods();
        const instance_method_count = method_counts.instance;
        const static_method_count = method_counts.static;
        const class_method_count = method_counts.class;
        pub const total_method_count = instance_method_count + static_method_count + class_method_count;

        pub fn buildMethodTable() [total_method_count + 1]c.PyMethodDef {
            var table: [total_method_count + 1]c.PyMethodDef = undefined;
            var instance_idx: usize = 0;
            var static_idx: usize = instance_method_count;
            var class_idx: usize = instance_method_count + static_method_count;
            inline for (decls) |d| {
                switch (methodKind(d.name)) {
                    .instance => if (!isExcludedDunder(d.name)) {
                        table[instance_idx] = makeMethodDef(d.name, .instance);
                        instance_idx += 1;
                    },
                    .static => if (isFunctionDecl(d.name)) {
                        table[static_idx] = makeMethodDef(d.name, .static);
                        static_idx += 1;
                    },
                    .class => if (isFunctionDecl(d.name)) {
                        table[class_idx] = makeMethodDef(d.name, .class);
                        class_idx += 1;
                    },
                }
            }
            table[total_method_count] = .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
            return table;
        }

        fn makeMethodDef(comptime name: [:0]const u8, comptime kind: MethodKind) c.PyMethodDef {
            const F = @TypeOf(@field(T, name));
            const sig = signature.buildMlDocWithOptions(
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
                .ml_meth = @ptrCast(&wrapMethod(name, kind)),
                .ml_flags = flags,
                .ml_doc = sig,
            };
        }

        /// Unified wrapper for instance, static, and class methods.
        ///
        /// The three method kinds differ only in:
        ///   - how many leading params to skip (1 for instance/class, 0 for static)
        ///   - how the first param is materialised (data pointer, cls, or nothing)
        ///   - whether ``__enter__`` returning ``*T`` should return self
        ///
        /// All other logic — arity check, positional conversion, release, and
        /// return handling — is identical and lives here once.
        fn wrapMethod(
            comptime name: []const u8,
            comptime kind: MethodKind,
        ) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const F = @TypeOf(@field(T, name));
            const fn_info = @typeInfo(F).@"fn";
            const Params = fn_info.params;
            const Skip: usize = switch (kind) {
                .instance, .class => 1,
                .static => 0,
            };
            const is_enter = kind == .instance and std.mem.eql(u8, name, "__enter__");

            const S = struct {
                fn wrapper(py_self: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
                    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
                    const num_pos: usize = if (args_tuple) |t| t.length() else 0;
                    const N = Params.len - Skip;
                    // Count required (non-optional) parameters, matching
                    // pyfn_typed's behavior: optional params may be omitted.
                    const required_count = comptime marshal.requiredParamCount(F, Skip);
                    if (num_pos < required_count or num_pos > N) {
                        errors.typeError(
                            "{s}() takes {d}-{d} positional argument(s) ({d} given)",
                            .{ name, required_count, N, num_pos },
                        );
                        return null;
                    }

                    var zig_args: std.meta.ArgsTuple(F) = undefined;
                    var converted_count: usize = 0;

                    // Materialise the implicit first parameter (self/cls) for
                    // instance and class methods. Static methods skip this.
                    switch (kind) {
                        .instance => {
                            const py = py_self orelse return null;
                            const data: *T = core.unwrap(T, py);
                            const FirstParam = Params[0].type orelse return null;
                            zig_args[0] = if (FirstParam == T) data.* else data;
                        },
                        .class => {
                            const cls = py_self orelse return null;
                            const FirstParam = Params[0].type orelse return null;
                            if (FirstParam == *object.Object) {
                                zig_args[0] = @ptrCast(cls);
                            } else if (FirstParam == *c.PyObject) {
                                zig_args[0] = cls;
                            } else {
                                @compileError(
                                    "class method '" ++ name ++
                                        "' first parameter must be *Object or *c.PyObject",
                                );
                            }
                        },
                        .static => {},
                    }

                    inline for (Params[Skip..], 0..) |param, i| {
                        const PT = param.type orelse {
                            errors.typeError("missing argument {d}", .{i + 1});
                            marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                            return null;
                        };
                        // Mirror pyfn_typed's dispatch: a runtime positional
                        // check on top, with the comptime optional-type check
                        // as a sibling `else if` branch. Nesting a comptime
                        // branch (or `continue`) inside the runtime `if` is
                        // rejected by Zig 0.16 as comptime control flow inside
                        // a runtime block.
                        if (i < num_pos) {
                            const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                            const converted = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label);
                            if (converted) |value| {
                                zig_args[i + Skip] = value;
                                converted_count += 1;
                            } else {
                                marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                                return null;
                            }
                        } else if (comptime @typeInfo(PT) == .optional) {
                            zig_args[i + Skip] = null;
                        } else {
                            errors.typeError("missing argument {d}", .{i + 1});
                            marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                            return null;
                        }
                    }

                    const result = @call(.auto, @field(T, name), zig_args);
                    marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                    const RT = @TypeOf(result);

                    // ``__enter__`` returning the receiver participates in
                    // with-statements by returning self instead of a new object.
                    if (is_enter) {
                        if (RT == *T or RT == *const T) {
                            const py = py_self orelse return null;
                            object.increfRaw(py);
                            return py;
                        }
                    }

                    return marshal.handleReturn(RT, result);
                }
            };
            return S.wrapper;
        }
    };
}
const testing = std.testing;

test "MethodBuilder counts instance, static, and class methods" {
    const T = struct {
        x: i32 = 0,

        pub fn instanceMethod(self: *@This(), a: i32) i32 {
            return self.x + a;
        }

        pub fn staticMethod(a: i32, b: i32) i32 {
            return a + b;
        }

        pub const __pymz_class_methods__ = .{
            .classMethod = true,
        };
        pub fn classMethod(cls: *c.PyObject, a: i32) i32 {
            _ = cls;
            return a;
        }
    };
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 1), M.instance_method_count);
    try testing.expectEqual(@as(usize, 1), M.static_method_count);
    try testing.expectEqual(@as(usize, 1), M.class_method_count);
    try testing.expectEqual(@as(usize, 3), M.total_method_count);
}

test "MethodBuilder total_method_count is zero for empty struct" {
    const T = struct {};
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 0), M.total_method_count);
}

test "MethodBuilder table ends with sentinel entry" {
    const T = struct {
        pub fn helper(a: i32) i32 {
            return a;
        }
    };
    const M = MethodBuilder(T);
    const table = comptime M.buildMethodTable();
    // 1 method + 1 sentinel.
    try testing.expectEqual(@as(usize, 2), table.len);
    // Sentinel: null name, null meth, zero flags.
    try testing.expect(table[1].ml_name == null);
    try testing.expect(table[1].ml_meth == null);
    try testing.expectEqual(@as(c_int, 0), table[1].ml_flags);
}

test "MethodBuilder distinguishes instance from static by first param" {
    const T = struct {
        value: i32 = 0,

        // First param is *@This() -> instance method.
        pub fn inst(self: *@This()) i32 {
            return self.value;
        }

        // First param is not *@This() -> static method.
        pub fn stat(a: i32) i32 {
            return a;
        }
    };
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 1), M.instance_method_count);
    try testing.expectEqual(@as(usize, 1), M.static_method_count);
}

test "MethodBuilder respects __pymz_class_methods__ override" {
    const T = struct {
        pub const __pymz_class_methods__ = .{
            .marked = true,
        };

        // Even though the first param looks like an instance param (*@This()),
        // __pymz_class_methods__ overrides it to be a class method.
        pub fn marked(self: *@This()) i32 {
            return @intFromPtr(self);
        }
    };
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 0), M.instance_method_count);
    try testing.expectEqual(@as(usize, 1), M.class_method_count);
}

test "MethodBuilder excludes handled dunders from instance count" {
    const T = struct {
        pub fn __repr__(self: *const @This()) []const u8 {
            _ = self;
            return "T";
        }
        pub fn normalMethod(self: *@This()) void {
            _ = self;
        }
    };
    const M = MethodBuilder(T);
    // __repr__ is excluded (handled by ReprBuilder), only normalMethod counts.
    try testing.expectEqual(@as(usize, 1), M.instance_method_count);
}

test "isByteSlice identifies string literal types" {
    try testing.expect(isByteSlice([]const u8));
    try testing.expect(isByteSlice([]u8));
    try testing.expect(!isByteSlice(i32));
    try testing.expect(!isByteSlice(*u8));
    try testing.expect(!isByteSlice([*:0]const u8));
}
