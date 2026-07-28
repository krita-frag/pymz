//! 为 Python 可调用包装器构建 `__text_signature__` 字符串（ml_doc）。
//!
//! CPython 使用 Argument Clinic 格式从 `ml_doc` 解析签名：
//!   `"funcname($module, arg0, arg1, /)\n--\n\nDocstring text"`
//! 签名部分成为 `__text_signature__`，被 `help()` 和 `inspect.signature()` 使用。

const std = @import("std");

/// 文本签名生成的方法类型。
/// 决定 CPython 从签名中剥离的隐藏参数前缀。
pub const MethodKind = enum {
    /// 模块级函数：隐藏 `$module` 参数。
    module_func,
    /// 实例方法：隐藏 `$self` 参数。
    instance_method,
    /// 静态方法：无隐藏参数。
    static_method,
    /// 类方法：隐藏 `$type` 参数。
    class_method,
};

/// 如何渲染签名中的参数。
pub const KwargsMode = enum {
    /// 纯位置参数：`funcname($module, arg0, arg1, /)`。
    positional,
    /// 来自 `Args(T)` 结构体的命名 kwargs：`funcname($module, /, a, b=None)`。
    args_struct,
    /// 混合位置/关键字：`funcname($module, a, b)`。
    mixed,
    /// 完全可变参数：`funcname($module, *args, **kwargs)`。
    varargs,
};

/// 构建带有嵌入 `__text_signature__` 的 `ml_doc` 字符串。
pub fn buildMlDoc(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime doc: ?[]const u8,
) [:0]const u8 {
    return buildMlDocWithOptions(name, Fn, kind, .positional, doc, null);
}

/// 功能完整的 `ml_doc` 构建器，支持显式 kwargs 模式和可选的参数名
/// 覆盖（逗号分隔，与参数顺序匹配）。
pub fn buildMlDocWithOptions(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime kwargs_mode: KwargsMode,
    comptime doc: ?[]const u8,
    comptime param_names: ?[]const u8,
) [:0]const u8 {
    comptime {
        const fn_info = @typeInfo(Fn);
        if (fn_info != .@"fn") {
            @compileError("buildMlDoc: expected a function type, got " ++ @typeName(Fn));
        }
        const params = fn_info.@"fn".params;

        var result: []const u8 = name ++ "(";

        const hidden: ?[]const u8 = switch (kind) {
            .module_func => "$module",
            .instance_method => "$self",
            .class_method => "$type",
            .static_method => null,
        };

        switch (kwargs_mode) {
            .args_struct => {
                var need_comma = false;
                if (hidden) |h| {
                    result = result ++ h ++ ", /";
                    need_comma = true;
                }

                if (params.len >= 1) {
                    const ArgsWrapperType = params[0].type.?;
                    if (@typeInfo(ArgsWrapperType) == .@"struct" and @hasDecl(ArgsWrapperType, "ArgsStruct")) {
                        const ArgsStructType = ArgsWrapperType.ArgsStruct;
                        const args_fields = @typeInfo(ArgsStructType).@"struct".fields;

                        for (args_fields) |field| {
                            if (need_comma) {
                                result = result ++ ", ";
                            }
                            result = result ++ field.name;
                            if (field.default_value_ptr != null or @typeInfo(field.type) == .optional) {
                                result = result ++ "=None";
                            }
                            need_comma = true;
                        }
                    }
                }
            },
            .positional, .mixed => {
                var has_any = false;
                if (hidden) |h| {
                    result = result ++ h;
                    has_any = true;
                }

                const skip: usize = switch (kind) {
                    .instance_method, .class_method => 1,
                    .module_func, .static_method => 0,
                };

                var arg_idx: usize = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (has_any) result = result ++ ", ";
                        result = result ++ paramDisplayName(param_names, arg_idx);
                        if (@typeInfo(ptype) == .optional) {
                            result = result ++ "=None";
                        }
                        has_any = true;
                        arg_idx += 1;
                    }
                }

                // 只有 `.positional` 将参数标记为仅位置参数（`", /"`）。
                if (kwargs_mode == .positional and has_any) {
                    result = result ++ ", /";
                }
            },
            .varargs => {
                if (hidden) |h| {
                    result = result ++ h ++ ", ";
                }
                result = result ++ "*args, **kwargs";
            },
        }

        result = result ++ ")\n--\n\n";

        if (doc) |d| {
            result = result ++ d;
        }

        return comptimeStrZ(result);
    }
}

/// 从逗号分隔的字符串中提取第 N 个参数名。
pub fn getParamName(comptime names_str: []const u8, comptime idx: usize) []const u8 {
    comptime {
        var current_idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= names_str.len) : (i += 1) {
            if (i == names_str.len or names_str[i] == ',') {
                if (current_idx == idx) {
                    var s = start;
                    var e = i;
                    while (s < e and (names_str[s] == ' ' or names_str[s] == '\t')) s += 1;
                    while (e > s and (names_str[e - 1] == ' ' or names_str[e - 1] == '\t')) e -= 1;
                    return names_str[s..e];
                }
                current_idx += 1;
                start = i + 1;
            }
        }
        return std.fmt.comptimePrint("arg{d}", .{idx});
    }
}

fn paramDisplayName(comptime param_names: ?[]const u8, comptime arg_index: usize) []const u8 {
    if (param_names) |pn| {
        return getParamName(pn, arg_index);
    }
    return std.fmt.comptimePrint("arg{d}", .{arg_index});
}

fn comptimeStrZ(comptime s: []const u8) [:0]const u8 {
    comptime {
        const with_null = s ++ "\x00";
        return with_null[0..s.len :0];
    }
}