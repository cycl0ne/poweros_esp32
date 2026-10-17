// SPDX-License-Identifier: MPL-2.0
//! Inhibit: a drive's file system kept off its medium, or let back on.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");

/// Stops a drive's file system from using its medium, or lets it use the
/// medium again.
///
/// SYNOPSIS:
/// ```zig
/// fn Inhibit(db: *DosBase, drive: [*:0]const u8, on: bool) bool
/// ```
///
/// SINCE: 1.8. LVO -588.
///
/// INPUTS:
/// - `drive` - the drive, with its colon: a device (`SD0:`), a volume or
///   an assign to one. Once inhibited a drive may have no volume, so it is
///   let go by its device's name.
/// - `on` - true to inhibit the drive, false to take an inhibit back.
///
/// RESULT:
/// True when the handler did it; false with IoErr saying why -
/// `ERROR_OBJECT_IN_USE` while a file on the drive is open for writing,
/// `ERROR_ACTION_NOT_KNOWN` from a handler that cannot be inhibited,
/// `ERROR_DEVICE_NOT_MOUNTED` for a drive that is not there.
///
/// BEHAVIOR:
/// `ACTION_INHIBIT` to the drive's handler, with `DOSTRUE` or `DOSFALSE`.
/// Inhibited, the handler puts what it holds in memory on the medium and
/// keeps off it: it answers every packet but those that give a lock or a
/// file back as for a disk it cannot read (`ERROR_NOT_A_DOS_DISK`), and
/// Info says the drive is busy (`ID_BUSY_DISK`). Inhibits nest, and the
/// drive is in use again when the last one is taken back: the handler
/// then reads the medium as it finds it - the same, a fresh one, or none.
/// Taking back an inhibit the drive does not have does nothing.
///
/// CONTEXT:
/// - Waits: yes, for the handler, which writes what it holds first.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the device list.
/// - Process: a Process.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// A program that writes a medium itself - a format, a copy of a whole
/// disk - inhibits its drive first and takes the inhibit back however it
/// ends; a drive left inhibited stays busy until the system starts again.
/// A lock taken before stays a lock, but what it names may be gone after.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Format`, `Info`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Inhibit("SD0:", true)) return dos_lib.IoErr();
/// defer _ = dos_lib.Inhibit("SD0:", false);
/// ```
pub fn Inhibit(db: *DosBase, drive: [*:0]const u8, on: bool) bool {
    const dos_lib = db.iface();
    const dp = dos_lib.GetDeviceProc(drive, null) orelse return false;
    defer dos_lib.FreeDeviceProc(dp);
    const port = dp.port orelse return _lock.failZero(db, dos.ERROR_DEVICE_NOT_MOUNTED) != 0;
    const flag: isize = if (on) dos.DOSTRUE else dos.DOSFALSE;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.inhibit), .{ flag, 0, 0, 0, 0 }) orelse
        return _lock.failZero(db, dos.ERROR_NO_FREE_STORE) != 0;
    if (answer.res1 == 0) {
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    return true;
}
