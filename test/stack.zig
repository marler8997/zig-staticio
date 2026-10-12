//! Patches stack, std has both staticio's and the test patch's changes.

comptime {
    if (!@hasDecl(std, "IoVtable")) @compileError("missing staticio's patch");
    if (!@hasDecl(std, "stack_test_decl")) @compileError("missing the stacked patch");
}

pub fn main() void {}

const std = @import("std");
