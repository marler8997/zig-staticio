pub fn build(b: *std.Build) void {
    const patch_path = "src/std-" ++ zig_version ++ ".patch";

    // the patch for the zig doing the build, apply it with zig-patch
    b.addNamedLazyPath("std.patch", b.path(patch_path));

    // regenerates the patch for this zig, see tools/gen.zig
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

/// The zig lib's std directory, `b.graph.path(.zig_lib, "std")` from zig 0.17.
fn zigStdDir(b: *std.Build) std.Build.LazyPath {
    if (zig_16) return .{ .cwd_relative = b.graph.zig_lib_directory.join(b.allocator, &.{"std"}) catch @panic("OOM") };
    return b.graph.path(.zig_lib, "std");
}

const std = @import("std");
const zig_version = @import("builtin").zig_version_string;
const zig_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) == .lt;
