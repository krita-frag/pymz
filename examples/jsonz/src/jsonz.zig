const std = @import("std");
const pymz = @import("pymz");

// ============================================================================
// jsonz — a practical Zig-backed JSON extension for Python.
//
// Demonstrates every major pymz feature in a single usable module:
//   * typed positional functions
//   * keyword-argument functions
//   * custom exceptions
//   * complex type conversion (list / dict / primitive <-> Zig JSON values)
//   * Zig struct exposed as a Python class with public fields and methods
//   * Python 2 / 3 comptime compatibility
// ============================================================================

const JsonError = pymz.exception(.value_error, "JSON processing error.");

// ----------------------------------------------------------------------------
// Zig <-> Python JSON value conversion helpers
// ----------------------------------------------------------------------------

/// Recursively convert a parsed `std.json.Value` into a Python object.
fn jsonValueToPy(value: std.json.Value) pymz.Result(*pymz.Value) {
    const obj: *pymz.Value = switch (value) {
        .null => @ptrCast(pymz.none()),
        .bool => |b| @ptrCast(pymz.boolean(b)),
        .integer => |i| try pymz.integer(i),
        .float => |f| try pymz.floating(f),
        .number_string => |s| try pymz.string(s),
        .string => |s| try pymz.string(s),
        .array => |arr| blk: {
            const list = try pymz.list(arr.items.len);
            errdefer list.decref();
            for (arr.items, 0..) |item, i| {
                const py_item = try jsonValueToPy(item);
                try list.listSet(i, py_item);
            }
            break :blk list;
        },
        .object => |map| blk: {
            const dict = try pymz.dict();
            errdefer dict.decref();
            var it = map.iterator();
            while (it.next()) |entry| {
                const py_value = try jsonValueToPy(entry.value_ptr.*);
                defer py_value.decref();
                const key = try pymz.string(entry.key_ptr.*);
                defer key.decref();
                try dict.dictSet(key, py_value);
            }
            break :blk dict;
        },
    };
    return obj;
}

/// Recursively free a `std.json.Value` tree that we built from Python objects.
fn freeJsonValue(value: *std.json.Value, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| freeJsonValue(item, allocator);
            arr.deinit();
        },
        .object => |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(entry.value_ptr, allocator);
            }
            map.deinit();
        },
        else => {},
    }
}

/// Recursively convert a Python object into a `std.json.Value` tree.
fn pyToJson(obj: *pymz.Value) pymz.Result(std.json.Value) {
    if (obj.isNone()) return .null;
    if (obj.isBool()) {
        return .{ .bool = obj.asBool() };
    }
    if (obj.isInt()) {
        return .{ .integer = try obj.asInt(i64) };
    }
    if (obj.isFloat()) {
        return .{ .float = try obj.asFloat(f64) };
    }
    if (obj.isString()) {
        const slice = obj.asString();
        const copy = std.heap.c_allocator.dupe(u8, slice) catch return error.PyError;
        return .{ .string = copy };
    }
    if (obj.isList() or obj.isTuple()) {
        var arr = std.json.Array.init(std.heap.c_allocator);
        errdefer {
            for (arr.items) |*item| freeJsonValue(item, std.heap.c_allocator);
            arr.deinit();
        }
        const len = try obj.sequenceLength();
        for (0..len) |i| {
            const item_obj = obj.sequenceGet(i).?;
            const json_item = try pyToJson(item_obj);
            arr.append(json_item) catch return error.PyError;
        }
        return .{ .array = arr };
    }
    if (obj.isDict()) {
        var map = std.json.ObjectMap.init(std.heap.c_allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                std.heap.c_allocator.free(entry.key_ptr.*);
                freeJsonValue(entry.value_ptr, std.heap.c_allocator);
            }
            map.deinit();
        }
        const items = try obj.dictItems();
        defer items.decref();
        const len = try items.sequenceLength();
        for (0..len) |i| {
            const pair = items.sequenceGet(i).?;
            const key_obj = pair.sequenceGet(0).?;
            const val_obj = pair.sequenceGet(1).?;
            const key_str = key_obj.asString();
            const key_copy = std.heap.c_allocator.dupe(u8, key_str) catch return error.PyError;
            errdefer std.heap.c_allocator.free(key_copy);
            const json_val = try pyToJson(val_obj);
            errdefer {
                var mutable = json_val;
                freeJsonValue(&mutable, std.heap.c_allocator);
            }
            map.put(key_copy, json_val) catch return error.PyError;
        }
        return .{ .object = map };
    }
    return JsonError.raise("object is not JSON serializable");
}

