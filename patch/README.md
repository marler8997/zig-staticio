# patch

Applies git style unified diffs to a copy of a directory.

```
patch SRC_DIR OUT_DIR DEP_FILE PATCH...
```

OUT_DIR is replaced with a copy of SRC_DIR with the patches applied in order. DEP_FILE lists the files copied from SRC_DIR, so the zig build system reruns the tool when one changes or is deleted (not when one is added):

```zig
// build.zig
const run = b.addRunArtifact(b.dependency("patch", .{ .target = b.graph.host }).artifact("patch"));
run.addDirectoryArg2(some_dep.path("src"), .{});
const patched_dir = run.addOutputDirectoryArg2("patched", .{});
_ = run.addDepFileOutputArg2("deps.d", .{});
run.addFileArg(b.path("fix.patch"));
```

## Patches

Supported: modified files, `new file mode`, `copy from`/`copy to` and `rename from`/`rename to` (with or without hunks) and `\ No newline at end of file`. Copies and renames read the file as it was before the patch, like git.

Hunk line numbers are ignored. Each hunk's old lines must appear exactly once in the file, otherwise patching fails. There's no fuzz, so a patch for one version of a directory fails loudly on another, and patches still apply after earlier patches have moved lines around.
