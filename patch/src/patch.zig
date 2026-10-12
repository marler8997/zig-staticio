//! Copies a directory and applies git style unified diffs to it.
//!
//! Supports modified files, `new file mode`, `copy from`/`copy to`,
//! `rename from`/`rename to` and `\ No newline at end of file`; `index` and
//! similarity lines are ignored. Hunk line numbers are ignored, each hunk's old
//! text must appear exactly once, at a line start, in order. Anything else is
//! an error.
//!
//! Usage: patch SRC_DIR OUT_DIR DEP_FILE PATCH...
//!   DEP_FILE gets the files copied from SRC_DIR, for the build system.

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) fatal("usage: patch SRC_DIR OUT_DIR DEP_FILE PATCH...", .{});
    const src_path = args[1];
    const out_path = args[2];
    const dep_path = args[3];

    const cwd = std.Io.Dir.cwd();
    const src_abs = cwd.realPathFileAlloc(io, src_path, arena) catch |err|
        fatal("resolve '{s}' failed with {t}", .{ src_path, err });
    const out_abs = realPathMaybeMissing(io, arena, out_path);
    // OUT_DIR is deleted and SRC_DIR walked, neither may contain the other
    if (contains(src_abs, out_abs) or contains(out_abs, src_abs))
        fatal("SRC_DIR '{s}' and OUT_DIR '{s}' overlap", .{ src_abs, out_abs });

    // clear a previous run's output
    cwd.deleteTree(io, out_path) catch |err|
        fatal("delete '{s}' failed with {t}", .{ out_path, err });
    var out_dir = cwd.createDirPathOpen(io, out_path, .{}) catch |err|
        fatal("create '{s}' failed with {t}", .{ out_path, err });
    defer out_dir.close(io);

    {
        const dep_file = cwd.createFile(io, dep_path, .{}) catch |err|
            fatal("create '{s}' failed with {t}", .{ dep_path, err });
        defer dep_file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var dep_writer = dep_file.writer(io, &buf);
        copyTree(io, init.gpa, src_path, src_abs, out_dir, &dep_writer.interface) catch |err| switch (err) {
            error.WriteFailed => fatal("write '{s}' failed with {t}", .{ dep_path, dep_writer.err.? }),
        };
    }

    // the patch and its section list live per patch, file contents per section
    var patch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer patch_arena.deinit();
    var file_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer file_arena.deinit();
    for (args[4..]) |patch_path| {
        _ = patch_arena.reset(.retain_capacity);
        const a = patch_arena.allocator();
        const patch = cwd.readFileAlloc(io, patch_path, a, .unlimited) catch |err|
            fatal("read '{s}' failed with {t}", .{ patch_path, err });
        var sections: SectionIterator = .{ .patch = patch };
        // the files this patch has written or renamed, a copy or rename must
        // not read one of them
        var written: std.StringHashMapUnmanaged(void) = .empty;
        while (sections.next() catch |err| fatal("{s}:{}: {t}", .{ patch_path, sections.line_number, err })) |section| {
            _ = file_arena.reset(.retain_capacity);
            var line: usize = section.body_line;
            applySection(io, file_arena.allocator(), out_dir, section, &written, &line) catch |err| fatal(
                "{s}:{}: patching '{s}' failed with {t}",
                .{ patch_path, line, section.target, err },
            );
            written.put(a, section.target, {}) catch @panic("OOM");
            if (section.kind == .rename) written.put(a, section.kind.rename, {}) catch @panic("OOM");
        }
    }
}

/// Absolute `path` with symlinks resolved, `path` or its parents may not exist.
fn realPathMaybeMissing(io: std.Io, arena: std.mem.Allocator, path: []const u8) []const u8 {
    const cwd_abs = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch |err|
        fatal("resolve '.' failed with {t}", .{err});
    const abs = std.fs.path.resolve(arena, &.{ cwd_abs, path }) catch @panic("OOM");
    var existing: []const u8 = abs;
    while (true) {
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, existing, arena) catch |err| switch (err) {
            error.FileNotFound => {
                existing = std.fs.path.dirname(existing) orelse fatal("resolve '{s}' failed", .{path});
                continue;
            },
            else => fatal("resolve '{s}' failed with {t}", .{ existing, err }),
        };
        return std.mem.concat(arena, u8, &.{ real, abs[existing.len..] }) catch @panic("OOM");
    }
}

