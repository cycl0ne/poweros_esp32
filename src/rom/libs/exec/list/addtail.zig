// SPDX-License-Identifier: MPL-2.0
//! AddTail: puts a node at the tail of a list, as `Insert` behind the last
//! node. With `RemHead` it makes a queue that keeps its order.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const Insert = @import("insert.zig").Insert;
const NewList = @import("newlist.zig").NewList;

/// Puts a node at the tail of a list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddTail(base: *ExecBase, list: *List, node: *Node) void
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `list` - the list to add to.
/// - `node` - the node to add. Not already on a list.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `Insert` behind the last node. With `RemHead` it makes a queue that
/// keeps its order, which is what a message port is.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddHead`, `RemHead`, `Enqueue`
///
/// EXAMPLES:
/// ```zig
/// sys.AddTail(&list, &node);
/// ```
pub fn AddTail(base: *ExecBase, list: *List, node: *Node) void {
    // Direct: the bootstrap lists memory before there is a table (codex 1).
    Insert(base, list, node, list.tail_pred);
}

// --- tests (host: ./zig build test) -----------------------------------------

test "AddTail keeps the order nodes were added in" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var a: Node = .{ .pri = -5 };
    var b: Node = .{ .pri = 5 };
    AddTail(base, &list, &a);
    AddTail(base, &list, &b);
    try _list.expectOrder(&list, &.{ &a, &b });
}
