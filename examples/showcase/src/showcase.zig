const std = @import("std");
const pymz = @import("pymz");
const py = pymz.py;
const v = py.value;
const d = py.decl;

const gpa = std.heap.c_allocator;

const ShowcaseError = d.exception(.runtime_error, "Showcase error.");

const ProtocolDemoImpl = struct {
    _data: []u8,

    pub fn __new__(text: []const u8) v.Result(ProtocolDemoImpl) {
        const duped = gpa.dupe(u8, text) catch return error.OutOfMemory;
        return .{ ._data = duped };
    }

    pub fn __del__(self: *ProtocolDemoImpl) void {
        gpa.free(self._data);
    }

    pub fn __enter__(self: *ProtocolDemoImpl) *ProtocolDemoImpl {
        return self;
    }

    pub fn __exit__(
        self: *ProtocolDemoImpl,
        exc_type: ?*v.Object,
        exc_value: ?*v.Object,
        exc_tb: ?*v.Object,
    ) void {
        _ = self;
        _ = exc_type;
        _ = exc_value;
        _ = exc_tb;
    }

    pub fn __buffer__(self: *const ProtocolDemoImpl) []const u8 {
        return self._data;
    }
};

const ProtocolDemo = d.class(ProtocolDemoImpl, .{
    .doc = "Context manager and byte buffer demo.",
    .limited = false,
});

const MatrixBufferImpl = struct {
    pub const shape = [_]usize{ 2, 2 };
    pub const strides = [_]isize{ 2, 1 };

    _data: [4]u8,

    pub fn __new__() MatrixBufferImpl {
        return .{ ._data = .{ 1, 2, 3, 4 } };
    }

    pub fn __buffer__(self: *const MatrixBufferImpl) v.Buffer {
        return .{
            .ptr = @ptrCast(@constCast(self._data[0..].ptr)),
            .shape = MatrixBufferImpl.shape[0..],
            .strides = MatrixBufferImpl.strides[0..],
            .format = "B",
            .readonly = true,
        };
    }
};

const MatrixBuffer = d.class(MatrixBufferImpl, .{
    .doc = "A read-only 2x2 byte matrix.",
    .limited = false,
});

const BaseCounterImpl = struct {
    _count: i64,

    pub fn __new__() BaseCounterImpl {
        return .{ ._count = 0 };
    }

    pub fn increment(self: *BaseCounterImpl) i64 {
        self._count += 1;
        return self._count;
    }
};

const BaseCounter = d.class(BaseCounterImpl, .{
    .doc = "Counter that increments by one.",
    .limited = false,
});

const BaseCounterDef = BaseCounter.classdefWithName("BaseCounter");

const DerivedCounterImpl = struct {
    _count: i64 = 0,
    _step: i64,

    pub fn __new__(step: i64) DerivedCounterImpl {
        return .{ ._count = 0, ._step = step };
    }

    pub fn increment(self: *DerivedCounterImpl) i64 {
        self._count += self._step;
        return self._count;
    }
};

const DerivedCounter = d.classWithBase("DerivedCounter", DerivedCounterImpl, &BaseCounterDef, .{
    .doc = "Counter that increments by a fixed step.",
    .limited = false,
});

var gc_node_deallocs: usize = 0;

const GCNodeImpl = struct {
    _value: i64,
    _child: ?*v.Object = null,

    pub const pymz_meta = d.classMeta(.{
        .method_param_names = .{ .set_child = "child" },
    });

    pub fn __new__(value: i64) GCNodeImpl {
        return .{ ._value = value, ._child = null };
    }

    pub fn __del__(self: *GCNodeImpl) void {
        _ = self;
        gc_node_deallocs += 1;
    }

    pub fn set_child(self: *GCNodeImpl, child: ?*v.Object) void {
        if (self._child) |old| {
            old.decref();
        }
        self._child = if (child) |obj| obj.newref() else null;
    }

    pub fn __traverse__(
        self: *const GCNodeImpl,
        visit: *const fn (*v.Object, ?*anyopaque) callconv(.c) c_int,
        arg: ?*anyopaque,
    ) !void {
        if (self._child) |child| {
            if (visit(child, arg) != 0) return error.VisitFailed;
        }
    }

    pub fn __clear__(self: *GCNodeImpl) !void {
        if (self._child) |child| {
            child.decref();
            self._child = null;
        }
    }
};

const GCNode = d.class(GCNodeImpl, .{
    .doc = "A GC-managed node with an optional child.",
    .limited = false,
});

fn gcNodeDeallocCountImpl() usize {
    return gc_node_deallocs;
}

const gc_node_dealloc_count = d.function(gcNodeDeallocCountImpl, .{
    .doc = "Return the number of GCNode deallocations.",
    .limited = false,
});

var gc_cycle_node_deallocs: usize = 0;

