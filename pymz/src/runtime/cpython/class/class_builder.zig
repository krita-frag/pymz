//! 统一的 Python 类构建器：核心辅助函数、生命周期回调和生成编排。

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
    /// 编译期写入类型对象 ``tp_name`` 的名称。此为参考信息：类在模块中导出的
    /// 实际属性名由 ``Module.addClass`` 的第一个参数决定，而非此字段。
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
            // 安全 CPython 互操作所需的布局不变性：
            // - PyObject 头部在偏移量 0 处，使 CPython 可通过指针转换将包装器视为常规 PyObject。
            // - 整体对齐必须满足 T，使 ``_storage`` 可转换为 ``*T`` 而不产生不对齐。
            std.debug.assert(@offsetOf(@This(), "ob_base") == 0);
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
    // std.debug.assert 仅在 Debug/ReleaseSafe 模式下触发。传入空指针是 C API
    // 契约违规，而非用户可处理的错误。
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
        // GC 参与：类有框架管理的 PyObject 字段或用户定义的 __traverse__/__clear__
        // 时启用 GC。py_dealloc 需在清理前 untrack 以防止 GC 遍历半拆除的对象。
        const has_gc = @hasDecl(T, "__traverse__") or @hasDecl(T, "__clear__") or blk: {
            for (fields) |field| {
                if (!isPrivateField(field.name)) {
                    if (traits.isObjectPtr(field.type) or traits.isObjectPtrOptional(field.type)) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };

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
                // __new__ 可能返回普通值或错误联合。编译期分发使非错误路径零开销。
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
                        const typed_ptr: *const field.type = @ptrCast(@alignCast(dv));
                        @field(data_ptr.*, field.name) = typed_ptr.*;
                    }
                } else if (idx < num_pos) {
                    const py_item = args_tuple.?.get(idx) orelse {
                        errors.typeError("missing argument '{s}'", .{field.name});
                        initErrorCleanup(data_ptr, initialized_count);
                        return -1;
                    };
                    @field(data_ptr.*, field.name) = blk: {
                        const converted = convert.fromPy(field.type, py_item) catch {
                            initErrorCleanup(data_ptr, initialized_count);
                            return -1;
                        };
                        // fromPy 对 *Object / ?*Object 返回借用引用（无 incref），
                        // 类字段需要 owned 引用（dealloc 时由 cleanupFields decref），
                        // 因此在此显式 incref。
                        if (comptime traits.isObjectPtr(field.type)) {
                            converted.incref();
                        } else if (comptime traits.isObjectPtrOptional(field.type)) {
                            if (converted) |o| o.incref();
                        }
                        break :blk converted;
                    };
                    idx += 1;
                } else if (field.default_value_ptr) |dv| {
                    // default_value_ptr is *const anyopaque; cast to the field's
                    // type before dereferencing to load the comptime-known default.
                    @field(data_ptr.*, field.name) = @as(*const field.type, @ptrCast(@alignCast(dv))).*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(data_ptr.*, field.name) = null;
                } else {
                    errors.typeError("missing required argument '{s}'", .{field.name});
                    initErrorCleanup(data_ptr, initialized_count);
                    return -1;
                }
                initialized_count += 1;
            }
            wrapper.initialized = true;
            return 0;
        }

        /// 释放结构体字段资源。
        ///
        /// `count` 为 `null` 时释放所有字段（用于 `py_dealloc`）；为 `n` 时只
        /// 释放前 `n` 个字段（用于 `py_init` 部分初始化失败后的回滚）。
        ///
        /// 类型感知：
        ///   - `isObjectPtr`：decref（PyObject 指针字段，框架持有新引用）。
        ///   - `isObjectPtrOptional`：非空时 decref。
        ///   - 非私有字段：`releaseValue`（处理 owned bytes、ArrayList 等）。
        ///   - 私有字段（`_` 前缀）：跳过，由用户的 `__del__` 负责。
        ///
        /// 旧实现的 `cleanupFieldsPrefix` 仅调用 `releaseValue` 而无 `isObjectPtr`
        /// 分支，导致 `py_init` 部分初始化失败时 `*Object` 字段不被 decref，造成
        /// 引用泄漏。此合并实现统一类型感知逻辑，消除该泄漏。
        ///
        /// 实现说明：`inline for` 的循环索引 `i` 是 comptime 已知，但 `limit`
        /// 来自运行时参数 `count`。Zig 0.16 禁止在 `inline for` 中用运行时条件
        /// 触发 `continue`（"comptime control flow inside runtime block"），因此
        /// 把运行时边界检查改为包裹循环体的 `if (i < limit)`，让 `comptime if`
        /// 分支在 runtime block 内仍可被编译期求值。
        fn cleanupFields(data: *T, count: ?usize) void {
            const limit = count orelse fields.len;
            inline for (fields, 0..) |field, i| {
                if (i < limit) {
                    const FT = field.type;
                    if (comptime traits.isObjectPtr(FT)) {
                        @field(data, field.name).decref();
                    } else if (comptime traits.isObjectPtrOptional(FT)) {
                        if (@field(data, field.name)) |obj| obj.decref();
                        @field(data, field.name) = null;
                    } else if (!comptime isPrivateField(field.name)) {
                        convert.releaseValue(&@field(data, field.name));
                    }
                }
            }
        }

        /// Error-path cleanup for py_init: calls __del__ (if any fields were
        /// initialized) to release private field resources, then cleanupFields
        /// for public fields. The user's __del__ must handle partially
        /// initialized state (uninitialized fields are zeroed memory).
        fn initErrorCleanup(data: *T, count: usize) void {
            if (has_del and count > 0) {
                T.__del__(data);
            }
            cleanupFields(data, count);
        }

        pub fn py_dealloc(py_self: ?*c.PyObject) callconv(.c) void {
            const py = py_self orelse return;
            const wrapper: *Self = @ptrCast(@alignCast(py));

            // GC 跟踪对象在 cleanupFields 之前取消跟踪，以防止
            // decref 触发对部分拆除对象的 GC 遍历。
            // 使用 pymz_PyObject_GC_UnTrack 包装器（python_c.h），在所有 Python 版本中可见。
            if (comptime has_gc) {
                c.pymz_PyObject_GC_UnTrack(@ptrCast(py));
            }

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
                cleanupFields(wrapper.getData(), null);
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

/// 以下划线开头的私有字段不会在析构时由框架的 ``cleanupFields`` 自动释放。
/// 用户需负责释放私有字段持有的资源，通常通过 ``__del__`` 实现。
/// 公共字段使用 ``releaseValue`` 自动释放。
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
            // mp_ass_subscript 同时承担 __setitem__ 与 __delitem__：
            // py_setitem 包装器按 py_value 是否为 NULL 分流到对应方法。
            // 任一声明即需安装插槽。
            if (ProtocolInfo.has_setitem or ProtocolInfo.has_delitem) m.mp_ass_subscript = @ptrCast(&ProtocolInfo.py_setitem);
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
            // 将复合协议条件提升为命名布尔常量，使插槽赋值块的每个决策在声明点即文档化。
            const has_mapping = ProtocolInfo.has_len or
                ProtocolInfo.has_getitem or
                ProtocolInfo.has_setitem or
                ProtocolInfo.has_delitem;
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
                // GC 跟踪对象通过 PyType_GenericAlloc 分配，内存布局在
                // PyObject 前包含 PyGC_Head。tp_free 必须是 PyObject_GC_Del
                // 以正确释放整个 GC 头部 + 对象块；使用 PyObject_Free 会
                // 从错误偏移释放，导致 GC 头部泄漏或堆损坏。
                t.tp_flags |= c.Py_TPFLAGS_HAVE_GC;
                t.tp_free = @ptrCast(&c.PyObject_GC_Del);
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
// 为 Zig 支持的类生成 Python GC 协议。
//
// 框架管理的公共 PyObject 字段（非 _ 前缀的 *Object / ?*Object）在 dealloc 时
// 由 cleanupFields 自动 decref。GCBuilder 与此对称：py_traverse 自动访问这些
// 字段使 GC 能检测循环引用，py_clear 自动清除 ?*Object 字段（decref + NULL）
// 以打破循环。
//
// 用户通过 __traverse__ / __clear__ 管理私有字段（_ 前缀），作为框架自动
// 行为的补充而非替代。当类同时有公共 PyObject 字段和用户定义的 __traverse__
// 时，两者都会被调用：先访问框架字段，再调用用户的 __traverse__。

pub fn GCBuilder(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".fields;

        // 检测框架管理的公共 PyObject 字段：cleanupFields 在 dealloc 时管理
        // 这些字段的引用计数，py_traverse 必须对称地访问它们以支持 GC
        // 循环检测。
        const has_framework_object_refs = blk: {
            for (fields) |field| {
                if (!isPrivateField(field.name)) {
                    if (traits.isObjectPtr(field.type) or traits.isObjectPtrOptional(field.type)) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };

        // ?*Object 字段可被 tp_clear 安全置 NULL（打破循环引用）。
        // *Object（非 optional）字段无法置 NULL，但仍纳入 has_clearable_refs
        // 以确保 CPython 要求"tp_traverse 非 NULL 时 tp_clear 必须非 NULL"得到满足。
        // py_clear 中 *Object 字段不会被 decref（无法置 NULL 避免 double-decref），
        // 仅 ?*Object 字段被实际清除。
        const has_clearable_refs = blk: {
            for (fields) |field| {
                if (!isPrivateField(field.name) and
                    (traits.isObjectPtr(field.type) or traits.isObjectPtrOptional(field.type)))
                {
                    break :blk true;
                }
            }
            break :blk false;
        };

        pub const has_user_traverse = @hasDecl(T, "__traverse__");
        pub const has_user_clear = @hasDecl(T, "__clear__");

        pub const has_traverse = has_user_traverse or has_framework_object_refs;
        pub const has_clear = has_user_clear or has_clearable_refs;

        pub const handled_dunders: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            if (has_user_traverse) names = names ++ .{"__traverse__"};
            if (has_user_clear) names = names ++ .{"__clear__"};
            break :blk names;
        };

        pub fn py_traverse(py_self: ?*c.PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = unwrapConst(T, py);

            // 访问框架管理的公共 PyObject 字段，使 GC 能检测循环引用。
            if (comptime has_framework_object_refs) {
                const VisitFn = *const fn (?*c.PyObject, ?*anyopaque) callconv(.c) c_int;
                const visit_fn: VisitFn = @ptrCast(visit);
                inline for (fields) |field| {
                    if (comptime !isPrivateField(field.name)) {
                        if (comptime traits.isObjectPtr(field.type)) {
                            const obj: ?*c.PyObject = @ptrCast(@field(data, field.name));
                            if (obj != null) {
                                if (visit_fn(obj, arg) != 0) return -1;
                            }
                        } else if (comptime traits.isObjectPtrOptional(field.type)) {
                            if (@field(data, field.name)) |obj| {
                                const py_obj: ?*c.PyObject = @ptrCast(obj);
                                if (visit_fn(py_obj, arg) != 0) return -1;
                            }
                        }
                    }
                }
            }

            // 调用用户的 __traverse__ 访问私有字段（_ 前缀）。
            if (comptime has_user_traverse) {
                const UserVisit = *const fn (*Object, ?*anyopaque) callconv(.c) c_int;
                const user_visit: UserVisit = @ptrCast(visit);
                @field(T, "__traverse__")(data, user_visit, arg) catch return -1;
            }
            return 0;
        }

        pub fn py_clear(py_self: ?*c.PyObject) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const data = unwrap(T, py);

            // 清除框架管理的 ?*Object 字段（decref + NULL）。
            if (comptime has_clearable_refs) {
                inline for (fields) |field| {
                    if (comptime !isPrivateField(field.name) and traits.isObjectPtrOptional(field.type)) {
                        if (@field(data, field.name)) |obj| {
                            obj.decref();
                            @field(data, field.name) = null;
                        }
                    }
                }
            }

            // 调用用户的 __clear__ 清除私有字段。
            if (comptime has_user_clear) {
                @field(T, "__clear__")(data) catch return -1;
            }
            return 0;
        }
    };
}

