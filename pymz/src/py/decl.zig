//! Python 声明辅助函数。
//!
//! 本命名空间将模块/类/函数描述符与值构造辅助函数分开存放，
//! 以保持公共 API 表面小巧清晰。

const std = @import("std");
const interface = @import("pymz_backend");
const value = @import("value.zig");

pub const backend = value.backend;
pub const FnMode = backend.FnMode;

/// `classMeta` 接受的合法字段名集合，编译期校验用户输入。
///
/// 新增字段时同步更新此切片、`classMetaTemplate` 的默认值和 `classMeta` 文档。
/// 闭合字段集合是设计选择：让拼写错误在编译期失败，而非在运行时被静默忽略。
const known_meta_fields = [_][]const u8{
    "readonly_fields",
    "method_param_names",
    "class_methods",
    "handled_dunders",
    "excluded_dunders",
};

fn isKnownMetaField(comptime name: []const u8) bool {
    inline for (known_meta_fields) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

fn formatKnownMetaFields() []const u8 {
    comptime var msg: []const u8 = "";
    inline for (known_meta_fields, 0..) |k, i| {
        if (i > 0) msg = msg ++ ", ";
        msg = msg ++ "'" ++ k ++ "'";
    }
    return msg;
}

pub fn function(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    return backend.function(func, desc);
}

pub fn positionalFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    return backend.positionalFunction(func, desc);
}

pub fn kwFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    return backend.kwFunction(func, desc);
}

pub fn varargsFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    return backend.varargsFunction(func, desc);
}

/// 声明一个 Zig struct 为 Python 类。
///
/// 后端在编译期通过反射把 `T` 暴露为 CPython 类型：公开字段映射为属性，
/// `pub fn` 声明映射为方法。可选的元数据通过 `pymz_meta` 集中声明来覆盖
/// 默认行为：在 `T` 上声明 `pub const pymz_meta = d.classMeta(.{...})`，
/// 参见 `classMeta` 的文档了解支持的字段。
///
/// dunder 方法约定：在 `T` 上声明同名 `pub fn` 即可参与对应 Python 协议，
/// 由后端在编译期装配到类型对象上。内置交由协议构建器处理的 dunder 包括
/// `__new__`（自定义构造）、`__repr__`/`__str__`、`__hash__`、比较算子
/// （`__eq__`/`__ne__`/`__lt__`/`__le__`/`__gt__`/`__ge__`）、容器协议
/// （`__len__`/`__getitem__`/`__setitem__`/`__delitem__`/`__contains__`/
/// `__iter__`/`__next__`）、`__call__`、缓冲区协议（`__buffer__`/
/// `__release_buffer__`）、GC 协议（`__traverse__`/`__clear__`）与属性代理
/// （`__getattr__`/`__setattr__`）。`__enter__`/`__exit__` 作为普通实例方法
/// 声明即可支持 with 语句，其中 `__enter__` 返回 `*T`/`*const T` 时返回 self；
/// `__del__` 注册为析构回调（不进方法表）。
///
/// 以下划线 `_` 开头的私有字段不会被框架自动释放。用户必须在 `__del__` 中
/// 手动释放私有字段资源。
pub fn class(
    comptime T: type,
    comptime doc_or_options: anytype,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.class_model) {
            @compileError("selected backend does not support class declarations");
        }
    }
    return backend.class(T, doc_or_options);
}

pub fn classWithBase(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime base: *const backend.ClassDef,
    comptime doc_or_options: anytype,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.class_model) {
            @compileError("selected backend does not support class declarations");
        }
    }
    return backend.classWithBase(name, T, base, doc_or_options);
}

