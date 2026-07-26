//! Surface tests for the headless backend.
//!
//! These tests exercise the public `pymz.py` API through the headless backend
//! to verify that the core library does not implicitly depend on CPython.

const std = @import("std");
const pymz = @import("pymz");
const py = pymz.py.value;
const decl = pymz.py.decl;
const backend = pymz.py.backend;

test "headless integer roundtrip" {
    const n = try py.integer(42);
    try std.testing.expectEqual(@as(i64, 42), try backend.Int.as(n, i64));
}

test "headless float roundtrip" {
    const f = try py.floating(3.14);
    const value = try backend.Float.as(f, f64);
    try std.testing.expectApproxEqAbs(3.14, value, 0.001);
}

test "headless boolean roundtrip" {
    const t = py.boolean(true);
    try std.testing.expect(try backend.Bool.as(t));
}

test "headless string roundtrip" {
    const s = try py.string("hello");
    try std.testing.expectEqualStrings("hello", try backend.Str.asSlice(s));
}

test "headless list basics" {
    const list = try py.list(2);
    const a = try py.integer(1);
    const b = try py.integer(2);
    backend.List.setUnsafe(list, 0, a);
    backend.List.setUnsafe(list, 1, b);
    try std.testing.expectEqual(@as(usize, 2), backend.List.len(list));
    try std.testing.expectEqual(@as(i64, 1), try backend.Int.as(backend.List.getUnsafe(list, 0), i64));
    try std.testing.expectEqual(@as(i64, 2), try backend.Int.as(backend.List.getUnsafe(list, 1), i64));
}

test "headless dict basics" {
    const dict = try py.dict();
    const value = try py.integer(7);
    try backend.Dict.setItem(dict, "key", value);
    const retrieved = backend.Dict.getItem(dict, "key");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i64, 7), try backend.Int.as(retrieved.?, i64));
}

test "headless module declaration compiles" {
    const Mod = decl.module("headless_mod", .{}, null, null);
    _ = Mod.init();
}

test "headless class declaration compiles" {
    const Point = struct {
        x: i32,
        y: i32,
    };
    const PointClass = decl.class(Point, "A headless point.");
    _ = PointClass.classdef();
}
