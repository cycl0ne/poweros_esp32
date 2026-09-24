// SPDX-License-Identifier: MPL-2.0
//! Open: opens a file by name for reading, writing or both, and gives back
//! the handle that the other file calls take.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const locks = @import("../lock/_lock.zig");
const ActionCode = dos.ActionCode;
const FileHandle = dos.FileHandle;

/// Opens a file by name.
///
/// SYNOPSIS:
/// ```zig
/// fn Open(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -192.
///
/// INPUTS:
/// - `name` - the file's name: a path with or without a device, or "*" for
///   the process's console.
/// - `mode` - `MODE_OLDFILE` (an existing file), `MODE_NEWFILE` (a new
///   file, or an existing one emptied) or `MODE_READWRITE` (an existing
///   file, or a new one, opened shared).
///
/// RESULT:
/// The file's handle, or null. On null, `IoErr()` says why:
/// `ERROR_ACTION_NOT_KNOWN` for another `mode`, `ERROR_NO_FREE_STORE` when
/// the handle can't be allocated, or the handler's code
/// (`ERROR_OBJECT_NOT_FOUND`, `ERROR_OBJECT_IN_USE`,
/// `ERROR_DEVICE_NOT_MOUNTED`, ...).
///
/// BEHAVIOR:
/// The mode picks the packet: `ACTION_FINDINPUT`, `ACTION_FINDOUTPUT` or
/// `ACTION_FINDUPDATE`. The name is resolved to its handler and directory
/// as `Lock` resolves one, and the packet carries the new handle, the
/// directory's lock and the name. Along a multi-assign the next directory
/// is tried while the file isn't found - except for `MODE_NEWFILE`, which
/// creates the file in the first directory rather than looking for one to
/// replace.
///
/// "*" is the process's console, as CONSOLE:, or NIL: when the process has
/// none (or the caller is a plain Task). The handle starts line buffered,
/// with no buffer until the first buffered call.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// The handle is the caller's, to give to `Close` once. It is allocated
/// with `AllocDosObject(DOS_FILEHANDLE)` and freed again if the open fails.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Close`, `Read`, `Write`, `OpenFromLock`, `Lock`
///
/// EXAMPLES:
/// ```zig
/// const fh = dos_lib.Open("S:Startup-Sequence", dos.MODE_OLDFILE) orelse return dos_lib.IoErr();
/// defer _ = dos_lib.Close(fh);
/// ```
pub fn Open(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileHandle {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const action: ActionCode = switch (mode) {
        dos.MODE_OLDFILE => .findinput,
        dos.MODE_NEWFILE => .findoutput,
        dos.MODE_READWRITE => .findupdate,
        else => {
            _ = dos_lib.SetIoErr(dos.ERROR_ACTION_NOT_KNOWN);
            return null;
        },
    };
    var path = name;
    if (db.utility_base.Strcmp(name, "*") == 0) {
        const console = if (process.currentProcess(sys)) |p| p.console_task else null;
        path = if (console != null) "CONSOLE:" else "NIL:";
    }
    const block = dos_lib.AllocDosObject(dos.DOS_FILEHANDLE, null) orelse return null;
    const fh: *FileHandle = @ptrCast(@alignCast(block));
    if (locks.nameAction(db, path, action, .{ .fh = fh, .retry = action != .findoutput }) == 0) {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        return null;
    }
    return fh;
}
