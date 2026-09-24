// SPDX-License-Identifier: MPL-2.0
//! SignalRtgEvent: Tell a board's servers that something happened.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _event = @import("_event.zig");

/// Tells a board's servers that one of its events happened.
///
/// SYNOPSIS:
/// ```zig
/// fn SignalRtgEvent(_: *RtgBase, board: *rtg.RtgBoard, event: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `board` - the board.
/// - `event` - the `RTGEV_` event.
///
/// RESULT:
/// What the chain answered: the first non-zero answer, or 0 if every
/// server passed it on, or for an event that does not exist.
///
/// BEHAVIOR:
/// A driver calls it from its own interrupt. The servers run in turn,
/// highest priority first, until one answers non-zero. A blanking also
/// counts in the board's statistics.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes: this is what a driver's interrupt calls.
/// - Forbid: not needed.
/// - Process: any, or none.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgEventServer`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
/// ```
pub fn SignalRtgEvent(_: *RtgBase, board: *rtg.RtgBoard, event: u32) i32 {
    if (event >= rtg.events.RTGEV_COUNT) return 0;
    if (event == rtg.events.RTGEV_VBLANK) boards.privateOf(board).vblanks +%= 1;

    var node = board.event_lists[event].first();
    while (node) |n| : (node = n.next()) {
        const server: *exec.Interrupt = @fieldParentPtr("node", n);
        const code = server.code orelse continue;
        const run: rtg.RtgEventFn = @ptrCast(@alignCast(code));
        const answer = run(server.data, @ptrCast(board), event);
        if (answer != 0) return answer;
    }
    return 0;
}
