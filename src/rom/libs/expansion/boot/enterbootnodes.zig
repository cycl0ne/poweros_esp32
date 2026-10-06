// SPDX-License-Identifier: MPL-2.0
//! EnterBootNodes: every device node AddBootNode kept, onto dos's list,
//! and the one to boot from.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;
const _boot = @import("_boot.zig");

/// Hands dos.library the disks' device nodes kept for it, and says which
/// one to boot from.
///
/// SYNOPSIS:
/// ```zig
/// fn EnterBootNodes(eb: *ExpansionBase) ?*dos.DosList
/// ```
///
/// SINCE: 1.1. LVO -36.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The node to boot from: the first one taken whose boot priority is
/// above -128. Null when there is none, or dos.library is not up.
///
/// BEHAVIOR:
/// dos.library's, called once by its init, as soon as dos is on the
/// library list. Every node AddBootNode kept goes onto dos's device list
/// with AddDosEntry, highest boot priority first, and the list is left
/// empty: every node added from now on goes onto dos's list at once.
///
/// A node dos refuses - one of that name is there already - is freed.
///
/// CONTEXT:
/// - Waits: for the boot nodes' semaphore, and in OpenLibrary and
///   AddDosEntry.
/// - Interrupts: no.
/// - Locks: takes the boot nodes' semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The nodes become dos's; the one answered is on dos's list.
///
/// NOTES:
/// Without dos.library up it does nothing, and the nodes stay kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBootNode`, `MakeDosNode`
///
/// EXAMPLES:
/// ```zig
/// const boot = eb.EnterBootNodes() orelse return;
/// // boot.name is the system disk: SYS: goes there.
/// ```
pub fn EnterBootNodes(eb: *ExpansionBase) ?*dos.DosList {
    const sys = eb.sys_base;
    sys.ObtainSemaphore(&eb.boot_lock);
    defer sys.ReleaseSemaphore(&eb.boot_lock);
    const dos_base = _boot.openDos(eb) orelse return null;
    defer sys.CloseLibrary(dos_base.lib());
    var boot: ?*dos.DosList = null;
    while (sys.RemHead(&eb.boot_nodes)) |head| {
        const waiting: *_boot.BootNode = @fieldParentPtr("node", head);
        const node = waiting.device_node;
        const bootable = waiting.node.pri > -128;
        sys.FreeVec(waiting);
        if (!dos_base.AddDosEntry(node)) {
            sys.FreeVec(node);
            continue;
        }
        if (boot == null and bootable) boot = node;
    }
    return boot;
}
