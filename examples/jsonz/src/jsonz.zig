const std = @import("std");
const pymz = @import("pymz");
const py = pymz.py;
const v = py.value;
const d = py.decl;

// ============================================================================
// jsonz - 一个可独立运行的 Zig JSON 扩展示例。
//
// 提供比 Python 标准库更快的 JSON 解析与序列化，并展示 pymz 的常用 API。
// ============================================================================

const gpa = std.heap.c_allocator;

fn validateJsonLimitedImpl(text: []const u8) v.Result(bool) {
    if (text.len == 0) return false;
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) : (i += 1) {}
    if (i >= text.len) return false;
    const first = text[i];
    switch (first) {
        '{', '[', '"', '-', '0'...'9', 't', 'f', 'n' => {},
        else => return false,
    }
    // Bracket balance check (does not validate full grammar).
    var depth_brace: i32 = 0;
    var depth_bracket: i32 = 0;
    var in_string = false;
    var escape = false;
    for (text) |byte| {
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (byte == '\\') {
                escape = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '{') {
            depth_brace += 1;
        } else if (byte == '}') {
            depth_brace -= 1;
            if (depth_brace < 0) return false;
        } else if (byte == '[') {
            depth_bracket += 1;
        } else if (byte == ']') {
            depth_bracket -= 1;
            if (depth_bracket < 0) return false;
        }
    }
    return depth_brace == 0 and depth_bracket == 0 and !in_string;
}

fn validateJsonFullImpl(text: []const u8) v.Result(bool) {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        return false;
    };
    parsed.deinit();
    return true;
}

const validate_json_impl = if (pymz.platform.is_limited()) validateJsonLimitedImpl else validateJsonFullImpl;

const validate_json = d.positionalFunction(validate_json_impl, .{
    .doc = "Return True if text is valid JSON.",
    .param_names = &.{"text"},
});

const JsonError = d.exception(.value_error, "JSON processing error.");

fn jsonValueToPy(value: std.json.Value) v.Result(*v.Object) {
    return switch (value) {
        .null => v.none(),
        .bool => |b| v.boolean(b),
        .integer => |i| try v.integer(i),
        .float => |f| try v.floating(f),
        .number_string, .string => |s| try v.string(s),
        .array => |arr| blk: {
            const list = try v.list(arr.items.len);
            errdefer list.decref();
            for (arr.items, 0..) |item, i| {
                const py_item = try jsonValueToPy(item);
                try list.listSet(i, py_item);
            }
            break :blk list;
        },
        .object => |map| blk: {
            const dict = try v.dict();
            errdefer dict.decref();
            var it = map.iterator();
            while (it.next()) |entry| {
                const py_value = try jsonValueToPy(entry.value_ptr.*);
                defer py_value.decref();
                const key = try v.string(entry.key_ptr.*);
                defer key.decref();
                try dict.dictSet(key, py_value);
            }
            break :blk dict;
        },
    };
}

fn parseJsonImpl(text: []const u8) v.Result(*v.Object) {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        return JsonError.raise("invalid JSON");
    };
    defer parsed.deinit();
    return jsonValueToPy(parsed.value);
}

const parse_json = d.positionalFunction(parseJsonImpl, .{
    .doc = "Parse a JSON string into Python objects.",
    .param_names = &.{"text"},
    .limited = false,
});

const DumpArgs = struct {
    obj: *v.Object,
    indent: ?i64 = null,
};

fn dumpJsonImpl(args: v.Args(DumpArgs)) v.Result([]const u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendPyJson(gpa, &out, args.value.obj, args.value.indent, 0);
    return out.toOwnedSlice(gpa) catch return error.PyError;
}

const dump_json = d.kwFunction(dumpJsonImpl, .{
    .doc = "Serialize a Python object to a JSON string.",
    .limited = false,
});

fn appendPyJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    obj: *v.Object,
    indent: ?i64,
    depth: usize,
) v.Result(void) {
    if (obj.isNone()) {
        return appendSlice(allocator, out, "null");
    }
    if (obj.isBool()) {
        return appendSlice(allocator, out, if (try obj.asBool()) "true" else "false");
    }
    if (obj.isInt()) {
        const value = try obj.asInt(i64);
        const text = std.fmt.allocPrint(allocator, "{d}", .{value}) catch {
            return error.PyError;
        };
        defer allocator.free(text);
        return appendSlice(allocator, out, text);
    }
    if (obj.isFloat()) {
        const value = try obj.asFloat(f64);
        const text = std.fmt.allocPrint(allocator, "{d}", .{value}) catch {
            return error.PyError;
        };
        defer allocator.free(text);
        return appendSlice(allocator, out, text);
    }
    if (obj.isString()) {
        return appendJsonString(allocator, out, try obj.asString());
    }
    if (obj.isList() or obj.isTuple()) {
        return appendPySequenceJson(allocator, out, obj, indent, depth);
    }
    if (obj.isDict()) {
        return appendPyDictJson(allocator, out, obj, indent, depth);
    }
    return JsonError.raise("object is not JSON serializable");
}