/// 类元数据声明辅助函数。
///
/// 用于在 Zig struct 上声明 `pub const pymz_meta = d.classMeta(.{...})`，
/// 集中声明所有类元数据。后端在编译期通过 `pymz_meta` 读取配置。
///
/// 支持的字段（全部可选）：
/// - `readonly_fields`：匿名 struct，将字段名映射到 `bool`；为 `true` 的字段
///   只生成 getter、不生成 setter。
/// - `method_param_names`：匿名 struct，将方法名映射到该方法的位置参数名
///   （逗号分隔字符串或 `[]const []const u8`）。
/// - `class_methods`：匿名 struct，将方法名映射到 `bool`；为 `true` 时强制
///   把该方法导出为 classmethod。
/// - `handled_dunders` / `excluded_dunders`：`[]const []const u8`，按名字补充
///   注册或排除 dunder。`handled_dunders` 优先于 `excluded_dunders`。
///
/// 编译期校验所有字段名是否在 `known_meta_fields` 集合内，捕获拼写错误。
/// 用户传入未知字段会得到形如 `unknown field 'xyz'. Known fields: '...'`
/// 的明确错误。要查看完整字段集，调用 `classMetaTemplate()` 或参考其文档。
///
/// 仅声明子集时无需使用本函数——后端通过 `@hasField` 探测可选字段，
/// 省略的字段等同默认值。本函数的价值在于编译期字段名校验：在团队协作和
/// 重构场景中，把"字段名拼错导致元数据被静默忽略"的运行时陷阱降级为编译错误。
pub fn classMeta(comptime meta: anytype) @TypeOf(meta) {
    comptime {
        const T = @TypeOf(meta);
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError(
                "classMeta: expected anonymous struct literal, got " ++ @typeName(T),
            );
        }
        if (info.@"struct".is_tuple) {
            @compileError(
                "classMeta: expected struct literal with named fields, got tuple",
            );
        }
        for (info.@"struct".fields) |f| {
            if (!isKnownMetaField(f.name)) {
                @compileError(
                    "classMeta: unknown field '" ++ f.name ++ "'. " ++
                        "Known fields: " ++ formatKnownMetaFields(),
                );
            }
        }
    }
    return meta;
}

/// 类元数据骨架模板，返回包含所有支持字段（设为空默认值）的匿名 struct。
///
/// 用途：
///   1. **字段名参考**——在 IDE 中输入 `d.classMetaTemplate()` 后，返回类型
///      携带所有支持的字段名，便于补全和发现。
///   2. **空元数据快捷写法**——`pub const pymz_meta = d.classMetaTemplate();`
///      等价于声明全部字段为默认值，可读性优于 `.{}`。
///   3. **`@TypeOf` 推导参考**——`@TypeOf(d.classMetaTemplate())` 给出"完整
///      meta struct"类型，便于在泛型代码中约束参数。
///
/// **覆盖字段的方式**：Zig 匿名 struct 类型在源码位置上是名义的，无法通过
/// `@field(meta, "name") = value` 替换字段值（字段类型在 struct 字面量时已固定，
/// 赋值不同形状的匿名 struct 会触发类型不匹配）。要覆盖字段，请直接在
/// `classMeta(.{...})` 中列出需要的字段——省略的字段等同本模板的默认值：
///
///   pub const pymz_meta = d.classMeta(.{
///       .readonly_fields = .{ .id = true },
///       .method_param_names = .{ .add = "x,y" },
///   });
///
/// 字段名拼写错误会被 `classMeta` 在编译期捕获。本函数与 `classMeta` 配合
/// 提供"模板 + 校验"的两层辅助：模板用于发现字段，校验用于防止拼写错误。
pub fn classMetaTemplate() @TypeOf(.{
    .readonly_fields = .{},
    .method_param_names = .{},
    .class_methods = .{},
    .handled_dunders = &[_][]const u8{},
    .excluded_dunders = &[_][]const u8{},
}) {
    return .{
        .readonly_fields = .{},
        .method_param_names = .{},
        .class_methods = .{},
        .handled_dunders = &[_][]const u8{},
        .excluded_dunders = &[_][]const u8{},
    };
}

pub fn exception(
    comptime base: backend.ExceptionBase,
    comptime doc: ?[:0]const u8,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.exceptions) {
            @compileError("selected backend does not implement Python exceptions");
        }
    }
    return backend.exception(base, doc);
}

pub fn constant(comptime init: anytype) type {
    return backend.constant(init);
}

pub fn module(
    comptime name: [:0]const u8,
    comptime declarations_or_methods: anytype,
    comptime init_fn: ?backend.ModuleInitFn,
    comptime doc: ?[:0]const u8,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.module_model) {
            @compileError("selected backend does not implement Python modules");
        }
    }
    return backend.module(name, declarations_or_methods, init_fn, doc);
}
