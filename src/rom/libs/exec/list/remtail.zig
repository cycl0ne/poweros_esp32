// SPDX-License-Identifier: MPL-2.0
//! RemTail: takes the last node off a list. With `AddTail` it makes a
//! stack.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const AddTail = @import("addtail.zig").AddTail;
const NewList = @import("newlist.zig").NewList;
const Remove = @import("remove.zig").Remove;

/// Takes the last node off a list and answers it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemTail(base: *ExecBase, list: *List) ?*Node
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `list` - the list to take from.
///
/// RESULT:
/// The node that was at the tail, or null if the list was empty.
///
/// BEHAVIOR:
/// With `AddTail` it makes a stack, as with `RemHead` it makes a queue.
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
/// `RemHead`, `AddTail`
///
/// EXAMPLES:
/// ```zig
/// const last = sys.RemTail(&list) orelse return;
/// ```
pub fn RemTail(base: *ExecBase, list: *List) ?*Node {
    const node = list.last() orelse return null;
    // Direct: exec's list calls run before there is a table (codex 1).
    Remove(base, node);
    return node;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "RemTail answers the last node, then null" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    try testing.expect(RemTail(base, &list) == null);
    var a: Node = .{};
    var b: Node = .{};
    AddTail(base, &list, &a);
    AddTail(base, &list, &b);
    try testing.expectEqual(&b, RemTail(base, &list).?);
    try testing.expectEqual(&a, RemTail(base, &list).?);
    try testing.expect(RemTail(base, &list) == null);
    try testing.expect(list.isEmpty());
}
