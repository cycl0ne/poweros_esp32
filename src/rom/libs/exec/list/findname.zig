// SPDX-License-Identifier: MPL-2.0
//! FindName: finds the first node of a list with a given name. It walks
//! from the head, so on a list kept by priority the first match is also
//! the best one.
//!
//! The comparison is a leaf of its own: exec runs before utility.library
//! exists and cannot call it (codex rule 3).

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const List = sdk.exec.List;
const AddTail = @import("addtail.zig").AddTail;
const NewList = @import("newlist.zig").NewList;

/// Finds the first node of a list with a given name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindName(_: *ExecBase, list: *List, name: [*:0]const u8) ?*Node
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `list` - the list to walk. Any exec list; the system's own are reached
///   with `ExecList`.
/// - `name` - what to match. Compared exactly, case included.
///
/// RESULT:
/// The node, or null if no node of that name is on the list. A node with no
/// name is skipped rather than matched against.
///
/// BEHAVIOR:
/// It walks from the head and answers the first match, so where two nodes
/// share a name the one nearer the head wins - which on a list kept by
/// priority is the higher-priority one. That is how a library or a device
/// is replaced by adding a better one in front of it.
///
/// To find the second match, carry on from the node this answered rather
/// than calling again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself. On a system list, only if the caller can
///   be sure nothing is changing it, which from an interrupt it cannot.
/// - Forbid: not taken here, and needed by the caller for any list another
///   task may change - which is every list exec owns.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The node belongs to whatever put it on the list,
/// and is only worth the pointer for as long as the lock is held.
///
/// NOTES:
/// Case matters. A name that is typed by a user is matched somewhere else,
/// with utility.library's `Stricmp`, before it reaches this.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Enqueue`, `ExecList`, `FindPort`, `FindSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// defer sys.Permit();
/// const node = sys.FindName(sys.ExecList(EXECLIST_DEVICE).?, "timer.device");
/// ```
pub fn FindName(_: *ExecBase, list: *List, name: [*:0]const u8) ?*Node {
    var it = list.iterator();
    while (it.next()) |node| {
        const node_name = node.name orelse continue;
        if (sameName(node_name, name)) return node;
    }
    return null;
}

/// Whether two NUL-terminated names are the same, byte for byte.
///
/// INPUTS:
/// - `left`, `right` - the names to compare.
fn sameName(left: [*:0]const u8, right: [*:0]const u8) bool {
    var index: usize = 0;
    while (left[index] == right[index]) : (index += 1) {
        if (left[index] == 0) return true;
    }
    return false;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "FindName: the first match, case matters, no name is passed over" {
    const base: *ExecBase = undefined; // the list calls never read it
    var list: List = .{};
    NewList(base, &list);
    var unnamed: Node = .{};
    var first: Node = .{ .name = "timer" };
    var second: Node = .{ .name = "timer" };
    var longer: Node = .{ .name = "timers" };
    for ([_]*Node{ &unnamed, &longer, &first, &second }) |node| AddTail(base, &list, node);
    try testing.expectEqual(&first, FindName(base, &list, "timer").?);
    try testing.expectEqual(&longer, FindName(base, &list, "timers").?);
    try testing.expect(FindName(base, &list, "TIMER") == null);
    try testing.expect(FindName(base, &list, "time") == null);
    try testing.expect(FindName(base, &list, "") == null);
}
