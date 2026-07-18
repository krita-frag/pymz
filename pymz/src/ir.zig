//! Runtime-neutral compile-time declarations.

pub const ExportKind = enum {
    function,
    class,
    exception,
};

pub const FnMode = enum {
    positional,
    kwargs,
};
