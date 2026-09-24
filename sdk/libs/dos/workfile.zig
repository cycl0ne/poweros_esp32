// SPDX-License-Identifier: MIT
//! T:, where Execute's work files (T:Command-nn-Tnn) and the shell's
//! backquote output (T:tick$n) go. It is in the SDK so
//! that the shell and any program on disk can reach it, since each is built
//! as its own module. dos.library's init makes T a late assign to RAM:T;
//! the directory is made here the first time it is missing.

const dos = @import("dos.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// Open a file in T:, making T:'s directory if that is why it failed.
pub fn open(dl: *DosBase, name: [*:0]const u8, mode: i32) ?*dos.FileHandle {
    if (dl.Open(name, mode)) |fh| return fh;
    const err = dl.IoErr();
    if (!makeT(dl)) {
        _ = dl.SetIoErr(err);
        return null;
    }
    return dl.Open(name, mode);
}

/// The directory of T's late assign, made; false if T isn't a late assign
/// (it is bound already) or the directory can't be made.
fn makeT(dl: *DosBase) bool {
    var target: [256]u8 = undefined;
    const flags = dos.LDF_ASSIGNS | dos.LDF_READ;
    const start = dl.LockDosList(flags) orelse return false;
    const node = dl.FindDosEntry(start, "T", dos.LDF_ASSIGNS);
    var fits = false;
    if (node) |n| if (n.type == .late) if (n.misc.assign.assign_name) |path| {
        var i: usize = 0;
        while (path[i] != 0 and i + 1 < target.len) : (i += 1) target[i] = path[i];
        target[i] = 0;
        fits = path[i] == 0;
    };
    dl.UnLockDosList(flags);
    if (!fits) return false;
    const lock = dl.CreateDir(@ptrCast(&target)) orelse return false;
    dl.UnLock(lock);
    return true;
}