fn appendPySequenceJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    obj: *v.Object,
    indent: ?i64,
    depth: usize,
) v.Result(void) {
    const len = try obj.sequenceLength();
    try appendSlice(allocator, out, "[");
    for (0..len) |index| {
        const item = obj.sequenceGet(index) orelse {
            return JsonError.raise("failed to access sequence element");
        };
        if (index > 0) {
            try appendSlice(allocator, out, ",");
        }
        try appendPrettySeparator(allocator, out, indent, depth + 1);
        try appendPyJson(allocator, out, item, indent, depth + 1);
    }
    if (len > 0) {
        try appendPrettySeparator(allocator, out, indent, depth);
    }
    try appendSlice(allocator, out, "]");
}

fn appendPyDictJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    obj: *v.Object,
    indent: ?i64,
    depth: usize,
) v.Result(void) {
    const items = try obj.dictItems();
    defer items.decref();

    const len = try items.sequenceLength();
    try appendSlice(allocator, out, "{");
    for (0..len) |index| {
        const pair = items.sequenceGet(index) orelse {
            return JsonError.raise("failed to access dict item");
        };
        const key_obj = pair.sequenceGet(0) orelse {
            return JsonError.raise("failed to access dict key");
        };
        const value_obj = pair.sequenceGet(1) orelse {
            return JsonError.raise("failed to access dict value");
        };
        if (!key_obj.isString()) {
            return JsonError.raise("JSON object keys must be strings");
        }
        if (index > 0) {
            try appendSlice(allocator, out, ",");
        }
        try appendPrettySeparator(allocator, out, indent, depth + 1);
        try appendJsonString(allocator, out, try key_obj.asString());
        try appendSlice(allocator, out, if (indent == null) ":" else ": ");
        try appendPyJson(allocator, out, value_obj, indent, depth + 1);
    }
    if (len > 0) {
        try appendPrettySeparator(allocator, out, indent, depth);
    }
    try appendSlice(allocator, out, "}");
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) v.Result(void) {
    try appendSlice(allocator, out, "\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try appendSlice(allocator, out, "\\\""),
            '\\' => try appendSlice(allocator, out, "\\\\"),
            '\n' => try appendSlice(allocator, out, "\\n"),
            '\r' => try appendSlice(allocator, out, "\\r"),
            '\t' => try appendSlice(allocator, out, "\\t"),
            '\x08' => try appendSlice(allocator, out, "\\b"),
            '\x0c' => try appendSlice(allocator, out, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const text = std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte}) catch {
                    return error.PyError;
                };
                defer allocator.free(text);
                try appendSlice(allocator, out, text);
            },
            else => out.append(allocator, byte) catch return error.PyError,
        }
    }
    try appendSlice(allocator, out, "\"");
}

fn appendPrettySeparator(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: ?i64,
    depth: usize,
) v.Result(void) {
    const spaces_count = if (indent) |value| @as(usize, @intCast(@max(value, 0))) else return;
    try appendSlice(allocator, out, "\n");
    for (0..(spaces_count * depth)) |_| {
        out.append(allocator, ' ') catch return error.PyError;
    }
}

fn appendSlice(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) v.Result(void) {
    out.appendSlice(allocator, value) catch return error.PyError;
}

fn echoBytesImpl(data: []u8) v.Result([]u8) {
    return gpa.dupe(u8, data) catch return error.PyError;
}

const echo_bytes = d.positionalFunction(echoBytesImpl, .{
    .doc = "Return the input bytes unchanged.",
    .param_names = &.{"data"},
    .limited = false,
});

const JsonPathImpl = struct {
    _segments: std.ArrayList([]const u8),
    segment_count: usize,

    pub const pymz_meta = d.classMeta(.{
        .readonly_fields = .{ .segment_count = true },
        .method_param_names = .{ .find = "root" },
    });

    pub fn __repr__(self: *const JsonPathImpl) []const u8 {
        _ = self;
        return "JsonPath";
    }

    pub fn __new__(pattern: []const u8) v.Result(JsonPathImpl) {
        var segments: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (segments.items) |s| gpa.free(s);
            segments.deinit(gpa);
        }
        var it = std.mem.splitScalar(u8, pattern, '.');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const copy = gpa.dupe(u8, seg) catch return error.OutOfMemory;
            segments.append(gpa, copy) catch return error.OutOfMemory;
        }
        return .{ ._segments = segments, .segment_count = segments.items.len };
    }

    pub fn __del__(self: *JsonPathImpl) void {
        for (self._segments.items) |s| gpa.free(s);
        self._segments.deinit(gpa);
    }

    pub fn find(self: *const JsonPathImpl, root: *v.Object) v.Result(*v.Object) {
        var current = root;
        for (self._segments.items) |seg| {
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

const JsonPath = d.class(JsonPathImpl, .{
    .doc = "A dot-separated JSON path query.",
    .limited = false,
});

const version_constant = d.constant("1.0.0");

pub const pymz_module = d.module("_jsonz", .{
    .__version__ = version_constant,
    .parse_json = parse_json,
    .dump_json = dump_json,
    .validate_json = validate_json,
    .echo_bytes = echo_bytes,
    .JsonError = JsonError,
    .JsonPath = JsonPath,
}, null, "Fast, Zig-backed JSON utilities for Python.");

comptime {
    _ = pymz_module;
}
