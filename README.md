# staticio

Lets a program opt into static `std.Io` dispatch, so it only compiles the Io operations it can reach.

## Why

A custom Io only has to implement the operations the program can call. Each missing one is a compile error naming it (e.g. `struct 'MyIo' has no member named 'dirOpenFile'`), instead of a stub that fails at runtime.

It also debloats small release binaries and improves compile times. A stripped hello world (zig 0.17.0, x86_64-linux):

| mode         | size, std | size, staticio | compile, std | compile, staticio |
|--------------|-----------|----------------|--------------|-------------------|
| small        | 145 KiB   | 31 KiB         | 2.08s        | 0.91s             |
| fast         | 537 KiB   | 45 KiB         | 11.11s       | 1.18s             |
| safe         | 594 KiB   | 364 KiB        | 11.12s       | 9.15s             |
| debug        | 2.65 MiB  | 2.24 MiB       | 0.36s        | 0.33s             |

## Usage

Supports zig 0.16.0 and 0.17.0. staticio provides both a mechanism to create a patched std, with [patch](patch), and a patch for it, `src/std-<zig version>.patch`. The mechanism takes other patches in addition to staticio's. Import the patched std as `std` in a compile step's root module, which replaces std for the whole compilation:

```zig
// build.zig
const staticio = b.dependency("staticio", .{});
const patched_std = @import("staticio").addPatchedStd(staticio, &.{
    staticio.path("src/std-0.17.0.patch"), // or src/std-0.16.0.patch
    b.path("my-std.patch"),
});
exe.root_module.addImport("std", patched_std);
// or with only staticio's patch:
exe.root_module.addImport("std", staticio.module("std"));
```

```zig
// root source file
pub const std_options: std.Options = .{ .io_vtable = .threaded };
// or your own implementation:
pub const std_options: std.Options = .{ .io_vtable = .{ .custom = MyIo } };
```

[test/custom.zig](test/custom.zig) is a hello world whose Io implements only the 5 operations it reaches.

## Implementation

The patch (`src/std-<zig version>.patch`) behaves exactly like std unless the root module sets `std_options.io_vtable`, which turns `std.Io`'s runtime vtable pointer into a comptime field, making every `io.vtable.X(...)` a direct call. `Io.zig` becomes `IoRuntime.zig` (runtime vtable) and `IoStatic.zig` (comptime), so a direct `@import("Io.zig")` is a compile error instead of a silent runtime vtable. `zig build update-patch` regenerates it for the zig doing the build (see `tools/gen.zig`).

## Trade-off

Selecting an implementation fixes the whole program to it, it can't use a second one alongside it. Of std's own implementations only `std.Io.Threaded` can be selected (`.threaded`); in zig 0.17.0 the others don't match `std.Io.VTable`, and in zig 0.16.0 they aren't supported either.

With `.custom`, std's own uses of `std.Io.Threaded` are a compile error, since they'd call your functions with a `*Threaded` userdata. Declare `pub const std_options_debug_io` as your own Io where std's debug output (panics, stack traces) is reachable, and don't take a `std.process.Init` in `main`.

Tests run with the runtime vtable: zig's test runner declares its own `std_options`, so the root module's `io_vtable` doesn't apply. Code written against `std.Io` behaves the same either way, and tests can use any implementations, e.g. `std.Io.failing`. Building the program is what checks it only reaches the operations its Io implements.
