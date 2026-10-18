// SPDX-License-Identifier: MPL-2.0
//! Format: a fresh, empty volume over the medium in a drive.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;

/// Writes a fresh, empty volume over the medium in a drive.
///
/// SYNOPSIS:
/// ```zig
/// fn Format(db: *DosBase, drive: [*:0]const u8, name: ?[*:0]const u8, dos_type: u32) bool
/// ```
///
/// SINCE: 1.8. LVO -592.
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
///
/// RESULT:
/// True when the volume is written; false with IoErr saying why -
/// `ERROR_INVALID_COMPONENT_NAME` for a name that cannot be a volume's, or
/// what the handler answered: `ERROR_OBJECT_IN_USE` for a drive that is
/// not inhibited and has a volume, or one with something on it locked;
/// `ERROR_NO_DISK`; `ERROR_DISK_WRITE_PROTECTED`; `ERROR_INVALID_ARGUMENT`
/// for a format the medium cannot have or a DosType the handler does not
/// write; `ERROR_INVALID_COMPONENT_NAME` for a name its format cannot
/// hold; `ERROR_ACTION_NOT_KNOWN` from a handler that cannot format.
///
/// BEHAVIOR:
/// FormatTags with no tags: `ACTION_FORMAT` to the drive's handler, with
/// the name and the DosType, and the file system's own choice of
/// everything else. The handler refuses what it can before it writes
/// anything, then lays the volume out over the drive's area as its startup
/// message gives it - the whole medium, or the blocks its node names.
/// Everything that was on the area is gone. An inhibited drive keeps the new volume
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
/// `FormatTags`, `Inhibit`, `Relabel`, `Info`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.Inhibit("SD0:", true)) {
///     if (!dos_lib.Format("SD0:", "Photos", 0)) _ = dos_lib.PrintFault(dos_lib.IoErr(), "Format");
///     _ = dos_lib.Inhibit("SD0:", false);
/// }
/// ```
pub fn Format(db: *DosBase, drive: [*:0]const u8, name: ?[*:0]const u8, dos_type: u32) bool {
    return db.iface().FormatTags(drive, name, dos_type, null);
}
