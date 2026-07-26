//! Python buffer protocol generation for Zig-backed classes.

const c = @import("../c.zig").c;
const object = @import("../object.zig");
const core = @import("core.zig");

pub fn BufferBuilder(comptime T: type) type {
    return struct {
        pub const has_buffer = @hasDecl(T, "__buffer__");
        pub const has_release_buffer = @hasDecl(T, "__release_buffer__");

        const BufferSlice = struct {
            ptr: [*c]u8,
            len: usize,
            readonly: bool,
        };

        fn bufferSliceFromResult(comptime RT: type, result: RT) BufferSlice {
            const info = @typeInfo(RT);
            const is_slice = info == .pointer and info.pointer.size == .slice;
            if (!is_slice) {
                @compileError("__buffer__ must return a []u8 or []const u8 slice, got " ++ @typeName(RT));
            }
            const is_const = info.pointer.is_const;
            const child = info.pointer.child;
            if (child != u8) {
                @compileError("__buffer__ must return a []u8 or []const u8 slice, got " ++ @typeName(RT));
            }
            const ptr: [*c]u8 = if (is_const)
                @ptrCast(@constCast(result.ptr))
            else
                @ptrCast(result.ptr);
            return .{ .ptr = ptr, .len = result.len, .readonly = is_const };
        }

        const BufferResult = union(enum) {
            slice: BufferSlice,
            buffer: object.Buffer,
        };

        fn bufferFromResult(comptime RT: type, result: RT) BufferResult {
            if (RT == object.Buffer) return .{ .buffer = result };
            return .{ .slice = bufferSliceFromResult(RT, result) };
        }

        fn callBuffer(data: *const T, flags: c_int) BufferResult {
            const F = @TypeOf(@field(T, "__buffer__"));
            const params = @typeInfo(F).@"fn".params;
            if (params.len == 1) {
                const result = @field(T, "__buffer__")(data);
                return bufferFromResult(@TypeOf(result), result);
            } else if (params.len == 2) {
                const result = @field(T, "__buffer__")(data, @as(u32, @intCast(flags)));
                return bufferFromResult(@TypeOf(result), result);
            } else {
                @compileError("__buffer__ must take either (self) or (self, flags: u32)");
            }
        }

        fn calcLen(shape: []const usize) usize {
            var len: usize = 1;
            for (shape) |dim| len *= dim;
            return len;
        }

        pub fn py_getbuffer(py_self: ?*c.PyObject, view: ?*c.Py_buffer, flags: c_int) callconv(.c) c_int {
            const py = py_self orelse return -1;
            const v = view orelse return -1;
            const data = core.unwrapConst(T, py);
            const result = callBuffer(data, flags);

            switch (result) {
                .slice => |slice| {
                    return c.PyBuffer_FillInfo(
                        v,
                        py,
                        slice.ptr,
                        @intCast(slice.len),
                        if (slice.readonly) 1 else 0,
                        flags,
                    );
                },
                .buffer => |buf| {
                    v.buf = buf.ptr;
                    v.len = @intCast(calcLen(buf.shape));
                    v.readonly = if (buf.readonly) 1 else 0;
                    v.itemsize = 1;
                    if (@hasField(c.Py_buffer, "format")) {
                        v.format = if (buf.format) |f| @ptrCast(@constCast(f.ptr)) else null;
                    }
                    if (@hasField(c.Py_buffer, "ndim")) {
                        v.ndim = @intCast(buf.shape.len);
                    }
                    if (@hasField(c.Py_buffer, "shape")) {
                        v.shape = @ptrCast(@constCast(buf.shape.ptr));
                    }
                    if (@hasField(c.Py_buffer, "strides")) {
                        v.strides = if (buf.strides) |s| @ptrCast(@constCast(s.ptr)) else null;
                    }
                    if (@hasField(c.Py_buffer, "suboffsets")) {
                        v.suboffsets = null;
                    }
                    if (@hasField(c.Py_buffer, "internal")) {
                        v.internal = null;
                    }
                    if (@hasField(c.Py_buffer, "obj")) {
                        v.obj = py;
                        c.Py_INCREF(py);
                    }
                    return 0;
                },
            }
        }

        pub fn py_releasebuffer(py_self: ?*c.PyObject, view: ?*c.Py_buffer) callconv(.c) void {
            _ = view;
            if (comptime has_release_buffer) {
                const py = py_self orelse return;
                const data = core.unwrapConst(T, py);
                @field(T, "__release_buffer__")(data);
            }
        }
    };
}
