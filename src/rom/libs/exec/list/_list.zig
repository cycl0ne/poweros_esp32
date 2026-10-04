// SPDX-License-Identifier: MPL-2.0
//! Exec lists: doubly linked, and the list header doubles as the sentinel
//! node at both ends, so inserting and removing never test for the ends of
//! the list - the head insert and the middle insert are the same four
//! pointer writes. Node and List are the SDK's (sdk/libs/exec/nodes.zig,
//! sdk/libs/exec/lists.zig).
//!
//! Each call is a file of its own in this folder, named after it, with its
//! own tests; this file holds what their tests share. `Insert` is the
//! primitive: `AddHead`, `AddTail` and `Enqueue` choose a predecessor and
//! hand over to it, and `RemHead` and `RemTail` find a node and hand it to
//! `Remove`.
//!
//! Nothing here locks anything. The list belongs to whoever made it and so
//! does its locking; exec's own lists are each under a lock of their own,
//! which `LockExecList` takes for a program that walks one (`execList`
//! below says which).
//!
//! **These are the one part of exec that calls itself directly** rather
//! than through the jump table (codex rule 1). The bootstrap builds exec
//! with them - the memory regions go on a list before there is a SysBase
//! to call a vector through - so `AddTail` reaching `Insert` through the
//! table would fault before the machine exists. The host tests use them on
//! bare lists with no system at all, for the same reason.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;

// --- exec's own lists -------------------------------------------------------

/// How one of exec's lists is locked: the semaphore for the lists whose
/// holder runs other code, a spinlock for those taken on every call, and
/// Disable for the task queues, which the scheduler moves in exceptions.
pub const ListLock = enum { libraries, mem_handlers, memory, ports, semaphores, tasks };

/// One of exec's lists by number (`EXECLIST_*`), and its lock; null for a
/// number exec has no list for.
///
/// INPUTS:
/// - `base` - exec: its lists.
/// - `which` - the list's number.
pub fn execList(base: *ExecBase, which: u32) ?struct { list: *List, lock: ListLock } {
    return switch (which) {
        sdk.exec.EXECLIST_MEMORY => .{ .list = &base.mem_list, .lock = .memory },
        sdk.exec.EXECLIST_LIBRARIES => .{ .list = &base.lib_list, .lock = .libraries },
        sdk.exec.EXECLIST_DEVICES => .{ .list = &base.device_list, .lock = .libraries },
        sdk.exec.EXECLIST_RESOURCES => .{ .list = &base.resource_list, .lock = .libraries },
        sdk.exec.EXECLIST_PORTS => .{ .list = &base.port_list, .lock = .ports },
        sdk.exec.EXECLIST_SEMAPHORES => .{ .list = &base.sem_list, .lock = .semaphores },
        sdk.exec.EXECLIST_TASK_READY => .{ .list = &base.task_ready, .lock = .tasks },
        sdk.exec.EXECLIST_TASK_WAIT => .{ .list = &base.task_wait, .lock = .tasks },
        sdk.exec.EXECLIST_MEM_HANDLERS => .{ .list = &base.mem_handlers, .lock = .mem_handlers },
        else => null,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");

/// Asserts that `list` holds exactly `expected`, in that order, walked both
/// ways - so a link written wrong in either direction is caught. For the
/// tests in this folder.
pub fn expectOrder(list: *List, expected: []const *Node) !void {
    var it = list.iterator();
    for (expected) |want| try std.testing.expectEqual(want, it.next().?);
    try std.testing.expect(it.next() == null);

    var node = list.tail_pred.?;
    var index = expected.len;
    while (index > 0) : (index -= 1) {
        try std.testing.expectEqual(expected[index - 1], node);
        node = node.pred.?;
    }
    try std.testing.expectEqual(list.headNode(), node);
}
