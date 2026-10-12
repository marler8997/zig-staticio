//! Every module, nested ones too, must see the patched std.

comptime {
    if (!@hasDecl(std, "IoVtable")) @compileError("root module doesn't see the patched std");
}

pub fn main() void {
    if (!@import("sub").sees_patched_std) @panic("submodule doesn't see the patched std");
    if (!@import("sub").subsub_sees_patched_std) @panic("nested submodule doesn't see the patched std");
}

const std = @import("std");
