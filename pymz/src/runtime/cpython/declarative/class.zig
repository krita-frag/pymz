//! Class export descriptors.

const common = @import("common.zig");
const class_mod = @import("../class.zig");
const stubs = @import("../stubs.zig");
const c = @import("../c.zig").c;

pub const ExportKind = common.ExportKind;

pub fn class(
    comptime T: type,
    comptime doc: ?[:0]const u8,
) type {
    return ClassDescriptor(T, doc);
}

fn ClassDescriptor(
    comptime T: type,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const export_kind: ExportKind = .class;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const Impl = T;
        pub const doc = _doc;

        fn Runtime(comptime export_name: [:0]const u8) type {
            return class_mod.generateClass(export_name, Impl, null, doc);
        }

        pub fn readyWithName(comptime export_name: [:0]const u8) *c.PyTypeObject {
            return Runtime(export_name).ready();
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8) class_mod.ClassDef {
            return Runtime(export_name).classdef();
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubs.classStubAuto(export_name, Impl, doc);
        }
    };
}
