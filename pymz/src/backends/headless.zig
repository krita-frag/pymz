//! Headless backend for testing the pymz backend abstraction.
//!
//! This backend does not depend on any Python C API. It implements a minimal
//! in-memory object model just large enough to exercise the public `pymz.py`
//! surface and verify that the core library is not hard-coded to CPython.
//!
//! The object model is intentionally simple: scalars store their value directly
//! in a tagged `Object`, while containers use an allocator owned by the headless
//! runtime. This is enough to run unit tests and nix checks without a real
//! Python interpreter.

const std = @import("std");
const contract = @import("../backend.zig");

pub const Error = error{
    PyError,
    OutOfMemory,
    Overflow,
    InvalidArgument,
    IndexOutOfBounds,
    KeyNotFound,
    InvalidUtf8,
    SystemError,
    TypeError,
    IndexError,
    KeyError,
    NotImplemented,
    InvalidOperation,
};

pub inline fn Result(comptime T: type) type {
    return Error!T;
}

const headless_allocator = std.heap.page_allocator;

pub const Tag = enum(u8) {
    none,
    bool,
    int,
    float,
    string,
    bytes,
    list,
    dict,
    tuple,
    instance,
    exception,
};

pub const Object = extern struct {
    tag: Tag,
    _pad: [7]u8 = .{0} ** 7,
    data: usize,

    pub fn incref(self: *Object) void {
        _ = self;
    }

    pub fn decref(self: *Object) void {
        _ = self;
    }

    pub fn newref(self: *Object) *Object {
        return self;
    }

    pub fn asObject(self: *Object) *Object {
        return self;
    }
};

fn makeObject(tag: Tag, data: usize) *Object {
    const obj = headless_allocator.create(Object) catch @panic("headless OOM");
    obj.* = .{ .tag = tag, .data = data };
    return obj;
}

fn objectDataPtr(obj: *Object, comptime T: type) *T {
    return @ptrFromInt(obj.data);
}

fn objectDataPtrConst(obj: *const Object, comptime T: type) *const T {
    return @ptrFromInt(obj.data);
}

var none_object: Object = .{ .tag = .none, .data = 0 };

pub fn none() *Object {
    return &none_object;
}

pub fn boolean(value: bool) *Object {
    return makeObject(.bool, @intFromBool(value));
}

pub const Int = struct {
    pub fn from(value: anytype) Result(*Object) {
        const n: i64 = switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => @intCast(value),
            else => @panic("headless Int.from unsupported type"),
        };
        const ptr = try headless_allocator.create(i64);
        ptr.* = n;
        return makeObject(.int, @intFromPtr(ptr));
    }

    pub fn as(self: *const Object, comptime T: type) Error!T {
        if (self.tag != .int) return Error.TypeError;
        return std.math.cast(T, objectDataPtrConst(self, i64).*) orelse Error.TypeError;
    }
};

pub const Float = struct {
    pub fn from(value: anytype) Result(*Object) {
        const f: f64 = switch (@typeInfo(@TypeOf(value))) {
            .float, .comptime_float => @floatCast(value),
            .int => @floatFromInt(value),
            else => @panic("headless Float.from unsupported type"),
        };
        const ptr = try headless_allocator.create(f64);
        ptr.* = f;
        return makeObject(.float, @intFromPtr(ptr));
    }

    pub fn as(self: *const Object, comptime T: type) Error!T {
        if (self.tag != .float) return Error.TypeError;
        return @floatCast(objectDataPtrConst(self, f64).*);
    }
};

pub const Bool = struct {
    pub fn from(value: bool) Result(*Object) {
        return boolean(value);
    }

    pub fn as(self: *const Object) Error!bool {
        if (self.tag != .bool) return Error.TypeError;
        return self.data != 0;
    }
};

pub const Str = struct {
    pub fn fromSlice(value: []const u8) Result(*Object) {
        const ptr = try headless_allocator.allocSentinel(u8, value.len, 0);
        @memcpy(ptr[0..value.len], value);
        return makeObject(.string, @intFromPtr(ptr.ptr));
    }

    pub fn asSlice(self: *const Object) Error![]const u8 {
        if (self.tag != .string) return Error.TypeError;
        const ptr: [*:0]u8 = @ptrFromInt(self.data);
        return ptr[0..std.mem.len(ptr)];
    }
};