/// Whether `path` is `dir` or inside it, both absolute.
fn contains(dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or std.fs.path.isSep(path[dir.len]) or std.fs.path.isSep(dir[dir.len - 1]);
}

/// Copies the files of `src_path` (at `src_abs`) to `dest`, writing a
/// Makefile style dependency file of them to `deps`, so the build system
/// tracks them by content.
fn copyTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    src_path: []const u8,
    src_abs: []const u8,
    dest: std.Io.Dir,
    deps: *std.Io.Writer,
) error{WriteFailed}!void {
    var src = std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true }) catch |err|
        fatal("open '{s}' failed with {t}", .{ src_path, err });
    defer src.close(io);
    var walker = src.walk(gpa) catch |err| fatal("walk '{s}' failed with {t}", .{ src_path, err });
    defer walker.deinit();
    try deps.writeAll("deps:");
    while (walker.next(io) catch |err| fatal("walk '{s}' failed with {t}", .{ src_path, err })) |entry| switch (entry.kind) {
        .directory => dest.createDirPath(io, entry.path) catch |err|
            fatal("create '{s}' failed with {t}", .{ entry.path, err }),
        .file => {
            src.copyFile(entry.path, dest, entry.path, io, .{}) catch |err|
                fatal("copy '{s}/{s}' failed with {t}", .{ src_path, entry.path, err });
            try deps.writeAll(" \\\n ");
            try writeDepPath(deps, src_abs);
            try deps.writeByte(std.fs.path.sep);
            try writeDepPath(deps, entry.path);
        },
        else => fatal("unexpected {t} '{s}/{s}'", .{ entry.kind, src_path, entry.path }),
    };
    try deps.writeAll("\n");
    try deps.flush();
}

fn writeDepPath(w: *std.Io.Writer, path: []const u8) error{WriteFailed}!void {
    // zig's dependency file parser only unescapes spaces
    for (path) |c| {
        if (c == ' ') try w.writeByte('\\');
        try w.writeByte(c);
    }
}

/// On error `line` is the patch line of the hunk that failed.
fn applySection(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    section: Section,
    written: *const std.StringHashMapUnmanaged(void),
    line: *usize,
) !void {
    if (section.kind != .modify) {
        if (dir.statFile(io, section.target, .{})) |_| return error.FileAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    const original: []const u8 = switch (section.kind) {
        .modify => try dir.readFileAlloc(io, section.target, arena, .unlimited),
        .new => "",
        // git copies and renames the file as it was before the patch
        .copy, .rename => |source| if (written.contains(source))
            return error.SourceModifiedBySamePatch
        else
            try dir.readFileAlloc(io, source, arena, .unlimited),
    };
    var hunks: HunkIterator = .{ .arena = arena, .body = section.body, .line = section.body_line };
    const content = try applyHunks(arena, original, &hunks, line);
    if (std.fs.path.dirname(section.target)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = section.target, .data = content });
    if (section.kind == .rename) try dir.deleteFile(io, section.kind.rename);
}

/// Applies `hunks` to `content` like git, each hunk matched in the original
/// content and after the previous one. On error `line` is the patch line of
/// the hunk that failed.
fn applyHunks(arena: std.mem.Allocator, content: []const u8, hunks: *HunkIterator, line: *usize) ![]const u8 {
    // hunks only add their new text, which is part of the body
    var out: std.ArrayList(u8) = try .initCapacity(arena, content.len + hunks.body.len);
    var pos: usize = 0;
    while (true) {
        const hunk = hunks.next() catch |err| {
            line.* = hunks.line;
            return err;
        } orelse break;
        line.* = hunk.line;
        const at = try findHunk(content, hunk);
        if (at < pos) return error.HunkOutOfOrder;
        out.appendSliceAssumeCapacity(content[pos..at]);
        out.appendSliceAssumeCapacity(hunk.new);
        pos = at + hunk.old.len;
    }
    out.appendSliceAssumeCapacity(content[pos..]);
    return out.items;
}

