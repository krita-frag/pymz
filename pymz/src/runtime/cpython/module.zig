//! 方法定义和模块初始化辅助函数。
//!
//! 本模块提供原始（`pyfn_varargs`、`RawArgs`）和类型化（`pyfn_typed`、
//! `pyfn_kw`、`Args(T)`）两种包装器，用于将 Zig 函数转换为 Python 可调用
//! 的 C 回调。类型化包装器通过 `convert` 模块自动转换参数和返回值，模仿
//! PyO3 / PyOZ 的易用性。

const std = @import("std");
const c = @import("python_c");
const version = @import("version.zig");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const convert = @import("convert.zig");
const marshal = @import("marshal.zig");
const signature = @import("signature.zig");
const Object = object.Object;
const Error = errors.Error;

pub const MethodFlags = enum {
    varargs,
    keywords,

    pub inline fn toC(self: MethodFlags) c_int {
        return switch (self) {
            .varargs => c.METH_VARARGS,
            .keywords => c.METH_KEYWORDS,
        };
    }
};

pub const MethodDef = c.PyMethodDef;

pub inline fn sentinel() MethodDef {
    return .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
}

/// 从原始 C 回调构建 PyMethodDef 条目。回调必须与所选标志匹配
///（如 `fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject`）。
pub inline fn method(
    name: [:0]const u8,
    func: anytype,
    flags: MethodFlags,
    doc: ?[:0]const u8,
) MethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(&func),
        .ml_flags = flags.toC(),
        .ml_doc = if (doc) |d| d else null,
    };
}
/// 需要完整位置参数和关键字参数载荷的函数的包装器。
/// Zig 函数接收一个 `RawArgs`，其中 `kwargs` 在调用方传递了关键字参数时
/// 非空。
pub inline fn pyfn_varargs(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const S = struct {
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject, py_kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args = RawArgs.fromTuple(@ptrCast(py_args), @ptrCast(py_kwargs));
            const result = func(args) catch return null;
            return result;
        }
    };
    return S.wrapper;
}
/// 将类型化的 Zig 函数包装为 Python VARARGS 回调。
///
/// `func` 可以是例如 `fn (i64, i64) Error!i64` 或 `fn (i64) i64` 或
/// `fn () void`。每个参数通过 `convert.fromPy` 转换，返回值通过
/// `convert.toPy` 转换（出错时返回 `null`）。
pub fn pyfn_typed(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Params = fn_info.params;

    const S = struct {
        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const num_pos: usize = if (args_tuple) |t| t.length() else 0;

            const required_count = comptime marshal.requiredParamCount(Fn, 0);

            if (num_pos < required_count or num_pos > Params.len) {
                errors.typeError(
                    "function takes {d} to {d} positional argument(s) ({d} given)",
                    .{ required_count, Params.len, num_pos },
                );
                return null;
            }

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_typed: parameter has unknown type");
                if (i < num_pos) {
                    const arg_label = comptime std.fmt.comptimePrint("{d}", .{i + 1});
                    zig_args[i] = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label) catch {
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    };
                    converted_count += 1;
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument {d}", .{i + 1});
                    marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}
/// 将类型化的 Zig 函数包装为 Python VARARGS|KEYWORDS 回调。
/// 参数可通过位置或关键字传递，使用 `param_names` 指定参数名。
pub fn pyfn_mixed(comptime func: anytype, comptime param_names: ?[]const u8) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Params = fn_info.params;

    const S = struct {
        const names = param_names;

        fn paramName(comptime index: usize) []const u8 {
            if (names) |n| {
                return signature.getParamName(n, index);
            }
            return std.fmt.comptimePrint("arg{d}", .{index});
        }

        fn wrapper(_: ?*c.PyObject, py_args: ?*c.PyObject, py_kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const preamble = (extractArgs(py_args, py_kwargs, paramName, Params.len) orelse return null);
            const args_tuple = preamble.args;
            const kwargs_dict = preamble.kwargs;
            const pos_count = preamble.pos;

            var zig_args: std.meta.ArgsTuple(Fn) = undefined;
            var converted_count: usize = 0;
            inline for (Params, 0..) |param, i| {
                const PT = param.type orelse @compileError("pyfn_mixed: parameter has unknown type");
                if (i < pos_count) {
                    const arg_label = comptime paramName(i);
                    zig_args[i] = marshal.extractPositionalArg(PT, args_tuple.?, i, arg_label) catch {
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    };
                    converted_count += 1;
                } else if (kwargs_dict) |kw| {
                    const name_z = comptime convert.toSentinelStr(paramName(i));
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    if (c.PyDict_GetItemString(@ptrCast(kw), name_ptr)) |item| {
                        const py_item: *Object = @ptrCast(item);
                        zig_args[i] = marshal.convertField(PT, py_item, comptime paramName(i)) catch {
                            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                            return null;
                        };
                        converted_count += 1;
                    } else if (comptime @typeInfo(PT) == .optional) {
                        zig_args[i] = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)});
                        marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                        return null;
                    }
                } else if (comptime @typeInfo(PT) == .optional) {
                    zig_args[i] = null;
                } else {
                    errors.typeError("missing required argument: '{s}'", .{comptime paramName(i)});
                    marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
                    return null;
                }
            }

            const result = @call(.auto, func, zig_args);
            marshal.releaseArgsTuple(Fn, &zig_args, converted_count, 0);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

