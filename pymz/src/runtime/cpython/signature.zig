//! Build `__text_signature__` strings (ml_doc) for Python-callable wrappers.
//!
//! CPython parses signatures from `ml_doc` using the Argument Clinic format:
//!   `"funcname($module, arg0, arg1, /)\n--\n\nDocstring text"`
//! The signature portion becomes `__text_signature__` and is used by `help()`
//! and `inspect.signature()`.

const std = @import("std");

/// Method kind for text signature generation.
/// Determines the hidden parameter prefix that CPython strips from signatures.
pub const MethodKind = enum {
    /// Module-level function: hidden `$module` parameter.
    module_func,
    /// Instance method: hidden `$self` parameter.
    instance_method,
    /// Static method: no hidden parameter.
    static_method,
    /// Class method: hidden `$type` parameter.
    class_method,
};

/// How to render parameters in the signature.
pub const KwargsMode = enum {
    /// Plain positional: `funcname($module, arg0, arg1, /)`.
    positional,
    /// Named kwargs from an `Args(T)` struct: `funcname($module, /, a, b=None)`.
    args_struct,
    /// Mixed positional/keyword: `funcname($module, a, b)`.
    mixed,
    /// Fully variadic: `funcname($module, *args, **kwargs)`.
    varargs,
};

/// Build an `ml_doc` string with an embedded `__text_signature__`.
pub fn buildMlDoc(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime doc: ?[]const u8,
) [:0]const u8 {
    return buildMlDocWithOptions(name, Fn, kind, .positional, doc, null);
}

/// Full-featured `ml_doc` builder with explicit kwargs mode and optional
/// parameter names override (comma-separated, matching parameter order).
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

                // Only `.positional` marks parameters positional-only (`", /"`).
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

/// Extract the Nth parameter name from a comma-separated string.
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
