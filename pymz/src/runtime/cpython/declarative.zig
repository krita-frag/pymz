//! Declarative pyo3-style API for pymz.

const std = @import("std");
const ir = @import("../../ir.zig");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const types = @import("types.zig");
const module_mod = @import("module.zig");
const class_mod = @import("class.zig");
const stubs = @import("stubs.zig");

const Error = errors.Error;
const MethodDef = module_mod.MethodDef;
const MethodFlags = module_mod.MethodFlags;

pub const FnMode = ir.FnMode;
pub const ExportKind = ir.ExportKind;

fn sentinelName(comptime name: []const u8) [:0]const u8 {
    return (name ++ "\x00")[0..name.len :0];
}

fn isMetaDeclarationField(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__pymz_");
}

fn isMethodDefList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer_info| switch (@typeInfo(pointer_info.child)) {
            .array => |array_info| array_info.child == MethodDef,
            else => false,
        },
        else => false,
    };
}

fn isStubgenBuild() bool {
    const root = @import("root");
    if (@hasDecl(root, "pymz_stubgen")) {
        return root.pymz_stubgen;
    }
    return false;
}

// ============================================================================
// function
// ============================================================================

pub fn function(
    comptime func: anytype,
    comptime doc: ?[]const u8,
) type {
    return FunctionDescriptor(func, .positional, null, doc);
}

pub fn kwFunction(
    comptime func: anytype,
    comptime doc: ?[]const u8,
) type {
    return FunctionDescriptor(func, .kwargs, null, doc);
}

fn FunctionDescriptor(
    comptime Func: anytype,
    comptime mode_value: FnMode,
    comptime param_names_value: ?[]const u8,
    comptime doc_value: ?[]const u8,
) type {
    return struct {
        pub const export_kind: ExportKind = .function;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const func = Func;
        pub const mode = mode_value;
        pub const param_names = param_names_value;
        pub const doc = doc_value;

        pub const callback = if (mode == .kwargs) module_mod.pyfn_kw(func) else module_mod.pyfn_typed(func);

        pub fn methodDef() MethodDef {
            @compileError("FunctionDescriptor requires a fallback name; use methodDefWithName().");
        }

        pub fn methodDefWithName(comptime export_name: [:0]const u8) MethodDef {
            return methodDefWithNameAndParamNames(export_name, null);
        }

        pub fn methodDefWithNameAndParamNames(
            comptime export_name: [:0]const u8,
            comptime names: ?[]const u8,
        ) MethodDef {
            const effective_param_names = names orelse param_names;
            const ml_doc = if (mode == .kwargs)
                stubs.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .args_struct,
                    doc,
                    effective_param_names,
                )
            else
                stubs.buildMlDocWithOptions(
                    export_name,
                    @TypeOf(func),
                    .module_func,
                    .positional,
                    doc,
                    effective_param_names,
                );
            return .{
                .ml_name = export_name,
                .ml_meth = @ptrCast(&callback),
                .ml_flags = if (mode == .kwargs)
                    (MethodFlags.varargs.toC() | MethodFlags.keywords.toC())
                else
                    MethodFlags.varargs.toC(),
                .ml_doc = ml_doc,
            };
        }

        pub fn stub() stubs.Stub {
            @compileError("FunctionDescriptor requires a fallback name; use stubWithName().");
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubWithNameAndParamNames(export_name, null);
        }

        pub fn stubWithNameAndParamNames(
            comptime export_name: [:0]const u8,
            comptime names: ?[]const u8,
        ) stubs.Stub {
            const effective_param_names = names orelse param_names;
            return stubs.functionStubAuto(
                export_name,
                @TypeOf(func),
                if (mode == .kwargs) .args_struct else .positional,
                doc,
                effective_param_names,
            );
        }
    };
}

// ============================================================================
// class
// ============================================================================

pub fn class(
    comptime T: type,
    comptime doc: ?[:0]const u8,
) type {
    return ClassDescriptor(T, doc);
}

fn ClassDescriptor(
    comptime T: type,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const export_kind: ExportKind = .class;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const Impl = T;
        pub const doc = _doc;

        fn Runtime(comptime export_name: [:0]const u8) type {
            return class_mod.generateClass(export_name, Impl, doc);
        }

        pub fn ready() *c.PyTypeObject {
            @compileError("ClassDescriptor requires a fallback name; use readyWithName().");
        }

        pub fn readyWithName(comptime export_name: [:0]const u8) *c.PyTypeObject {
            return Runtime(export_name).ready();
        }

        pub fn classdef() class_mod.ClassDef {
            @compileError("ClassDescriptor requires a fallback name; use classdefWithName().");
        }

        pub fn classdefWithName(comptime export_name: [:0]const u8) class_mod.ClassDef {
            return Runtime(export_name).classdef();
        }

        pub fn stub() stubs.Stub {
            @compileError("ClassDescriptor requires a fallback name; use stubWithName().");
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubs.classStubAuto(export_name, Impl, doc);
        }
    };
}

// ============================================================================
// exception
// ============================================================================

pub fn exception(
    comptime base: errors.ExceptionBase,
    comptime doc: ?[:0]const u8,
) type {
    return ExceptionDescriptor(base, doc);
}

