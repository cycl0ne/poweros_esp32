// SPDX-License-Identifier: MPL-2.0
//! CreateDirs: every directory on a path made where there is none.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const fail = _lock.fail;

/// Makes every directory on the path `name` that is not there, from the
/// volume down: the directories a file is to go into, or a directory
/// with all those above it.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateDirs(db: *DosBase, name: [*:0]const u8, last: bool) bool
/// ```
///
/// SINCE: 1.18. LVO -632.
///
/// INPUTS:
/// - `name` - the path, as for Lock.
/// - `last` - its last part is a directory too, and made; false for the
///   name of a file whose directories are wanted.
///
/// RESULT:
/// True when every directory on the path is there; false with IoErr()
/// (CreateDir's errors, ERROR_OBJECT_WRONG_TYPE for a file in the way,
/// ERROR_NO_FREE_STORE, ERROR_LINE_TOO_LONG past dos.path_max).
///
/// BEHAVIOR:
/// The path is taken a part at a time, from the first after the device's
/// colon: each directory that does not lock is made with CreateDir, and
/// one that does - Examine says it is a directory - is gone on from. A `/` at the start or after another
/// stands for the directory above, as in any name, and is passed. With
/// `last` false the part after the last `/` is left alone.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// No lock is kept. The directories made stay when a later one fails.
///
/// NOTES:
/// A path the volume holds already answers true with nothing made. A
/// soft link to a directory is gone through, as Lock goes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDir`, `Lock`, `DeleteTree`
///
/// EXAMPLES:
/// ```zig
/// // The directories of a file about to be written.
/// if (!dl.CreateDirs("RAM:a/b/c/file", false)) return dl.PrintFault(dl.IoErr(), "RAM:a/b/c");
/// const file = dl.Open("RAM:a/b/c/file", dos.MODE_NEWFILE);
/// ```
pub fn CreateDirs(db: *DosBase, name: [*:0]const u8, last: bool) bool {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    var length: usize = 0;
    while (name[length] != 0) : (length += 1) {
        if (length >= dos.path_max) return fail(db, dos.ERROR_LINE_TOO_LONG);
    }
    // The path's copy, cut at each part, and the block Examine fills.
    const fib_at = (length + 1 + 7) & ~@as(usize, 7);
    const memory = sys.AllocVec(fib_at + @sizeOf(dos.FileInfoBlock), exec.MEMF_ANY) orelse return fail(db, dos.ERROR_NO_FREE_STORE);
    defer sys.FreeVec(memory);
    const path: [*]u8 = @ptrCast(memory);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(path + fib_at));
    @memcpy(path[0 .. length + 1], name[0 .. length + 1]);
    // Where the parts begin: past a device's colon.
    var start: usize = 0;
    for (0..length) |at| {
        if (path[at] == ':') {
            start = at + 1;
            break;
        }
    }
    var at = start;
    while (at <= length) : (at += 1) {
        const ends = at == length or path[at] == '/';
        if (!ends) continue;
        // A part of no length: the directory above, or the path's end.
        if (at == start or path[at - 1] == '/' or (at == length and !last)) continue;
        const kept = path[at];
        path[at] = 0;
        defer path[at] = kept;
        const directory: [*:0]const u8 = @ptrCast(path);
        if (dos_lib.Lock(directory, dos.ACCESS_READ)) |lock| {
            const examined = dos_lib.Examine(lock, fib);
            dos_lib.UnLock(lock);
            if (!examined) return false;
            if (!dos.isDirectory(fib.dir_entry_type)) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
            continue;
        }
        const made = dos_lib.CreateDir(directory) orelse return false;
        dos_lib.UnLock(made);
    }
    return true;
}
