// SPDX-License-Identifier: MPL-2.0
//! Relabel: a volume given a new name.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");

/// Gives the volume in a drive a new name, when its file system can.
///
/// SYNOPSIS:
/// ```zig
/// fn Relabel(db: *DosBase, drive: [*:0]const u8, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.4. LVO -568.
///
/// INPUTS:
/// - `drive` - the drive, with its colon: a device (`DH0:`), a volume
///   (`System:`) or an assign to one.
/// - `name` - the new name, without a colon: one to 30 characters, none
///   of them `:` or `/`.
///
/// RESULT:
/// True when the volume has the new name; false with IoErr saying why -
/// `ERROR_INVALID_COMPONENT_NAME` for a name that cannot be a volume's,
/// `ERROR_ACTION_NOT_KNOWN` for a file system that cannot rename, or what
/// the drive's handler answered (a name too long for its format, a write
/// protected disk).
///
/// BEHAVIOR:
/// `ACTION_RENAME_DISK` to the drive's handler, with the name. The
/// handler writes the name where its format keeps it and gives the
/// volume's node the new name - the same node, so a lock on the volume
/// still names it, by its new name. A handler may shorten what it cannot
/// hold: FAT keeps eleven characters in upper case.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the device list.
/// - Process: a Process.
///
/// OWNERSHIP:
/// `name` is read while the call lasts.
///
/// NOTES:
/// A program that shows volumes by name learns of the change by looking
/// at the device list again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Info`, `Rename`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Relabel("SD0:", "Photos")) _ = dos_lib.PrintFault(dos_lib.IoErr(), "Relabel");
/// ```
pub fn Relabel(db: *DosBase, drive: [*:0]const u8, name: [*:0]const u8) bool {
    const dos_lib = db.iface();
    const len = db.utility_base.Strlen(name);
    if (!dos.volumename.valid(name[0..len])) return _lock.failZero(db, dos.ERROR_INVALID_COMPONENT_NAME) != 0;
    const dp = dos_lib.GetDeviceProc(drive, null) orelse return false;
    defer dos_lib.FreeDeviceProc(dp);
    const port = dp.port orelse return _lock.failZero(db, dos.ERROR_DEVICE_NOT_MOUNTED) != 0;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.rename_disk), .{ @bitCast(@intFromPtr(name)), 0, 0, 0, 0 }) orelse
        return _lock.failZero(db, dos.ERROR_NO_FREE_STORE) != 0;
    if (answer.res1 == 0) {
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    return true;
}
