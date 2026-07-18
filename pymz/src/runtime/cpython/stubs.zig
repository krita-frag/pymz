//! Minimal .pyi stub generation and `__text_signature__` builder.
//!
//! Stubs are written at build time from a comptime-known list of `Stub` entries.
//! This gives IDEs and type checkers basic signatures for module-level functions
//! and constants without requiring runtime introspection.
//!
//! `buildMlDoc` produces an `ml_doc` string in the Argument Clinic format, which
//! CPython parses to populate `__text_signature__` so that `help()` and
//! `inspect.signature()` show proper parameter names.

const std = @import("std");
const traits = @import("traits.zig");

// ============================================================================
// .pyi stub generation
// ============================================================================

/// Description of a single exported Python symbol for stub generation.
pub const Stub = struct {
    name: []const u8,
    kind: Kind = .function,

    /// Function parameter list as it should appear in the stub, e.g. "a: int, b: int".
    /// For constants this field is ignored.
    params: []const u8 = "*args, **kwargs",

    /// Python annotation for the return type or constant type.
    returns: []const u8 = "Any",

    /// Docstring body (single line recommended).
    doc: []const u8 = "",

    /// For class stubs: list of method signatures and class attributes.
    /// Ignored for function/constant stubs.
    methods: []const MethodStub = &.{},

    pub const Kind = enum {
        function,
        constant,
        class,
        exception,
    };
};

/// A method entry inside a class stub.
pub const MethodStub = struct {
    name: []const u8,
    params: []const u8 = "self",
    returns: []const u8 = "Any",
    is_static: bool = false,
    doc: []const u8 = "",
};

/// Generate a complete .pyi file content from a module name and stub entries.
pub inline fn generate(comptime module_name: []const u8, comptime stubs: []const Stub) []const u8 {
    comptime {
        var result: []const u8 = "\"\"\"Type stubs for " ++ module_name ++ ".\"\"\"\n\n";
        result = result ++ "from typing import Any\n\n";

        for (stubs) |stub| {
            if (stub.doc.len > 0) {
                result = result ++ "# " ++ stub.doc ++ "\n";
            }
            switch (stub.kind) {
                .function => {
                    result = result ++ "def " ++ stub.name ++ "(" ++ stub.params ++ ") -> " ++ stub.returns ++ ": ...\n";
                },
                .constant => {
                    result = result ++ stub.name ++ ": " ++ stub.returns ++ "\n";
                },
                .exception => {
                    result = result ++ "class " ++ stub.name ++ "(Exception):\n";
                    if (stub.doc.len > 0) {
                        result = result ++ "    \"\"\"" ++ stub.doc ++ "\"\"\"\n";
                    }
                    result = result ++ "    ...\n";
                },
                .class => {
                    result = result ++ "class " ++ stub.name ++ ":\n";
                    if (stub.doc.len > 0) {
                        result = result ++ "    \"\"\"" ++ stub.doc ++ "\"\"\"\n";
                    }
                    if (stub.params.len > 0) {
                        result = result ++ "    def __init__(self, " ++ stub.params ++ ") -> None: ...\n";
                    } else {
                        result = result ++ "    def __init__(self) -> None: ...\n";
                    }
                    for (stub.methods) |m| {
                        if (m.doc.len > 0) {
                            result = result ++ "    # " ++ m.doc ++ "\n";
                        }
                        if (m.is_static) {
                            result = result ++ "    @staticmethod\n";
                            result = result ++ "    def " ++ m.name ++ "(" ++ m.params ++ ") -> " ++ m.returns ++ ": ...\n";
                        } else {
                            result = result ++ "    def " ++ m.name ++ "(self, " ++ m.params ++ ") -> " ++ m.returns ++ ": ...\n";
                        }
                    }
                    if (stub.methods.len == 0) {
                        result = result ++ "    ...\n";
                    }
                },
            }
        }

        return result;
    }
}

