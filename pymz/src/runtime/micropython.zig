//! MicroPython backend skeleton.
//!
//! This backend is an architecture placeholder. It mirrors the headless
//! backend's minimal object model so that `pymz` modules can be compiled with
//! `--runtime micropython` and the build system can exercise the multi-backend
//! machinery end-to-end.
//!
//! A real MicroPython backend would use `py/dynruntime.h` and the `mpy_init`
//! entry point instead of the CPython-style `PyInit_` convention. That
//! integration is intentionally left for future work because MicroPython's
//! object model, module loader, and native-code toolchain differ radically
//! from CPython.

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

const mp_allocator = std.heap.page_allocator;

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
    const obj = mp_allocator.create(Object) catch @panic("micropython OOM");
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
            else => @panic("micropython Int.from unsupported type"),
        };
        const ptr = try mp_allocator.create(i64);
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
            else => @panic("micropython Float.from unsupported type"),
        };
        const ptr = try mp_allocator.create(f64);
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
        const ptr = try mp_allocator.allocSentinel(u8, value.len, 0);
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
        const ptr = try mp_allocator.allocSentinel(u8, value.len, 0);
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
        const items = try mp_allocator.alloc(*Object, size);
        @memset(items, none());
        const ptr = try mp_allocator.create([]*Object);
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
        const ptr = try mp_allocator.create(Map);
        ptr.* = Map.init(mp_allocator);
        return makeObject(.dict, @intFromPtr(ptr));
    }

    pub fn setItem(self: *Object, key: []const u8, value: *Object) Error!void {
        const owned_key = try mp_allocator.dupe(u8, key);
        errdefer mp_allocator.free(owned_key);
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

pub const ExceptionBase = error{MicroPythonException};

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

pub const RawArgs = struct {
    args: []*Object,
    kwargs: ?*Object,

    pub inline fn len(self: RawArgs) usize {
        return self.args.len;
    }

    pub inline fn get(self: RawArgs, i: usize) ?*Object {
        if (i >= self.args.len) return null;
        return self.args[i];
    }

    pub inline fn getObject(self: RawArgs, i: usize) Error!*Object {
        if (self.get(i)) |o| return o;
        return Error.InvalidArgument;
    }

    pub inline fn hasKwargs(_: RawArgs) bool {
        return false;
    }

    pub inline fn kwLen(_: RawArgs) usize {
        return 0;
    }

    pub inline fn getKw(_: RawArgs, _: [:0]const u8) ?*Object {
        return null;
    }

    pub inline fn getKwObject(_: RawArgs, _: [:0]const u8) Error!*Object {
        return Error.InvalidArgument;
    }
};

/// Typed keyword-argument wrapper compatible with the public `pymz.Args(T)` API.
pub fn Args(comptime T: type) type {
    return struct {
        value: T,
        pub const ArgsStruct = T;
    };
}

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
                .name = "MicroPythonClass",
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
                .name = "MicroPythonException",
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
            return Dict.new() catch @panic("micropython OOM");
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
        .name = "micropython",
        .capabilities = .{
            .gil = true,
            .class_model = true,
        },
    };
}

pub fn Backend() type {
    return @This();
}
