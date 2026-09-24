// SPDX-License-Identifier: MPL-2.0
//! NextDosEntry: the next node of some types on the device list.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DosList = dos.DosList;

/// Finds the node after a given one that is of some types.
///
/// SYNOPSIS:
/// ```zig
/// fn NextDosEntry(db: *DosBase, dlist: *DosList, flags: u32) ?*DosList
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `dlist` - the node to go on from, or the head LockDosList gave.
/// - `flags` - the types, as for FindDosEntry.
///
/// RESULT:
/// The next matching node, or null at the end of the list.
///
/// BEHAVIOR:
/// FindDosEntry from the node after `dlist`, for any name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do. The caller holds the list (LockDosList).
///
/// OWNERSHIP:
/// As FindDosEntry.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindDosEntry`, `LockDosList`
///
/// EXAMPLES:
/// ```zig
/// var node = dos_lib.NextDosEntry(list, dos.LDF_VOLUMES);
/// while (node) |volume| : (node = dos_lib.NextDosEntry(volume, dos.LDF_VOLUMES)) {
///     show(volume.name);
/// }
/// ```
pub fn NextDosEntry(db: *DosBase, dlist: *DosList, flags: u32) ?*DosList {
    const dos_lib = db.iface();
    return dos_lib.FindDosEntry(dlist.next orelse return null, null, flags);
}