/// Build a function stub entry.
pub inline fn func(
    name: []const u8,
    params: []const u8,
    returns: []const u8,
    doc: []const u8,
) Stub {
    return .{
        .name = name,
        .kind = .function,
        .params = params,
        .returns = returns,
        .doc = doc,
    };
}

/// Build a constant stub entry.
pub inline fn constant(name: []const u8, py_type: []const u8, doc: []const u8) Stub {
    return .{
        .name = name,
        .kind = .constant,
        .returns = py_type,
        .doc = doc,
    };
}

/// Build an exception stub entry.
pub inline fn exceptionStub(name: []const u8, doc: []const u8) Stub {
    return .{
        .name = name,
        .kind = .exception,
        .doc = doc,
    };
}

/// Build a class stub entry.
pub inline fn classStub(
    name: []const u8,
    params: []const u8,
    doc: []const u8,
    methods: []const MethodStub,
) Stub {
    return .{
        .name = name,
        .kind = .class,
        .params = params,
        .doc = doc,
        .methods = methods,
    };
}

pub fn functionStubAuto(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kwargs_mode: KwargsMode,
    comptime doc: ?[]const u8,
    comptime param_names: ?[]const u8,
) Stub {
    return .{
        .name = name,
        .kind = .function,
        .params = buildStubParams(Fn, .module_func, kwargs_mode, param_names),
        .returns = pythonTypeName(functionReturnPayloadType(Fn)),
        .doc = doc orelse "",
    };
}

pub fn methodStubAuto(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime param_names: ?[]const u8,
    comptime doc: ?[]const u8,
) MethodStub {
    return .{
        .name = name,
        .params = buildStubParams(Fn, kind, .positional, param_names),
        .returns = pythonTypeName(functionReturnPayloadType(Fn)),
        .is_static = kind == .static_method,
        .doc = doc orelse "",
    };
}

pub fn classStubAuto(
    comptime name: []const u8,
    comptime T: type,
    comptime doc: ?[:0]const u8,
) Stub {
    const constructor_params = if (@hasDecl(T, "__new__"))
        buildStubParams(
            @TypeOf(T.__new__),
            .static_method,
            .positional,
            classConstructorParamNames(T),
        )
    else
        buildStructConstructorParams(T);

    return .{
        .name = name,
        .kind = .class,
        .params = constructor_params,
        .doc = if (doc) |d| d else "",
        .methods = buildClassMethodStubs(T),
    };
}

fn functionReturnPayloadType(comptime Fn: type) type {
    const fn_info = @typeInfo(Fn);
    if (fn_info != .@"fn") {
        @compileError("functionReturnPayloadType expects a function type");
    }
    const return_type = fn_info.@"fn".return_type orelse return void;
    return switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => return_type,
    };
}

fn pythonTypeName(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .bool => {
            return "bool";
        },
        .int, .comptime_int => {
            return "int";
        },
        .float, .comptime_float => {
            return "float";
        },
        .void => {
            return "None";
        },
        .optional => |info| {
            return pythonTypeName(info.child) ++ " | None";
        },
        .error_union => |info| {
            return pythonTypeName(info.payload);
        },
        .pointer => |info| {
            if (traits.isStringSlice(T)) {
                return "str";
            }
            if (traits.isObjectPtr(T)) {
                return "Any";
            }
            if (info.size == .slice) {
                return "list[Any]";
            }
            return "Any";
        },
        .@"struct" => {
            if (traits.isArrayList(T)) {
                return "list[Any]";
            }
            return "Any";
        },
        else => {
            return "Any";
        },
    }
}

