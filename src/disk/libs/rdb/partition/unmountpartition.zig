// SPDX-License-Identifier: MIT
//! UnmountPartition: a drive this handle's unit was mounted as taken off
//! dos's list again, the other half of MountPartition and
//! MountGPTPartition.
//!
//! A program that mounts a partition to do one thing with it - write a
//! kernel into the partition the firmware reads, look at what a medium
//! holds - leaves the drive on the list for the rest of the system's
//! life unless it can take it off again. This takes it off: the handler
//! is asked to end, which is where it writes what it still holds and
//! lets go of the unit, and the node it served goes with it.
//!
//! The drive is found by name and must open this handle's device and
//! unit, so one program cannot take another medium's drive off the list
//! by naming it. The check that nothing has it and the removal are done
//! under one lock of the list, as the mounting was.
//!
//! The code of a file system the table brought is freed with the last
//! node that uses it: the nodes of one unit's partitions share one
//! entry, so it is freed only when no other node on the list points at
//! the same one.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");

/// The list locked for the check and the removal as one.
const list_lock = dos.LDF_DEVICES | dos.LDF_WRITE;

/// How long the node is waited for after the handler has answered, a
/// tick at a time. A handler answers ACTION_DIE as the last thing its
/// code does, so dos counts the code's user down a moment later, when
/// the process has really ended - and only then is the node free to go.
const ending_ticks = 50;

/// Takes a drive of this handle's unit off dos's list, ending its
/// handler.
///
/// SYNOPSIS:
/// ```zig
/// fn UnmountPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.8. LVO -96.
///
/// INPUTS:
/// - `handle`: from OpenRDB, open on the device and unit the drive was
///   mounted from.
/// - `name`: the drive, without a colon, as MountPartition or
///   MountGPTPartition left it in `name`/`mounted` - which is not always
///   the name asked for, since a taken name gets dots.
///
/// RESULT:
/// RDBERR_OK, or RDBERR_NOTMOUNTED when no drive of that name opens this
/// handle's unit, RDBERR_INUSE when its handler will not end or
/// something reached the drive while it was ending, RDBERR_NOMEM when
/// dos.library cannot be opened.
///
/// BEHAVIOR:
/// The drive is looked for on the list by name. One that is there but
/// opens another device or unit is not this handle's and is left alone,
/// with RDBERR_NOTMOUNTED - a drive is matched the way MountPartition
/// matches one, by what the device is called and the unit it opens.
///
/// A handler that is running is sent ACTION_DIE, which it answers once
/// it has written what it holds and taken its volume off the list; one
/// that refuses, because a file or a lock is open on the drive, leaves
/// everything as it was and answers RDBERR_INUSE. A node whose handler
/// was never started is taken off without a packet.
///
/// The node is then removed under the list's lock, so a program that
/// reached the drive in between is not left holding a node that is going
/// away: a drive that has a task or a user again at that moment answers
/// RDBERR_INUSE, and the handler is the next use's to start.
///
/// A handler answers that packet as the last thing its code does, so for
/// a moment after the answer its process is still running the code dos
/// loaded and the node still counts it as a user. The node is waited for
/// over that moment, a tick at a time and half a second at most, rather
/// than called in use: what the answer promised has happened, and only
/// the ending itself is still in the way.
///
/// CONTEXT:
/// - Waits: yes, for the dos list's lock and for the handler's answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the dos list.
/// - Process: a Process, since the handler is sent a packet.
///
/// OWNERSHIP:
/// The node and the copy of the table's code the mounting made are
/// freed; a pointer to either is no use afterwards. The handle stays the
/// caller's.
///
/// NOTES:
/// The library stays in memory once anything has been mounted, since the
/// nodes still on the list name their handler by a string it holds.
///
/// A drive somebody else mounted from the same unit is taken off as
/// readily as one's own: the unit is what is checked, not who asked for
/// the mount.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MountPartition`, `MountGPTPartition`, `OpenRDB`
///
/// EXAMPLES:
/// ```zig
/// var name: rdb.MountName = undefined;
/// if (rb.MountGPTPartition(handle, part, "BOOT", &name, rdb.RDBMF_START | rdb.RDBMF_FAT) != rdb.RDBERR_OK) return;
/// defer _ = rb.UnmountPartition(handle, @ptrCast(&name));
/// // ... write the firmware's files into it ...
/// ```
pub fn UnmountPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) i32 {
    const sys = base.sys_base;
    const private = _handle.handleOf(handle);
    const device = private.device orelse return rdb.RDBERR_NOTMOUNTED;

    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    // Whose drive it is, and whether a handler is serving it: both read
    // under the list's own lock, and the packet sent without it, since a
    // handler answers while others ask the list for things.
    const read_lock = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(read_lock) orelse return rdb.RDBERR_NOMEM;
    const found = dl.FindDosEntry(list, name, dos.LDF_DEVICES);
    const ours = if (found) |node| oursToTake(node, device, private.unit) else false;
    const port = if (ours) found.?.task else null;
    dl.UnLockDosList(read_lock);
    if (!ours) return rdb.RDBERR_NOTMOUNTED;

    if (port) |handler| {
        if (dl.DoPkt(handler, @intFromEnum(dos.ActionCode.die), 0, 0, 0, 0, 0) == dos.DOSFALSE)
            return rdb.RDBERR_INUSE;
        // Its process is ending now; the node is taken as soon as it has.
        var waited: u32 = 0;
        while (true) {
            const code = take(sys, dl, name, device, private.unit);
            if (code != rdb.RDBERR_INUSE or waited >= ending_ticks) return code;
            waited += 1;
            dl.Delay(1);
        }
    }
    return take(sys, dl, name, device, private.unit);
}

