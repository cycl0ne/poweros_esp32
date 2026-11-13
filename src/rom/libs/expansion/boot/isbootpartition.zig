// SPDX-License-Identifier: MPL-2.0
//! IsBootPartition: whether a partition's identifier is the one the
//! firmware started this system from.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// Says whether a partition is the one the firmware read the kernel
/// from.
///
/// SYNOPSIS:
/// ```zig
/// fn IsBootPartition(eb: *ExpansionBase, guid: ?*const [16]u8) bool
/// ```
///
/// SINCE: 1.5. LVO -48.
///
/// INPUTS:
/// - `guid` - a partition's identifier, the sixteen bytes as they stand
///   in its disk's table (a GPT entry's unique identifier); null asks
///   whether the firmware named a partition at all.
///
/// RESULT:
/// True when the firmware named the partition it started this system
/// from (`SYSTAG_BootStart`'s `guid`) and `guid` is that one - or, for
/// null, when it named one.
///
/// BEHAVIOR:
/// A disk's driver asks this of each partition in the disk's table: the
/// disk that holds this partition is the one the system belongs on, and
/// the driver then names the system's drive on it with NoteBootDrive.
/// An identifier of all zeroes names no partition, so a machine whose
/// firmware says nothing answers false to everything.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NoteBootDrive`, `BootDrive`, `SystemTags`
///
/// EXAMPLES:
/// ```zig
/// for (entries) |entry| {
///     if (eb.IsBootPartition(&entry.unique_guid)) boot_disk = true;
/// }
/// ```
pub fn IsBootPartition(eb: *ExpansionBase, guid: ?*const [16]u8) bool {
    const start: ?*const st.BootStart = @ptrFromInt(eb.utility_base.GetTagData(st.SYSTAG_BootStart, 0, eb.system));
    const named = &(start orelse return false).guid;
    var any = false;
    for (named) |byte| {
        if (byte != 0) any = true;
    }
    if (!any) return false;
    const asked = guid orelse return true;
    for (named, asked) |want, have| {
        if (want != have) return false;
    }
    return true;
}
