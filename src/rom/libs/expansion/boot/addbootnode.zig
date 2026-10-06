// SPDX-License-Identifier: MPL-2.0
//! AddBootNode: a disk's device node into the system - onto dos's list if
//! dos is up, else kept until it is.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;
const _boot = @import("_boot.zig");

/// Puts a disk's device node into the system.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBootNode(eb: *ExpansionBase, boot_pri: i32, node: *dos.DosList) bool
/// ```
///
/// SINCE: 1.1. LVO -32.
///
/// INPUTS:
/// - `boot_pri` - where the disk stands when the boot disk is chosen:
///   the highest one is booted from, and -128 never is. A partition's
///   de_BootPri if it is bootable, else -128.
/// - `node` - a device node from MakeDosNode, its handler named.
///
/// RESULT:
/// True when the node is in: on dos's list, or kept for it. False when
/// there is no memory to keep it, or dos refused it - a node of that name
/// is there already.
///
/// BEHAVIOR:
/// **dos.library up** - it opens - the node goes onto its device list at
/// once, with AddDosEntry, and `boot_pri` says nothing: the system has
/// booted.
///
/// **dos.library not up yet** - a driver at cold start - the node is kept
/// on expansion's list of boot nodes, highest `boot_pri` first. dos's init
/// takes them all with EnterBootNodes, and boots from the first of them
/// above -128 that it took.
///
/// Both run under the boot nodes' semaphore, as EnterBootNodes does, so a
/// node is never kept after dos has taken the rest.
///
/// CONTEXT:
/// - Waits: for the boot nodes' semaphore, and in OpenLibrary and
///   AddDosEntry.
/// - Interrupts: no.
/// - Locks: takes the boot nodes' semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true the node is the system's: dos's once it is on its list, which
/// frees it with FreeDosEntry when it is removed. On false it is the
/// caller's again.
///
/// NOTES:
/// The handler is started the first time the device is used, not here.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeDosNode`, `EnterBootNodes`, dos.library `AddDosEntry`
///
/// EXAMPLES:
/// ```zig
/// const pri = if (pb.flags & hardblocks.PBFF_BOOTABLE != 0) pb.environment.boot_pri else -128;
/// if (!eb.AddBootNode(pri, node)) sys.FreeVec(node);
/// ```
pub fn AddBootNode(eb: *ExpansionBase, boot_pri: i32, node: *dos.DosList) bool {
    const sys = eb.sys_base;
    sys.ObtainSemaphore(&eb.boot_lock);
    defer sys.ReleaseSemaphore(&eb.boot_lock);
    if (_boot.openDos(eb)) |dos_base| {
        defer sys.CloseLibrary(dos_base.lib());
        return dos_base.AddDosEntry(node);
    }
    const memory = sys.AllocVec(@sizeOf(_boot.BootNode), exec.MEMF_CLEAR) orelse return false;
    const waiting: *_boot.BootNode = @ptrCast(@alignCast(memory));
    waiting.* = .{
        .node = .{ .pri = _boot.nodePri(boot_pri), .name = node.name },
        .device_node = node,
    };
    sys.Enqueue(&eb.boot_nodes, &waiting.node);
    return true;
}
