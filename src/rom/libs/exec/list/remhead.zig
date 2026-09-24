// SPDX-License-Identifier: MPL-2.0
//! RemHead: takes the first node off a list. Asking whether the list is
//! empty and taking the node are one call, so nothing can change between
//! the two.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const AddTail = @import("addtail.zig").AddTail;
const NewList = @import("newlist.zig").NewList;
const Remove = @import("remove.zig").Remove;

/// Takes the first node off a list and answers it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemHead(base: *ExecBase, list: *List) ?*Node
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `list` - the list to take from.
///
/// RESULT:
/// The node that was at the head, or null if the list was empty.
///
/// BEHAVIOR:
/// The test for empty is what makes this different from `Remove` on the
/// first node, and is why a queue is drained with this rather than by
/// asking whether the list is empty first - the question and the answer are
/// one call, so nothing can change between them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; the caller's locking is what decides.
/// - Forbid: not taken here, and the caller's to take.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The node is the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemTail`, `AddTail`, `GetMsg`
///
/// EXAMPLES:
/// ```zig
/// while (sys.RemHead(&list)) |node| {
///     // ... this one is ours now ...
/// }
/// ```
pub fn RemHead(base: *ExecBase, list: *List) ?*Node {
    const node = list.first() orelse return null;
    // Direct: exec's list calls run before there is a table (codex 1).
    Remove(base, node);
    return node;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "RemHead answers the first node, then null" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    try testing.expect(RemHead(base, &list) == null);
    var a: Node = .{};
    var b: Node = .{};
    AddTail(base, &list, &a);
    AddTail(base, &list, &b);
    try testing.expectEqual(&a, RemHead(base, &list).?);
    try testing.expectEqual(&b, RemHead(base, &list).?);
    try testing.expect(RemHead(base, &list) == null);
    try testing.expect(list.isEmpty());
}
