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
//! does its locking; exec's own lists are walked and changed under Forbid.
//!
//! **These are the one part of exec that calls itself directly** rather
//! than through the jump table (codex rule 1). The bootstrap builds exec
//! with them - the memory regions go on a list before there is a SysBase
//! to call a vector through - so `AddTail` reaching `Insert` through the
//! table would fault before the machine exists. The host tests use them on
//! bare lists with no system at all, for the same reason.

const sdk = @import("sdk");

const Node = sdk.exec.Node;
const List = sdk.exec.List;

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
