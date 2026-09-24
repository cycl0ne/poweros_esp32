// SPDX-License-Identifier: MPL-2.0
//! NewList: makes a list header empty. The two sentinels are pointed at
//! each other, which is what an empty list is; the work is the SDK's
//! `newList`, so a program that sets up a list without exec and exec itself
//! share one implementation.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;

/// Makes a list empty and ready to use.
///
/// SYNOPSIS:
/// ```zig
/// fn NewList(_: *ExecBase, list: *List) void
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `list` - the header to prepare. Whatever was on it is forgotten rather
///   than freed.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The two sentinels are pointed at each other, which is what an empty list
/// is. The list's type is left alone, so a header whose type was set when
/// it was declared keeps it.
///
/// A list must go through this before anything is added to it. A zeroed
/// header is not an empty list - its sentinels are null rather than
/// pointing at each other, and the first `AddTail` writes through one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; the caller's locking is what decides.
/// - Forbid: not needed. Nothing can be walking a list that does not exist
///   yet.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and nothing on the old list is freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTail`, `Enqueue`
///
/// EXAMPLES:
/// ```zig
/// var list: exec.List = undefined;
/// sys.NewList(&list);
/// ```
pub fn NewList(_: *ExecBase, list: *List) void {
    sdk.exec.lists.newList(list);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "NewList empties a header and keeps its type" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{ .type = .message };
    NewList(base, &list);
    try testing.expect(list.isEmpty());
    try testing.expect(list.first() == null);
    try testing.expectEqual(sdk.exec.NodeType.message, list.type);
}