fn findHunk(content: []const u8, hunk: Hunk) error{ HunkNotFound, HunkFoundMoreThanOnce }!usize {
    const at = if (hunk.old.len == 0) blk: {
        if (content.len != 0) return error.HunkNotFound;
        break :blk 0;
    } else try findOnceAtLineStart(content, hunk.old, hunk.at_eof);
    return at;
}

/// `at_eof`: only a match that ends `content` counts.
fn findOnceAtLineStart(content: []const u8, needle: []const u8, at_eof: bool) error{ HunkNotFound, HunkFoundMoreThanOnce }!usize {
    if (at_eof) {
        if (!std.mem.endsWith(u8, content, needle)) return error.HunkNotFound;
        const i = content.len - needle.len;
        if (i != 0 and content[i - 1] != '\n') return error.HunkNotFound;
        return i;
    }
    var found: ?usize = null;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, content, start, needle)) |i| : (start = i + 1) {
        if (i != 0 and content[i - 1] != '\n') continue;
        if (found != null) return error.HunkFoundMoreThanOnce;
        found = i;
    }
    return found orelse error.HunkNotFound;
}

const Section = struct {
    /// Relative to the patched directory.
    target: []const u8,
    kind: union(enum) {
        modify,
        new,
        /// Copied before applying the hunks.
        copy: []const u8,
        /// Renamed before applying the hunks.
        rename: []const u8,
    },
    /// Patch line before `body` starts.
    body_line: usize,
    body: []const u8,
};

const SectionIterator = struct {
    patch: []const u8,
    index: usize = 0,
    line_number: usize = 0,

    pub const Error = error{
        MissingDiffGitHeader,
        CrlfLineEndings,
        MissingFileHeader,
        UnsupportedHeader,
        BadPath,
        MismatchedPaths,
    };

    pub fn next(it: *SectionIterator) Error!?Section {
        // skip text before the first section
        while (it.peekLine()) |line| {
            if (std.mem.startsWith(u8, line, "diff --git ")) break;
            _ = it.nextLine();
        } else return null;
        const diff_line = it.nextLine().?;
        if (std.mem.endsWith(u8, diff_line, "\r")) return error.CrlfLineEndings;
        if (!std.mem.startsWith(u8, diff_line, "diff --git a/")) return error.MissingDiffGitHeader;

        var copy_from: ?[]const u8 = null;
        var copy_to: ?[]const u8 = null;
        var rename_from: ?[]const u8 = null;
        var rename_to: ?[]const u8 = null;
        var new_file = false;
        // the `---`/`+++` paths, missing for an unchanged copy or rename
        var old: ?[]const u8 = null;
        var target: ?[]const u8 = null;
        while (it.peekLine()) |line| {
            if (std.mem.startsWith(u8, line, "diff --git ")) break;
            _ = it.nextLine();
            if (std.mem.startsWith(u8, line, "--- ")) {
                const plus = it.nextLine() orelse return error.MissingFileHeader;
                if (!std.mem.startsWith(u8, plus, "+++ b/")) return error.MissingFileHeader;
                old = line["--- ".len..];
                target = try checkPath(plus["+++ b/".len..]);
                break;
            } else if (std.mem.startsWith(u8, line, "copy from ")) {
                copy_from = try checkPath(line["copy from ".len..]);
            } else if (std.mem.startsWith(u8, line, "copy to ")) {
                copy_to = try checkPath(line["copy to ".len..]);
            } else if (std.mem.startsWith(u8, line, "rename from ")) {
                rename_from = try checkPath(line["rename from ".len..]);
            } else if (std.mem.startsWith(u8, line, "rename to ")) {
                rename_to = try checkPath(line["rename to ".len..]);
            } else if (std.mem.startsWith(u8, line, "new file mode ")) {
                new_file = true;
            } else if (std.mem.startsWith(u8, line, "index ") or
                std.mem.startsWith(u8, line, "similarity index ") or
                std.mem.startsWith(u8, line, "dissimilarity index "))
            {
                // ignored
            } else return error.UnsupportedHeader;
        }

        const body_start = it.index;
        const body_line = it.line_number;
        if (target != null) while (it.peekLine()) |l| {
            if (std.mem.startsWith(u8, l, "diff --git ")) break;
            _ = it.nextLine();
        };
        const body = it.patch[body_start..it.index];

        if (new_file) {
            if (copy_from != null or copy_to != null or rename_from != null or rename_to != null) return error.UnsupportedHeader;
            const t = target orelse return .{ .target = try newFilePath(diff_line), .kind = .new, .body = body, .body_line = body_line };
            if (!std.mem.eql(u8, old.?, "/dev/null")) return error.UnsupportedHeader;
            return .{ .target = t, .kind = .new, .body = body, .body_line = body_line };
        }
        if ((copy_from == null) != (copy_to == null) or (rename_from == null) != (rename_to == null) or
            (copy_from != null and rename_from != null)) return error.UnsupportedHeader;
        const from = copy_from orelse rename_from orelse {
            const t = target orelse return error.MissingFileHeader;
            if (!std.mem.eql(u8, try oldPath(old.?), t)) return error.MismatchedPaths;
            return .{ .target = t, .kind = .modify, .body = body, .body_line = body_line };
        };
        const to = copy_to orelse rename_to.?;
        if (target) |t| {
            if (!std.mem.eql(u8, try oldPath(old.?), from) or !std.mem.eql(u8, t, to)) return error.MismatchedPaths;
        }
        return .{
            .target = to,
            .kind = if (copy_from != null) .{ .copy = from } else .{ .rename = from },
            .body = body,
            .body_line = body_line,
        };
    }

    /// The path of `diff --git a/PATH b/PATH`, for an empty new file.
    fn newFilePath(diff_line: []const u8) Error![]const u8 {
        const paths = diff_line["diff --git a/".len..];
        if (paths.len < " b/".len or (paths.len - " b/".len) % 2 != 0) return error.MismatchedPaths;
        const path = paths[0 .. (paths.len - " b/".len) / 2];
        const rest = paths[path.len..];
        if (!std.mem.startsWith(u8, rest, " b/") or !std.mem.eql(u8, rest[" b/".len..], path)) return error.MismatchedPaths;
        return checkPath(path);
    }

    fn oldPath(old: []const u8) Error![]const u8 {
        if (!std.mem.startsWith(u8, old, "a/")) return error.MissingFileHeader;
        return checkPath(old["a/".len..]);
    }

    fn peekLine(it: *SectionIterator) ?[]const u8 {
        if (it.index == it.patch.len) return null;
        const end = std.mem.indexOfScalarPos(u8, it.patch, it.index, '\n') orelse it.patch.len;
        return it.patch[it.index..end];
    }

    fn nextLine(it: *SectionIterator) ?[]const u8 {
        const line = it.peekLine() orelse return null;
        it.index = @min(it.patch.len, it.index + line.len + 1);
        it.line_number += 1;
        return line;
    }
};

