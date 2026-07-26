//! Runtime configuration file consumed by the Python-side loader.
//!
//! ``pymz-config.json`` sits next to the Python package and lists every
//! compiled extension variant. The loader picks the variant whose
//! runtime/ABI/platform tags best match the current interpreter.

const std = @import("std");

pub const Variant = struct {
    runtime: []const u8,
    python_version: ?[]const u8,
    abi_tag: []const u8,
    platform_tag: []const u8,
    filename: []const u8,
    backend_source: ?[]const u8 = null,
};

pub const Config = struct {
    version: []const u8,
    module: []const u8,
    distribution: ?[]const u8,
    /// ISO-8601 UTC timestamp when the configuration was generated.
    build_time: ?[]const u8 = null,
    /// Version of the tool that generated this file.
    tool_version: ?[]const u8 = null,
    /// Version of the backend/runtime the artifacts target (e.g. "3.12" or "headless").
    backend_version: ?[]const u8 = null,
    /// Build host triple (e.g. "aarch64-macos-none").
    build_host: ?[]const u8 = null,
    variants: []const Variant,
};

fn writeJsonString(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    try file.writeStreamingAll(io, "\"");
    for (bytes) |byte| {
        switch (byte) {
            '"' => try file.writeStreamingAll(io, "\\\""),
            '\\' => try file.writeStreamingAll(io, "\\\\"),
            '\n' => try file.writeStreamingAll(io, "\\n"),
            '\r' => try file.writeStreamingAll(io, "\\r"),
            '\t' => try file.writeStreamingAll(io, "\\t"),
            else => if (byte < 0x20) {
                const hex = "0123456789abcdef";
                var escape: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
                escape[4] = hex[byte >> 4];
                escape[5] = hex[byte & 0x0f];
                try file.writeStreamingAll(io, &escape);
            } else {
                var one: [1]u8 = .{byte};
                try file.writeStreamingAll(io, &one);
            },
        }
    }
    try file.writeStreamingAll(io, "\"");
}

fn writeOptionalString(file: std.Io.File, io: std.Io, value: ?[]const u8) !void {
    if (value) |v| {
        try writeJsonString(file, io, v);
    } else {
        try file.writeStreamingAll(io, "null");
    }
}

fn writeVariant(file: std.Io.File, io: std.Io, variant: Variant) !void {
    try file.writeStreamingAll(io, "  {\n");
    try file.writeStreamingAll(io, "    \"runtime\": ");
    try writeJsonString(file, io, variant.runtime);
    try file.writeStreamingAll(io, ",\n    \"python_version\": ");
    try writeOptionalString(file, io, variant.python_version);
    try file.writeStreamingAll(io, ",\n    \"abi_tag\": ");
    try writeJsonString(file, io, variant.abi_tag);
    try file.writeStreamingAll(io, ",\n    \"platform_tag\": ");
    try writeJsonString(file, io, variant.platform_tag);
    try file.writeStreamingAll(io, ",\n    \"filename\": ");
    try writeJsonString(file, io, variant.filename);
    try file.writeStreamingAll(io, ",\n    \"backend_source\": ");
    try writeOptionalString(file, io, variant.backend_source);
    try file.writeStreamingAll(io, "\n  }");
}

pub fn writeFile(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    config: Config,
) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, "{\n");
    try file.writeStreamingAll(io, "  \"version\": ");
    try writeJsonString(file, io, config.version);
    try file.writeStreamingAll(io, ",\n  \"module\": ");
    try writeJsonString(file, io, config.module);
    try file.writeStreamingAll(io, ",\n  \"distribution\": ");
    try writeOptionalString(file, io, config.distribution);
    try file.writeStreamingAll(io, ",\n  \"build_time\": ");
    try writeOptionalString(file, io, config.build_time);
    try file.writeStreamingAll(io, ",\n  \"tool_version\": ");
    try writeOptionalString(file, io, config.tool_version);
    try file.writeStreamingAll(io, ",\n  \"backend_version\": ");
    try writeOptionalString(file, io, config.backend_version);
    try file.writeStreamingAll(io, ",\n  \"build_host\": ");
    try writeOptionalString(file, io, config.build_host);
    try file.writeStreamingAll(io, ",\n  \"variants\": [\n");
    for (config.variants, 0..) |variant, index| {
        if (index != 0) {
            try file.writeStreamingAll(io, ",\n");
        }
        try writeVariant(file, io, variant);
    }
    try file.writeStreamingAll(io, "\n  ]\n}\n");
}
