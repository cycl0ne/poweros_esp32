// SPDX-License-Identifier: MPL-2.0
//! WaitBlit: Wait until the board's engine has finished what it was
//! given.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");

/// Waits until a board's engine has finished what it was given.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitBlit(_: *RtgBase, board: *rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `board` - the board.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Returns at once for a board with no engine, or one whose engine is
/// finished before it returns.
///
/// CONTEXT:
/// - Waits: yes, while the engine works.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FillRect`, `CopyRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.FillRect(buffer, &area, colour);
/// rb.WaitBlit(board);
/// ```
pub fn WaitBlit(_: *RtgBase, board: *rtg.RtgBoard) void {
    const ops = board.ops orelse return;
    const wait = ops.wait_blit orelse return;
    wait(board);
}