const GCCycleNodeImpl = struct {
    value: i64,
    child: ?*v.Object = null,

    pub fn __new__(value: i64) GCCycleNodeImpl {
        return .{ .value = value, .child = null };
    }

    pub fn __del__(self: *GCCycleNodeImpl) void {
        _ = self;
        gc_cycle_node_deallocs += 1;
    }

    pub fn set_child(self: *GCCycleNodeImpl, child: *v.Object) void {
        child.incref();
        if (self.child) |old| old.decref();
        self.child = child;
    }

    pub fn get_value(self: *const GCCycleNodeImpl) i64 {
        return self.value;
    }
};

const GCCycleNode = d.class(GCCycleNodeImpl, .{
    .doc = "A GC-managed node with a public child field for cycle testing.",
    .limited = false,
});

fn gcCycleNodeDeallocCountImpl() usize {
    return gc_cycle_node_deallocs;
}

const gc_cycle_node_dealloc_count = d.function(gcCycleNodeDeallocCountImpl, .{
    .doc = "Return the number of GCCycleNode deallocations.",
    .limited = false,
});

const CallableOptImpl = struct {
    base: i64,

    pub fn __new__(base: i64) CallableOptImpl {
        return .{ .base = base };
    }

    pub fn __call__(self: *const CallableOptImpl, factor: ?i64) i64 {
        if (factor) |f| return self.base * f;
        return self.base;
    }
};

const CallableOpt = d.class(CallableOptImpl, .{
    .doc = "A callable with an optional __call__ argument.",
    .limited = false,
});

const IntVecError = d.exception(.index_error, "IntVec index error.");

threadlocal var intvec_str_buf: [256]u8 = undefined;

const IntVecImpl = struct {
    _data: std.ArrayList(i64),
    _iter_index: usize,

    pub const pymz_meta = d.classMeta(.{
        .method_param_names = .{ .push = "value" },
    });

    pub fn __new__() IntVecImpl {
        return .{ ._data = .empty, ._iter_index = 0 };
    }

    pub fn __del__(self: *IntVecImpl) void {
        self._data.deinit(gpa);
    }

    pub fn __len__(self: *const IntVecImpl) usize {
        return self._data.items.len;
    }

    pub fn __getitem__(self: *const IntVecImpl, index: i64) v.Result(i64) {
        const len: i64 = @intCast(self._data.items.len);
        var idx = index;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) {
            return IntVecError.raise("index out of bounds");
        }
        return self._data.items[@intCast(idx)];
    }

    pub fn __setitem__(self: *IntVecImpl, index: i64, value: i64) v.Result(void) {
        const len: i64 = @intCast(self._data.items.len);
        var idx = index;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) {
            return IntVecError.raise("index out of bounds");
        }
        self._data.items[@intCast(idx)] = value;
    }

    pub fn __delitem__(self: *IntVecImpl, index: i64) v.Result(void) {
        const len: i64 = @intCast(self._data.items.len);
        var idx = index;
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) {
            return IntVecError.raise("index out of bounds");
        }
        _ = self._data.orderedRemove(@intCast(idx));
    }

    pub fn __contains__(self: *const IntVecImpl, value: i64) bool {
        for (self._data.items) |item| {
            if (item == value) return true;
        }
        return false;
    }

    pub fn __iter__(self: *IntVecImpl) *IntVecImpl {
        self._iter_index = 0;
        return self;
    }

    pub fn __next__(self: *IntVecImpl) ?i64 {
        if (self._iter_index >= self._data.items.len) return null;
        const value = self._data.items[self._iter_index];
        self._iter_index += 1;
        return value;
    }

    pub fn __eq__(self: *const IntVecImpl, other: *v.Object) bool {
        const other_len = other.sequenceLength() catch return false;
        if (self._data.items.len != other_len) return false;
        var i: usize = 0;
        while (i < self._data.items.len) : (i += 1) {
            const other_val = otherIntAt(other, i) catch return false;
            if (self._data.items[i] != other_val) return false;
        }
        return true;
    }

    pub fn __ne__(self: *const IntVecImpl, other: *v.Object) bool {
        return !self.__eq__(other);
    }

    pub fn __lt__(self: *const IntVecImpl, other: *v.Object) bool {
        const other_len = other.sequenceLength() catch return false;
        const min_len = @min(self._data.items.len, other_len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            const other_val = otherIntAt(other, i) catch return false;
            if (self._data.items[i] < other_val) return true;
            if (self._data.items[i] > other_val) return false;
        }
        return self._data.items.len < other_len;
    }

    pub fn __le__(self: *const IntVecImpl, other: *v.Object) bool {
        return self.__lt__(other) or self.__eq__(other);
    }

    pub fn __gt__(self: *const IntVecImpl, other: *v.Object) bool {
        const other_len = other.sequenceLength() catch return false;
        const min_len = @min(self._data.items.len, other_len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            const other_val = otherIntAt(other, i) catch return false;
            if (self._data.items[i] > other_val) return true;
            if (self._data.items[i] < other_val) return false;
        }
        return self._data.items.len > other_len;
    }

    pub fn __ge__(self: *const IntVecImpl, other: *v.Object) bool {
        return self.__gt__(other) or self.__eq__(other);
    }

    pub fn __str__(self: *const IntVecImpl) []const u8 {
        return formatIntVec(&intvec_str_buf, self._data.items, "[", "]");
    }

    pub fn __repr__(self: *const IntVecImpl) []const u8 {
        return formatIntVec(&intvec_str_buf, self._data.items, "IntVec([", "])");
    }

    pub fn __hash__(self: *const IntVecImpl) i64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(self._data.items));
        return @bitCast(hasher.final());
    }

    pub fn __call__(self: *const IntVecImpl) i64 {
        return @intCast(self._data.items.len);
    }

    pub fn push(self: *IntVecImpl, value: i64) v.Result(void) {
        self._data.append(gpa, value) catch return error.OutOfMemory;
    }

    pub fn pop(self: *IntVecImpl) v.Result(i64) {
        if (self._data.items.len == 0) {
            return IntVecError.raise("pop from empty vector");
        }
        return self._data.pop().?;
    }

    pub fn clear(self: *IntVecImpl) void {
        self._data.clearRetainingCapacity();
    }
};