fn ExceptionDescriptor(
    comptime _base: errors.ExceptionBase,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const export_kind: ExportKind = .exception;
        pub const auto_name = true;
        pub const name: ?[:0]const u8 = null;
        pub const base = _base;
        pub const doc = _doc;

        pub var value: errors.Exception = undefined;

        pub fn register(mod: *types.Module) Error!void {
            _ = mod;
            @compileError("ExceptionDescriptor requires a fallback name; use registerWithName().");
        }

        pub fn registerWithName(mod: *types.Module, comptime export_name: [:0]const u8) Error!void {
            value = try errors.createException(mod, export_name, base, doc);
        }

        pub fn raise(msg: [:0]const u8) Error {
            return value.raise(msg);
        }

        pub fn raiseFormat(comptime fmt: []const u8, args: anytype) Error {
            return value.raiseFormat(fmt, args);
        }

        pub fn stub() stubs.Stub {
            @compileError("ExceptionDescriptor requires a fallback name; use stubWithName().");
        }

        pub fn stubWithName(comptime export_name: [:0]const u8) stubs.Stub {
            return stubs.exceptionStub(export_name, if (doc) |d| d else "");
        }
    };
}

// ============================================================================
// module
// ============================================================================

fn ModuleFromMethodTable(
    comptime _name: [:0]const u8,
    comptime _methods: []const MethodDef,
    comptime _init_fn: ?module_mod.ModuleInitFn,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const name = _name;
        pub const methods = _methods;
        pub const init_fn = _init_fn;
        pub const doc = _doc;

        comptime {
            _ = module_mod.moduleInit(name, @ptrCast(@constCast(methods.ptr)), init_fn, doc);
        }
    };
}

fn ModuleDescriptor(
    comptime _name: [:0]const u8,
    comptime _declarations: anytype,
    comptime _init_fn: ?module_mod.ModuleInitFn,
    comptime _doc: ?[:0]const u8,
) type {
    return struct {
        pub const name = _name;
        pub const declarations = _declarations;
        pub const init_fn = _init_fn;
        pub const doc = _doc;

        const method_count = countDeclarations(.function);
        const stub_count = countStubDeclarations();

        fn countDeclarations(comptime kind: ExportKind) usize {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime isMetaDeclarationField(field.name)) {
                    continue;
                }
                const Declaration = @field(declarations, field.name);
                if (Declaration.export_kind == kind) {
                    count += 1;
                }
            }
            return count;
        }

        fn countStubDeclarations() usize {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime isMetaDeclarationField(field.name)) {
                    continue;
                }
                count += 1;
            }
            return count;
        }

        fn parameterNamesFor(
            comptime export_name: []const u8,
            comptime Declaration: type,
        ) ?[]const u8 {
            if (@hasDecl(Declaration, "param_names")) {
                if (Declaration.param_names) |names| {
                    return names;
                }
            }
            if (@hasField(@TypeOf(declarations), "__pymz_param_names__")) {
                const names = declarations.__pymz_param_names__;
                if (@hasField(@TypeOf(names), export_name)) {
                    return @field(names, export_name);
                }
            }
            return null;
        }

        fn buildMethodTable() [method_count + 1]MethodDef {
            var methods: [method_count + 1]MethodDef = undefined;
            var index: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime isMetaDeclarationField(field.name)) {
                    continue;
                }
                const Declaration = @field(declarations, field.name);
                if (Declaration.export_kind == .function) {
                    const param_names = parameterNamesFor(field.name, Declaration);
                    methods[index] = Declaration.methodDefWithNameAndParamNames(
                        sentinelName(field.name),
                        param_names,
                    );
                    index += 1;
                }
            }
            methods[index] = module_mod.sentinel();
            return methods;
        }

        fn buildStubs() [stub_count]stubs.Stub {
            var result: [stub_count]stubs.Stub = undefined;
            var index: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime isMetaDeclarationField(field.name)) {
                    continue;
                }
                const Declaration = @field(declarations, field.name);
                switch (Declaration.export_kind) {
                    .function => {
                        const param_names = parameterNamesFor(field.name, Declaration);
                        result[index] = Declaration.stubWithNameAndParamNames(
                            sentinelName(field.name),
                            param_names,
                        );
                    },
                    .class, .exception => {
                        result[index] = Declaration.stubWithName(sentinelName(field.name));
                    },
                }
                index += 1;
            }
            return result;
        }

        const StubHolder = struct {
            pub const entries = buildStubs();
        };

        pub const stub_content = stubs.generate(name, StubHolder.entries[0..]);

        pub fn stubContent() []const u8 {
            return stub_content;
        }

        const Runtime = struct {
            pub var method_table = buildMethodTable();

            fn initModule(mod: *types.Module) errors.Error!void {
                inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                    if (comptime isMetaDeclarationField(field.name)) {
                        continue;
                    }
                    const Declaration = @field(declarations, field.name);
                    switch (Declaration.export_kind) {
                        .function => {},
                        .class => {
                            const class_def = Declaration.classdefWithName(sentinelName(field.name));
                            try mod.addClass(class_def.name, class_def);
                        },
                        .exception => try Declaration.registerWithName(mod, sentinelName(field.name)),
                    }
                }
                if (init_fn) |f| {
                    try f(mod);
                }
            }
        };

        comptime {
            if (!isStubgenBuild()) {
                _ = module_mod.moduleInit(
                    name,
                    @ptrCast(&Runtime.method_table),
                    Runtime.initModule,
                    doc,
                );
            }
        }
    };
}

pub fn module(
    comptime name: [:0]const u8,
    comptime declarations_or_methods: anytype,
    comptime init_fn: ?module_mod.ModuleInitFn,
    comptime doc: ?[:0]const u8,
) type {
    if (isMethodDefList(@TypeOf(declarations_or_methods))) {
        return ModuleFromMethodTable(name, declarations_or_methods, init_fn, doc);
    }
    return ModuleDescriptor(name, declarations_or_methods, init_fn, doc);
}
