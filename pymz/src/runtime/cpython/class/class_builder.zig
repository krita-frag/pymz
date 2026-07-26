//! Unified Python class builder: core helpers, lifecycle callbacks, and generation wiring.

const std = @import("std");
const c = @import("python_c");
const errors = @import("../errors.zig");
const object = @import("../object.zig");
const types = @import("../types.zig");
const convert = @import("../convert.zig");
const marshal = @import("../marshal.zig");
const traits = @import("../traits.zig");
const common = @import("../declarative/common.zig");
const decl_class = @import("../declarative/class.zig");
const methods = @import("methods.zig");
const repr = @import("repr.zig");
const protocol = @import("protocol.zig");

pub const Object = object.Object;
pub const Error = errors.Error;

pub const ClassDef = struct {
    /// The name baked into the type object's ``tp_name`` at comptime. This is
    /// informational: the actual attribute name under which the class is
    /// exported in a module is determined by ``Module.addClass``'s first
    /// parameter, not by this field.
    name: [:0]const u8,
    ready_fn: *const fn () ?*c.PyTypeObject,
    doc: ?[:0]const u8,
    base: ?*const ClassDef = null,

    pub inline fn getTypeObject(self: ClassDef) ?*c.PyTypeObject {
        return self.ready_fn();
    }
};

pub fn Wrapper(comptime T: type) type {
    return extern struct {
        ob_base: c.PyObject,
        initialized: bool,
        _pad: [0]u8 align(@alignOf(T)),
        _storage: [@sizeOf(T)]u8 align(@alignOf(T)),

        comptime {
            // Layout invariants required for safe CPython interop:
            // - PyObject header at offset 0 so CPython can treat the wrapper
            //   as a regular PyObject via pointer casts.
            std.debug.assert(@offsetOf(@This(), "ob_base") == 0);
            // - Overall alignment must satisfy T so that ``_storage`` can be
            //   cast to ``*T`` without misalignment.
            std.debug.assert(@alignOf(@This()) >= @alignOf(T));
        }

        pub inline fn fromPyObject(py: *c.PyObject) *Wrapper(T) {
            return @ptrCast(@alignCast(py));
        }

        pub inline fn asPyObject(self: *Wrapper(T)) *c.PyObject {
            return @ptrCast(self);
        }

        pub inline fn getData(self: *Wrapper(T)) *T {
            return @ptrCast(@alignCast(&self._storage));
        }

        pub inline fn getDataConst(self: *const Wrapper(T)) *const T {
            return @ptrCast(@alignCast(&self._storage));
        }
    };
}

pub inline fn unwrap(comptime T: type, py: *c.PyObject) *T {
    // std.debug.assert only fires in Debug/ReleaseSafe, matching the previous
    // explicit mode check. Reaching these with a null pointer is a C API
    // contract violation, not a user-facing error.
    std.debug.assert(@intFromPtr(py) != 0);
    std.debug.assert(@intFromPtr(py.*.ob_type) != 0);
    return Wrapper(T).fromPyObject(py).getData();
}

pub inline fn unwrapConst(comptime T: type, py: *c.PyObject) *const T {
    std.debug.assert(@intFromPtr(py) != 0);
    std.debug.assert(@intFromPtr(py.*.ob_type) != 0);
    return Wrapper(T).fromPyObject(py).getDataConst();
}

pub inline fn unwrapChecked(comptime T: type, py: *c.PyObject, typ: *c.PyTypeObject) ?*T {
    if (c.PyObject_TypeCheck(py, typ) == 0) {
        errors.typeError("expected {s}, got {s}", .{ typ.*.tp_name, convert.pyTypeName(@ptrCast(py)) });
        return null;
    }
    return unwrap(T, py);
}

pub inline fn unwrapCheckedConst(comptime T: type, py: *c.PyObject, typ: *c.PyTypeObject) ?*const T {
    if (c.PyObject_TypeCheck(py, typ) == 0) {
        errors.typeError("expected {s}, got {s}", .{ typ.*.tp_name, convert.pyTypeName(@ptrCast(py)) });
        return null;
    }
    return unwrapConst(T, py);
}

pub fn isPrivateField(comptime name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

pub fn isSelfParam(comptime T: type, comptime Self: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == Self,
        else => T == Self,
    };
}

