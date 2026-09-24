// SPDX-License-Identifier: MPL-2.0
//! SameDevice: whether two locks are on one device.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const mount = @import("../doslist/_doslist.zig");
const FileLock = dos.FileLock;

/// Tells whether two locks are on the same device.
///
/// SYNOPSIS:
/// ```zig
/// fn SameDevice(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) bool
/// ```
///
/// SINCE: 1.0. LVO -400.
///
/// INPUTS:
/// - `lock1` - one lock.
/// - `lock2` - the other lock.
///
/// RESULT:
/// True if they are on one device, false otherwise and if either is null.
///
/// BEHAVIOR:
/// Two locks are on one device if they are the same lock, name the same
/// volume, or come from the same handler. Otherwise the two handlers'
/// device nodes are looked up, and their FileSysStartupMsgs compared: the
/// same exec device name and unit is one medium under two handlers, read
/// while the device list stays locked. A node whose startup is a plain
/// number (RAW:, a window) has no medium to compare. No packet is sent.
///
/// CONTEXT:
/// - Waits: yes, for the device list (LockDosList, LDF_READ).
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Both locks stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SameLock`, `Info`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.SameDevice(from, to)) return copyAcross(from, to);
/// ```
pub fn SameDevice(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) bool {
    const a = lock1 orelse return false;
    const b = lock2 orelse return false;
    if (a == b) return true;
    if (a.volume != null and a.volume == b.volume) return true;
    if (a.task != null and a.task == b.task) return true;
    return mount.sameMedium(db, a.task, b.task);
}
