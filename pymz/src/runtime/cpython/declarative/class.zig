//! Class export descriptors.

const common = @import("common.zig");
const class_mod = @import("../class/class_builder.zig");
const limiter = @import("../limiter.zig");
const c = @import("python_c");

pub const ExportKind = common.ExportKind;

pub const ClassOptions = struct {
    doc: ?[:0]const u8 = null,
    /// Platform filter. `null` = include on all platforms; `true` = limited ABI only;
    /// `false` = full ABI only.
    limited: ?bool = null,
};

pub fn extractClassOptions(comptime doc_or_options: anytype) ClassOptions {
    const T = @TypeOf(doc_or_options);
    if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == [:0]const u8) {
        return .{ .doc = doc_or_options };
    }
    if (@typeInfo(T) == .@"struct") {
        var opts: ClassOptions = .{};
        if (@hasField(T, "doc")) opts.doc = doc_or_options.doc;
        if (@hasField(T, "limited")) opts.limited = doc_or_options.limited;
        return opts;
    }
    @compileError("expected doc string or ClassOptions, got " ++ @typeName(T));
}

pub fn class(
    comptime T: type,
    comptime doc_or_options: anytype,
) type {
    return ClassDescriptor(T, extractClassOptions(doc_or_options));
}

/// Declare a Zig struct as a Python class with an explicit name and a base
/// class. Unlike `class`, the name is fixed at declaration time (not derived
/// from the module field name), so the descriptor carries `auto_name = false`
/// and `classdefWithName`/`readyWithName` build the type from the explicit
/// name. The descriptor exposes the same surface (`export_kind`, `is_active`,
/// `classdefWithName`, `readyWithName`) as `ClassDescriptor` so the module
/// builder treats both uniformly.
pub fn classWithBase(
    comptime class_name: [:0]const u8,
    comptime T: type,
    comptime base: *const class_mod.ClassDef,
    comptime doc_or_options: anytype,
) type {
    return ClassWithBaseDescriptor(class_name, T, base, extractClassOptions(doc_or_options));
}

fn ClassDescriptor(
    comptime T: type,
    comptime opts: ClassOptions,
) type {
    return struct {
        pub const export_kind: ExportKind = .class;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const Impl = T;
        pub const doc = opts.doc;
        pub const limited = opts.limited;
        pub const is_active = limiter.isActiveForPlatform(opts.limited);

        fn Runtime(comptime export_name: [:0]const u8) type {
            return class_mod.generateClass(export_name, Impl, null, doc);
        }

        pub fn readyWithName(comptime export_name: [:0]const u8) *c.PyTypeObject {
            return Runtime(export_name).ready();
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8) class_mod.ClassDef {
            return Runtime(export_name).classdef();
        }
    };
}

fn ClassWithBaseDescriptor(
    comptime class_name: [:0]const u8,
    comptime T: type,
    comptime base: *const class_mod.ClassDef,
    comptime opts: ClassOptions,
) type {
    return struct {
        pub const export_kind: ExportKind = .class;
        pub const auto_name = false;
        pub const name: ?[:0]const u8 = class_name;
        pub const Impl = T;
        pub const doc = opts.doc;
        pub const limited = opts.limited;
        pub const is_active = limiter.isActiveForPlatform(opts.limited);

        // The class name is fixed by the caller, so the runtime type does not
        // depend on the module field name passed to `*WithName`.
        fn Runtime() type {
            return class_mod.generateClass(class_name, Impl, base, doc);
        }

        pub fn readyWithName(comptime export_name: [:0]const u8) *c.PyTypeObject {
            _ = export_name;
            return Runtime().ready();
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8) class_mod.ClassDef {
            _ = export_name;
            return Runtime().classdef();
        }
    };
}