/// Rejects absolute paths, `..` and control characters.
fn checkPath(path: []const u8) error{BadPath}![]const u8 {
    // ':' would allow a windows drive like `C:x`
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\:") != null) return error.BadPath;
    for (path) |c| if (c < ' ' or c == 0x7f) return error.BadPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadPath;
    }
    return path;
}

const Hunk = struct {
    /// Context and removed lines.
    old: []const u8,
    /// Context and added lines.
    new: []const u8,
    /// Set by `\ No newline at end of file`, the hunk must end the file.
    at_eof: bool,
    /// Patch line of the `@@` header.
    line: usize,
};

const HunkIterator = struct {
    /// Holds returned hunks.
    arena: std.mem.Allocator,
    body: []const u8,
    index: usize = 0,
    /// Patch line of the last line read.
    line: usize,

    pub const Error = error{ BadHunkHeader, BadHunkLine, HunkTooShort, OutOfMemory };

    pub fn next(it: *HunkIterator) Error!?Hunk {
        const header = it.nextLine() orelse return null;
        const header_line = it.line;
        if (!std.mem.startsWith(u8, header, "@@ -")) return error.BadHunkHeader;
        const counts = try parseHunkHeader(header);
        var old_left = counts.old;
        var new_left = counts.new;
        // copied so `\ No newline at end of file` can drop a newline
        var old: std.ArrayList(u8) = .empty;
        var new: std.ArrayList(u8) = .empty;
        var last: enum { none, old, new, both } = .none;
        var at_eof = false;
        while (old_left > 0 or new_left > 0 or it.peekIsNoNewline()) {
            const line = it.nextLine() orelse return error.HunkTooShort;
            if (std.mem.startsWith(u8, line, "\\")) {
                if (!std.mem.startsWith(u8, line, "\\ No newline at end of file")) return error.BadHunkLine;
                switch (last) {
                    .none => return error.BadHunkLine,
                    .old => _ = old.pop(),
                    .new => _ = new.pop(),
                    .both => {
                        _ = old.pop();
                        _ = new.pop();
                    },
                }
                last = .none;
                at_eof = true;
                continue;
            }
            // stripped trailing whitespace makes empty context lines ""
            const kind: u8 = if (line.len == 0) ' ' else line[0];
            const text = if (line.len == 0) "" else line[1..];
            switch (kind) {
                ' ' => {
                    if (old_left == 0 or new_left == 0) return error.BadHunkLine;
                    try it.appendLine(&old, text);
                    try it.appendLine(&new, text);
                    old_left -= 1;
                    new_left -= 1;
                    last = .both;
                },
                '-' => {
                    if (old_left == 0) return error.BadHunkLine;
                    try it.appendLine(&old, text);
                    old_left -= 1;
                    last = .old;
                },
                '+' => {
                    if (new_left == 0) return error.BadHunkLine;
                    try it.appendLine(&new, text);
                    new_left -= 1;
                    last = .new;
                },
                else => return error.BadHunkLine,
            }
        }
        return .{ .old = old.items, .new = new.items, .at_eof = at_eof, .line = header_line };
    }

    fn appendLine(it: *HunkIterator, list: *std.ArrayList(u8), text: []const u8) error{OutOfMemory}!void {
        try list.ensureUnusedCapacity(it.arena, text.len + 1);
        list.appendSliceAssumeCapacity(text);
        list.appendAssumeCapacity('\n');
    }

    fn peekIsNoNewline(it: *HunkIterator) bool {
        return std.mem.startsWith(u8, it.body[it.index..], "\\ No newline at end of file");
    }

    fn nextLine(it: *HunkIterator) ?[]const u8 {
        if (it.index == it.body.len) return null;
        const end = std.mem.indexOfScalarPos(u8, it.body, it.index, '\n') orelse it.body.len;
        const line = it.body[it.index..end];
        it.index = @min(it.body.len, end + 1);
        it.line += 1;
        return line;
    }
};

