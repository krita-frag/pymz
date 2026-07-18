const std = @import("std");

pub const ZipEntry = struct {
    filename: []const u8,
    crc32: u32,
    size: u32,
    offset: u64,
};

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn writeIntLE(file: std.Io.File, io: std.Io, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try file.writeStreamingAll(io, &bytes);
}

pub fn writeZipEntry(
    file: std.Io.File,
    io: std.Io,
    filename: []const u8,
    data: []const u8,
    offset: *u64,
    entries: *std.ArrayList(ZipEntry),
    allocator: std.mem.Allocator,
) !void {
    const header_size = @as(u64, 30) + filename.len;
    const entry_offset = offset.*;
    const checksum = crc32(data);

    try file.writeStreamingAll(io, "PK\x03\x04");
    try writeIntLE(file, io, u16, 20);
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u32, checksum);
    try writeIntLE(file, io, u32, @intCast(data.len));
    try writeIntLE(file, io, u32, @intCast(data.len));
    try writeIntLE(file, io, u16, @intCast(filename.len));
    try writeIntLE(file, io, u16, 0);
    try file.writeStreamingAll(io, filename);
    try file.writeStreamingAll(io, data);

    try entries.append(allocator, .{
        .filename = try allocator.dupe(u8, filename),
        .crc32 = checksum,
        .size = @intCast(data.len),
        .offset = entry_offset,
    });
    offset.* += header_size + @as(u64, data.len);
}

pub fn writeZipFooter(
    file: std.Io.File,
    io: std.Io,
    entries: []const ZipEntry,
    offset: u64,
) !void {
    const cd_offset = offset;
    var cd_size: u64 = 0;

    for (entries) |entry| {
        const filename_len = entry.filename.len;
        try file.writeStreamingAll(io, "PK\x01\x02");
        try writeIntLE(file, io, u16, 20);
        try writeIntLE(file, io, u16, 20);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u32, entry.crc32);
        try writeIntLE(file, io, u32, entry.size);
        try writeIntLE(file, io, u32, entry.size);
        try writeIntLE(file, io, u16, @intCast(filename_len));
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u16, 0);
        try writeIntLE(file, io, u32, 0);
        try writeIntLE(file, io, u32, @intCast(entry.offset));
        try file.writeStreamingAll(io, entry.filename);
        cd_size += 46 + filename_len;
    }

    try file.writeStreamingAll(io, "PK\x05\x06");
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u16, 0);
    try writeIntLE(file, io, u16, @intCast(entries.len));
    try writeIntLE(file, io, u16, @intCast(entries.len));
    try writeIntLE(file, io, u32, @intCast(cd_size));
    try writeIntLE(file, io, u32, @intCast(cd_offset));
    try writeIntLE(file, io, u16, 0);
}
