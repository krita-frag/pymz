//! 为 Zig 支持的类生成 Python 方法表。

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

/// 编译期辅助函数：当 ``ValueType`` 是（可能是 const 的）字节切片时返回 true，
/// 即字符串字面量或 ``[]const u8``。用于区分作为单个逗号分隔字符串给出的
/// 逐方法参数名覆盖和作为名称数组给出的覆盖。
fn isByteSlice(comptime ValueType: type) bool {
    const info = @typeInfo(ValueType);
    if (info != .pointer) return false;
    return switch (info.pointer.size) {
        .slice => info.pointer.child == u8,
        // 字符串字面量（`*const [N:0]u8` / `*const [N]u8`）是指向 u8 数组的指针；
        // 它们可转换为 `[]const u8`，被视为逗号分隔的参数名字符串。
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
            if (!@hasDecl(T, "pymz_meta")) return null;
            const meta = T.pymz_meta;
            if (!@hasField(@TypeOf(meta), "method_param_names")) return null;
            const overrides = meta.method_param_names;
            if (!@hasField(@TypeOf(overrides), method_name)) return null;
            return extractParamNamesValue(@field(overrides, method_name));
        }

        fn extractParamNamesValue(comptime value: anytype) ?[]const u8 {
            const ValueType = @TypeOf(value);
            if (isByteSlice(ValueType)) {
                return value;
            }
            // 假设是参数名数组，拼接为字符串。
            return common.joinParamNames(value);
        }

        fn isClassMethod(comptime name: []const u8) bool {
            if (!@hasDecl(T, "pymz_meta")) return false;
            const meta = T.pymz_meta;
            if (!@hasField(@TypeOf(meta), "class_methods")) return false;
            const cm = meta.class_methods;
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

        /// 一次遍历 `decls` 统计实例/静态/类方法数量。
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

        /// 实例方法、静态方法和类方法的统一包装器。
        ///
        /// 三种方法类型仅在以下方面不同：
        ///   - 需要跳过的前导参数数量（实例/类方法为 1，静态方法为 0）
        ///   - 第一个参数如何实例化（数据指针、cls 或无）
        ///   - ``__enter__`` 返回 ``*T`` 时是否应返回 self
        ///
        /// 所有其他逻辑——参数个数检查、位置参数转换、释放和返回值处理——
        /// 完全相同，在此处实现一次。
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
                    // 计算必需（非可选）参数的数量，与 pyfn_typed 的行为一致：
                    // 可选参数可省略。
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

                    // 为实例方法和类方法实例化隐式第一个参数（self/cls）。
                    // 静态方法跳过此步骤。
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
                        // 镜像 pyfn_typed 的分发逻辑：先运行时位置参数检查，
                        // 再通过编译期 else if 分支检查可选类型。在运行时 if
                        // 内部嵌套编译期分支（或 continue）会被 Zig 0.16 拒绝，
                        // 因为运行时块内不允许编译期控制流。
                        if (i < num_pos) {
                            const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                            zig_args[i + Skip] = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label) catch {
                                marshal.releaseArgsTuple(F, &zig_args, converted_count, Skip);
                                return null;
                            };
                            converted_count += 1;
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

                    // ``__enter__`` 返回接收者自身，参与 with 语句时返回 self
                    // 而非新对象。
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

test "MethodBuilder 统计实例、静态和类方法" {
    const T = struct {
        x: i32 = 0,

        pub fn instanceMethod(self: *@This(), a: i32) i32 {
            return self.x + a;
        }

        pub fn staticMethod(a: i32, b: i32) i32 {
            return a + b;
        }

        pub const pymz_meta = .{
            .class_methods = .{ .classMethod = true },
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

test "MethodBuilder 空结构体的 total_method_count 为零" {
    const T = struct {};
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 0), M.total_method_count);
}

test "MethodBuilder 方法表以哨兵条目结尾" {
    const T = struct {
        pub fn helper(a: i32) i32 {
            return a;
        }
    };
    const M = MethodBuilder(T);
    const table = comptime M.buildMethodTable();
    // 1 个方法 + 1 个哨兵。
    try testing.expectEqual(@as(usize, 2), table.len);
    // 哨兵：null 名称、null 方法指针、零标志。
    try testing.expect(table[1].ml_name == null);
    try testing.expect(table[1].ml_meth == null);
    try testing.expectEqual(@as(c_int, 0), table[1].ml_flags);
}

test "MethodBuilder 通过第一个参数区分实例和静态方法" {
    const T = struct {
        value: i32 = 0,

        // 第一个参数是 *@This() -> 实例方法。
        pub fn inst(self: *@This()) i32 {
            return self.value;
        }

        // 第一个参数不是 *@This() -> 静态方法。
        pub fn stat(a: i32) i32 {
            return a;
        }
    };
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 1), M.instance_method_count);
    try testing.expectEqual(@as(usize, 1), M.static_method_count);
}

test "MethodBuilder 尊重 pymz_meta.class_methods 覆盖" {
    const T = struct {
        pub const pymz_meta = .{
            .class_methods = .{ .marked = true },
        };

        // 即使第一个参数看起来像实例参数（*@This()），
        // pymz_meta.class_methods 将其覆盖为类方法。
        pub fn marked(self: *@This()) i32 {
            return @intFromPtr(self);
        }
    };
    const M = MethodBuilder(T);
    try testing.expectEqual(@as(usize, 0), M.instance_method_count);
    try testing.expectEqual(@as(usize, 1), M.class_method_count);
}

test "MethodBuilder 从实例计数中排除已处理的 dunder" {
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
    // __repr__ 被排除（由 ReprBuilder 处理），只有 normalMethod 计入。
    try testing.expectEqual(@as(usize, 1), M.instance_method_count);
}

test "isByteSlice 识别字符串字面量类型" {
    try testing.expect(isByteSlice([]const u8));
    try testing.expect(isByteSlice([]u8));
    try testing.expect(!isByteSlice(i32));
    try testing.expect(!isByteSlice(*u8));
    try testing.expect(!isByteSlice([*:0]const u8));
}