pub fn countPublicFields(comptime T: type) usize {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".fields) |f| {
        if (!isPrivateField(f.name)) n += 1;
    }
    return n;
}

pub fn LifecycleBuilder(comptime T: type) type {
    return struct {
        const Self = Wrapper(T);
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
                        errors.typeError("this constructor does not accept keyword arguments", .{});
                        return -1;
                    }
                }
                if (num_pos != Params.len) {
                    errors.typeError(
                        "__new__ takes exactly {d} positional argument(s) ({d} given)",
                        .{ Params.len, num_pos },
                    );
                    return -1;
                }

                var zig_args: std.meta.ArgsTuple(Fn) = undefined;
                var converted_count: usize = 0;
                inline for (Params, 0..) |param, i| {
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing argument {d}", .{i + 1});
                        marshal.releaseArgsTuple(NewFn, &zig_args, converted_count, 0);
                        return -1;
                    };
                    const PT = param.type orelse {
                        marshal.releaseArgsTuple(NewFn, &zig_args, converted_count, 0);
                        return -1;
                    };
                    zig_args[i] = convert.fromPy(PT, py_item) catch {
                        marshal.releaseArgsTuple(NewFn, &zig_args, converted_count, 0);
                        return -1;
                    };
                    converted_count += 1;
                }
                const result = @call(.auto, T.__new__, zig_args);
                // `__new__` may return either a plain value or an error union.
                // Compile-time dispatch keeps the non-error path zero-cost.
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    wrapper.getData().* = result catch |err| {
                        marshal.releaseArgsTuple(NewFn, &zig_args, converted_count, 0);
                        if (errors.errorOccurred() == null) {
                            errors.mapError(err);
                        }
                        return -1;
                    };
                } else {
                    wrapper.getData().* = result;
                }
                wrapper.initialized = true;
                marshal.releaseArgsTuple(NewFn, &zig_args, converted_count, 0);
                return 0;
            }

            const args_tuple: ?*types.Tuple = if (args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;
            if (kwargs) |kw| {
                if (c.PyDict_Size(kw) != 0) {
                    errors.typeError("this constructor does not accept keyword arguments", .{});
                    return -1;
                }
            }

            var idx: usize = 0;
            var initialized_count: usize = 0;
            const data_ptr = wrapper.getData();
            inline for (fields) |field| {
                if (comptime isPrivateField(field.name)) {
                    if (field.default_value_ptr) |dv| {
                        @field(data_ptr.*, field.name) = dv.*;
                    }
                } else if (idx < num_pos) {
                    const py_item = args_tuple.?.get(idx) orelse {
                        errors.typeError("missing argument '{s}'", .{field.name});
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
                    errors.typeError("missing required argument '{s}'", .{field.name});
                    cleanupFieldsPrefix(data_ptr, initialized_count);
                    return -1;
                }
                initialized_count += 1;
            }
            wrapper.initialized = true;
            return 0;
        }

        fn cleanupFields(data: *T) void {
            inline for (fields) |field| {
                const FT = field.type;
                if (comptime traits.isObjectPtr(FT)) {
                    @field(data, field.name).decref();
                } else if (comptime traits.isObjectPtrOptional(FT)) {
                    if (@field(data, field.name)) |obj| obj.decref();
                } else if (!comptime isPrivateField(field.name)) {
                    convert.releaseValue(&@field(data, field.name));
                }
            }
        }

        fn cleanupFieldsPrefix(data: *T, count: usize) void {
            inline for (fields, 0..) |field, i| {
                if (i < count and !comptime isPrivateField(field.name)) {
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

fn ClassDefHelpers(comptime name: [:0]const u8, comptime base: ?*const ClassDef, comptime doc: ?[:0]const u8) type {
    return struct {
        pub fn classdef(comptime ready_fn: *const fn () ?*c.PyTypeObject) ClassDef {
            return .{
                .name = name,
                .ready_fn = ready_fn,
                .doc = doc,
                .base = if (comptime base) |b| b else null,
            };
        }
    };
}

/// Private fields (names starting with `_`) are NOT automatically released
/// by the framework's `cleanupFields` during deallocation. The user is
/// responsible for freeing any resources owned by private fields, typically
/// via `__del__`. Public fields are released automatically using `releaseValue`.
pub fn generateClass(comptime name: [:0]const u8, comptime T: type, comptime base: ?*const ClassDef, comptime doc: ?[:0]const u8) type {
    const Helpers = ClassDefHelpers(name, base, doc);
    const Lifecycle = LifecycleBuilder(T);
    const Methods = methods.MethodBuilder(T);
    const Properties = PropertiesBuilder(T);
    const ReprInfo = repr.ReprBuilder(T);
    const IteratorInfo = repr.IteratorBuilder(T);
    const ProtocolInfo = protocol.ProtocolBuilder(T);
    const BufferInfo = BufferBuilder(T);
    const GCInfo = GCBuilder(T);

    const method_table = Methods.buildMethodTable();
    const getset_table = Properties.buildGetSetTable();

    return struct {
        const Self = @This();
        pub const export_kind: common.ExportKind = .class;
        pub const WrapperType = Wrapper(T);

        pub var method_table_storage: [method_table.len]c.PyMethodDef = method_table;
        pub var getset_table_storage: [getset_table.len]c.PyGetSetDef = getset_table;

        pub var mapping_methods: c.PyMappingMethods = blk: {
            var m = std.mem.zeroes(c.PyMappingMethods);
            if (ProtocolInfo.has_len) m.mp_length = @ptrCast(&ProtocolInfo.py_len);
            if (ProtocolInfo.has_getitem) m.mp_subscript = @ptrCast(&ProtocolInfo.py_getitem);
            if (ProtocolInfo.has_setitem) m.mp_ass_subscript = @ptrCast(&ProtocolInfo.py_setitem);
            break :blk m;
        };

        pub var sequence_methods: c.PySequenceMethods = blk: {
            var s = std.mem.zeroes(c.PySequenceMethods);
            if (ProtocolInfo.has_len) s.sq_length = @ptrCast(&ProtocolInfo.py_len);
            if (ProtocolInfo.has_contains) s.sq_contains = @ptrCast(&ProtocolInfo.py_contains);
            break :blk s;
        };

        pub var buffer_methods: c.PyBufferProcs = blk: {
            var b = std.mem.zeroes(c.PyBufferProcs);
            if (BufferInfo.has_buffer) b.bf_getbuffer = @ptrCast(&BufferInfo.py_getbuffer);
            if (BufferInfo.has_buffer) b.bf_releasebuffer = @ptrCast(&BufferInfo.py_releasebuffer);
            break :blk b;
        };

        pub var type_object: c.PyTypeObject = blk: {
            // Hoist compound protocol conditions into named booleans so the
            // slot-assignment block below stays scannable and each decision
            // is documented at the point of declaration.
            const has_mapping = ProtocolInfo.has_len or
                ProtocolInfo.has_getitem or
                ProtocolInfo.has_setitem;
            const has_sequence = ProtocolInfo.has_len or ProtocolInfo.has_contains;
            const has_gc = GCInfo.has_traverse or GCInfo.has_clear;

            var t: c.PyTypeObject = std.mem.zeroes(c.PyTypeObject);
            t.tp_name = name;
            t.tp_basicsize = @sizeOf(WrapperType);
            t.tp_itemsize = 0;
            t.tp_dealloc = @ptrCast(&Lifecycle.py_dealloc);
            t.tp_new = @ptrCast(&Lifecycle.py_new);
            t.tp_init = @ptrCast(&Lifecycle.py_init);
            t.tp_methods = &method_table_storage;
            t.tp_flags = c.Py_TPFLAGS_DEFAULT | c.Py_TPFLAGS_BASETYPE;
            t.tp_doc = if (doc) |d| d else null;
            if (ReprInfo.has_repr) {
                t.tp_repr = @ptrCast(&ReprInfo.py_repr);
            }
            if (ReprInfo.has_str) {
                t.tp_str = @ptrCast(&ReprInfo.py_str);
            }
            if (IteratorInfo.has_iter) {
                t.tp_iter = @ptrCast(&IteratorInfo.py_iter);
            }
            if (IteratorInfo.has_next) {
                t.tp_iternext = @ptrCast(&IteratorInfo.py_iternext);
            }
            if (has_mapping) {
                t.tp_as_mapping = &mapping_methods;
            }
            if (has_sequence) {
                t.tp_as_sequence = &sequence_methods;
            }
            if (BufferInfo.has_buffer) {
                t.tp_as_buffer = &buffer_methods;
            }
            if (ProtocolInfo.has_call) {
                t.tp_call = @ptrCast(&ProtocolInfo.py_call);
            }
            if (ProtocolInfo.has_hash) {
                t.tp_hash = @ptrCast(&ProtocolInfo.py_hash);
            }
            if (ProtocolInfo.has_richcompare) {
                t.tp_richcompare = @ptrCast(&ProtocolInfo.py_richcompare);
            }
            if (ProtocolInfo.has_getattr) {
                t.tp_getattro = @ptrCast(&ProtocolInfo.py_getattr);
            }
            if (ProtocolInfo.has_setattr) {
                t.tp_setattro = @ptrCast(&ProtocolInfo.py_setattr);
            }
            if (GCInfo.has_traverse) {
                t.tp_traverse = @ptrCast(&GCInfo.py_traverse);
            }
            if (GCInfo.has_clear) {
                t.tp_clear = @ptrCast(&GCInfo.py_clear);
            }
            if (has_gc) {
                t.tp_flags |= c.Py_TPFLAGS_HAVE_GC;
            }
            break :blk t;
        };

        pub fn ready() ?*c.PyTypeObject {
            type_object.tp_getset = &getset_table_storage;
            if (comptime base) |b| {
                type_object.tp_base = b.ready_fn() orelse return null;
            }
            if (c.PyType_Ready(&type_object) < 0) {
                return null;
            }
            return &type_object;
        }

        pub fn classdef() ClassDef {
            return Helpers.classdef(&ready);
        }
    };
}

pub const ClassOptions = decl_class.ClassOptions;
const extractClassOptions = decl_class.extractClassOptions;

pub fn class(comptime name: [:0]const u8, comptime T: type, comptime doc_or_options: anytype) type {
    const opts = extractClassOptions(doc_or_options);
    return generateClass(name, T, null, opts.doc);
}

pub fn classWithBase(comptime name: [:0]const u8, comptime T: type, comptime base: *const ClassDef, comptime doc_or_options: anytype) type {
    const opts = extractClassOptions(doc_or_options);
    return generateClass(name, T, base, opts.doc);
}

// ── GCBuilder ─────────────────────────────────────────────────────────────
// Python GC protocol generation for Zig-backed classes.
// Detects and wraps `__traverse__` / `__clear__` dunders declared on T, and
// maps them to CPython's tp_traverse / tp_clear slot callbacks. The types are
// merged into this file because they are only used by `generateClass` above.

pub fn GCBuilder(comptime T: type) type {
    return struct {
        pub const has_traverse = @hasDecl(T, "__traverse__");
        pub const has_clear = @hasDecl(T, "__clear__");

        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_traverse) names = names ++ .{"__traverse__"};
            if (has_clear) names = names ++ .{"__clear__"};
            break :blk names;
        };

        pub fn py_traverse(py_self: ?*c.PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = unwrapConst(T, py);
            if (comptime has_traverse) {
                const UserVisit = *const fn (*Object, ?*anyopaque) callconv(.c) c_int;
                const user_visit: UserVisit = @ptrCast(visit);
                @field(T, "__traverse__")(data, user_visit, arg) catch return -1;
            }
            return 0;
        }

        pub fn py_clear(py_self: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = unwrap(T, py);
            if (comptime has_clear) {
                @field(T, "__clear__")(data) catch return -1;
            }
            return 0;
        }
    };
}

// ── BufferBuilder ──────────────────────────────────────────────────────────
// Python buffer protocol generation for Zig-backed classes.
// Detects and wraps `__buffer__` / `__release_buffer__` dunders, mapping them
// to CPython's tp_as_buffer.bf_getbuffer / bf_releasebuffer slots.

pub fn BufferBuilder(comptime T: type) type {
    return struct {
        pub const has_buffer = @hasDecl(T, "__buffer__");
        pub const has_release_buffer = @hasDecl(T, "__release_buffer__");

        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_buffer) names = names ++ .{"__buffer__"};
            if (has_release_buffer) names = names ++ .{"__release_buffer__"};
            break :blk names;
        };

        const BufferSlice = struct {
            ptr: [*c]u8,
            len: usize,
            readonly: bool,
        };

        fn bufferSliceFromResult(comptime RT: type, result: RT) BufferSlice {
            const info = @typeInfo(RT);
            const is_slice = info == .pointer and info.pointer.size == .slice;
            if (!is_slice) {
                @compileError("__buffer__ must return a []u8 or []const u8 slice, got " ++ @typeName(RT));
            }
            const is_const = info.pointer.is_const;
            const child = info.pointer.child;
            if (child != u8) {
                @compileError("__buffer__ must return a []u8 or []const u8 slice, got " ++ @typeName(RT));
            }
            const ptr: [*c]u8 = if (is_const)
                @ptrCast(@constCast(result.ptr))
            else
                @ptrCast(result.ptr);
            return .{ .ptr = ptr, .len = result.len, .readonly = is_const };
        }

        const BufferResult = union(enum) {
            slice: BufferSlice,
            buffer: object.Buffer,
        };

        fn bufferFromResult(comptime RT: type, result: RT) BufferResult {
            if (RT == object.Buffer) return .{ .buffer = result };
            return .{ .slice = bufferSliceFromResult(RT, result) };
        }

        fn callBuffer(data: *const T, flags: c_int) BufferResult {
            const F = @TypeOf(@field(T, "__buffer__"));
            const params = @typeInfo(F).@"fn".params;
            if (params.len == 1) {
                const result = @field(T, "__buffer__")(data);
                return bufferFromResult(@TypeOf(result), result);
            } else if (params.len == 2) {
                const result = @field(T, "__buffer__")(data, @as(u32, @intCast(flags)));
                return bufferFromResult(@TypeOf(result), result);
            } else {
                @compileError("__buffer__ must take either (self) or (self, flags: u32)");
            }
        }

        fn calcLen(shape: []const usize) usize {
            var len: usize = 1;
            for (shape) |dim| len *= dim;
            return len;
        }

        pub fn py_getbuffer(py_self: ?*c.PyObject, view: ?*c.Py_buffer, flags: c_int) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const v = view orelse return -1;
            const data = unwrapConst(T, py);
            const result = callBuffer(data, flags);

            switch (result) {
                .slice => |slice| {
                    return c.PyBuffer_FillInfo(
                        v,
                        py,
                        slice.ptr,
                        @intCast(slice.len),
                        if (slice.readonly) 1 else 0,
                        flags,
                    );
                },
                .buffer => |buf| {
                    v.buf = buf.ptr;
                    v.len = @intCast(calcLen(buf.shape));
                    v.readonly = if (buf.readonly) 1 else 0;
                    v.itemsize = 1;
                    if (@hasField(c.Py_buffer, "format")) {
                        v.format = if (buf.format) |f| @ptrCast(@constCast(f.ptr)) else null;
                    }
                    if (@hasField(c.Py_buffer, "ndim")) {
                        v.ndim = @intCast(buf.shape.len);
                    }
                    if (@hasField(c.Py_buffer, "shape")) {
                        v.shape = @ptrCast(@constCast(buf.shape.ptr));
                    }
                    if (@hasField(c.Py_buffer, "strides")) {
                        v.strides = if (buf.strides) |s| @ptrCast(@constCast(s.ptr)) else null;
                    }
                    if (@hasField(c.Py_buffer, "suboffsets")) {
                        v.suboffsets = null;
                    }
                    if (@hasField(c.Py_buffer, "internal")) {
                        v.internal = null;
                    }
                    if (@hasField(c.Py_buffer, "obj")) {
                        v.obj = py;
                        object.increfRaw(py);
                    }
                    return 0;
                },
            }
        }

        pub fn py_releasebuffer(py_self: ?*c.PyObject, view: ?*c.Py_buffer) callconv(.c) void {
            _ = view;
            if (comptime has_release_buffer) {
                const py = py_self orelse return;
                const data = unwrapConst(T, py);
                @field(T, "__release_buffer__")(data);
            }
        }
    };
}

