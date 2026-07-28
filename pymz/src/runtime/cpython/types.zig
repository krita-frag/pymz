//! 数值和集合类型包装器。

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const compat = @import("compat.zig");
const Object = object.Object;
const Error = errors.Error;
const class_mod = @import("class/class_builder.zig");

pub const Int = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Int) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Int) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Int) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Int) *Int {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.intCheck(obj.asPy());
    }

    pub inline fn from(value: anytype) Error!*Int {
        return switch (@typeInfo(@TypeOf(value))) {
            .int => |info| if (info.signedness == .signed)
                fromSigned(value)
            else
                fromUnsigned(value),
            .comptime_int => fromSigned(value),
            else => @compileError("Int.from expects an integer"),
        };
    }

    pub inline fn fromSigned(value: isize) Error!*Int {
        if (compat.intFromSigned(value)) |r| return @as(*Int, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn fromUnsigned(value: usize) Error!*Int {
        if (compat.intFromUnsigned(value)) |r| return @as(*Int, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn as(self: *Int, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.signedness == .signed) {
                    const v = try compat.intAsSigned(self.asPy());
                    const min = std.math.minInt(T);
                    const max = std.math.maxInt(T);
                    if (v < min or v > max) {
                        errors.overflowError("int too large to convert to {s}", .{@typeName(T)});
                        return error.PyError;
                    }
                    return @intCast(v);
                } else {
                    const v = try compat.intAsUnsigned(self.asPy());
                    const max = std.math.maxInt(T);
                    if (v > max) {
                        errors.overflowError("int too large to convert to {s}", .{@typeName(T)});
                        return error.PyError;
                    }
                    return @intCast(v);
                }
            },
            else => @compileError("Int.as expects an integer type"),
        }
    }
};

pub const Float = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Float) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Float) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Float) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Float) *Float {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyFloat_Check(obj.asPy()));
    }

    pub inline fn from(value: anytype) Error!*Float {
        const v: f64 = switch (@typeInfo(@TypeOf(value))) {
            .float, .comptime_float => @floatCast(value),
            else => @compileError("Float.from expects a float"),
        };
        if (c.PyFloat_FromDouble(v)) |r| return @as(*Float, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn as(self: *Float, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .float => {
                const v = c.PyFloat_AsDouble(self.asPy());
                if (v == -1.0 and errors.errorOccurred() != null) return error.PyError;
                return @floatCast(v);
            },
            else => @compileError("Float.as expects a float type"),
        }
    }
};

pub const Bool = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Bool) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Bool) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Bool) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Bool) *Bool {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyBool_Check(obj.asPy()));
    }

    /// 创建 `True` 或 `False` 的新引用。与 `Int.from` 和 `Float.from` 类似，
    /// 调用方拥有返回的引用，必须 decref（或转移所有权给 Python）。
    pub inline fn from(value: bool) *Bool {
        const obj = if (value) c.Py_True else c.Py_False;
        c.pymz_Py_INCREF(obj);
        return @ptrCast(obj);
    }

    pub inline fn as(self: *Bool) bool {
        return @intFromPtr(self) == @intFromPtr(c.Py_True);
    }
};