// ── BufferBuilder ──────────────────────────────────────────────────────────
// 为 Zig 支持的类生成 Python buffer 协议。
// 检测并包装 __buffer__ / __release_buffer__ 特殊方法，映射到 CPython 的
// tp_as_buffer.bf_getbuffer / bf_releasebuffer 插槽。

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
// 为 Zig 支持的类生成 Python 属性（getset）表。
// 公共结构体字段暴露为 Python 属性。只读字段可通过 pymz_meta.readonly_fields
// 标记为仅 getter 的属性。

pub fn PropertiesBuilder(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".fields;
        const public_count = countPublicFields(T);

        fn isReadOnlyField(comptime field_name: []const u8) bool {
            if (!@hasDecl(T, "pymz_meta")) return false;
            const meta = T.pymz_meta;
            if (!@hasField(@TypeOf(meta), "readonly_fields")) return false;
            const ro = meta.readonly_fields;
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
                    const wrapper: *Wrapper(T) = @ptrCast(@alignCast(py));
                    const data = wrapper.getData();
                    const v = py_value orelse {
                        errors.typeError("cannot delete attribute '{s}'", .{field_name});
                        return -1;
                    };
                    const obj: *Object = @ptrCast(v);
                    const new_value = convert.fromPy(FieldType, obj) catch return -1;
                    // fromPy returns a borrowed reference for *Object / ?*Object;
                    // class fields need owned references, so incref here.
                    if (comptime traits.isObjectPtr(FieldType)) {
                        new_value.incref();
                    } else if (comptime traits.isObjectPtrOptional(FieldType)) {
                        if (new_value) |o| o.incref();
                    }
                    // Release old value only if the object has been initialized.
                    // Before initialization (PyType_GenericNew zeroes memory),
                    // calling decref on a zeroed *Object is UB in Zig.
                    if (wrapper.initialized) {
                        if (comptime traits.isObjectPtr(FieldType)) {
                            @field(data, field_name).decref();
                        } else if (comptime traits.isObjectPtrOptional(FieldType)) {
                            if (@field(data, field_name)) |old| old.decref();
                        } else {
                            convert.releaseValue(&@field(data, field_name));
                        }
                    }
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

test "isPrivateField 识别以下划线开头的名称" {
    try testing.expect(isPrivateField("_internal"));
    try testing.expect(isPrivateField("__dunder"));
    try testing.expect(!isPrivateField("public"));
    try testing.expect(!isPrivateField("a"));
    // 空字符串没有前导下划线，不是私有字段。
    try testing.expect(!isPrivateField(""));
}

test "isSelfParam 匹配值和指针类型的 self 参数" {
    const T = struct { x: i32 };

    // 按值传递。
    try testing.expect(isSelfParam(T, T));

    // 按指针传递（const 和 mutable）。
    try testing.expect(isSelfParam(*T, T));
    try testing.expect(isSelfParam(*const T, T));

    // 不匹配的类型。
    try testing.expect(!isSelfParam(i32, T));
    try testing.expect(!isSelfParam(*i32, T));
}

test "countPublicFields 跳过私有字段" {
    const T = struct {
        public_a: i32,
        _private_b: i32,
        public_c: []const u8,
        __pymz_marker__: i32 = 0,
    };
    // public_a 和 public_c 是公共字段；_private_b 和 __pymz_marker__ 是私有字段。
    try testing.expectEqual(@as(usize, 2), countPublicFields(T));
}

test "countPublicFields 全私有结构体返回零" {
    const T = struct {
        _a: i32,
        _b: i32,
    };
    try testing.expectEqual(@as(usize, 0), countPublicFields(T));
}

test "countPublicFields 全公共结构体返回正确计数" {
    const T = struct {
        a: i32,
        b: i32,
        c: i32,
    };
    try testing.expectEqual(@as(usize, 3), countPublicFields(T));
}

test "Wrapper 将 PyObject 放置在偏移量零处" {
    const T = struct { x: i64, y: i64 };
    const W = Wrapper(T);
    // PyObject 头部必须是第一个字段，使 CPython 可将包装器指针转换为 PyObject*。
    try testing.expectEqual(@as(usize, 0), @offsetOf(W, "ob_base"));
}

test "Wrapper 的存储对齐满足 T" {
    const T = struct { x: i64, y: i64 };
    const W = Wrapper(T);
    // 整体包装器对齐必须满足 T 的对齐要求，使 _storage 可转换为 *T 而不产生不对齐。
    try testing.expect(@alignOf(W) >= @alignOf(T));
}

test "Wrapper 的存储空间足以容纳 T" {
    const T = struct { x: i64, y: i64, z: [16]u8 };
    const W = Wrapper(T);
    // _storage 是 [@sizeOf(T)]u8，因此包装器必须至少为 PyObject 头部加上 T 的大小。
    try testing.expect(@sizeOf(W) >= @sizeOf(c.PyObject) + @sizeOf(T));
}

test "extractClassOptions 接受文档字符串" {
    const opts = extractClassOptions("a doc");
    try testing.expectEqualStrings("a doc", opts.doc.?);
    try testing.expect(opts.limited == null);
}

test "extractClassOptions 接受选项结构体" {
    const opts = extractClassOptions(.{ .doc = "d", .limited = true });
    try testing.expectEqualStrings("d", opts.doc.?);
    try testing.expect(opts.limited.? == true);
}

test "extractClassOptions 接受仅含 doc 的选项结构体" {
    const opts = extractClassOptions(.{ .doc = "only doc" });
    try testing.expectEqualStrings("only doc", opts.doc.?);
    try testing.expect(opts.limited == null);
}

test "extractClassOptions 接受仅含 limited 的选项结构体" {
    const opts = extractClassOptions(.{ .limited = false });
    try testing.expect(opts.doc == null);
    try testing.expect(opts.limited.? == false);
}
