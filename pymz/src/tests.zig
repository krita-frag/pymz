//! pymz 核心库的编译期安全单元测试聚合。
//!
//! 这些测试不需要 Python 解释器，可通过 `zig test pymz/src/tests.zig`
//! 或通过工作区 `zig build test` 运行。

const std = @import("std");
const common = @import("runtime/cpython/declarative/common.zig");
const dunders = @import("runtime/cpython/class/dunders.zig");
const fn_descriptor = @import("runtime/cpython/declarative/function.zig");
const class_descriptor = @import("runtime/cpython/declarative/class.zig");
const limiter = @import("runtime/cpython/limiter.zig");
const signature = @import("runtime/cpython/signature.zig");
const convert = @import("runtime/cpython/convert.zig");

// 引入 pymz 公共 API，使整个模块被编译期检查覆盖。
const pymz = @import("pymz.zig");
comptime {
    _ = pymz;
}

test "FunctionOptions preserves doc and signature" {
    const opts = common.extractFunctionOptions(.{
        .doc = "A doc",
        .signature = "a, b",
    });
    try std.testing.expectEqualStrings("A doc", opts.doc.?);
    try std.testing.expectEqualStrings("a, b", opts.signature.?);
    try std.testing.expect(opts.param_names == null);
    try std.testing.expect(opts.limited == null);
}

test "FunctionOptions prefers param_names array over signature" {
    comptime {
        const opts = common.extractFunctionOptions(.{
            .doc = "A doc",
            .signature = "x, y",
            .param_names = &.{ "a", "b" },
        });
        const resolved = common.resolveParamNames(opts);
        try std.testing.expectEqualStrings("a,b", resolved.?);
    }
}

test "FunctionOptions supports limited platform filter" {
    const opts = common.extractFunctionOptions(.{
        .limited = true,
    });
    try std.testing.expect(opts.limited.?);
}

test "joinParamNames handles single and multiple names" {
    comptime {
        try std.testing.expectEqualStrings("x", common.joinParamNames(&.{"x"}));
        try std.testing.expectEqualStrings("x,y,z", common.joinParamNames(&.{ "x", "y", "z" }));
    }
}

test "positional string desc is treated as doc" {
    const opts = common.extractFunctionOptions("doc only");
    try std.testing.expectEqualStrings("doc only", opts.doc.?);
    try std.testing.expect(opts.signature == null);
}

test "pymz_meta excluded_dunders extend the registry" {
    const TestClass = struct {
        pub const pymz_meta = .{
            .excluded_dunders = &.{ "__await__", "__aiter__" },
        };
    };
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__await__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__aiter__"));
    try std.testing.expect(!dunders.isReservedDunder(TestClass, "__anext__"));
}

test "pymz_meta handled_dunders are marked handled" {
    const TestClass = struct {
        pub const pymz_meta = .{
            .handled_dunders = &.{"__await__"},
        };
    };
    try std.testing.expect(dunders.isHandled(TestClass, "__await__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__await__"));
}

test "builtin handled dunders are excluded from method table" {
    // 新的 dunders 模块查询构建器，构建器检查类型上是否有 @hasDecl。
    // 仅当类型实际声明了 dunder 时，它才被保留。
    const TestClass = struct {
        pub fn __repr__(self: *const @This()) []const u8 {
            _ = self;
            return "";
        }
        pub fn __len__(self: *const @This()) usize {
            _ = self;
            return 0;
        }
        pub fn __call__(self: *@This()) void {
            _ = self;
        }
        pub fn __del__(self: *@This()) void {
            _ = self;
        }
    };
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__repr__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__len__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__call__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__del__"));
    // 类型上未声明的 dunder 不会被保留。
    const EmptyClass = struct {};
    try std.testing.expect(!dunders.isReservedDunder(EmptyClass, "__repr__"));
    try std.testing.expect(!dunders.isReservedDunder(EmptyClass, "__len__"));
}

test "non-dunders and unknown dunders are not excluded" {
    const TestClass = struct {};
    try std.testing.expect(!dunders.isReservedDunder(TestClass, "increment"));
    try std.testing.expect(!dunders.isReservedDunder(TestClass, "__missing__"));
}

test "per-class excluded dunders extend the registry" {
    const TestClass = struct {
        pub const pymz_meta = .{
            .excluded_dunders = &.{ "__await__", "__aiter__" },
        };
    };
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__await__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__aiter__"));
    try std.testing.expect(!dunders.isReservedDunder(TestClass, "__anext__"));
}

test "per-class handled dunders are marked handled" {
    const TestClass = struct {
        pub const pymz_meta = .{
            .handled_dunders = &.{"__await__"},
        };
    };
    try std.testing.expect(dunders.isHandled(TestClass, "__await__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__await__"));
}

fn dummyFn() void {}
const DummyClassImpl = struct {};

test "isActiveForPlatform with no filter is always active" {
    comptime {
        try std.testing.expect(limiter.isActiveForPlatform(null));
    }
}

