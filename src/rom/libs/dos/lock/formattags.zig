// SPDX-License-Identifier: MPL-2.0
//! FormatTags: a fresh, empty volume over the medium in a drive, with
//! FORMAT_* tags.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const TagItem = sdk.utility.TagItem;

/// Writes a fresh, empty volume over the medium in a drive, as a tag list
/// says.
///
/// SYNOPSIS:
/// ```zig
/// fn FormatTags(db: *DosBase, drive: [*:0]const u8, name: ?[*:0]const u8, dos_type: u32, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 1.9. LVO -604.
///
/// INPUTS:
/// - `drive` - the drive's device, with its colon (`SD0:`).
/// - `name` - the new volume's name, without a colon: one to 30
///   characters, none of them `:` or `/`. Null for the file system's own:
///   none on FAT, `Empty` on the flash file system and on posfs.
/// - `dos_type` - the format, for a file system that writes more than one;
///   0 for the drive's own. A FAT drive takes its own DosType with the
///   last byte `FORMAT_FAT32`, `FORMAT_EXFAT` or `FORMAT_BY_SIZE`
///   (`sdk.dos.fat.typeWithFormat`).
/// - `tags` - FORMAT_* tags, or null for none:
///   - `FORMAT_BlockSize` - the volume's unit of allocation in bytes, a
///     power of two: posfs's block (4096 to 65536, and on the flash a
///     multiple of its sector), FAT's cluster (one sector to 32 KiB on
///     FAT32, to 32 MiB on exFAT, and as many clusters as the format
///     needs). 0, or the tag left out, for the file system's own choice.
///     The flash file system has the one size, its sector.
///
/// RESULT:
/// True when the volume is written; false with IoErr saying why -
/// `ERROR_INVALID_COMPONENT_NAME` for a name that cannot be a volume's, or
/// what the handler answered: `ERROR_OBJECT_IN_USE` for a drive that is
/// not inhibited and has a volume, or one with something on it locked;
/// `ERROR_NO_DISK`; `ERROR_DISK_WRITE_PROTECTED`; `ERROR_INVALID_ARGUMENT`
/// for a format the medium cannot have, a DosType the handler does not
/// write or a FORMAT_BlockSize it cannot have; `ERROR_INVALID_COMPONENT_NAME` for a name its format cannot
/// hold; `ERROR_ACTION_NOT_KNOWN` from a handler that cannot format.
///
/// BEHAVIOR:
/// `ACTION_FORMAT` to the drive's handler, with the name, the DosType and
/// the tags. The handler reads the tags it knows and passes the others
/// by; it refuses what it can before it writes anything, then lays the
/// volume out over the drive's area as its startup message gives it - the whole medium, or the blocks its node names. Everything
/// that was on the area is gone. An inhibited drive keeps the new volume
/// until the last inhibit is taken back; one that held no volume mounts
/// it at once.
///
/// CONTEXT:
/// - Waits: yes, for the handler, which writes the volume's structures -
///   on a large card a few seconds.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the device list.
/// - Process: a Process.
///
/// OWNERSHIP:
/// `name` is read while the call lasts.
///
/// NOTES:
/// Inhibit the drive first: a drive whose volume is in use refuses. The
/// medium is taken as it is - nothing is erased or checked block by block
/// - so a format of a large card is quick.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Format`, `Inhibit`, `Relabel`, `Info`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{
///     .{ .tag = dos.FORMAT_BlockSize, .data = 16384 },
///     .{ .tag = sdk.utility.TAG_DONE, .data = 0 },
/// };
/// if (dos_lib.Inhibit("SD0:", true)) {
///     if (!dos_lib.FormatTags("SD0:", "Photos", 0, &tags)) _ = dos_lib.PrintFault(dos_lib.IoErr(), "Format");
///     _ = dos_lib.Inhibit("SD0:", false);
/// }
/// ```
pub fn FormatTags(db: *DosBase, drive: [*:0]const u8, name: ?[*:0]const u8, dos_type: u32, tags: ?[*]const TagItem) bool {
    const dos_lib = db.iface();
    if (name) |given| {
        const len = db.utility_base.Strlen(given);
        if (!dos.volumename.valid(given[0..len])) return _lock.failZero(db, dos.ERROR_INVALID_COMPONENT_NAME) != 0;
    }
    const dp = dos_lib.GetDeviceProc(drive, null) orelse return false;
    defer dos_lib.FreeDeviceProc(dp);
    const port = dp.port orelse return _lock.failZero(db, dos.ERROR_DEVICE_NOT_MOUNTED) != 0;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.format), .{
        @bitCast(@intFromPtr(name)),
        @bitCast(@as(usize, dos_type)),
        @bitCast(@intFromPtr(tags)),
        0,
        0,
    }) orelse return _lock.failZero(db, dos.ERROR_NO_FREE_STORE) != 0;
    if (answer.res1 == 0) {
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    return true;
}
