// SPDX-License-Identifier: MPL-2.0
//! Enqueue: puts a node on a list in priority order, highest at the head.
//! It walks from the head to find its place and hands over to `Insert`, so
//! it is the one list call whose cost grows with the list.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const Insert = @import("insert.zig").Insert;
const NewList = @import("newlist.zig").NewList;

/// Puts a node on a list in priority order.
///
/// SYNOPSIS:
/// ```zig
/// fn Enqueue(base: *ExecBase, list: *List, node: *Node) void
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `list` - a list already in priority order. On a list that is not, the
///   result is not ordered either: this places one node, it does not sort.
/// - `node` - the node to add, its `pri` already set. Not already on a list.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It walks from the head and goes in behind every node of the same or
/// higher priority - so equal priorities keep the order they were added in,
/// first in nearer the head. That fairness is what makes a ready queue of
/// equal-priority tasks round-robin rather than starving the later ones.
///
/// Highest priority at the head is why `FindName` answering the first match
/// answers the best one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; the caller's locking is what decides.
/// - Forbid: not taken here, and the caller's to take.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list now holds the node.
///
/// NOTES:
/// It walks the list, so it is the one list call whose cost grows with the
/// list's length.
///
/// It goes in behind every node of the same or higher priority, so equal
/// priorities keep the order they arrived in - which is what makes a ready
/// queue of equal tasks round-robin.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTail`, `FindName`, `AddLibrary`, `AddIntServer`
///
/// EXAMPLES:
/// ```zig
/// node.pri = 10;
/// sys.Enqueue(&list, &node);
/// ```
pub fn Enqueue(base: *ExecBase, list: *List, node: *Node) void {
    var pred: ?*Node = null;
    var it = list.iterator();
    while (it.next()) |on_list| {
        if (on_list.pri < node.pri) break;
        pred = on_list;
    }
    // Direct: the bootstrap lists memory before there is a table (codex 1).
    Insert(base, list, node, pred);
}

// --- tests (host: ./zig build test) -----------------------------------------

test "Enqueue sorts by priority, first in first within a priority" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var low: Node = .{ .pri = -5 };
    var mid1: Node = .{ .pri = 0 };
    var high: Node = .{ .pri = 10 };
    var mid2: Node = .{ .pri = 0 };
    for ([_]*Node{ &low, &mid1, &high, &mid2 }) |node| Enqueue(base, &list, node);
    try _list.expectOrder(&list, &.{ &high, &mid1, &mid2, &low });
}