test "isActiveForPlatform matches limited filter against platform" {
    comptime {
        // mock 后端报告 is_limited_api = false（完整 ABI）。
        // limited=true -> 仅限 limited ABI 上活跃 -> 此处不活跃。
        // limited=false -> 仅限完整 ABI 上活跃 -> 此处活跃。
        try std.testing.expect(!limiter.isActiveForPlatform(true));
        try std.testing.expect(limiter.isActiveForPlatform(false));
    }
}

test "function descriptor is active by default" {
    const desc = fn_descriptor.positionalFunction(dummyFn, .{});
    try std.testing.expect(desc.is_active);
}

test "function descriptor respects limited filter" {
    const desc_full = fn_descriptor.positionalFunction(dummyFn, .{ .limited = false });
    try std.testing.expect(desc_full.is_active);

    const desc_limited = fn_descriptor.positionalFunction(dummyFn, .{ .limited = true });
    try std.testing.expect(!desc_limited.is_active);
}

test "class descriptor is active by default" {
    const desc = class_descriptor.class(DummyClassImpl, .{});
    try std.testing.expect(desc.is_active);
}

test "class descriptor respects limited filter" {
    const desc_full = class_descriptor.class(DummyClassImpl, .{ .limited = false });
    try std.testing.expect(desc_full.is_active);

    const desc_limited = class_descriptor.class(DummyClassImpl, .{ .limited = true });
    try std.testing.expect(!desc_limited.is_active);
}

fn sigVoidFn() void {}
fn sigTwoArgs(a: i64, b: i64) i64 {
    _ = a;
    _ = b;
    return 0;
}
fn sigOptArg(a: i64, b: ?i64) i64 {
    _ = a;
    _ = b;
    return 0;
}

test "buildMlDoc produces module-function signature with $module" {
    const doc = comptime signature.buildMlDoc("add", @TypeOf(sigTwoArgs), .module_func, "Add two ints.");
    // 签名必须以函数名和左括号开头。
    try std.testing.expect(std.mem.startsWith(u8, doc, "add("));
    // 模块级函数必须包含隐藏的 $module 参数。
    try std.testing.expect(std.mem.indexOf(u8, doc, "$module") != null);
    // 签名分隔符必须在右括号之后。
    try std.testing.expect(std.mem.indexOf(u8, doc, ")\n--\n\n") != null);
    // 文档字符串必须在分隔符之后出现。
    try std.testing.expect(std.mem.indexOf(u8, doc, "Add two ints.") != null);
}

test "buildMlDoc for static method omits hidden parameter" {
    const doc = comptime signature.buildMlDoc("static_fn", @TypeOf(sigTwoArgs), .static_method, null);
    try std.testing.expect(std.mem.startsWith(u8, doc, "static_fn("));
    // 静态方法不能有 $module、$self 或 $type。
    try std.testing.expect(std.mem.indexOf(u8, doc, "$module") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "$self") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "$type") == null);
}

test "buildMlDoc for instance method includes $self" {
    const doc = comptime signature.buildMlDoc(
        "method",
        @TypeOf(sigTwoArgs),
        .instance_method,
        "An instance method.",
    );
    try std.testing.expect(std.mem.indexOf(u8, doc, "$self") != null);
}

test "buildMlDoc renders optional params with =None default" {
    const doc = comptime signature.buildMlDoc("opt_fn", @TypeOf(sigOptArg), .module_func, null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "=None") != null);
}

test "buildMlDoc handles zero-argument functions" {
    const doc = comptime signature.buildMlDoc("void_fn", @TypeOf(sigVoidFn), .module_func, null);
    // 零参数模块函数仍然有 $module，然后是 /。
    try std.testing.expect(std.mem.indexOf(u8, doc, "$module") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, ")\n--\n\n") != null);
}

test "getParamName extracts names from comma-separated string" {
    try std.testing.expectEqualStrings(
        "alpha",
        comptime signature.getParamName("alpha,beta,gamma", 0),
    );
    try std.testing.expectEqualStrings(
        "beta",
        comptime signature.getParamName("alpha,beta,gamma", 1),
    );
    try std.testing.expectEqualStrings(
        "gamma",
        comptime signature.getParamName("alpha,beta,gamma", 2),
    );
}

test "getParamName trims surrounding whitespace" {
    try std.testing.expectEqualStrings(
        "x",
        comptime signature.getParamName(" x , y ", 0),
    );
    try std.testing.expectEqualStrings(
        "y",
        comptime signature.getParamName(" x , y ", 1),
    );
}

test "getParamName falls back to argN for out-of-range index" {
    try std.testing.expectEqualStrings(
        "arg2",
        comptime signature.getParamName("a,b", 2),
    );
}