pub const Unicode = Str;

pub const Bytes = struct {
    pub fn fromSlice(value: []const u8) Result(*Object) {
        const ptr = try headless_allocator.allocSentinel(u8, value.len, 0);
        @memcpy(ptr[0..value.len], value);
        return makeObject(.bytes, @intFromPtr(ptr.ptr));
    }

    pub fn asSlice(self: *const Object) Error![]const u8 {
        if (self.tag != .bytes) return Error.TypeError;
        const ptr: [*:0]u8 = @ptrFromInt(self.data);
        return ptr[0..std.mem.len(ptr)];
    }
};

pub const ByteArray = Bytes;

pub const List = struct {
    pub fn new(size: usize) Result(*Object) {
        const items = try headless_allocator.alloc(*Object, size);
        @memset(items, none());
        const ptr = try headless_allocator.create([]*Object);
        ptr.* = items;
        return makeObject(.list, @intFromPtr(ptr));
    }

    pub fn setUnsafe(self: *Object, index: usize, value: *Object) void {
        const items = objectDataPtr(self, []*Object).*;
        items[index] = value;
    }

    pub fn getUnsafe(self: *const Object, index: usize) *Object {
        const items = objectDataPtrConst(self, []*Object).*;
        return items[index];
    }

    pub fn len(self: *const Object) usize {
        return objectDataPtrConst(self, []*Object).*.len;
    }
};

pub const Tuple = List;

pub const Dict = struct {
    const Map = std.StringHashMap(*Object);

    pub fn new() Result(*Object) {
        const ptr = try headless_allocator.create(Map);
        ptr.* = Map.init(headless_allocator);
        return makeObject(.dict, @intFromPtr(ptr));
    }

    pub fn setItem(self: *Object, key: []const u8, value: *Object) Error!void {
        const owned_key = try headless_allocator.dupe(u8, key);
        errdefer headless_allocator.free(owned_key);
        try objectDataPtr(self, Map).put(owned_key, value);
    }

    pub fn getItem(self: *const Object, key: []const u8) ?*Object {
        return objectDataPtrConst(self, Map).get(key);
    }
};

pub const Set = struct {
    pub fn fromSlice(_: []const *Object) Result(*Object) {
        return Error.NotImplemented;
    }
};

pub const FrozenSet = Set;

pub const Slice = struct {
    pub fn new(_: ?isize, _: ?isize, _: ?isize) Result(*Object) {
        return Error.NotImplemented;
    }
};

pub const Buffer = struct {
    pub const View = struct {
        buf: []const u8,
        shape: []const usize,
        strides: []const isize,
        format: []const u8,
    };
};

pub const Type = struct {
    pub fn check(_: *const Object, _: *const Object) bool {
        return true;
    }
};

pub const ExceptionBase = error{HeadlessException};

pub const Exception = struct {
    pub fn raise(base: ExceptionBase, comptime fmt: []const u8, args: anytype) Error {
        _ = base;
        _ = fmt;
        _ = args;
        return Error.InvalidOperation;
    }
};

pub const Repr = struct {
    pub const callback = fn (*Object) callconv(.c) ?*Object;
};

pub const Args = struct {
    pub fn positional(_: *Object, _: usize) Error!*Object {
        return Error.NotImplemented;
    }

    pub fn kwargs(_: *Object, _: []const u8) Error!?*Object {
        return Error.NotImplemented;
    }
};

pub const RawArgs = struct {
    pub fn len(_: RawArgs) usize {
        return 0;
    }

    pub fn get(_: RawArgs, _: usize) Error!*Object {
        return Error.NotImplemented;
    }
};

pub const FnMode = enum {
    positional,
    kwargs,
    mixed,
    varargs,
};

pub const ClassDef = struct {
    name: [:0]const u8,
    ready_fn: *const fn () *Object,
    doc: ?[:0]const u8,
    base: ?*const ClassDef = null,

    pub inline fn getTypeObject(self: ClassDef) *Object {
        return self.ready_fn();
    }
};