fn otherIntAt(other: *v.Object, index: usize) v.Result(i64) {
    if (other.sequenceGet(index)) |borrowed| {
        return borrowed.asInt(i64);
    }
    const item = try other.getItem(@intCast(index));
    defer item.decref();
    return item.asInt(i64);
}

fn formatIntVec(buf: []u8, items: []const i64, prefix: []const u8, suffix: []const u8) []const u8 {
    var pos: usize = 0;
    if (pos + prefix.len <= buf.len) {
        @memcpy(buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
    }
    for (items, 0..) |item, i| {
        if (i > 0 and pos + 2 <= buf.len) {
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        const text = std.fmt.bufPrint(buf[pos..], "{d}", .{item}) catch break;
        pos += text.len;
    }
    if (pos + suffix.len <= buf.len) {
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }
    return buf[0..pos];
}

const IntVec = d.class(IntVecImpl, .{
    .doc = "A growable integer vector demonstrating container and comparison protocols.",
    .limited = false,
});

var object_holder_deallocs: usize = 0;

const ObjectHolderImpl = struct {
    value: i64,
    child: ?*v.Object = null,

    pub fn __del__(self: *ObjectHolderImpl) void {
        _ = self;
        object_holder_deallocs += 1;
    }

    pub fn get_value(self: *const ObjectHolderImpl) i64 {
        return self.value;
    }

    pub fn get_child(self: *const ObjectHolderImpl) ?*v.Object {
        // 返回 `*Object` / `?*Object` 的方法必须返回 owned（新）引用：
        // handlePayload 会把该引用转移给 Python 调用方。直接返回字段的
        // 借用引用会把 holder 持有的引用转移出去，导致 Python 端 decref
        // 与析构时的 cleanupFields 双重释放。返回字段时用 `.newref()`。
        if (self.child) |child| return child.newref();
        return null;
    }
};

const ObjectHolder = d.class(ObjectHolderImpl, .{
    .doc = "A class with a ?*Object field initialized from constructor argument.",
    .limited = false,
});

fn objectHolderDeallocCountImpl() usize {
    return object_holder_deallocs;
}

const object_holder_dealloc_count = d.function(objectHolderDeallocCountImpl, .{
    .doc = "Return the number of ObjectHolder deallocations.",
    .limited = false,
});

// ── Handle / Registry: py_class 跨类返回 ─────────────────────────────────
// HandleImpl 声明 `py_class`：Registry.make() 返回的 HandleImpl 值会被 pymz
// 自动物化为 `Handle` class 实例（无需手写 toPy，也避免 toPy 被方法表暴露）；
// Registry.add() 的参数为 HandleImpl，pymz 从传入的 `Handle` 实例提取载荷
// （fromPy 对称方向）。`py_class.name` 是类的唯一事实来源，必须与模块导出键
// 一致（本示例中均为 "Handle"）。

const HandleImpl = struct {
    _value: i64,

    pub const pymz_meta = d.classMeta(.{
        .readonly_fields = .{ ._value = true },
        .method_param_names = .{ .__new__ = "value" },
    });

    /// 跨类返回声明：任何返回 HandleImpl 的 method 自动物化为 Handle 实例。
    pub const py_class: v.convert.PyClass = .{ .descriptor = Handle, .name = "Handle" };

    pub fn __new__(value: i64) HandleImpl {
        return .{ ._value = value };
    }

    pub fn get_value(self: *const HandleImpl) i64 {
        return self._value;
    }
};

const Handle = d.class(HandleImpl, .{
    .doc = "A value handle demonstrating py_class cross-class return.",
    .limited = false,
});

const RegistryImpl = struct {
    /// 跨类返回：返回 HandleImpl，pymz 自动物化为 Handle 实例。
    pub fn make(self: *RegistryImpl, value: i64) HandleImpl {
        _ = self;
        return .{ ._value = value };
    }

    /// 跨类入参：参数为 HandleImpl，pymz 从 Handle 实例提取载荷后传入。
    pub fn add(self: *RegistryImpl, a: HandleImpl, b: HandleImpl) i64 {
        _ = self;
        return a._value + b._value;
    }
};

const Registry = d.class(RegistryImpl, .{
    .doc = "A registry whose methods cross classes via py_class.",
    .limited = false,
});

const PyObjectPtr = @TypeOf(v.none().asPy());

fn sumAllImpl(args: v.RawArgs) v.Result(PyObjectPtr) {
    var sum: i64 = 0;
    var i: usize = 0;
    while (i < args.len()) : (i += 1) {
        sum += @intCast(try args.getInt(i));
    }
    const result = try v.integer(sum);
    return result.asPy();
}

const sum_all = d.varargsFunction(sumAllImpl, .{
    .doc = "Sum all positional arguments.",
    .limited = false,
});

fn makeContainersImpl() v.Result(*v.Object) {
    const result = try v.dict();
    errdefer result.decref();

    // bytes
    {
        const key = try v.string("bytes");
        defer key.decref();
        const val = try v.bytes("hello");
        try result.dictSet(key, val);
        val.decref();
    }

    // bytearray
    {
        const key = try v.string("bytearray");
        defer key.decref();
        const val = try v.bytearray("world");
        try result.dictSet(key, val);
        val.decref();
    }

    // tuple (setUnsafe steals references)
    {
        const key = try v.string("tuple");
        defer key.decref();
        const tup = try v.tuple(3);
        errdefer tup.decref();
        const tup_t: *v.Tuple = @ptrCast(tup);
        try tup_t.setUnsafe(0, try v.integer(1));
        try tup_t.setUnsafe(1, try v.integer(2));
        try tup_t.setUnsafe(2, try v.integer(3));
        try result.dictSet(key, tup);
        tup.decref();
    }

    // set (PySet_Add borrows references)
    {
        const key = try v.string("set");
        defer key.decref();
        const elem1 = try v.integer(1);
        defer elem1.decref();
        const elem2 = try v.integer(2);
        defer elem2.decref();
        const items = [_]*v.Object{ elem1, elem2 };
        const val = try v.set(&items);
        try result.dictSet(key, val);
        val.decref();
    }

    // frozenset (fromSlice borrows references, incref'd internally)
    {
        const key = try v.string("frozenset");
        defer key.decref();
        const elem1 = try v.integer(10);
        const elem2 = try v.integer(20);
        const items = [_]*v.Object{ elem1, elem2 };
        const val = try v.frozenset(&items);
        try result.dictSet(key, val);
        val.decref();
    }

    // unicode
    {
        const key = try v.string("unicode");
        defer key.decref();
        const val = try v.unicode("h\xc3\xa9llo");
        try result.dictSet(key, val);
        val.decref();
    }

    // slice
    {
        const key = try v.string("slice");
        defer key.decref();
        const val = try v.slice(0, 10, 2);
        try result.dictSet(key, val);
        val.decref();
    }

    return result;
}

const make_containers = d.function(makeContainersImpl, .{
    .doc = "Return a dict of containers built with value constructors.",
    .limited = false,
});

const version_constant = d.constant("1.0.0");

pub const pymz_module = d.module("_showcase", .{
    .__version__ = version_constant,
    .ProtocolDemo = ProtocolDemo,
    .MatrixBuffer = MatrixBuffer,
    .BaseCounter = BaseCounter,
    .DerivedCounter = DerivedCounter,
    .GCNode = GCNode,
    .gc_node_dealloc_count = gc_node_dealloc_count,
    .GCCycleNode = GCCycleNode,
    .gc_cycle_node_dealloc_count = gc_cycle_node_dealloc_count,
    .CallableOpt = CallableOpt,
    .IntVec = IntVec,
    .IntVecError = IntVecError,
    .ObjectHolder = ObjectHolder,
    .object_holder_dealloc_count = object_holder_dealloc_count,
    .Handle = Handle,
    .Registry = Registry,
    .sum_all = sum_all,
    .make_containers = make_containers,
    .ShowcaseError = ShowcaseError,
}, null, "pymz feature showcase: classes, GC, protocols, inheritance, containers.");

comptime {
    _ = pymz_module;
}