/// `pyfn_mixed` 和 `pyfn_kw` 共享的包装器前奏：
/// 提取 args 元组、kwargs 字典和位置参数数量；验证数量和关键字名称。
/// 验证失败时返回 `null`（Python 错误已设置）。
fn extractArgs(
    py_args: ?*c.PyObject,
    py_kwargs: ?*c.PyObject,
    comptime FieldName: fn (comptime usize) []const u8,
    comptime max_count: usize,
) ?struct { args: ?*types.Tuple, kwargs: ?*types.Dict, pos: usize } {
    const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
    const kwargs_dict: ?*types.Dict = if (py_kwargs) |k| @ptrCast(k) else null;
    const pos_count: usize = if (args_tuple) |t| t.length() else 0;

    if (pos_count > max_count) {
        errors.typeError(
            "function takes at most {d} positional argument(s) ({d} given)",
            .{ max_count, pos_count },
        );
        return null;
    }

    if (kwargs_dict) |kw| {
        if (!marshal.validateKeywordNames(kw, pos_count, FieldName, max_count)) {
            return null;
        }
    }

    return .{ .args = args_tuple, .kwargs = kwargs_dict, .pos = pos_count };
}

/// 接受 `Args(T)` 参数的函数的类型化包装器，其中 `T` 是一个结构体。
/// `T` 的字段成为关键字参数名；可选字段默认为 `null`，带 `= value` 默认值
/// 的字段使用这些默认值。
pub fn pyfn_kw(comptime func: anytype) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const params = fn_info.params;
    if (params.len != 1) {
        @compileError("pyfn_kw: function must take a single Args(T) parameter");
    }
    const ArgsWrapper = params[0].type orelse @compileError("pyfn_kw: cannot infer Args type");
    if (@typeInfo(ArgsWrapper) != .@"struct" or !@hasDecl(ArgsWrapper, "ArgsStruct")) {
        @compileError(
            "pyfn_kw: parameter must be Args(T). Change `fn(" ++
                @typeName(ArgsWrapper) ++
                ")` to `fn(pymz.Args(YourStruct))`",
        );
    }
    const InnerT = ArgsWrapper.ArgsStruct;
    const InnerInfo = @typeInfo(InnerT);
    if (InnerInfo != .@"struct") {
        @compileError("pyfn_kw: Args(T) expects T to be a struct, got " ++ @typeName(InnerT));
    }
    const Fields = InnerInfo.@"struct".fields;

    const S = struct {
        // 每个字段的初始化标志。当字段按乱序填充时（如索引 0 有默认值，
        // 索引 1 通过关键字参数提供），使用单个计数器跟踪连续前缀是不够的：
        // 这样做会跳过释放实际通过 `convert.fromPy` 转换的字段。
        // 我们改为精确记录哪些字段已被赋值，以便清理路径能精确释放它们。
        const InitFlags = [Fields.len]bool;

        fn releaseFields(value: *InnerT, init: *const InitFlags) void {
            inline for (Fields, 0..) |field, i| {
                if (init[i]) {
                    convert.releaseValue(&@field(value, field.name));
                }
            }
        }

        fn fieldName(comptime index: usize) []const u8 {
            return Fields[index].name;
        }

        fn wrapper(
            _: ?*c.PyObject,
            py_args: ?*c.PyObject,
            py_kwargs: ?*c.PyObject,
        ) callconv(.c) ?*c.PyObject {
            const args_tuple: ?*types.Tuple = if (py_args) |a| @ptrCast(a) else null;
            const kwargs_dict: ?*types.Dict = if (py_kwargs) |k| @ptrCast(k) else null;
            const pos_count: usize = if (args_tuple) |t| t.length() else 0;

            if (pos_count > Fields.len) {
                errors.typeError(
                    "function takes at most {d} positional argument(s) ({d} given)",
                    .{ Fields.len, pos_count },
                );
                return null;
            }

            if (kwargs_dict) |kw| {
                if (!marshal.validateKeywordNames(kw, pos_count, fieldName, Fields.len)) {
                    return null;
                }
            }

            var value: InnerT = undefined;
            var initialized: InitFlags = [_]bool{false} ** Fields.len;

            inline for (Fields, 0..) |field, i| {
                const is_optional = @typeInfo(field.type) == .optional;
                const has_default = field.default_value_ptr != null;

                if (i < pos_count) {
                    // 位置参数
                    const py_item = args_tuple.?.get(i) orelse {
                        errors.typeError("missing positional argument {d}", .{i + 1});
                        releaseFields(&value, &initialized);
                        return null;
                    };
                    @field(value, field.name) = marshal.convertField(field.type, py_item, field.name) catch {
                        releaseFields(&value, &initialized);
                        return null;
                    };
                    initialized[i] = true;
                } else if (kwargs_dict) |kw| {
                    // 按名称尝试关键字参数
                    const name_z = comptime convert.toSentinelStr(field.name);
                    const name_ptr: [*c]const u8 = name_z.ptr;
                    const py_item_opt: ?*Object = @ptrCast(c.PyDict_GetItemString(@ptrCast(kw), name_ptr));
                    if (py_item_opt) |py_item| {
                        @field(value, field.name) = marshal.convertField(field.type, py_item, field.name) catch {
                            releaseFields(&value, &initialized);
                            return null;
                        };
                    } else if (has_default) {
                        @field(value, field.name) = field.defaultValue().?;
                    } else if (is_optional) {
                        @field(value, field.name) = null;
                    } else {
                        errors.typeError("missing required argument: '{s}'", .{field.name});
                        releaseFields(&value, &initialized);
                        return null;
                    }
                    initialized[i] = true;
                } else if (has_default) {
                    @field(value, field.name) = field.defaultValue().?;
                    initialized[i] = true;
                } else if (is_optional) {
                    @field(value, field.name) = null;
                    initialized[i] = true;
                } else {
                    errors.typeError("missing required argument: '{s}'", .{field.name});
                    releaseFields(&value, &initialized);
                    return null;
                }
            }

            const wrapped = ArgsWrapper{ .value = value };
            const result = func(wrapped);
            releaseFields(&value, &initialized);
            return marshal.handleReturn(@TypeOf(result), result);
        }
    };
    return S.wrapper;
}

