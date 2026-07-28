//! 函数导出描述符。

const common = @import("common.zig");
const module_mod = @import("../module.zig");
const limiter = @import("../limiter.zig");
const signature = @import("../signature.zig");

pub const ExportKind = common.ExportKind;
pub const FnMode = common.FnMode;
pub const FunctionOptions = common.FunctionOptions;

fn FunctionDescriptor(
    comptime Func: anytype,
    comptime mode_value: FnMode,
    comptime param_names_value: ?[]const u8,
    comptime doc_value: ?[]const u8,
    comptime limited_value: ?bool,
) type {
    return struct {
        pub const export_kind: ExportKind = .function;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const func = Func;
        pub const mode = mode_value;
        pub const param_names = param_names_value;
        pub const doc = doc_value;
        pub const limited = limited_value;
        pub const is_active = limiter.isActiveForPlatform(limited_value);

        pub fn methodDefWithName(comptime export_name: [:0]const u8) common.MethodDef {
            return methodDefWithNameAndParamNames(export_name, null);
        }

        pub fn methodDefWithNameAndParamNames(
            comptime export_name: [:0]const u8,
            comptime names: ?[]const u8,
        ) common.MethodDef {
            const effective_param_names = names orelse param_names;
            const callback = switch (mode) {
                .kwargs => module_mod.pyfn_kw(func),
                .positional => module_mod.pyfn_typed(func),
                .mixed => module_mod.pyfn_mixed(func, effective_param_names),
                .varargs => module_mod.pyfn_varargs(func),
            };
            const ml_doc = switch (mode) {
                .kwargs => signature.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .args_struct,
                    doc,
                    effective_param_names,
                ),
                .positional => signature.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .positional,
                    doc,
                    effective_param_names,
                ),
                .mixed => signature.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .mixed,
                    doc,
                    effective_param_names,
                ),
                .varargs => signature.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .varargs,
                    doc,
                    effective_param_names,
                ),
            };
            const flags: c_int = switch (mode) {
                .kwargs => common.MethodFlags.varargs.toC() | common.MethodFlags.keywords.toC(),
                .positional => common.MethodFlags.varargs.toC(),
                .mixed => common.MethodFlags.varargs.toC() | common.MethodFlags.keywords.toC(),
                .varargs => common.MethodFlags.varargs.toC() | common.MethodFlags.keywords.toC(),
            };
            return .{
                .ml_name = export_name,
                .ml_meth = @ptrCast(&callback),
                .ml_flags = flags,
                .ml_doc = ml_doc,
            };
        }
    };
}

pub fn function(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    const opts = common.extractFunctionOptions(desc);
    return FunctionDescriptor(func, .mixed, common.resolveParamNames(opts), opts.doc, opts.limited);
}

pub fn positionalFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    const opts = common.extractFunctionOptions(desc);
    return FunctionDescriptor(func, .positional, common.resolveParamNames(opts), opts.doc, opts.limited);
}

pub fn kwFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    const opts = common.extractFunctionOptions(desc);
    return FunctionDescriptor(func, .kwargs, common.resolveParamNames(opts), opts.doc, opts.limited);
}

pub fn varargsFunction(
    comptime func: anytype,
    comptime desc: anytype,
) type {
    const opts = common.extractFunctionOptions(desc);
    return FunctionDescriptor(func, .varargs, common.resolveParamNames(opts), opts.doc, opts.limited);
}