// ----------------------------------------------------------------------------
// Module functions
// ----------------------------------------------------------------------------

fn parseJsonImpl(text: []const u8) pymz.Result(*pymz.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, text, .{}) catch {
        return JsonError.raise("invalid JSON");
    };
    defer parsed.deinit();
    return jsonValueToPy(parsed.value);
}

const parse_json = pymz.function(parseJsonImpl, "Parse a JSON string into Python objects.");

const DumpArgs = struct {
    obj: *pymz.Value,
    indent: ?i64 = null,
};

fn dumpJsonImpl(args: pymz.Args(DumpArgs)) pymz.Result([]const u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.heap.c_allocator);
    try appendPyJson(&out, args.value.obj, args.value.indent, 0);
    return out.toOwnedSlice(std.heap.c_allocator) catch return error.PyError;
}

const dump_json = pymz.kwFunction(dumpJsonImpl, "Serialize a Python object to a JSON string.");

fn appendPyJson(
    out: *std.ArrayList(u8),
    obj: *pymz.Value,
    indent: ?i64,
    depth: usize,
) pymz.Result(void) {
    if (obj.isNone()) {
        return appendSlice(out, "null");
    }
    if (obj.isBool()) {
        return appendSlice(out, if (obj.asBool()) "true" else "false");
    }
    if (obj.isInt()) {
        const value = try obj.asInt(i64);
        const text = std.fmt.allocPrint(std.heap.c_allocator, "{d}", .{value}) catch {
            return error.PyError;
        };
        defer std.heap.c_allocator.free(text);
        return appendSlice(out, text);
    }
    if (obj.isFloat()) {
        const value = try obj.asFloat(f64);
        const text = std.fmt.allocPrint(std.heap.c_allocator, "{d}", .{value}) catch {
            return error.PyError;
        };
        defer std.heap.c_allocator.free(text);
        return appendSlice(out, text);
    }

    if (obj.isString()) {
        return appendJsonString(out, obj.asString());
    }
    if (obj.isList() or obj.isTuple()) {
        return appendPySequenceJson(out, obj, indent, depth);
    }
    if (obj.isDict()) {
        return appendPyDictJson(out, obj, indent, depth);
    }
    return JsonError.raise("object is not JSON serializable");
}

fn appendPySequenceJson(
    out: *std.ArrayList(u8),
    obj: *pymz.Value,
    indent: ?i64,
    depth: usize,
) pymz.Result(void) {
    const len = try obj.sequenceLength();
    try appendSlice(out, "[");
    for (0..len) |index| {
        const item = obj.sequenceGet(index).?;
        if (index > 0) {
            try appendSlice(out, ",");
        }
        try appendPrettySeparator(out, indent, depth + 1);
        try appendPyJson(out, item, indent, depth + 1);
    }
    if (len > 0) {
        try appendPrettySeparator(out, indent, depth);
    }
    try appendSlice(out, "]");
}

fn appendPyDictJson(
    out: *std.ArrayList(u8),
    obj: *pymz.Value,
    indent: ?i64,
    depth: usize,
) pymz.Result(void) {
    const items = try obj.dictItems();
    defer items.decref();

    const len = try items.sequenceLength();
    try appendSlice(out, "{");
    for (0..len) |index| {
        const pair = items.sequenceGet(index).?;
        const key_obj = pair.sequenceGet(0).?;
        const value_obj = pair.sequenceGet(1).?;
        if (!key_obj.isString()) {
            return JsonError.raise("JSON object keys must be strings");
        }
        if (index > 0) {
            try appendSlice(out, ",");
        }
        try appendPrettySeparator(out, indent, depth + 1);
        try appendJsonString(out, key_obj.asString());
        try appendSlice(out, if (indent == null) ":" else ": ");
        try appendPyJson(out, value_obj, indent, depth + 1);
    }
    if (len > 0) {
        try appendPrettySeparator(out, indent, depth);
    }
    try appendSlice(out, "}");
}

