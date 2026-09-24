// SPDX-License-Identifier: MPL-2.0
//! Remove: takes a node off whatever list it is on. The list is not named,
//! because the node's own links reach both neighbours.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const AddTail = @import("addtail.zig").AddTail;
const NewList = @import("newlist.zig").NewList;

/// Takes a node off whatever list it is on.
///
/// SYNOPSIS:
/// ```zig
/// fn Remove(_: *ExecBase, node: *Node) void
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `node` - a node that is **on** a list. It is not checked, and removing
///   one that is not writes through whatever its links happen to hold.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list is not named because the node's own links are enough to find
/// its neighbours. Two pointer writes, and the node's own links are left as
/// they were - so a node just removed still points into the list and must
/// not be removed twice.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; the caller's locking is what decides.
/// - Forbid: not taken here, and the caller's to take.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The node is the caller's again and may now be
/// freed.
///
/// NOTES:
/// Removing while walking a list works, because the iterator reads the
/// successor before handing a node over.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemHead`, `RemTail`, `Insert`
///
/// EXAMPLES:
/// ```zig
/// sys.Remove(&node);
/// ```
pub fn Remove(_: *ExecBase, node: *Node) void {
    node.pred.?.succ = node.succ;
    node.succ.?.pred = node.pred;
}

// --- tests (host: ./zig build test) -----------------------------------------

test "Remove takes a node out of the middle" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var a: Node = .{};
    var b: Node = .{};
    var c: Node = .{};
    for ([_]*Node{ &a, &b, &c }) |node| AddTail(base, &list, node);
    Remove(base, &b);
    try _list.expectOrder(&list, &.{ &a, &c });
}

test "Remove while iterating empties the list" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var nodes = [_]Node{ .{}, .{}, .{} };
    for (&nodes) |*node| AddTail(base, &list, node);
    var it = list.iterator();
    while (it.next()) |node| Remove(base, node);
    try @import("std").testing.expect(list.isEmpty());
}
