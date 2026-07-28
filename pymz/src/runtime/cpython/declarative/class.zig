//! 类导出描述符。

const common = @import("common.zig");
const class_mod = @import("../class/class_builder.zig");
const limiter = @import("../limiter.zig");
const c = @import("python_c");

pub const ExportKind = common.ExportKind;

pub const ClassOptions = struct {
    doc: ?[:0]const u8 = null,
    /// 平台过滤器。`null` = 包含所有平台；`true` = 仅限 limited ABI；`false` = 仅限完整 ABI。
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

/// 将 Zig struct 声明为具有显式名称和基类的 Python 类。
/// 与 `class` 不同，名称在声明时固定（并非从模块字段名派生），
/// 因此描述符携带 `auto_name = false`，
/// 且 `classdefWithName`/`readyWithName` 从显式名称构建类型。
/// 描述符暴露与 `ClassDescriptor` 相同的接口（`export_kind`、`is_active`、
/// `classdefWithName`、`readyWithName`），使模块构建器统一对待两者。
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

        // 类名由调用方固定，因此运行时类型不依赖于传递给 `*WithName` 的模块字段名。
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