/// Line counts of `@@ -a[,b] +c[,d] @@`, a missing count is 1.
fn parseHunkHeader(header: []const u8) error{BadHunkHeader}!struct { old: usize, new: usize } {
    const end = std.mem.indexOfPos(u8, header, 4, " @@") orelse return error.BadHunkHeader;
    const ranges = header["@@ -".len..end];
    const space = std.mem.indexOfScalar(u8, ranges, ' ') orelse return error.BadHunkHeader;
    if (ranges.len < space + 2 or ranges[space + 1] != '+') return error.BadHunkHeader;
    return .{
        .old = try parseCount(ranges[0..space]),
        .new = try parseCount(ranges[space + 2 ..]),
    };
}

fn parseCount(range: []const u8) error{BadHunkHeader}!usize {
    const comma = std.mem.indexOfScalar(u8, range, ',') orelse {
        _ = std.fmt.parseInt(usize, range, 10) catch return error.BadHunkHeader;
        return 1;
    };
    _ = std.fmt.parseInt(usize, range[0..comma], 10) catch return error.BadHunkHeader;
    return std.fmt.parseInt(usize, range[comma + 1 ..], 10) catch return error.BadHunkHeader;
}

fn applyAll(arena: std.mem.Allocator, content: []const u8, body: []const u8) ![]const u8 {
    var hunks: HunkIterator = .{ .arena = arena, .body = body, .line = 0 };
    var line: usize = 0;
    return applyHunks(arena, content, &hunks, &line);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

test "modify" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try applyAll(arena.allocator(), "a\nb\nc\nd\n",
        \\@@ -2,2 +2,3 @@
        \\ b
        \\-c
        \\+C
        \\+C2
        \\
    );
    try testing.expectEqualStrings("a\nb\nC\nC2\nd\n", result);
}

