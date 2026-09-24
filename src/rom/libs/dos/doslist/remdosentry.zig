// SPDX-License-Identifier: MPL-2.0
//! RemDosEntry: takes a node off the device list.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DosList = dos.DosList;

/// Takes a node off the device list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemDosEntry(db: *DosBase, dlist: *DosList) bool
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `dlist` - the node.
///
/// RESULT:
/// True if it was on the list and is off it now; false if it wasn't there.
///
/// BEHAVIOR:
/// The entry and delete locks (LDF_ENTRY | LDF_DELETE | LDF_WRITE) are
/// taken for the call, so no handler is being started for the node and
/// nobody else is removing one. The node's `next` is cleared.
///
/// CONTEXT:
/// - Waits: yes, for the entry and delete locks.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do. The caller holds the list with LDF_WRITE.
///
/// OWNERSHIP:
/// The node is the caller's again, to free with FreeDosEntry or put back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddDosEntry`, `FreeDosEntry`, `LockDosList`
///
/// EXAMPLES:
/// ```zig
/// const flags = dos.LDF_ASSIGNS | dos.LDF_WRITE;
/// const list = dos_lib.LockDosList(flags).?;
/// if (dos_lib.FindDosEntry(list, "WORK", dos.LDF_ASSIGNS)) |node| {
///     if (dos_lib.RemDosEntry(node)) dos_lib.FreeDosEntry(node);
/// }
/// dos_lib.UnLockDosList(flags);
/// ```
pub fn RemDosEntry(db: *DosBase, dlist: *DosList) bool {
    const dos_lib = db.iface();
    const flags = dos.LDF_DELETE | dos.LDF_ENTRY | dos.LDF_WRITE;
    _ = dos_lib.LockDosList(flags);
    defer dos_lib.UnLockDosList(flags);
    var link: *?*DosList = &db.dos_list.next;
    while (link.*) |n| : (link = &n.next) {
        if (n == dlist) {
            link.* = n.next;
            n.next = null;
            return true;
        }
    }
    return false;
}
