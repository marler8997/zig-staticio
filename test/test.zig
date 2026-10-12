//! Without `io_vtable`, std.Io keeps its runtime vtable.

comptime {
    if (@FieldType(std.Io, "vtable") != *const std.Io.VTable) @compileError("expected the runtime Io");
}

test "runtime Io" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello staticio\n" });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello staticio\n", try tmp.dir.readFile(io, "hello.txt", &buf));
}

test "runtime Io allows several implementations" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "real" });
    try std.testing.expectError(error.NoSpaceLeft, tmp.dir.writeFile(std.Io.failing, .{ .sub_path = "failing.txt", .data = "x" }));
    _ = try tmp.dir.statFile(io, "real.txt", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "failing.txt", .{}));
}

const std = @import("std");
