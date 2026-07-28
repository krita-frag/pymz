//! pymz 函数/方法包装器的参数编组。
//!
//! 本模块负责位于 Python `PyMethodDef` 回调与用户 Zig 函数之间的参数提取
//! 和返回值管道：
//!
//!   - `extractPositionalArg` / `convertField` / `validateKeywordNames` 从
//!     Python 元组/字典中提取参数，并通过 `convert` 进行转换。
//!   - `releaseArgsTuple` 在后续参数失败或包装函数返回时释放已部分转换的
//!     参数。
//!   - `handleReturn` 将 Zig 返回值（或错误）转换为适合从 `PyMethodDef`
//!     回调返回的 `*c.PyObject`。
//!
//! 转换原语本身（`toPy`、`fromPy`、`releaseValue`、`pyTypeName`）位于
//! `convert.zig` 中；本模块导入它们而非重复转换逻辑。依赖关系是单向的
//!（`marshal` -> `convert`）：`convert.zig` 不导入本模块，因此不存在
//! 导入循环，两个职责保持可分离。

const std = @import("std");
const c = @import("python_c");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
const convert = @import("convert.zig");
const mem = @import("../../mem.zig");

const Object = object.Object;

/// 释放 `std.meta.ArgsTuple(Fn)` 中前 `count` 个已转换的参数。
///
/// 每个 `pyfn_*` / 方法包装器都使用此函数，在后续参数转换失败或包装函数
/// 返回后清理已部分转换的参数元组。`skip` 是开头的非 Python 转换参数数量
///（如实例方法的 `self`、类方法的 `cls`）；这些槽位不会被触及。
pub fn releaseArgsTuple(
    comptime Fn: type,
    args: *std.meta.ArgsTuple(Fn),
    count: usize,
    comptime skip: usize,
) void {
    const Params = @typeInfo(Fn).@"fn".params;
    inline for (Params[skip..], 0..) |param, i| {
        if (i < count) {
            if (param.type) |_| {
                convert.releaseValue(&args[i + skip]);
            }
        }
    }
}

/// 计算函数参数列表中必需（非 optional）参数的数量，跳过前 `skip` 个参数
///（如实例方法和类方法的 `self`/`cls`）。没有类型的参数（如 `anytype`）
/// 不计入。
///
/// 仅编译期使用。`pyfn_typed` 和 `MethodBuilder.wrapMethod` 用它计算最小
/// 位置参数数量，用于参数数量检查的错误消息。
pub fn requiredParamCount(comptime Fn: type, comptime skip: usize) usize {
    const Params = @typeInfo(Fn).@"fn".params;
    var count: usize = 0;
    for (Params[skip..]) |param| {
        const PT = param.type orelse continue;
        if (@typeInfo(PT) != .optional) count += 1;
    }
    return count;
}

/// 从 Python 元组中提取单个位置参数并转换。
///
/// 成功时返回转换后的值（对于 `?T` 类型，值可以是 `null`，表示 Python
/// `None` 被成功转换——这与转换失败有本质区别）。
///
/// 失败时返回错误。如果 `fromPy` 已设置 Python 异常（如溢出错误），异常
/// 被保留；否则设置 `TypeError` 含参数期望/实际类型信息。调用方应在
/// `catch` 块中释放先前已转换的参数并从包装器返回 `null`/`-1`。
///
/// 返回 `Error!PT` 而非 `?PT` 是为了消除 `??T` 歧义：当 `PT` 是 `?T`
/// 时，`?PT` 无法区分"转换失败"与"成功转换为 None"。
///
/// `arg_label` 用于错误消息，应标识参数（如基于 1 的索引字符串或参数名）。
pub fn extractPositionalArg(
    comptime PT: type,
    args_tuple: *types.Tuple,
    index: usize,
    arg_label: []const u8,
) errors.Error!PT {
    const py_item = args_tuple.get(index) orelse {
        errors.typeError("missing argument {s}", .{arg_label});
        return error.PyError;
    };
    return convert.fromPy(PT, py_item) catch |err| {
        // 保留 fromPy 可能已设置的更具体异常（如 OverflowError），
        // 仅在无异常时设置 TypeError。
        if (errors.errorOccurred() == null) {
            errors.typeError(
                "argument {s} expects {s}, got {s}",
                .{ arg_label, @typeName(PT), convert.pyTypeName(py_item) },
            );
        }
        return err;
    };
}

/// 将 Python 对象转换为结构体字段值，处理可选类型和 `None` 输入。
/// 由 `pyfn_kw` 和任何从 Python 参数填充结构体字段的包装器使用。
///
/// 成功时返回转换后的值。失败时返回错误，保留 `fromPy` 已设置的具体异常
/// 或在无异常时设置 `TypeError`。调用方负责释放任何先前已转换的字段。
pub fn convertField(
    comptime FT: type,
    py_item: *Object,
    field_name: []const u8,
) errors.Error!FT {
    if (@typeInfo(FT) == .optional) {
        if (py_item.isNone()) return null;
        const InnerT = @typeInfo(FT).optional.child;
        return convert.fromPy(InnerT, py_item) catch |err| {
            if (errors.errorOccurred() == null) {
                errors.typeError(
                    "argument '{s}' expects {s}, got {s}",
                    .{ field_name, @typeName(FT), convert.pyTypeName(py_item) },
                );
            }
            return err;
        };
    }
    return convert.fromPy(FT, py_item) catch |err| {
        if (errors.errorOccurred() == null) {
            errors.typeError(
                "argument '{s}' expects {s}, got {s}",
                .{ field_name, @typeName(FT), convert.pyTypeName(py_item) },
            );
        }
        return err;
    };
}

