// SPDX-License-Identifier: MPL-2.0
//! AddHead: puts a node at the head of a list, as `Insert` with no
//! predecessor.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const Insert = @import("insert.zig").Insert;
const NewList = @import("newlist.zig").NewList;

/// Puts a node at the head of a list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddHead(base: *ExecBase, list: *List, node: *Node) void
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `list` - the list to add to.
/// - `node` - the node to add. Not already on a list.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `Insert` with no predecessor. The node's priority is not looked at, so a
/// list kept in priority order must be added to with `Enqueue` instead.
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
/// `AddTail`, `RemHead`, `Insert`
///
/// EXAMPLES:
/// ```zig
/// sys.AddHead(&list, &node);
/// ```
pub fn AddHead(base: *ExecBase, list: *List, node: *Node) void {
    // Direct: the bootstrap lists memory before there is a table (codex 1).
    Insert(base, list, node, null);
}

// --- tests (host: ./zig build test) -----------------------------------------

test "AddHead puts each node in front of the last" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var a: Node = .{ .pri = -5 };
    var b: Node = .{ .pri = 5 };
    AddHead(base, &list, &a);
    AddHead(base, &list, &b);
    try _list.expectOrder(&list, &.{ &b, &a });
}