pub const Tuple = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Tuple) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Tuple) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Tuple) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Tuple) *Tuple {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyTuple_Check(obj.asPy()));
    }

    pub inline fn new(size: usize) Error!*Tuple {
        if (c.PyTuple_New(@as(c.Py_ssize_t, @intCast(size)))) |r| return @as(*Tuple, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn setUnsafe(self: *Tuple, i: usize, obj: *Object) Error!void {
        // PyTuple_SetItem 在成功时会窃取引用。
        // 在失败时（无效索引）它不会窃取，因此调用者的
        // 引用会泄漏。返回错误以便调用者处理。
        if (c.PyTuple_SetItem(self.asPy(), @as(c.Py_ssize_t, @intCast(i)), @ptrCast(obj)) < 0) {
            return error.PyError;
        }
    }

    pub inline fn get(self: *Tuple, i: usize) ?*Object {
        if (i >= self.length()) return null;
        const item = c.PyTuple_GetItem(self.asPy(), @as(c.Py_ssize_t, @intCast(i)));
        return @as(*Object, @ptrCast(item));
    }

    pub inline fn length(self: *Tuple) usize {
        return @intCast(c.PyTuple_Size(self.asPy()));
    }
};

pub const List = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const List) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *List) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *List) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *List) *List {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyList_Check(obj.asPy()));
    }

    pub inline fn new(size: usize) Error!*List {
        if (c.PyList_New(@as(c.Py_ssize_t, @intCast(size)))) |r| return @as(*List, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn append(self: *List, obj: *Object) Error!void {
        if (c.PyList_Append(self.asPy(), @ptrCast(obj)) < 0) return error.PyError;
    }

    pub inline fn get(self: *List, i: usize) ?*Object {
        if (i >= self.length()) return null;
        const item = c.PyList_GetItem(self.asPy(), @as(c.Py_ssize_t, @intCast(i)));
        return @as(*Object, @ptrCast(item));
    }

    pub inline fn set(self: *List, i: usize, obj: *Object) Error!void {
        if (c.PyList_SetItem(self.asPy(), @as(c.Py_ssize_t, @intCast(i)), @ptrCast(obj)) < 0) {
            obj.decref();
            return error.PyError;
        }
    }

    pub inline fn length(self: *List) usize {
        return @intCast(c.PyList_Size(self.asPy()));
    }
};

pub const Dict = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Dict) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Dict) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Dict) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Dict) *Dict {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyDict_Check(obj.asPy()));
    }

    pub inline fn new() Error!*Dict {
        if (c.PyDict_New()) |r| return @as(*Dict, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn setItemString(self: *Dict, key: [:0]const u8, value: *Object) Error!void {
        if (c.PyDict_SetItemString(self.asPy(), key, @ptrCast(value)) < 0) return error.PyError;
    }

    pub inline fn getItemString(self: *Dict, key: [:0]const u8) ?*Object {
        return @as(?*Object, @ptrCast(c.PyDict_GetItemString(self.asPy(), key)));
    }
};

pub const Set = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Set) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Set) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Set) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Set) *Set {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PySet_Check(obj.asPy()));
    }

    pub inline fn new() Error!*Set {
        if (c.PySet_New(null)) |r| return @as(*Set, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn fromSlice(items: []const *Object) Error!*Set {
        const set = try new();
        errdefer set.decref();
        for (items) |item| {
            try set.add(item);
        }
        return set;
    }

    pub inline fn add(self: *Set, obj: *Object) Error!void {
        if (c.PySet_Add(self.asPy(), @ptrCast(obj)) < 0) return error.PyError;
    }

    pub inline fn length(self: *Set) usize {
        return @intCast(c.PySet_Size(self.asPy()));
    }
};

pub const FrozenSet = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const FrozenSet) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *FrozenSet) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *FrozenSet) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *FrozenSet) *FrozenSet {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PyFrozenSet_Check(obj.asPy()));
    }

    pub inline fn fromSlice(items: []const *Object) Error!*FrozenSet {
        // 匹配 Set.fromSlice 的借用语义：输入项是借用的（不被消费）。
        // List.set 会窃取引用，因此在设置前对每个项进行 incref，
        // 以保持输入的引用计数不变。
        const list = try List.new(items.len);
        defer list.decref();
        for (items, 0..) |item, i| {
            item.incref();
            // List.set 在成功时窃取引用，在失败时 decref，
            // 因此错误处理程序中不需要手动 decref。
            list.set(i, item) catch return error.PyError;
        }
        if (c.PyFrozenSet_New(@as(*c.PyObject, @ptrCast(list)))) |r| return @as(*FrozenSet, @ptrCast(r));
        return error.PyError;
    }

    pub inline fn length(self: *FrozenSet) usize {
        return @intCast(c.PySet_Size(self.asPy()));
    }
};
pub const Slice = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn asPy(self: *const Slice) *c.PyObject {
        return @ptrCast(@constCast(self));
    }

    pub inline fn incref(self: *Slice) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Slice) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Slice) *Slice {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn check(obj: *Object) bool {
        return compat.cApiBool(c.PySlice_Check(obj.asPy()));
    }

    pub inline fn new(start: ?isize, stop: ?isize, step: ?isize) Error!*Slice {
        // PySlice_New 不会窃取其参数的引用（它内部会 incref），因此
        // Int.fromSigned 创建的任何新引用都必须在调用后 decref。Py_None
        // 是借用的单例，绝对不能 decref。跟踪哪些槽位持有新引用，以便
        // defer 清理在成功和失败时都能精确释放正确的集合。
        var start_obj: *c.PyObject = @ptrCast(c.pymz_Py_None());
        var stop_obj: *c.PyObject = @ptrCast(c.pymz_Py_None());
        var step_obj: *c.PyObject = @ptrCast(c.pymz_Py_None());
        var start_is_new = false;
        var stop_is_new = false;
        var step_is_new = false;
        defer {
            if (start_is_new) object.decrefRaw(start_obj);
            if (stop_is_new) object.decrefRaw(stop_obj);
            if (step_is_new) object.decrefRaw(step_obj);
        }

        if (start) |s| {
            start_obj = @ptrCast(try Int.fromSigned(s));
            start_is_new = true;
        }
        if (stop) |s| {
            stop_obj = @ptrCast(try Int.fromSigned(s));
            stop_is_new = true;
        }
        if (step) |s| {
            step_obj = @ptrCast(try Int.fromSigned(s));
            step_is_new = true;
        }

        if (c.PySlice_New(start_obj, stop_obj, step_obj)) |r| return @as(*Slice, @ptrCast(r));
        return error.PyError;
    }

    pub const Indices = struct {
        start: usize,
        stop: usize,
        step: isize,
        length: usize,
    };

    /// 根据 `length` 个元素的序列解析切片。
    pub inline fn getIndices(self: *Slice, length: usize) Error!Indices {
        var start: c.Py_ssize_t = 0;
        var stop: c.Py_ssize_t = 0;
        var step: c.Py_ssize_t = 0;
        var slicelength: c.Py_ssize_t = 0;
        const rc = c.PySlice_GetIndicesEx(
            self.asPy(),
            @as(c.Py_ssize_t, @intCast(length)),
            &start,
            &stop,
            &step,
            &slicelength,
        );
        if (rc < 0) return error.PyError;
        return .{
            .start = @intCast(start),
            .stop = @intCast(stop),
            .step = @intCast(step),
            .length = @intCast(slicelength),
        };
    }
};
pub const Module = extern struct {
    impl: c.PyObject,

    pub const IS_PYOBJECT = true;

    pub inline fn incref(self: *Module) void {
        Object.RefCount.incref(@This(), self);
    }
    pub inline fn decref(self: *Module) void {
        Object.RefCount.decref(@This(), self);
    }
    pub inline fn newref(self: *Module) *Module {
        return Object.RefCount.newref(@This(), self);
    }

    pub inline fn addObjectRef(self: *Module, name: [:0]const u8, value: *Object) Error!void {
        if (version.is_py3 and version.versionAtLeast(3, 10)) {
            if (c.PyModule_AddObjectRef(@as(*c.PyObject, @ptrCast(self)), name, @ptrCast(value)) < 0) return error.PyError;
        } else {
            if (c.PyModule_AddObject(@as(*c.PyObject, @ptrCast(self)), name, @ptrCast(value.newref())) < 0) {
                value.decref();
                return error.PyError;
            }
        }
    }

    pub inline fn addIntConstant(self: *Module, name: [:0]const u8, value: isize) Error!void {
        if (c.PyModule_AddIntConstant(@as(*c.PyObject, @ptrCast(self)), name, @intCast(value)) < 0) return error.PyError;
    }

    pub inline fn addStringConstant(self: *Module, name: [:0]const u8, value: [:0]const u8) Error!void {
        if (c.PyModule_AddStringConstant(@as(*c.PyObject, @ptrCast(self)), name, value) < 0) return error.PyError;
    }

    /// 注册一个 Python 类（通过 `pymz.class` 构建）为模块属性。
    /// 调用类的 `ready()` 来调用 `PyType_Ready`，然后将生成的 `*PyTypeObject`
    /// 以 `name` 为键添加到模块字典中。
    pub inline fn addClass(self: *Module, name: [:0]const u8, class_def: class_mod.ClassDef) Error!void {
        const type_obj = class_def.ready_fn() orelse return error.PyError;
        const py_type: *Object = @ptrCast(@alignCast(type_obj));
        try self.addObjectRef(name, py_type);
    }

    /// 借用模块名的 UTF-8 字符串引用。
    /// 出错时返回空字符串（Python 错误已设置）。
    pub inline fn getName(self: *Module) [:0]const u8 {
        const ptr = c.PyModule_GetName(@as(*c.PyObject, @ptrCast(self)));
        if (ptr == null) return "";
        return std.mem.span(ptr);
    }
};
