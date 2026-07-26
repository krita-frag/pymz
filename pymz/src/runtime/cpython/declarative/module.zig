//! Module export descriptors.

const std = @import("std");
const common = @import("common.zig");
const module_mod = @import("../module.zig");
const types = @import("../types.zig");
const stubs = @import("../stubs.zig");

const Error = @import("../errors.zig").Error;
const MethodDef = common.MethodDef;

pub fn module(
    comptime name: [:0]const u8,
    comptime declarations_or_methods: anytype,
    comptime init_fn: ?module_mod.ModuleInitFn,
    comptime doc: ?[:0]const u8,
) type {
    if (common.isMethodDefList(@TypeOf(declarations_or_methods))) {
        return ModuleFromMethodTable(name, declarations_or_methods, init_fn, doc);
    }
    return ModuleDescriptor(name, declarations_or_methods, init_fn, doc);
}

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

        fn countDeclarations(comptime kind: common.ExportKind) usize {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime common.isMetaDeclarationField(field.name)) continue;
                const Declaration = @field(declarations, field.name);
                if (Declaration.export_kind == kind) count += 1;
            }
            return count;
        }

        fn countStubDeclarations() usize {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                if (comptime common.isMetaDeclarationField(field.name)) continue;
                count += 1;
            }
            return count;
        }

        fn parameterNamesFor(
            comptime export_name: []const u8,
            comptime Declaration: type,
        ) ?[]const u8 {
            if (@hasDecl(Declaration, "param_names")) {
                if (Declaration.param_names) |names| return names;
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
                if (comptime common.isMetaDeclarationField(field.name)) continue;
                const Declaration = @field(declarations, field.name);
                if (Declaration.export_kind == .function) {
                    const param_names = parameterNamesFor(field.name, Declaration);
                    methods[index] = Declaration.methodDefWithNameAndParamNames(
                        common.sentinelName(field.name),
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
                if (comptime common.isMetaDeclarationField(field.name)) continue;
                const Declaration = @field(declarations, field.name);
                switch (Declaration.export_kind) {
                    .function => {
                        const param_names = parameterNamesFor(field.name, Declaration);
                        result[index] = Declaration.stubWithNameAndParamNames(
                            common.sentinelName(field.name),
                            param_names,
                        );
                    },
                    .class => {
                        result[index] = Declaration.stubWithName(common.sentinelName(field.name));
                    },
                    .exception => {
                        result[index] = Declaration.stubWithName(common.sentinelName(field.name));
                    },
                    .constant => {
                        result[index] = Declaration.stubWithName(common.sentinelName(field.name));
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

            fn initModule(mod: *types.Module) Error!void {
                inline for (std.meta.fields(@TypeOf(declarations))) |field| {
                    if (comptime common.isMetaDeclarationField(field.name)) continue;
                    const Declaration = @field(declarations, field.name);
                    switch (Declaration.export_kind) {
                        .function => {},
                        .class => {
                            const class_def = Declaration.classdefWithName(common.sentinelName(field.name));
                            try mod.addClass(class_def.name, class_def);
                        },
                        .exception => try Declaration.registerWithName(mod, common.sentinelName(field.name)),
                        .constant => try Declaration.registerWithName(mod, common.sentinelName(field.name)),
                    }
                }
                if (init_fn) |f| {
                    try f(mod);
                }
            }
        };

        comptime {
            if (!stubs.isStubgenBuild()) {
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
