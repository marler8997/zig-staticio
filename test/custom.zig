//! A custom Io only implements the operations the program can reach.
//! Built with optimize small, other modes also reach the panic handler's operations.

pub const std_options: std.Options = .{ .io_vtable = .{ .custom = RecordingIo } };

/// Records streaming writes instead of performing them. Must not panic, the
/// panic handler reaches more operations.
const RecordingIo = struct {
    var buffer: [64]u8 = undefined;
    var len: usize = 0;

    pub fn operate(_: ?*anyopaque, op: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        // the program only writes to stdout
        const w = switch (op) {
            .file_write_streaming => |w| w,
            else => unreachable,
        };
        return .{ .file_write_streaming = recordAll(w.header, w.data, w.splat) };
    }

    fn recordAll(header: []const u8, data: []const []const u8, splat: usize) error{NoSpaceLeft}!usize {
        var n = try record(header);
        for (data[0 .. data.len - 1]) |bytes| n += try record(bytes);
        for (0..splat) |_| n += try record(data[data.len - 1]);
        return n;
    }

    // stdout's writer is streaming, but positional writes are reachable at
    // compile time because the writer can switch modes at runtime
    pub fn fileWritePositional(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
        return error.Unseekable;
    }
    pub fn fileSeekTo(_: ?*anyopaque, _: std.Io.File, _: u64) std.Io.File.SeekError!void {
        return error.Unseekable;
    }
    pub fn fileWriteFileStreaming(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: *std.Io.File.Reader, _: std.Io.Limit) std.Io.File.Writer.WriteFileError!usize {
        return error.Unimplemented;
    }
    pub fn fileWriteFilePositional(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: *std.Io.File.Reader, _: std.Io.Limit, _: u64) std.Io.File.WriteFilePositionalError!usize {
        return error.Unimplemented;
    }

    fn record(bytes: []const u8) error{NoSpaceLeft}!usize {
        if (bytes.len > buffer.len - len) return error.NoSpaceLeft;
        @memcpy(buffer[len..][0..bytes.len], bytes);
        len += bytes.len;
        return bytes.len;
    }
};

pub fn main() void {
    const io: std.Io = .{ .userdata = null };
    var w = std.Io.File.stdout().writerStreaming(io, &.{});
    w.interface.writeAll("hello staticio\n") catch std.process.exit(2);
    const ok = std.mem.eql(u8, RecordingIo.buffer[0..RecordingIo.len], "hello staticio\n");
    std.process.exit(if (ok) 0 else 1);
}

const std = @import("std");