/// Whether a node is a drive of this device and unit: the startup a
/// mounting left on it says which unit it opens.
fn oursToTake(node: *dos.DosList, device: [*:0]const u8, unit: u32) bool {
    const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse return false;
    return dos.filehandler.opensUnit(startup, device, unit);
}

/// The node off the list and freed, with the code of a file system no
/// other node has: found again under the write lock, since the handler
/// answered without it.
fn take(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, device: [*:0]const u8, unit: u32) i32 {
    const list = dl.LockDosList(list_lock) orelse return rdb.RDBERR_NOMEM;
    const node = dl.FindDosEntry(list, name, dos.LDF_DEVICES) orelse {
        dl.UnLockDosList(list_lock);
        return rdb.RDBERR_NOTMOUNTED;
    };
    if (!oursToTake(node, device, unit)) {
        dl.UnLockDosList(list_lock);
        return rdb.RDBERR_NOTMOUNTED;
    }
    // Two words, each read whole under the lock: the handler lets go of
    // its port under it, and its users are counted down before.
    if (node.task != null or node.misc.handler.users != 0) {
        dl.UnLockDosList(list_lock);
        return rdb.RDBERR_INUSE;
    }
    const entry = node.misc.handler.file_sys;
    const last = if (entry) |one| lastUser(dl, list, node, one) else false;
    const removed = dl.RemDosEntry(node);
    dl.UnLockDosList(list_lock);
    if (!removed) return rdb.RDBERR_INUSE;
    // The node is one block of expansion.library's making, the names and
    // the startup in it.
    sys.FreeVec(node);
    if (last) {
        sys.FreeVec(entry.?.image);
        sys.FreeVec(entry.?);
    }
    return rdb.RDBERR_OK;
}

/// Whether this node is the only one left pointing at that file system's
/// entry, so that its code goes with it. The list is the caller's lock.
fn lastUser(dl: *DosBase, list: *dos.DosList, mine: *dos.DosList, entry: *dos.FileSysEntry) bool {
    var walk = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (walk) |node| : (walk = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        if (node == mine) continue;
        if (node.misc.handler.file_sys == entry) return false;
    }
    return true;
}
