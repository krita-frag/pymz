//! Python declaration helpers.
//!
//! This namespace keeps module/class/function descriptors separate from value
//! construction helpers so the public surface stays small and legible.

const interface = @import("../interface.zig");
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

pub fn class(
    comptime T: type,
    comptime doc: ?[:0]const u8,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.class_model) {
            @compileError("selected backend does not support class declarations");
        }
    }
    return backend.class(T, doc);
}

pub fn classWithBase(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime base: *const backend.ClassDef,
    comptime doc: ?[:0]const u8,
) type {
    comptime {
        if (!interface.backendSpec().capabilities.class_model) {
            @compileError("selected backend does not support class declarations");
        }
    }
    return backend.classWithBase(name, T, base, doc);
}

pub fn exception(
    comptime base: backend.ExceptionBase,
    comptime doc: ?[:0]const u8,
) type {
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
    return backend.module(name, declarations_or_methods, init_fn, doc);
}
