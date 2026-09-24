// SPDX-License-Identifier: MPL-2.0
//! FreeDeviceProc: frees a DevProc GetDeviceProc gave.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DevProc = dos.DevProc;

/// Frees a DevProc GetDeviceProc gave.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeDeviceProc(db: *DosBase, dp: ?*DevProc) void
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `dp` - the DevProc; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A lock GetDeviceProc made for it (DVPF_UNLOCK, a non-binding
/// assign's) is unlocked, then the DevProc is freed. A lock it only
/// borrowed - an assign's directory, the current directory - is left
/// alone.
///
/// CONTEXT:
/// - Waits: yes, when it unlocks a lock (a packet to its handler).
/// - Interrupts: not safe.
/// - Forbid: not to be held; it may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `dp` is gone and must not be used again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// defer dos_lib.FreeDeviceProc(dp);
/// ```
pub fn FreeDeviceProc(db: *DosBase, dp: ?*DevProc) void {
    const dos_lib = db.iface();
    const it = dp orelse return;
    if (it.flags & dos.DVPF_UNLOCK != 0) dos_lib.UnLock(it.lock);
    db.sys_base.FreeVec(it);
}
