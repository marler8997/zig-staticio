pub const sees_patched_std = @hasDecl(@import("std"), "IoVtable");
pub const subsub_sees_patched_std = @import("subsub").sees_patched_std;
