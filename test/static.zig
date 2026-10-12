//! With `io_vtable`, std.Io's vtable is comptime.

pub const std_options: std.Options = .{ .io_vtable = .threaded };

comptime {
    if (@FieldType(std.Io, "vtable") != type) @compileError("expected the static Io");
}

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "staticio-test.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "hello staticio\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buf: [64]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, path, &buf);
    if (!std.mem.eql(u8, content, "hello staticio\n")) {
        std.log.err("read back '{s}'", .{content});
        std.process.exit(1);
    }
}

const std = @import("std");
