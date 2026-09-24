// SPDX-License-Identifier: MPL-2.0
//! AddDosEntry: puts a node on the device list.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const conflicts = _doslist.conflicts;
const DosList = dos.DosList;

/// Puts a device, volume or assign node on the device list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddDosEntry(db: *DosBase, dlist: *DosList) bool
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `dlist` - the node, from MakeDosEntry, not on the list.
///
/// RESULT:
/// True if it is on the list; false with IoErr() ERROR_OBJECT_EXISTS if its
/// name is taken.
///
/// BEHAVIOR:
/// Names are compared without case. A name is taken by any node of that
/// name, except that a volume may sit beside a device or an assign of its
/// name, and beside another volume of its name with a different creation
/// date - two disks of one name are two volumes. The node goes at the front
/// of the list. The list is locked with LDF_ALL | LDF_WRITE for the call.
///
/// CONTEXT:
/// - Waits: yes, for the device list's semaphores.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the list's from now on, until RemDosEntry takes it off.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeDosEntry`, `RemDosEntry`, `FindDosEntry`
///
/// EXAMPLES:
/// ```zig
/// const node = dos_lib.MakeDosEntry("WORK", dos.DLT_DIRECTORY) orelse return false;
/// if (!dos_lib.AddDosEntry(node)) {
///     dos_lib.FreeDosEntry(node);
///     return false;
/// }
/// ```
pub fn AddDosEntry(db: *DosBase, dlist: *DosList) bool {
    const dos_lib = db.iface();
    const flags = dos.LDF_ALL | dos.LDF_WRITE;
    _ = dos_lib.LockDosList(flags);
    defer dos_lib.UnLockDosList(flags);
    var node = db.dos_list.next;
    while (node) |n| : (node = n.next) {
        if (db.utility_base.Stricmp(n.name, dlist.name) != 0) continue;
        if (conflicts(n, dlist)) {
            _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_EXISTS);
            return false;
        }
    }
    dlist.next = db.dos_list.next;
    db.dos_list.next = dlist;
    return true;
}