pub const ModuleInitFn = *const fn (*Object) Error!void;

pub const Module = struct {
    pub fn init(_: [:0]const u8) Result {
        return Dict.new();
    }
};

pub fn function(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    _ = func;
    _ = desc;
    return struct {
        pub const export_kind: enum { function } = .function;
        pub fn stub() contract.BackendSpec {
            return backendSpec();
        }
    };
}

pub fn positionalFunction(comptime func: anytype, comptime desc: anytype) type {
    return function(func, desc);
}

pub fn kwFunction(comptime func: anytype, comptime desc: anytype) type {
    return function(func, desc);
}

pub fn varargsFunction(comptime func: anytype, comptime desc: anytype) type {
    return function(func, desc);
}

pub fn class(comptime T: type, comptime doc: ?[:0]const u8) type {
    _ = T;
    return struct {
        pub const export_kind: enum { class } = .class;
        pub fn classdef() ClassDef {
            return .{
                .name = "HeadlessClass",
                .ready_fn = &ready,
                .doc = doc,
            };
        }

        fn ready() *Object {
            return makeObject(.instance, 0);
        }
    };
}

pub fn classWithBase(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime base: *const ClassDef,
    comptime doc: ?[:0]const u8,
) type {
    return struct {
        pub const export_kind: enum { class } = .class;
        pub fn classdef() ClassDef {
            return .{
                .name = name,
                .ready_fn = &ready,
                .doc = doc,
                .base = base,
            };
        }

        fn ready() *Object {
            _ = @sizeOf(T);
            return makeObject(.instance, 0);
        }
    };
}

pub fn exception(comptime base: ExceptionBase, comptime doc: ?[:0]const u8) type {
    _ = base;
    return struct {
        pub const export_kind: enum { exception } = .exception;
        pub fn classdef() ClassDef {
            return .{
                .name = "HeadlessException",
                .ready_fn = &ready,
                .doc = doc,
            };
        }

        fn ready() *Object {
            return makeObject(.exception, 0);
        }
    };
}

pub fn constant(comptime init: anytype) type {
    return struct {
        pub const export_kind: enum { constant } = .constant;
        pub const value = init;
    };
}

pub fn module(
    comptime name: [:0]const u8,
    comptime declarations_or_methods: anytype,
    comptime init_fn: ?ModuleInitFn,
    comptime doc: ?[:0]const u8,
) type {
    _ = declarations_or_methods;
    _ = init_fn;
    return struct {
        pub const module_name = name;
        pub const module_doc = doc;

        pub fn init() *Object {
            return Dict.new() catch @panic("headless OOM");
        }
    };
}

pub const ThreadState = opaque {};
pub const GILState = usize;

pub fn isInitialized() bool {
    return true;
}

pub fn initialize() void {}

pub fn finalize() void {}

pub fn saveThread() ?*ThreadState {
    return null;
}

pub fn restoreThread(_: ?*ThreadState) void {}

pub fn threadStateGet() ?*ThreadState {
    return null;
}

pub const GIL = struct {
    pub fn ensure() GILState {
        return 0;
    }

    pub fn release(_: GILState) void {}

    pub const Guard = struct {
        pub fn release(_: *Guard) void {}
        pub fn deinit(_: *Guard) void {}
    };

    pub fn acquire() Guard {
        return .{};
    }
};

pub const convert = struct {
    pub fn toPy(_: anytype) Error!*Object {
        return Error.NotImplemented;
    }

    pub fn fromPy(comptime T: type, _: *const Object) Error!T {
        return std.mem.zeroes(T);
    }
};

pub const py_major: u32 = 0;
pub const py_minor: u32 = 0;
pub const py_hex: u32 = 0;
pub const is_py3 = false;
pub const is_py2 = false;
pub const is_limited_api = false;

pub fn versionAtLeast(_: u32, _: u32) bool {
    return true;
}

pub fn backendSpec() contract.BackendSpec {
    return .{
        .name = "headless",
        .capabilities = .{
            .gil = true,
            .class_model = true,
        },
    };
}

pub fn Backend() type {
    return @This();
}