// ── PropertiesBuilder ──────────────────────────────────────────────────────
// Python property (getset) table generation for Zig-backed classes.
// Public struct fields are exposed as Python attributes. The
// `__pymz_readonly_fields__` magic constant can mark specific fields as
// getter-only (no setter generated).

pub fn PropertiesBuilder(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".fields;
        const public_count = countPublicFields(T);

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
                if (!isPrivateField(field.name)) {
                    table[idx] = makeGetSetDef(field);
                    idx += 1;
                }
            }
            return table;
        }

        fn makeGetSetDef(comptime field: anytype) c.PyGetSetDef {
            const FieldType = field.type;
            const field_name = field.name;
            const name_z: [:0]const u8 = comptime convert.toSentinelStr(field_name);

            const Getter = struct {
                fn get(py_self: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
                    const py = py_self orelse return null;
                    const data = unwrapConst(T, py);
                    const value = @field(data, field_name);
                    const obj = convert.toPy(value) catch return null;
                    return @ptrCast(obj);
                }
            };

            const Setter = struct {
                fn set(py_self: ?*c.PyObject, py_value: ?*c.PyObject, _: ?*anyopaque) callconv(.c) c_int {
                    const py = py_self orelse return -1;
                    const data = unwrap(T, py);
                    const v = py_value orelse {
                        errors.typeError("cannot delete attribute '{s}'", .{field_name});
                        return -1;
                    };
                    const obj: *Object = @ptrCast(v);
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

const testing = std.testing;

test "isPrivateField identifies underscore-prefixed names" {
    try testing.expect(isPrivateField("_internal"));
    try testing.expect(isPrivateField("__dunder"));
    try testing.expect(!isPrivateField("public"));
    try testing.expect(!isPrivateField("a"));
    // Empty string is not private: no leading underscore.
    try testing.expect(!isPrivateField(""));
}

test "isSelfParam matches value and pointer self types" {
    const T = struct { x: i32 };

    // By value.
    try testing.expect(isSelfParam(T, T));

    // By pointer (const and mutable).
    try testing.expect(isSelfParam(*T, T));
    try testing.expect(isSelfParam(*const T, T));

    // Non-matching types.
    try testing.expect(!isSelfParam(i32, T));
    try testing.expect(!isSelfParam(*i32, T));
}

test "countPublicFields skips private fields" {
    const T = struct {
        public_a: i32,
        _private_b: i32,
        public_c: []const u8,
        __pymz_marker__: i32 = 0,
    };
    // public_a and public_c are public; _private_b and __pymz_marker__ are private.
    try testing.expectEqual(@as(usize, 2), countPublicFields(T));
}

test "countPublicFields returns zero for all-private struct" {
    const T = struct {
        _a: i32,
        _b: i32,
    };
    try testing.expectEqual(@as(usize, 0), countPublicFields(T));
}

test "countPublicFields returns count for all-public struct" {
    const T = struct {
        a: i32,
        b: i32,
        c: i32,
    };
    try testing.expectEqual(@as(usize, 3), countPublicFields(T));
}

test "Wrapper places PyObject at offset zero" {
    const T = struct { x: i64, y: i64 };
    const W = Wrapper(T);
    // The PyObject header must be the first field so CPython can cast the
    // wrapper pointer to PyObject*.
    try testing.expectEqual(@as(usize, 0), @offsetOf(W, "ob_base"));
}

test "Wrapper storage is aligned to T" {
    const T = struct { x: i64, y: i64 };
    const W = Wrapper(T);
    // The overall wrapper alignment must satisfy T's alignment so that
    // _storage can be cast to *T without misalignment.
    try testing.expect(@alignOf(W) >= @alignOf(T));
}

test "Wrapper storage has enough bytes for T" {
    const T = struct { x: i64, y: i64, z: [16]u8 };
    const W = Wrapper(T);
    // _storage is [@sizeOf(T)]u8, so the wrapper must be at least that large
    // plus the PyObject header.
    try testing.expect(@sizeOf(W) >= @sizeOf(c.PyObject) + @sizeOf(T));
}

test "extractClassOptions accepts doc string" {
    const opts = extractClassOptions("a doc");
    try testing.expectEqualStrings("a doc", opts.doc.?);
    try testing.expect(opts.limited == null);
}

test "extractClassOptions accepts options struct" {
    const opts = extractClassOptions(.{ .doc = "d", .limited = true });
    try testing.expectEqualStrings("d", opts.doc.?);
    try testing.expect(opts.limited.? == true);
}

test "extractClassOptions accepts options struct with only doc" {
    const opts = extractClassOptions(.{ .doc = "only doc" });
    try testing.expectEqualStrings("only doc", opts.doc.?);
    try testing.expect(opts.limited == null);
}

test "extractClassOptions accepts options struct with only limited" {
    const opts = extractClassOptions(.{ .limited = false });
    try testing.expect(opts.doc == null);
    try testing.expect(opts.limited.? == false);
}