test "empty context lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try applyAll(arena.allocator(), "a\n\nb\n", "@@ -1,3 +1,3 @@\n a\n\n-b\n+B\n");
    try testing.expectEqualStrings("a\n\nB\n", result);
}

test "no newline at end of file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try applyAll(arena.allocator(), "a\nb",
        \\@@ -1,2 +1,2 @@
        \\ a
        \\-b
        \\\ No newline at end of file
        \\+B
        \\
    );
    try testing.expectEqualStrings("a\nB\n", result);
}

test "hunk must match exactly once at a line start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hunk = "@@ -1 +1 @@\n-b\n+B\n";
    try testing.expectError(error.HunkFoundMoreThanOnce, applyAll(arena.allocator(), "b\nb\n", hunk));
    try testing.expectError(error.HunkNotFound, applyAll(arena.allocator(), "ab\n", hunk));
    try testing.expectError(error.HunkNotFound, applyAll(arena.allocator(), "c\n", hunk));
}

test "sections" {
    var it: SectionIterator = .{ .patch =
        \\description
        \\diff --git a/x.zig b/x.zig
        \\index 1..2 100644
        \\--- a/x.zig
        \\+++ b/x.zig
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/x.zig b/y.zig
        \\copy from x.zig
        \\copy to y.zig
        \\--- a/x.zig
        \\+++ b/y.zig
        \\@@ -1 +1 @@
        \\-b
        \\+c
        \\diff --git a/z.zig b/z.zig
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/z.zig
        \\@@ -0,0 +1 @@
        \\+z
        \\
    };
    const modify = (try it.next()).?;
    try testing.expectEqualStrings("x.zig", modify.target);
    try testing.expect(modify.kind == .modify);
    const copy = (try it.next()).?;
    try testing.expectEqualStrings("y.zig", copy.target);
    try testing.expectEqualStrings("x.zig", copy.kind.copy);
    const new = (try it.next()).?;
    try testing.expectEqualStrings("z.zig", new.target);
    try testing.expect(new.kind == .new);
    try testing.expect((try it.next()) == null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("z\n", try applyAll(arena.allocator(), "", new.body));
}

test "rejected headers and paths" {
    var deleted: SectionIterator = .{ .patch = "diff --git a/x b/x\ndeleted file mode 100644\n--- a/x\n+++ /dev/null\n" };
    try testing.expectError(error.UnsupportedHeader, deleted.next());
    var escape: SectionIterator = .{ .patch = "diff --git a/x b/x\n--- a/../x\n+++ b/../x\n" };
    try testing.expectError(error.BadPath, escape.next());
}

test "a hunk without a final newline must end the file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old_side = "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+B\n";
    try testing.expectError(error.HunkNotFound, applyAll(arena.allocator(), "a\nbc\n", old_side));
    const new_side = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n\\ No newline at end of file\n";
    try testing.expectError(error.HunkNotFound, applyAll(arena.allocator(), "a\nb\nc\n", new_side));
    try testing.expectEqualStrings("a\nB", try applyAll(arena.allocator(), "a\nb\n", new_side));
}

test "windows drive paths are rejected" {
    try testing.expectError(error.BadPath, checkPath("C:x"));
    try testing.expectError(error.BadPath, checkPath("C:/x"));
}

const std = @import("std");
const testing = std.testing;

test "hunks match the original content, in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the second hunk's old text only exists in the first hunk's new text
    try testing.expectError(error.HunkNotFound, applyAll(a, "a\nb\n", "@@ -1 +1,2 @@\n a\n+X\n@@ -2 +3 @@\n-X\n+Y\n"));
    // the first hunk inserts a copy of the second hunk's old text
    try testing.expectEqualStrings("a\nb\nB\n", try applyAll(a, "a\nb\n", "@@ -1 +1,2 @@\n a\n+b\n@@ -2 +3 @@\n-b\n+B\n"));
    try testing.expectError(error.HunkOutOfOrder, applyAll(a, "a\nb\n", "@@ -2 +2 @@\n-b\n+B\n@@ -1 +1 @@\n-a\n+A\n"));
}