/// 原始 `*Tuple` / `*Dict` 参数的运行时访问器。由 `pyfn_varargs` 使用。
pub const RawArgs = struct {
    args: *types.Tuple,
    kwargs: ?*types.Dict,

    pub inline fn fromTuple(args: *types.Tuple, kwargs: ?*types.Dict) RawArgs {
        return .{ .args = args, .kwargs = kwargs };
    }

    pub inline fn len(self: RawArgs) usize {
        return self.args.length();
    }

    pub inline fn get(self: RawArgs, i: usize) ?*Object {
        return self.args.get(i);
    }

    pub inline fn getObject(self: RawArgs, i: usize) Error!*Object {
        if (self.get(i)) |o| return o;
        errors.typeError("expected at least {d} arguments", .{i + 1});
        return error.PyError;
    }

    pub inline fn getInt(self: RawArgs, i: usize) Error!isize {
        const obj = try self.getObject(i);
        if (!types.Int.check(obj)) {
            errors.typeError("argument {d} must be an integer", .{i + 1});
            return error.PyError;
        }
        return types.Int.as(@ptrCast(obj), isize);
    }

    pub inline fn getStr(self: RawArgs, i: usize) Error!*object.Str {
        const obj = try self.getObject(i);
        if (!object.Str.check(obj)) {
            errors.typeError("argument {d} must be a string", .{i + 1});
            return error.PyError;
        }
        return @ptrCast(obj);
    }

    /// 如果提供了任何关键字参数则返回真。
    pub inline fn hasKwargs(self: RawArgs) bool {
        return self.kwargs != null and self.kwargs.?.length() > 0;
    }

    /// 返回提供的关键字参数数量。
    pub inline fn kwLen(self: RawArgs) usize {
        return if (self.kwargs) |kw| kw.length() else 0;
    }

    /// 按名称借用的关键字参数引用，缺失时返回 null。
    pub inline fn getKw(self: RawArgs, name: [:0]const u8) ?*Object {
        const kw = self.kwargs orelse return null;
        return kw.getItemString(name);
    }

    /// 按名称返回关键字参数，缺失时抛出 TypeError。
    pub inline fn getKwObject(self: RawArgs, name: [:0]const u8) Error!*Object {
        if (self.getKw(name)) |o| return o;
        errors.typeError("missing required keyword argument: '{s}'", .{name});
        return error.PyError;
    }
};

