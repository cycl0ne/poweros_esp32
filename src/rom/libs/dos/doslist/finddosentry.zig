// SPDX-License-Identifier: MPL-2.0
//! FindDosEntry: finds a node on the device list by type and name.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const typeFlag = _doslist.typeFlag;
const DosList = dos.DosList;

/// Finds the first node of some types, and optionally of a name, from a
/// node on.
///
/// SYNOPSIS:
/// ```zig
/// fn FindDosEntry(db: *DosBase, dlist: *DosList, name: ?[*:0]const u8, flags: u32) ?*DosList
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `dlist` - where to start: the head LockDosList gave, or a node found
///   before (it is itself looked at).
/// - `name` - the name, without the colon, in any case; null for any name.
/// - `flags` - the types: LDF_DEVICES, LDF_VOLUMES, LDF_ASSIGNS; other bits
///   are ignored.
///
/// RESULT:
/// The node, or null if none from `dlist` on matches.
///
/// BEHAVIOR:
/// Directory, late and non-binding assigns all answer to LDF_ASSIGNS. The
/// head node and private nodes are never found. Names are compared without
/// case.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do. The caller holds the list (LockDosList).
///
/// OWNERSHIP:
/// The node stays the list's; it is valid while the list is locked.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockDosList`, `NextDosEntry`
///
/// EXAMPLES:
/// ```zig
/// const list = dos_lib.LockDosList(dos.LDF_DEVICES | dos.LDF_READ).?;
/// const found = dos_lib.FindDosEntry(list, "DH0", dos.LDF_DEVICES) != null;
/// dos_lib.UnLockDosList(dos.LDF_DEVICES | dos.LDF_READ);
/// ```
pub fn FindDosEntry(db: *DosBase, dlist: *DosList, name: ?[*:0]const u8, flags: u32) ?*DosList {
    var node: ?*DosList = dlist;
    while (node) |n| : (node = n.next) {
        if (typeFlag(n) & flags == 0) continue;
        if (name) |wanted| {
            if (db.utility_base.Stricmp(n.name, wanted) != 0) continue;
        }
        return n;
    }
    return null;
}