fn appendJsonString(out: *std.ArrayList(u8), value: []const u8) pymz.Result(void) {
    try appendSlice(out, "\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try appendSlice(out, "\\\""),
            '\\' => try appendSlice(out, "\\\\"),
            '\n' => try appendSlice(out, "\\n"),
            '\r' => try appendSlice(out, "\\r"),
            '\t' => try appendSlice(out, "\\t"),
            else => out.append(std.heap.c_allocator, byte) catch return error.PyError,
        }
    }
    try appendSlice(out, "\"");
}

fn appendPrettySeparator(
    out: *std.ArrayList(u8),
    indent: ?i64,
    depth: usize,
) pymz.Result(void) {
    const spaces_count = if (indent) |value| @as(usize, @intCast(@max(value, 0))) else return;
    try appendSlice(out, "\n");
    for (0..(spaces_count * depth)) |_| {
        out.append(std.heap.c_allocator, ' ') catch return error.PyError;
    }
}

fn appendSlice(out: *std.ArrayList(u8), value: []const u8) pymz.Result(void) {
    out.appendSlice(std.heap.c_allocator, value) catch return error.PyError;
}

fn validateJsonImpl(text: []const u8) pymz.Result(bool) {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, text, .{}) catch {
        return false;
    };
    parsed.deinit();
    return true;
}

const validate_json = pymz.function(validateJsonImpl, "Return True if text is valid JSON.");

// ----------------------------------------------------------------------------
// JsonPath — a tiny Python class wrapping a parsed dot-path query.
// ----------------------------------------------------------------------------

pub const JsonPathImpl = struct {
    segments: std.ArrayList([]const u8),
    pub const __pymz_constructor_param_names__ = "pattern";
    pub const __pymz_method_param_names__ = .{
        .find = "root",
    };
    pub const __repr__ = pymz.Repr(repr);

    fn repr(_: *const JsonPathImpl) []const u8 {
        return "JsonPath";
    }

    pub fn __new__(pattern: []const u8) JsonPathImpl {
        var segments: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (segments.items) |s| std.heap.c_allocator.free(s);
            segments.deinit(std.heap.c_allocator);
        }
        var it = std.mem.splitScalar(u8, pattern, '.');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const copy = std.heap.c_allocator.dupe(u8, seg) catch @panic("out of memory");
            segments.append(std.heap.c_allocator, copy) catch @panic("out of memory");
        }
        return .{ .segments = segments };
    }

    pub fn find(self: *const JsonPathImpl, root: *pymz.Value) pymz.Result(*pymz.Value) {
        var current = root;
        for (self.segments.items) |seg| {
            if (current.isList()) {
                const idx = std.fmt.parseInt(usize, seg, 10) catch {
                    return JsonError.raise("path segment is not a valid list index");
                };
                const item = current.sequenceGet(idx) orelse {
                    return JsonError.raise("list index out of range");
                };
                current = item;
            } else if (current.isDict()) {
                const item = try current.dictGetString(seg);
                current = item orelse return JsonError.raise("key not found in path");
            } else {
                return JsonError.raise("path traverses a non-indexable value");
            }
        }
        return current.newref();
    }
};

const json_path_doc = "A dot-separated JSON path query.";

const JsonPath = pymz.class(JsonPathImpl, json_path_doc);

pub const pymz_module = pymz.module("jsonz", .{
    .__pymz_param_names__ = .{
        .parse_json = "text",
        .validate_json = "text",
    },
    .parse_json = parse_json,
    .dump_json = dump_json,
    .validate_json = validate_json,
    .JsonError = JsonError,
    .JsonPath = JsonPath,
}, null, "Fast, Zig-backed JSON utilities for Python.");

comptime {
    _ = pymz_module;
}
