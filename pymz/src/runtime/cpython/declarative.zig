//! Declarative pyo3-style API for pymz.

const common = @import("declarative/common.zig");
const function_decl = @import("declarative/function.zig");
const class_decl = @import("declarative/class.zig");
const exception_decl = @import("declarative/exception.zig");
const constant_decl = @import("declarative/constant.zig");
const module_decl = @import("declarative/module.zig");

pub const ExportKind = common.ExportKind;
pub const FnMode = common.FnMode;
pub const FunctionOptions = common.FunctionOptions;

pub const function = function_decl.function;
pub const positionalFunction = function_decl.positionalFunction;
pub const kwFunction = function_decl.kwFunction;
pub const varargsFunction = function_decl.varargsFunction;
pub const class = class_decl.class;
pub const exception = exception_decl.exception;
pub const constant = constant_decl.constant;
pub const module = module_decl.module;