/// 类型化的关键字参数包装器。与 `pyfn_kw` 配合使用：
///
/// ```zig
/// const AddArgs = struct { a: i64, b: i64, c: ?i64 = null };
/// fn add(args: pymz.Args(AddArgs)) pymz.Result(i64) { ... }
/// ```
pub fn Args(comptime T: type) type {
    return struct {
        value: T,
        pub const ArgsStruct = T;
    };
}

/// `moduleInit` 接受的模块初始化回调签名。
pub const ModuleInitFn = *const fn (mod: *types.Module) Error!void;

/// 定义 Python 扩展模块。此宏为 Python 2（`init<name>`）或 Python 3
///（`PyInit_<name>`）导出正确的入口点。
///
/// Python 3 上使用 PEP 489 多阶段初始化（`m_slots` + `PyModuleDef_Init`），
/// 提供正确的子解释器支持。Python 2 上使用传统的 `Py_InitModule` 路径。
pub fn moduleInit(comptime name: [:0]const u8, methods: [*c]MethodDef, init_fn: ?ModuleInitFn, comptime doc: ?[:0]const u8) type {
    // 验证 Zig 翻译后的结构体布局是否与 CPython 期望的大小一致。
    // 不匹配会导致字段未对齐和 PyModuleDef_Init 内部的段错误。
    comptime std.debug.assert(@sizeOf(c.PyModuleDef_Slot) == @sizeOf(extern struct { slot: c_int, value: ?*anyopaque }));
    // 验证 PyModuleDef_Base 和 m_size 的偏移。CPython 3.12 的 PyObject 为
    // 16 bytes（union ob_refcnt + 指针 ob_type），PyModuleDef_Base 为 40 bytes
    //（PyObject + m_init + m_index + m_copy）。m_size 在 m_base 之后第 3 个字段。
    comptime std.debug.assert(@sizeOf(c.PyModuleDef_Base) == 40);
    comptime std.debug.assert(@offsetOf(c.PyModuleDef, "m_size") == 56);
    const Initializer = if (version.is_py3) struct {
        // PEP 489 多阶段初始化：模块定义在解释器关闭前一直存活
        //（Python 持有 def 对象的引用）。
        var module_def: c.PyModuleDef = .{
            // 完全零初始化 m_base（PyModuleDef_Base）。CPython 的
            // PyModuleDef_HEAD_INIT 会清零所有四个字段（ob_base、m_init、
            // m_index、m_copy）；部分初始化导致 m_index / m_copy 未初始化
            // 会在 3.12+ 的 PyModuleDef_Init 中引发段错误。
            .m_base = std.mem.zeroes(c.PyModuleDef_Base),
            .m_name = name,
            .m_doc = if (doc) |d| d else null,
            .m_size = 1, // PEP 489 多阶段初始化要求 m_size >= 0；用 1 而非 0 避免部分 CPython 版本在 m_size=0 时的兼容性问题
            .m_methods = methods,
            .m_slots = &slots,
            .m_traverse = null,
            .m_clear = null,
            .m_free = null,
        };

        // Slots 数组：Py_mod_exec（slot=2）用于模块填充回调，
        // 以 {0, NULL} 哨兵终止。
        // PEP 489 定义：Py_mod_create=1（自定义模块对象创建），
        // Py_mod_exec=2（模块填充）。我们使用 Py_mod_exec 让 CPython
        // 负责创建模块对象，仅在 exec 回调中填充方法/类/常量。
        var slots = [_]c.PyModuleDef_Slot{
            .{ .slot = c.Py_mod_exec, .value = @ptrCast(@constCast(&execFn)) },
            .{ .slot = 0, .value = null },
        };

        /// PEP 489 `Py_mod_exec` 槽位处理函数。由 CPython 在模块对象创建后调用。
        /// 成功返回 0，失败返回 -1（需设置 Python 异常）。
        fn execFn(mod: ?*c.PyObject, _: c_int) callconv(.c) c_int {
            if (init_fn) |f| {
                const m = mod orelse return -1;
                f(@ptrCast(m)) catch {
                    return -1;
                };
            }
            return 0;
        }

        /// PEP 489 初始化入口点：通过 `PyModuleDef_Init`（而非 `PyModule_Create`）
        /// 返回模块定义。
        fn init() callconv(.c) [*c]c.PyObject {
            return c.pymz_PyModuleDef_Init(&module_def);
        }
    } else struct {
        fn init() callconv(.c) void {
            const mod = c.Py_InitModule(name, methods) orelse return;
            // Python 2 的 Py_InitModule 不接受文档字符串；改为作为模块属性设置。
            if (doc) |d| {
                // __doc__ setting failure does not affect module functionality.
                // Clear any exception set by the failed call to avoid polluting
                // subsequent operations.
                if (c.PyModule_AddStringConstant(mod, "__doc__", d) < 0) {
                    c.PyErr_Clear();
                }
            }
            if (init_fn) |f| {
                f(@ptrCast(mod)) catch {
                    // Python 2 初始化器返回 void，但模块在 Py_InitModule 后仍由
                    // 解释器持有。保留活动的异常并停止注册。
                    return;
                };
            }
        }
    };

    return struct {
        comptime {
            const fn_name = if (version.is_py3) "PyInit_" ++ name else "init" ++ name;
            @export(&Initializer.init, .{ .name = fn_name, .linkage = .strong });
        }
    };
}

test "method and sentinel produce well-formed MethodDef" {
    const S = struct {
        fn callback(_: ?*c.PyObject, _: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            return null;
        }
    };
    const def = method("test", S.callback, .varargs, "doc");
    try std.testing.expectEqualStrings("test", std.mem.span(def.ml_name.?));
    try std.testing.expectEqual(@as(c_int, c.METH_VARARGS), def.ml_flags);

    const end = sentinel();
    try std.testing.expect(end.ml_name == null);
    try std.testing.expectEqual(@as(c_int, 0), end.ml_flags);
}
