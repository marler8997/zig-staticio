//! Tests staticio as a package applying its patch with zig-patch would.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run the tests");

    const staticio_patch = b.dependency("staticio", .{}).namedLazyPath("std.patch");
    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{staticio_patch},
    }).module("std");

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    })).step);
    for ([_]struct { []const u8, Optimize, *std.Build.Module }{
        .{ "static", optimize, patched_std },
        // other modes also reach the panic handler's operations
        .{ "custom", optimize_small, patched_std },
        // other patches stack on staticio's
        .{ "stack", optimize, b.dependency("patch", .{
            .std_patches = &[_]std.Build.LazyPath{ staticio_patch, b.path("stack.patch") },
        }).module("std") },
    }) |exe| {
        test_step.dependOn(&b.addRunArtifact(b.addExecutable(.{
            .name = exe[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}.zig", .{exe[0]})),
                .target = target,
                .optimize = exe[1],
                .imports = &.{.{ .name = "std", .module = exe[2] }},
            }),
        })).step);
    }
}

const std = @import("std");
const zig_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) == .lt;
// std.builtin.OptimizeMode became std.lang.Optimize in zig 0.17
const Optimize = if (zig_16) std.builtin.OptimizeMode else std.lang.Optimize;
const optimize_small: Optimize = if (zig_16) .ReleaseSmall else .small;
