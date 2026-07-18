//! Minimal .pyi stub generation inspired by PyOZ.
//!
//! Stubs are written at build time from a comptime-known list of `Stub` entries.
//! This gives IDEs and type checkers basic signatures for module-level functions
//! and constants without requiring runtime introspection.

const std = @import("std");

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

    pub const Kind = enum {
        function,
        constant,
    };
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