fn buildStubParams(
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime kwargs_mode: KwargsMode,
    comptime param_names: ?[]const u8,
) []const u8 {
    const fn_info = @typeInfo(Fn);
    if (fn_info != .@"fn") {
        @compileError("buildStubParams expects a function type");
    }
    const params = fn_info.@"fn".params;
    const skip: usize = switch (kind) {
        .instance_method => 1,
        .module_func, .static_method => 0,
    };

    switch (kwargs_mode) {
        .args_struct => {
            if (params.len == 0) return "";
            const args_wrapper_type = params[0].type orelse return "";
            if (@typeInfo(args_wrapper_type) != .@"struct" or !@hasDecl(args_wrapper_type, "ArgsStruct")) {
                @compileError("buildStubParams(.args_struct) expects Args(T)");
            }
            return buildStructFieldParams(args_wrapper_type.ArgsStruct);
        },
        .positional => {
            var result: []const u8 = "";
            var need_comma = false;
            var arg_index: usize = 0;
            for (params[skip..]) |param| {
                const param_type = param.type orelse continue;
                if (need_comma) {
                    result = result ++ ", ";
                }
                result = result ++ buildTypedParam(
                    parameterDisplayName(param_names, arg_index),
                    param_type,
                    defaultSuffixForType(param_type, false),
                );
                need_comma = true;
                arg_index += 1;
            }
            if (need_comma) {
                result = result ++ ", /";
            }
            return result;
        },
        .auto_kwargs => {
            var result: []const u8 = "";
            var need_comma = false;
            var arg_index: usize = 0;
            var has_required = false;

            for (params[skip..]) |param| {
                if (param.type) |ptype| {
                    if (@typeInfo(ptype) != .optional) {
                        if (need_comma) {
                            result = result ++ ", ";
                        }
                        result = result ++ buildTypedParam(
                            parameterDisplayName(param_names, arg_index),
                            ptype,
                            "",
                        );
                        need_comma = true;
                        has_required = true;
                    }
                    arg_index += 1;
                }
            }

            if (has_required) {
                result = result ++ ", /";
                need_comma = true;
            }

            arg_index = 0;
            for (params[skip..]) |param| {
                if (param.type) |ptype| {
                    if (@typeInfo(ptype) == .optional) {
                        if (need_comma) {
                            result = result ++ ", ";
                        }
                        result = result ++ buildTypedParam(
                            parameterDisplayName(param_names, arg_index),
                            ptype,
                            defaultSuffixForType(ptype, false),
                        );
                        need_comma = true;
                    }
                    arg_index += 1;
                }
            }
            return result;
        },
    }
}

fn buildStructConstructorParams(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    var result: []const u8 = "";
    var need_comma = false;
    for (fields) |field| {
        if (field.name.len > 0 and field.name[0] == '_') {
            continue;
        }
        if (need_comma) {
            result = result ++ ", ";
        }
        result = result ++ buildTypedParam(
            field.name,
            field.type,
            defaultSuffixForType(field.type, field.default_value_ptr != null),
        );
        need_comma = true;
    }
    return result;
}

fn buildStructFieldParams(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    var result: []const u8 = "";
    var need_comma = false;
    for (fields) |field| {
        if (need_comma) {
            result = result ++ ", ";
        }
        result = result ++ buildTypedParam(
            field.name,
            field.type,
            defaultSuffixForType(field.type, field.default_value_ptr != null),
        );
        need_comma = true;
    }
    return result;
}

fn buildTypedParam(
    comptime name: []const u8,
    comptime T: type,
    comptime default_suffix: []const u8,
) []const u8 {
    return name ++ ": " ++ pythonTypeName(T) ++ default_suffix;
}

fn defaultSuffixForType(comptime T: type, comptime has_default: bool) []const u8 {
    if (@typeInfo(T) == .optional) {
        return " = None";
    }
    if (has_default) {
        return " = ...";
    }
    return "";
}

fn parameterDisplayName(comptime param_names: ?[]const u8, comptime arg_index: usize) []const u8 {
    if (param_names) |names| {
        return getParamName(names, arg_index);
    }
    return std.fmt.comptimePrint("arg{d}", .{arg_index});
}

fn classMethodParamNames(comptime T: type, comptime method_name: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "__pymz_method_param_names__")) {
        return null;
    }
    const overrides = T.__pymz_method_param_names__;
    if (!@hasField(@TypeOf(overrides), method_name)) {
        return null;
    }
    return @field(overrides, method_name);
}