test "buildMlDocWithOptions uses param_names override" {
    const doc = comptime signature.buildMlDocWithOptions(
        "named",
        @TypeOf(sigTwoArgs),
        .module_func,
        .positional,
        null,
        "left,right",
    );
    try std.testing.expect(std.mem.indexOf(u8, doc, "left") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "right") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "arg0") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "arg1") == null);
}

test "buildMlDocWithOptions varargs mode renders *args, **kwargs" {
    const doc = comptime signature.buildMlDocWithOptions(
        "varfn",
        @TypeOf(sigVoidFn),
        .module_func,
        .varargs,
        null,
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, doc, "*args") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "**kwargs") != null);
}

// ---------------------------------------------------------------------------
// classMeta 校验与 classMetaTemplate 模板辅助测试
// ---------------------------------------------------------------------------

const decl = pymz.py.decl;

test "classMeta accepts all known fields" {
    // 编译期通过即证明所有已知字段名都被接受；任何未知字段会触发 @compileError
    // 让整个测试文件编译失败，因此本测试同时是"接受有效字段"和"拒绝无效字段"
    // 的回归守卫——后者由编译器在编译期静态保证。
    const meta = comptime decl.classMeta(.{
        .readonly_fields = .{ .id = true },
        .method_param_names = .{ .add = "x,y" },
        .class_methods = .{ .create = true },
        .handled_dunders = &.{"__await__"},
        .excluded_dunders = &.{"__aiter__"},
    });
    try std.testing.expectEqual(true, meta.readonly_fields.id);
    try std.testing.expectEqualStrings("x,y", meta.method_param_names.add);
    try std.testing.expectEqual(true, meta.class_methods.create);
}

test "classMeta accepts subset of fields" {
    // 省略的字段在后端通过 @hasField 探测，等同默认值。
    const meta = comptime decl.classMeta(.{
        .readonly_fields = .{ .id = true },
    });
    try std.testing.expectEqual(true, meta.readonly_fields.id);
}

test "classMetaTemplate returns struct with all known fields" {
    const meta = comptime decl.classMetaTemplate();
    const T = @TypeOf(meta);

    // 所有 5 个已知字段都必须存在于返回类型中，证明模板覆盖完整。
    try std.testing.expect(@hasField(T, "readonly_fields"));
    try std.testing.expect(@hasField(T, "method_param_names"));
    try std.testing.expect(@hasField(T, "class_methods"));
    try std.testing.expect(@hasField(T, "handled_dunders"));
    try std.testing.expect(@hasField(T, "excluded_dunders"));

    // 默认值：空集合 / 空切片。
    try std.testing.expectEqual(@as(usize, 0), meta.handled_dunders.len);
    try std.testing.expectEqual(@as(usize, 0), meta.excluded_dunders.len);
}

test "classMetaTemplate passes classMeta validation" {
    // 模板返回值必须能通过 classMeta 校验——这要求模板的字段名集合
    // 与 classMeta 的 known_meta_fields 完全一致，是单一真相源的回归守卫。
    const meta = comptime decl.classMeta(decl.classMetaTemplate());
    const T = @TypeOf(meta);
    try std.testing.expect(@hasField(T, "readonly_fields"));
    try std.testing.expect(@hasField(T, "method_param_names"));
    try std.testing.expect(@hasField(T, "class_methods"));
    try std.testing.expect(@hasField(T, "handled_dunders"));
    try std.testing.expect(@hasField(T, "excluded_dunders"));
}

// ---------------------------------------------------------------------------
// Type conversion extensibility tests
// ---------------------------------------------------------------------------

test "hasUserToPy detects direct toPy declaration" {
    const MyType = struct {
        pub fn toPy(self: @This()) void {
            _ = self;
        }
    };
    try std.testing.expect(convert.hasUserToPy(MyType));
}

test "hasUserFromPy detects direct fromPy declaration" {
    const MyType = struct {
        pub fn fromPy(obj: anytype) void {
            _ = obj;
        }
    };
    try std.testing.expect(convert.hasUserFromPy(MyType));
}

test "hasUserToPy detects PymzConvert trait" {
    const MyType = struct {
        pub const PymzConvert = struct {
            pub fn intoPy(value: @This()) void {
                _ = value;
            }
            pub fn fromPy(obj: anytype) void {
                _ = obj;
            }
        };
    };
    try std.testing.expect(convert.hasUserToPy(MyType));
    try std.testing.expect(convert.hasUserFromPy(MyType));
}

test "hasUserToPy returns false for types without conversion" {
    const PlainStruct = struct {};
    try std.testing.expect(!convert.hasUserToPy(PlainStruct));
    try std.testing.expect(!convert.hasUserFromPy(PlainStruct));
}

test "hasUserToPy returns false for primitive types" {
    try std.testing.expect(!convert.hasUserToPy(i64));
    try std.testing.expect(!convert.hasUserToPy(f64));
    try std.testing.expect(!convert.hasUserToPy(bool));
    try std.testing.expect(!convert.hasUserFromPy(i64));
    try std.testing.expect(!convert.hasUserFromPy([]const u8));
}