test "body line without a final newline" {
    var it: SectionIterator = .{ .patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b" };
    try testing.expectEqual(3, (try it.next()).?.body_line);
}

test "contains" {
    try testing.expect(contains("/a/b", "/a/b"));
    try testing.expect(contains("/a/b", "/a/b/c"));
    try testing.expect(!contains("/a/b", "/a/bc"));
    try testing.expect(contains("/", "/a"));
}

test "dependency paths escape spaces" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDepPath(&w, "a b");
    try testing.expectEqualStrings("a\\ b", w.buffered());
}

test "copies and renames, with and without hunks" {
    var it: SectionIterator = .{ .patch =
        \\diff --git a/x.zig b/y.zig
        \\similarity index 100%
        \\copy from x.zig
        \\copy to y.zig
        \\diff --git a/x.zig b/z.zig
        \\rename from x.zig
        \\rename to z.zig
        \\--- a/x.zig
        \\+++ b/z.zig
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    };
    const copy = (try it.next()).?;
    try testing.expectEqualStrings("y.zig", copy.target);
    try testing.expectEqualStrings("x.zig", copy.kind.copy);
    try testing.expectEqualStrings("", copy.body);
    const rename = (try it.next()).?;
    try testing.expectEqualStrings("z.zig", rename.target);
    try testing.expectEqualStrings("x.zig", rename.kind.rename);
    try testing.expectEqual(9, rename.body_line);
    try testing.expect((try it.next()) == null);

    var mismatched: SectionIterator = .{ .patch = "diff --git a/x b/y\nrename from x\nrename to y\n--- a/x\n+++ b/z\n" };
    try testing.expectError(error.MismatchedPaths, mismatched.next());
    var mixed: SectionIterator = .{ .patch = "diff --git a/x b/y\ncopy from x\nrename to y\n" };
    try testing.expectError(error.UnsupportedHeader, mixed.next());
}

test "rename applies to the directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "x", .data = "a\n" });
    var it: SectionIterator = .{ .patch =
        \\diff --git a/x b/c
        \\copy from x
        \\copy to c
        \\diff --git a/x b/r
        \\rename from x
        \\rename to r
        \\diff --git a/r b/c2
        \\copy from r
        \\copy to c2
        \\
    };
    var written: std.StringHashMapUnmanaged(void) = .empty;
    var line: usize = 0;
    for (0..2) |_| {
        const section = (try it.next()).?;
        try applySection(io, a, tmp.dir, section, &written, &line);
        try written.put(a, section.target, {});
        if (section.kind == .rename) try written.put(a, section.kind.rename, {});
    }
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a\n", try tmp.dir.readFile(io, "c", &buf));
    try testing.expectEqualStrings("a\n", try tmp.dir.readFile(io, "r", &buf));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "x", .{}));
    // git reads sources as they were before the patch, `r` didn't exist yet
    try testing.expectError(error.SourceModifiedBySamePatch, applySection(io, a, tmp.dir, (try it.next()).?, &written, &line));
}

test "a hunk without a final newline only matches at the end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // `a\nb` also starts the line `bc` earlier
    try testing.expectEqualStrings("a\nbc\na\nB\n", try applyAll(arena.allocator(), "a\nbc\na\nb", "@@ -3,2 +3,2 @@\n a\n-b\n\\ No newline at end of file\n+B\n"));
}

test "crlf patches and control characters are rejected" {
    var crlf: SectionIterator = .{ .patch = "diff --git a/x b/x\r\n--- a/x\r\n+++ b/x\r\n" };
    try testing.expectError(error.CrlfLineEndings, crlf.next());
    try testing.expectError(error.BadPath, checkPath("x\r"));
}

test "empty new file" {
    var it: SectionIterator = .{ .patch = "diff --git a/d/e b/d/e\nnew file mode 100644\nindex 0000000..e69de29\n" };
    const section = (try it.next()).?;
    try testing.expectEqualStrings("d/e", section.target);
    try testing.expect(section.kind == .new);
    try testing.expectEqualStrings("", section.body);
    var mismatched: SectionIterator = .{ .patch = "diff --git a/d b/e\nnew file mode 100644\n" };
    try testing.expectError(error.MismatchedPaths, mismatched.next());
}
