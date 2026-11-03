pub fn build(b: *std.Build) void {
    const patch_path = "src/std-" ++ patch_version ++ ".patch";

    // the patch for the zig doing the build, apply it with zig-patch
    b.addNamedLazyPath("std.patch", b.path(patch_path));

    const update_patch = b.step("update-patch", "Regenerate the std patch for this zig version");
    if (!std.mem.eql(u8, patch_version, zig_version)) {
        // the generated patch has this zig's version and line numbers
        update_patch.dependOn(&b.addFail("zig " ++ zig_version ++ " shares the patch of zig " ++ patch_version ++ ", run update-patch with that version").step);
        return;
    }

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
    update_patch.dependOn(&update.step);
}

/// The zig lib's std directory, `b.graph.path(.zig_lib, "std")` from zig 0.17.
fn zigStdDir(b: *std.Build) std.Build.LazyPath {
    if (zig_16) return .{ .cwd_relative = b.graph.zig_lib_directory.join(b.allocator, &.{"std"}) catch @panic("OOM") };
    return b.graph.path(.zig_lib, "std");
}

const std = @import("std");
const zig_version = @import("builtin").zig_version_string;
/// The version whose patch this zig uses. zig-patch ignores line numbers, so a
/// patch can be shared by versions where its hunks match the same code.
const patch_version = if (std.mem.eql(u8, zig_version, "0.17.1")) "0.17.0" else zig_version;
const zig_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) == .lt;
