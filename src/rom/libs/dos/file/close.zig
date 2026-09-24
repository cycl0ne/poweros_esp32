// SPDX-License-Identifier: MPL-2.0
//! Close: writes out what a handle's buffer still holds, tells the handler
//! the file is done with, and frees the handle.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const packets = @import("../packet/_packet.zig");
const locks = @import("../lock/_lock.zig");
const buffered = @import("_file.zig");
const ActionCode = dos.ActionCode;
const FileHandle = dos.FileHandle;

/// Closes a file and frees its handle.
///
/// SYNOPSIS:
/// ```zig
/// fn Close(db: *DosBase, file: ?*FileHandle) bool
/// ```
///
/// SINCE: 1.0. LVO -196.
///
/// INPUTS:
/// - `file` - the handle from `Open` or `OpenFromLock`, or null.
///
/// RESULT:
/// True when the waiting bytes went out and the handler closed the file.
/// False for a null `file`, when the write-out failed, or when the handler
/// refused; `IoErr()` then holds the reason (`ERROR_NO_FREE_STORE` when no
/// packet could be sent). On success `IoErr()` is what it was before the
/// call.
///
/// BEHAVIOR:
/// The buffered bytes that wait to be written are written first, and a
/// buffer dos allocated is freed. Then `ACTION_END` goes to the handler
/// with the handle. The handle is freed whatever the outcome - a failed
/// close cannot be retried with it.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// The handle is gone after the call, even when it answers false. A buffer
/// the caller gave `SetVBuf` stays the caller's.
///
/// NOTES:
/// A handle is closed once. A second `Close` of the same pointer frees
/// freed memory; nothing checks for it. When no packet can be sent the
/// handle is freed all the same, and the handler still thinks the file is
/// open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Open`, `Flush`, `SetVBuf`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Close(fh)) return dos_lib.IoErr();
/// ```
pub fn Close(db: *DosBase, file: ?*FileHandle) bool {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const fh = file orelse return false;
    defer dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
    const saved = dos_lib.IoErr();
    const written = buffered.release(db, fh);
    const write_error = dos_lib.IoErr();
    const port = fh.task orelse return written;
    const answer = packets.exchange(sys, port, @intFromEnum(ActionCode.end), .{ locks.asArg(fh), 0, 0, 0, 0 }) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    if (answer.res1 == 0) {
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    _ = dos_lib.SetIoErr(if (written) saved else write_error);
    return written;
}
