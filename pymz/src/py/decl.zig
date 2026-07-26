//! Python declaration helpers.
//!
//! This namespace keeps module/class/function descriptors separate from value
//! construction helpers so the public surface stays small and legible.

const interface = @import("pymz_backend");
const value = @import("value.zig");

pub const backend = value.backend;
pub const FnMode = backend.FnMode;

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
/// `pub fn` 声明映射为方法，并支持以下可选的 `__pymz_*` 魔法字段与 dunder
/// 约定来覆盖默认行为（由 `runtime/cpython/class/` 下的构建器检测）。
///
/// `__pymz_*` 魔法字段（全部可选）：
/// - `__pymz_constructor_param_names__: []const []const u8`：构造函数
///   (`__new__`) 的位置参数名，按声明顺序排列，用于生成签名与帮助文本。
/// - `__pymz_method_param_names__`：匿名 struct，将方法名映射到该方法的位置
///   参数名；值可为逗号分隔字符串或 `[]const []const u8` 数组，例如
///   `pub const __pymz_method_param_names__ = .{ .find = "root" };`。
/// - `__pymz_readonly_fields__`：匿名 struct，将字段名映射到 `bool`；为
///   `true` 的字段只生成 getter、不生成 setter，例如
///   `pub const __pymz_readonly_fields__ = .{ .segment_count = true };`。
/// - `__pymz_class_methods__`：匿名 struct，将方法名映射到 `bool`；为 `true`
///   时强制把该方法导出为 classmethod，覆盖按首参是否为 `*T` 的自动推断。
/// - `__pymz_handled_dunders__` / `__pymz_excluded_dunders__`：
///   `[]const []const u8`，按名字补充注册 dunder。`handled` 表示交由协议
///   构建器处理（不进普通方法表），`excluded` 表示直接丢弃；`handled` 优先。
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
/// Private fields (names starting with `_`) are not automatically released
/// by the framework. Users must free private field resources in `__del__`.
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
