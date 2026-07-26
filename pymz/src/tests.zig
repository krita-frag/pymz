//! Aggregates comptime-safe unit tests for the pymz core library.
//!
//! These tests do not require a Python interpreter and can be run with
//! `zig test pymz/src/tests.zig` or through the workspace `zig build test`.

const std = @import("std");
const common = @import("runtime/cpython/declarative/common.zig");
const dunders = @import("runtime/cpython/class/dunders.zig");
const fn_descriptor = @import("runtime/cpython/declarative/function.zig");
const class_descriptor = @import("runtime/cpython/declarative/class.zig");
const limiter = @import("runtime/cpython/limiter.zig");
const signature = @import("runtime/cpython/signature.zig");

// Pull in the pymz public API so the entire module is exercised.
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

test "builtin handled dunders are excluded from method table" {
    // The new dunders module queries builders, which check @hasDecl on T.
    // Dunders are only reserved when the type actually declares them.
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
    // Dunders NOT declared on the type are not reserved.
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
        pub const __pymz_excluded_dunders__ = &.{ "__await__", "__aiter__" };
    };
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__await__"));
    try std.testing.expect(dunders.isReservedDunder(TestClass, "__aiter__"));
    try std.testing.expect(!dunders.isReservedDunder(TestClass, "__anext__"));
}

test "per-class handled dunders are marked handled" {
    const TestClass = struct {
        pub const __pymz_handled_dunders__ = &.{"__await__"};
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
        // The mock backend reports is_limited_api = false (full ABI).
        // limited=true -> only active on limited ABI -> inactive here.
        // limited=false -> only active on full ABI -> active here.
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
    // The signature must start with the function name and open paren.
    try std.testing.expect(std.mem.startsWith(u8, doc, "add("));
    // The hidden $module parameter must be present for module-level functions.
    try std.testing.expect(std.mem.indexOf(u8, doc, "$module") != null);
    // The signature separator must follow the closing paren.
    try std.testing.expect(std.mem.indexOf(u8, doc, ")\n--\n\n") != null);
    // The docstring text must appear after the separator.
    try std.testing.expect(std.mem.indexOf(u8, doc, "Add two ints.") != null);
}

test "buildMlDoc for static method omits hidden parameter" {
    const doc = comptime signature.buildMlDoc("static_fn", @TypeOf(sigTwoArgs), .static_method, null);
    try std.testing.expect(std.mem.startsWith(u8, doc, "static_fn("));
    // Static methods must not have $module, $self, or $type.
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
    // A zero-arg module function still has $module, then /.
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