/// 验证关键字参数名是否与编译期有效名称列表匹配。
///
/// 遍历 `kwargs_dict` 中的每个键，确保每个键都是字符串且匹配 `names` 中
/// 的某一个，并且对应的索引未被位置参数占用（`pos_count`）。违反任何条件
/// 时，设置 `TypeError` 并返回 `false`；调用方应中止包装器。
///
/// `nameAtIndex` 必须是一个 `comptime fn(comptime usize) []const u8`，对
/// 给定索引返回有效的关键字名称，若索引超出范围则返回空字符串。索引在
/// 编译期传递，因为调用方在 `inline for` 中遍历它。
pub fn validateKeywordNames(
    kwargs_dict: *types.Dict,
    pos_count: usize,
    comptime nameAtIndex: fn (comptime index: usize) []const u8,
    comptime field_count: usize,
) bool {
    var pos: c.Py_ssize_t = 0;
    var key_obj: ?*c.PyObject = null;
    var value_obj: ?*c.PyObject = null;
    while (c.PyDict_Next(@ptrCast(kwargs_dict), &pos, &key_obj, &value_obj) != 0) {
        const keyword_obj: *Object = @ptrCast(key_obj orelse {
            errors.typeError("keyword argument name must be str", .{});
            return false;
        });
        if (!object.Str.check(keyword_obj)) {
            errors.typeError("keyword argument name must be str", .{});
            return false;
        }

        const keyword_name = object.Str.asString(@ptrCast(keyword_obj)) catch |err| {
            errors.mapError(err);
            return false;
        };

        var found_idx: ?usize = null;
        inline for (0..field_count) |i| {
            if (std.mem.eql(u8, keyword_name, comptime nameAtIndex(i))) {
                found_idx = i;
                break;
            }
        }

        if (found_idx == null) {
            errors.typeError("got an unexpected keyword argument '{s}'", .{keyword_name});
            return false;
        }
        if (found_idx.? < pos_count) {
            errors.typeError("got multiple values for argument '{s}'", .{keyword_name});
            return false;
        }
    }
    return true;
}

/// 将 Zig 返回值（可能为错误联合类型）转换为适合从 `PyMethodDef` 回调返回
/// 的 Python 对象。
///
/// 遇到 Zig 错误时，将其映射到 Python 异常（除非已设置）并返回 `null`。
/// 成功时返回一个新引用。包装器产生的临时值通过 `releaseReturnedValue` 释放。
pub fn handleReturn(comptime RT: type, result: RT) ?*c.PyObject {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return handlePayload(@TypeOf(value), value);
            } else |err| {
                if (errors.errorOccurred() == null) {
                    errors.mapError(err);
                }
                return null;
            }
        },
        else => return handlePayload(RT, result),
    }
}

/// 在 `toPy` 将包装器产生的值转换为 Python 对象后，释放其所有权。
///
/// 返回 `*Object` / `*c.PyObject` 的 Zig 函数遵循 CPython 返回值约定：
/// 它们返回一个新引用。`toPy` 已经 incref 产生了 Python 端的新引用，因此
/// 在此 decref 原始值以避免泄漏。包装器返回的可变 `[]u8` 切片通过
/// `convert.releaseValue` 释放。
fn releaseReturnedValue(value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (value) |inner| {
                releaseReturnedValue(inner);
            }
            _ = optional_info;
        },
        .pointer => |pointer_info| {
            if (traits.isObjectPtr(T)) {
                value.decref();
                return;
            }
            if (pointer_info.child == c.PyObject) {
                @as(*object.Object, @ptrCast(value)).decref();
                return;
            }
            if (pointer_info.size == .slice and pointer_info.child == u8 and !pointer_info.is_const) {
                convert.releaseValue(&value);
            }
        },
        .@"struct" => |struct_info| {
            // Handle top-level ArrayList(T): deinit its backing buffer.
            if (comptime traits.isArrayList(T)) {
                var mut = value;
                mut.deinit(mem.allocator);
                return;
            }
            // Release *Object / ?*Object fields (incref'd by toPy) and
            // ArrayList(T) fields (backing buffer) and owned []u8 fields.
            inline for (struct_info.fields) |field| {
                const FT = field.type;
                if (comptime traits.isObjectPtr(FT)) {
                    @field(value, field.name).decref();
                } else if (comptime traits.isObjectPtrOptional(FT)) {
                    if (@field(value, field.name)) |obj| obj.decref();
                } else if (comptime traits.isArrayList(FT)) {
                    var mut = @field(value, field.name);
                    mut.deinit(mem.allocator);
                } else if (comptime @typeInfo(FT) == .pointer and
                    @typeInfo(FT).pointer.size == .slice and
                    @typeInfo(FT).pointer.child == u8 and
                    !@typeInfo(FT).pointer.is_const)
                {
                    convert.releaseValue(&@field(value, field.name));
                }
            }
        },
        else => {},
    }
}

fn handlePayload(comptime T: type, value: T) ?*c.PyObject {
    defer releaseReturnedValue(value);
    const obj = convert.toPy(value) catch return null;
    return @ptrCast(obj);
}