fn classConstructorParamNames(comptime T: type) ?[]const u8 {
    if (@hasDecl(T, "__pymz_constructor_param_names__")) {
        return T.__pymz_constructor_param_names__;
    }
    return null;
}

fn buildClassMethodStubs(comptime T: type) []const MethodStub {
    const decls = @typeInfo(T).@"struct".decls;
    const method_count = comptime countClassMethods(T, decls);
    const Holder = struct {
        pub const methods = blk: {
            var tmp: [method_count]MethodStub = undefined;
            var index: usize = 0;
            for (decls) |decl| {
                if (isInstanceStubMethod(T, decl.name)) {
                    tmp[index] = methodStubAuto(
                        decl.name,
                        @TypeOf(@field(T, decl.name)),
                        .instance_method,
                        classMethodParamNames(T, decl.name),
                        null,
                    );
                    index += 1;
                } else if (isStaticStubMethod(T, decl.name)) {
                    tmp[index] = methodStubAuto(
                        decl.name,
                        @TypeOf(@field(T, decl.name)),
                        .static_method,
                        classMethodParamNames(T, decl.name),
                        null,
                    );
                    index += 1;
                }
            }
            break :blk tmp;
        };
    };
    return Holder.methods[0..];
}

fn countClassMethods(comptime T: type, comptime decls: anytype) usize {
    var count: usize = 0;
    for (decls) |decl| {
        if (isInstanceStubMethod(T, decl.name) or isStaticStubMethod(T, decl.name)) {
            count += 1;
        }
    }
    return count;
}

fn isInstanceStubMethod(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name)) {
        return false;
    }
    if (isExcludedStubDunder(name)) {
        return false;
    }
    const F = @TypeOf(@field(T, name));
    const info = @typeInfo(F);
    if (info != .@"fn") {
        return false;
    }
    const params = info.@"fn".params;
    if (params.len == 0) {
        return false;
    }
    const first_type = params[0].type orelse return false;
    return switch (@typeInfo(first_type)) {
        .pointer => |pointer_info| pointer_info.child == T,
        else => first_type == T,
    };
}

fn isStaticStubMethod(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name)) {
        return false;
    }
    if (isExcludedStubDunder(name)) {
        return false;
    }
    const F = @TypeOf(@field(T, name));
    if (@typeInfo(F) != .@"fn") {
        return false;
    }
    return !isInstanceStubMethod(T, name);
}

