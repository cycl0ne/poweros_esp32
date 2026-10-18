// SPDX-License-Identifier: MPL-2.0
//! MakeLink: a new name for an object (a hard link), or a name for a path
//! (a soft link).

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const nameAction = _lock.nameAction;
const fail = _lock.fail;
const FileLock = dos.FileLock;

/// Makes a link: a second name for an object, or a name for a path.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeLink(db: *DosBase, name: [*:0]const u8, dest: usize, soft: bool) bool
/// ```
///
/// SINCE: 1.9. LVO -596.
///
/// INPUTS:
/// - `name` - the link's name, as for Lock; nothing may have it yet.
/// - `dest` - for a hard link the address of a lock on the object, which
///   must be on the volume `name` is on; for a soft link the address of a
///   path, NUL-terminated, at most `sdk.dos.path_max` characters.
/// - `soft` - true for a soft link, false for a hard one.
///
/// RESULT:
/// True when the link is made; false with IoErr saying why -
/// ERROR_REQUIRED_ARG_MISSING for no path or an empty one,
/// ERROR_LINE_TOO_LONG, ERROR_INVALID_LOCK for no lock,
/// ERROR_RENAME_ACROSS_DEVICES for a lock on another handler than the
/// name's, or what the handler answered: ERROR_OBJECT_EXISTS,
/// ERROR_OBJECT_WRONG_TYPE for a hard link to a directory where the file
/// system has none, ERROR_ACTION_NOT_KNOWN from one without links.
///
/// BEHAVIOR:
/// ACTION_MAKE_LINK to the name's handler, as (the directory `name` is
/// from, `name`, `dest`, LINK_SOFT or LINK_HARD), in the first directory
/// of a multi-assign, where a new file would go. A hard link is the object
/// itself under another name: either name opens it, and it stays until its
/// last name is deleted. A soft link holds its path and nothing else; the
/// path need not lead anywhere yet. Lock and Open follow it, from the
/// link's directory for a path without a device part; Delete, Rename and
/// the setters act on the link itself.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; a process gets IoErr.
///
/// OWNERSHIP:
/// The lock stays the caller's, to UnLock; the path is copied by the
/// handler.
///
/// NOTES:
/// A soft link's path is kept as it is given: a relative one is followed
/// from the directory the link is in, so a link that moves takes it along.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadLink`, `Lock`, `DeleteFile`
///
/// EXAMPLES:
/// ```zig
/// // Work:Tools names SYS:Utilities, wherever it is followed from.
/// if (!dos_lib.MakeLink("Work:Tools", @intFromPtr("SYS:Utilities"), true)) {
///     _ = dos_lib.PrintFault(dos_lib.IoErr(), "MakeLink");
/// }
/// ```
pub fn MakeLink(db: *DosBase, name: [*:0]const u8, dest: usize, soft: bool) bool {
    const dos_lib = db.iface();
    if (soft) {
        const path: [*:0]const u8 = @ptrFromInt(dest);
        if (dest == 0 or path[0] == 0) return fail(db, dos.ERROR_REQUIRED_ARG_MISSING);
        if (db.utility_base.Strlen(path) > dos.path_max) return fail(db, dos.ERROR_LINE_TOO_LONG);
    } else {
        const object: *FileLock = @ptrFromInt(if (dest != 0) dest else return fail(db, dos.ERROR_INVALID_LOCK));
        const dp = dos_lib.GetDeviceProc(name, null) orelse return false;
        const same = dp.port != null and dp.port == object.task;
        dos_lib.FreeDeviceProc(dp);
        if (!same) return fail(db, dos.ERROR_RENAME_ACROSS_DEVICES);
    }
    const kind = if (soft) dos.LINK_SOFT else dos.LINK_HARD;
    return nameAction(db, name, .make_link, .{ .arg3 = @bitCast(dest), .arg4 = kind, .retry = false }) != 0;
}
