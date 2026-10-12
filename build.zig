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
        gen.addDirectoryArg(zigStdDir(b));
        const generated = gen.addOutputFileArg("std.patch");
        _ = gen.addDepFileOutputArg("deps.d");
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
    for ([_]struct { []const u8, Optimize }{
        .{ "static", optimize },
        // other modes also reach the panic handler's operations
        .{ "custom", optimize_small },
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
    run.addDirectoryArg(zigStdDir(b));
    const dir = run.addOutputDirectoryArg("std");
    _ = run.addDepFileOutputArg("deps.d");
    for (patches) |patch| run.addFileArg(patch);
    return dir;
}

/// The zig lib's std directory, `b.graph.path(.zig_lib, "std")` from zig 0.17.
fn zigStdDir(b: *std.Build) std.Build.LazyPath {
    if (zig_16) return .{ .cwd_relative = b.graph.zig_lib_directory.join(b.allocator, &.{"std"}) catch @panic("OOM") };
    return b.graph.path(.zig_lib, "std");
}

const std = @import("std");
const zig_version = @import("builtin").zig_version_string;
const zig_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) == .lt;
// std.builtin.OptimizeMode became std.lang.Optimize in zig 0.17
const Optimize = if (zig_16) std.builtin.OptimizeMode else std.lang.Optimize;
const optimize_small: Optimize = if (zig_16) .ReleaseSmall else .small;
