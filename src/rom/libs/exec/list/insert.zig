// SPDX-License-Identifier: MPL-2.0
//! Insert: puts a node on a list behind a given one. It is the one
//! primitive the adding calls are built on - `AddHead`, `AddTail` and
//! `Enqueue` each choose a predecessor and hand over to it.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const NewList = @import("newlist.zig").NewList;

/// Puts a node on a list after a given node.
///
/// SYNOPSIS:
/// ```zig
/// fn Insert(_: *ExecBase, list: *List, node: *Node, pred: ?*Node) void
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `list` - the list to insert into.
/// - `node` - the node to insert. Not already on a list.
/// - `pred` - the node to go behind, which must be on `list`; null puts it
///   at the head.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Four pointer writes and no test for the ends, because the list header is
/// the sentinel at both: inserting at the head and inserting in the middle
/// are the same four writes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; the caller's locking is what decides.
/// - Forbid: not taken here. Needed by the caller on any list another task
///   may be walking.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list now holds the node, which must outlive
/// its place on it.
///
/// NOTES:
/// Four pointer writes and no test for the ends: with no predecessor the
/// list header's head sentinel stands in for one, so the head insert and
/// the middle insert are the same writes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddHead`, `AddTail`, `Enqueue`, `Remove`
///
/// EXAMPLES:
/// ```zig
/// sys.Insert(&list, &node, after);
/// ```
pub fn Insert(_: *ExecBase, list: *List, node: *Node, pred: ?*Node) void {
    const before = pred orelse list.headNode();
    const after = before.succ.?;
    node.succ = after;
    node.pred = before;
    after.pred = node;
    before.succ = node;
}

// --- tests (host: ./zig build test) -----------------------------------------

test "Insert: null goes to the head, a predecessor puts it behind" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var a: Node = .{};
    var b: Node = .{};
    var c: Node = .{};
    Insert(base, &list, &c, null);
    Insert(base, &list, &a, null);
    Insert(base, &list, &b, &a);
    try _list.expectOrder(&list, &.{ &a, &b, &c });
}
