//! Top-level class generation wiring.

const std = @import("std");
const c = @import("../c.zig").c;
const common = @import("../declarative/common.zig");
const stubs = @import("../stubs.zig");
const core = @import("core.zig");
const lifecycle = @import("lifecycle.zig");
const methods = @import("methods.zig");
const properties = @import("properties.zig");
const repr = @import("repr.zig");
const protocol = @import("protocol.zig");
const buffer = @import("buffer.zig");
const gc = @import("gc.zig");

pub fn generateClass(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime base: ?*const core.ClassDef,
    comptime doc: ?[:0]const u8,
) type {
    return generateNormalClass(name, T, base, doc);
}

fn ClassDefHelpers(comptime name: [:0]const u8, comptime T: type, comptime base: ?*const core.ClassDef, comptime doc: ?[:0]const u8) type {
    return struct {
        pub fn classdef(comptime ready_fn: *const fn () *c.PyTypeObject) core.ClassDef {
            return .{
                .name = name,
                .ready_fn = ready_fn,
                .doc = doc,
                .base = if (comptime base) |b| b else null,
            };
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8, comptime ready_fn: *const fn () *c.PyTypeObject) core.ClassDef {
            _ = export_name;
            return classdef(ready_fn);
        }

        pub fn stub() stubs.Stub {
            return stubs.classStubAuto(name, T, doc);
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            _ = export_name;
            return stub();
        }
    };
}

fn generateNormalClass(comptime name: [:0]const u8, comptime T: type, comptime base: ?*const core.ClassDef, comptime doc: ?[:0]const u8) type {
    const Helpers = ClassDefHelpers(name, T, base, doc);
    const Lifecycle = lifecycle.LifecycleBuilder(T);
    const Methods = methods.MethodBuilder(T);
    const Properties = properties.PropertiesBuilder(T);
    const ReprInfo = repr.ReprBuilder(T);
    const IteratorInfo = repr.IteratorBuilder(T);
    const ProtocolInfo = protocol.ProtocolBuilder(T);
    const BufferInfo = buffer.BufferBuilder(T);
    const GCInfo = gc.GCBuilder(T);

    const method_table = Methods.buildMethodTable();
    const getset_table = Properties.buildGetSetTable();

    return struct {
        const Self = @This();
        pub const export_kind: common.ExportKind = .class;
        pub const WrapperType = core.Wrapper(T);

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
            if (ProtocolInfo.has_len or ProtocolInfo.has_getitem or ProtocolInfo.has_setitem) {
                t.tp_as_mapping = &mapping_methods;
            }
            if (ProtocolInfo.has_len or ProtocolInfo.has_contains) {
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
            if (GCInfo.has_traverse) {
                t.tp_traverse = @ptrCast(&GCInfo.py_traverse);
                t.tp_flags |= c.Py_TPFLAGS_HAVE_GC;
            }
            if (GCInfo.has_clear) {
                t.tp_clear = @ptrCast(&GCInfo.py_clear);
                t.tp_flags |= c.Py_TPFLAGS_HAVE_GC;
            }
            break :blk t;
        };

        pub fn ready() *c.PyTypeObject {
            if (stubs.isStubgenBuild()) return &type_object;
            type_object.tp_getset = &getset_table_storage;
            if (comptime base) |b| {
                type_object.tp_base = b.ready_fn();
            }
            if (c.PyType_Ready(&type_object) < 0) {}
            return &type_object;
        }

        pub fn classdef() core.ClassDef {
            return Helpers.classdef(&ready);
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8) core.ClassDef {
            return Helpers.classdefWithName(export_name, &ready);
        }

        pub fn stub() stubs.Stub {
            return Helpers.stub();
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return Helpers.stubWithName(export_name);
        }
    };
}

pub fn class(comptime name: [:0]const u8, comptime T: type, comptime doc: ?[:0]const u8) type {
    return generateClass(name, T, null, doc);
}

pub fn classWithBase(comptime name: [:0]const u8, comptime T: type, comptime base: *const core.ClassDef, comptime doc: ?[:0]const u8) type {
    return generateClass(name, T, base, doc);
}
