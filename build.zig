//! staticio: opt-in static std.Io dispatch, see README.md.

/// Returns std with `patches` applied, `staticio` is this package's dependency.
pub fn addPatchedStd(staticio: *std.Build.Dependency, patches: []const std.Build.LazyPath) *std.Build.Module {
    const b = staticio.builder;
    return b.createModule(.{ .root_source_file = patchStd(b, patches).path(b, "std.zig") });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const patch_path = "src/std-" ++ zig_version ++ ".patch";

    // std with only this patch applied, import it as "std"
    const patched_std = b.addModule("std", .{
        .root_source_file = patchStd(b, &.{b.path(patch_path)}).path(b, "std.zig"),
    });

    // regenerates the patch for this zig, see tools/gen.zig
    {
        const gen = b.addRunArtifact(b.addExecutable(.{
            .name = "staticio-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen.zig"),
                .target = b.graph.host,
            }),
        }));
        gen.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
        const generated = gen.addOutputFileArg2("std.patch", .{});
        _ = gen.addDepFileOutputArg2("deps.d", .{});
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(generated, patch_path);
        b.step("update-patch", "Regenerate the std patch for this zig version").dependOn(&update.step);
    }

    const test_step = b.step("test", "Run the tests");
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "std", .module = patched_std }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(t).step);
    for ([_]struct { []const u8, std.lang.Optimize }{
        .{ "static", optimize },
        // other modes also reach the panic handler's operations
        .{ "custom", .small },
    }) |exe| {
        test_step.dependOn(&b.addRunArtifact(b.addExecutable(.{
            .name = exe[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}.zig", .{exe[0]})),
                .target = target,
                .optimize = exe[1],
                .imports = &.{.{ .name = "std", .module = patched_std }},
            }),
        })).step);
    }
    // other patches stack on this one
    const stacked_std = b.createModule(.{
        .root_source_file = patchStd(b, &.{ b.path(patch_path), b.path("test/stack.patch") }).path(b, "std.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(b.addExecutable(.{
        .name = "stack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stack.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "std", .module = stacked_std }},
        }),
    })).step);
    const subsub = b.createModule(.{ .root_source_file = b.path("test/subsub.zig") });
    const sub = b.createModule(.{
        .root_source_file = b.path("test/sub.zig"),
        .imports = &.{.{ .name = "subsub", .module = subsub }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addExecutable(.{
        .name = "submodules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/submodules.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "std", .module = patched_std },
                .{ .name = "sub", .module = sub },
            },
        }),
    })).step);
}

/// Returns a copy of std with `patches` applied.
fn patchStd(b: *std.Build, patches: []const std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(b.dependency("patch", .{ .target = b.graph.host }).artifact("patch"));
    run.setName("patch std");
    run.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
    const dir = run.addOutputDirectoryArg2("std", .{});
    _ = run.addDepFileOutputArg2("deps.d", .{});
    for (patches) |patch| run.addFileArg(patch);
    return dir;
}

const std = @import("std");
const zig_version = @import("builtin").zig_version_string;
