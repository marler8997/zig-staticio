pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/patch.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(b.addExecutable(.{ .name = "patch", .root_module = module }));

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

const std = @import("std");
