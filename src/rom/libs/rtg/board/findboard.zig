// SPDX-License-Identifier: MPL-2.0
//! FindBoard: The board of that name, or null.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Finds a board by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoard(rb: *RtgBase, board_name: [*:0]const u8) ?*rtg.RtgBoard
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `board_name` - the name the library gave it: its driver's, a point
///   and a number ("rgb.0").
///
/// RESULT:
/// The board, or null.
///
/// BEHAVIOR:
/// An exact match on the name. A board whose device has gone
/// (`RTGBF_GONE`) is found too: its handle stays what it was.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the board list.
/// - Interrupts: no.
/// - Locks: takes the board list's lock, shared, for the step. No spinlock
///   may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. A board is never freed for a program, so the
/// handle is good for as long as the machine runs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextBoard`, `BindRtgDrivers`
///
/// EXAMPLES:
/// ```zig
/// const board = rb.FindBoard("rgb.0") orelse return;
/// ```
pub fn FindBoard(rb: *RtgBase, board_name: [*:0]const u8) ?*rtg.RtgBoard {
    const sys = rb.sys_base;
    // Held while it is searched, so no board leaves it under the search.
    sys.ObtainSemaphoreShared(&rb.board_lock);
    defer sys.ReleaseSemaphore(&rb.board_lock);
    const node = sys.FindName(&rb.boards, board_name) orelse return null;
    return @fieldParentPtr("node", node);
}