fn isExcludedStubDunder(comptime name: []const u8) bool {
    const excluded = [_][]const u8{
        "__new__",      "__del__",  "__repr__",    "__str__",     "__hash__",
        "__eq__",       "__ne__",   "__lt__",      "__le__",      "__gt__",
        "__ge__",       "__len__",  "__getitem__", "__setitem__", "__delitem__",
        "__contains__", "__iter__", "__next__",    "__call__",
    };
    for (excluded) |entry| {
        if (std.mem.eql(u8, name, entry)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// __text_signature__ / ml_doc builder (Argument Clinic format)
// ============================================================================

/// Method kind for text signature generation.
/// Determines the hidden parameter prefix that CPython strips from signatures.
pub const MethodKind = enum {
    /// Module-level function: hidden `$module` parameter.
    module_func,
    /// Instance method: hidden `$self` parameter.
    instance_method,
    /// Static method: no hidden parameter.
    static_method,
};

/// Build an `ml_doc` string with an embedded `__text_signature__`.
///
/// CPython parses signatures from `ml_doc` using the Argument Clinic format:
///   `"funcname($module, arg0, arg1, /)\n--\n\nDocstring text"`
///
/// The signature portion is extracted as `__text_signature__` and used by
/// `help()` and `inspect.signature()` to show proper parameter names.
///
/// For functions taking `Args(T)`, pass `KwargsMode.args_struct` to render the
/// struct fields as named keyword arguments. For functions with optional `?T`
/// parameters, pass `KwargsMode.auto_kwargs` to split them into a
/// positional-only group followed by keyword-capable optional parameters.
pub fn buildMlDoc(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime doc: ?[]const u8,
) [:0]const u8 {
    return buildMlDocWithOptions(name, Fn, kind, .positional, doc, null);
}

/// How to render parameters in the signature.
pub const KwargsMode = enum {
    /// Plain positional: `funcname($module, arg0, arg1, /)`.
    positional,
    /// Named kwargs from an `Args(T)` struct: `funcname($module, /, a, b=None)`.
    args_struct,
    /// Auto kwargs: required params positional-only, optional params as keywords.
    /// `funcname($module, req1, req2, /, opt1=None, opt2=None)`.
    auto_kwargs,
};

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

        // Hidden parameter prefix (stripped by inspect)
        const hidden: ?[]const u8 = switch (kind) {
            .module_func => "$module",
            .instance_method => "$self",
            .static_method => null,
        };

        switch (kwargs_mode) {
            .args_struct => {
                // Named kwargs: funcname($module, /, field1, field2=None)
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
            .auto_kwargs => {
                // Auto kwargs: funcname($module, req1, req2, /, opt1=None, opt2=None)
                var has_any = false;
                if (hidden) |h| {
                    result = result ++ h;
                    has_any = true;
                }

                const skip: usize = switch (kind) {
                    .instance_method => 1,
                    .module_func, .static_method => 0,
                };

                // First pass: required (non-optional) params — positional-only
                var arg_idx: usize = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) != .optional) {
                            if (has_any) result = result ++ ", ";
                            if (param_names) |pn| {
                                result = result ++ getParamName(pn, arg_idx);
                            } else {
                                result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                            }
                            has_any = true;
                        }
                        arg_idx += 1;
                    }
                }

                // Positional-only separator
                if (has_any) {
                    result = result ++ ", /";
                }

                // Second pass: optional (?T) params — keyword-capable
                arg_idx = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) == .optional) {
                            result = result ++ ", ";
                            if (param_names) |pn| {
                                result = result ++ getParamName(pn, arg_idx);
                            } else {
                                result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                            }
                            result = result ++ "=None";
                        }
                        arg_idx += 1;
                    }
                }
            },
            .positional => {
                // Regular positional: funcname($module, arg0, arg1, /)
                var has_any = false;
                if (hidden) |h| {
                    result = result ++ h;
                    has_any = true;
                }

                // Skip self/cls parameter for instance/class methods
                const skip: usize = switch (kind) {
                    .instance_method => 1,
                    .module_func, .static_method => 0,
                };

                var arg_idx: usize = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (has_any) result = result ++ ", ";
                        if (param_names) |pn| {
                            result = result ++ getParamName(pn, arg_idx);
                        } else {
                            result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                        }
                        // Mark optional parameters
                        if (@typeInfo(ptype) == .optional) {
                            result = result ++ "=None";
                        }
                        has_any = true;
                        arg_idx += 1;
                    }
                }

                // Mark as positional-only (trailing /)
                if (has_any) {
                    result = result ++ ", /";
                }
            },
        }

        result = result ++ ")\n--\n\n";

        // Append docstring
        if (doc) |d| {
            result = result ++ d;
        }

        return comptimeStrZ(result);
    }
}

/// Build a `[:0]const u8` from a comptime-known `[]const u8` by appending a NUL.
fn comptimeStrZ(comptime s: []const u8) [:0]const u8 {
    comptime {
        const with_null = s ++ "\x00";
        return with_null[0..s.len :0];
    }
}

/// Extract the Nth parameter name from a comma-separated string.
/// e.g., getParamName("entries, ring, flags", 1) -> "ring"
/// Falls back to "argN" if the index is out of range.
fn getParamName(comptime names_str: []const u8, comptime idx: usize) []const u8 {
    comptime {
        var current_idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= names_str.len) : (i += 1) {
            if (i == names_str.len or names_str[i] == ',') {
                if (current_idx == idx) {
                    // Trim whitespace from both ends
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
