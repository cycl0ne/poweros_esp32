// SPDX-License-Identifier: MPL-2.0
//! FrameDone: A frame of a board's display ended.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _frame = @import("_frame.zig");

/// Says that a frame of a board's display ended.
///
/// SYNOPSIS:
/// ```zig
/// fn FrameDone(rb: *RtgBase, board: *rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.22. LVO -256.
///
/// INPUTS:
/// - `board` - the board whose display ended a frame: one of the
///   caller's own.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The frame is counted (`RtgBoardStats.blanks`), and every task that
/// waits for frames of the board (`WaitVBlank`) is counted one frame on
/// and signalled when its count is reached. From the first call on the
/// board is one that says its frames (`RTGBC_VBLANK`): a wait is for
/// them, with a limit, and no longer by the clock.
///
/// A driver calls it once a frame, from the interrupt that says the
/// frame ended - the blanking's, or the one that starts the next
/// picture. A driver without such an interrupt does not call it, and
/// its board is waited for by the clock.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes. That is where it is called.
/// - Locks: none taken. The count and the walk of the waiters are inside
///   Disable, which an interrupt is in already.
/// - Process: any, or none.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitVBlank`, `GetBoardStats`, `MonitorChanged`
///
/// EXAMPLES:
/// ```zig
/// // The frame interrupt's server.
/// panel.rtg_base.FrameDone(panel.board);
/// ```
pub fn FrameDone(rb: *RtgBase, board: *rtg.RtgBoard) void {
    _frame.done(rb.sys_base, &boards.privateOf(board).frames);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "frames: counted as the driver says them, and the board says that it does" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeBoard(rb);

    // A board whose driver has said no frame counts none and says none.
    try testing.expectEqual(@as(u32, 0), fixture.blanksOf(rb, board));
    try testing.expect(!fixture.saysFrames(rb, board));

    fixture.fake.endFrame(board);
    fixture.fake.endFrame(board);
    fixture.fake.endFrame(board);
    try testing.expectEqual(@as(u32, 3), fixture.blanksOf(rb, board));
    try testing.expect(fixture.saysFrames(rb, board));
    // The frames only go up: the counters' reset leaves them.
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), fixture.base(rb).BoardControl(board, rtg.boards.RTGCTRL_RESET_STATS, 0));
    try testing.expectEqual(@as(u32, 3), fixture.blanksOf(rb, board));
    // Another board's frames are its own.
    const other = try fixture.makeBoard(rb);
    try testing.expectEqual(@as(u32, 0), fixture.blanksOf(rb, other));
    try testing.expect(!fixture.saysFrames(rb, other));

    // A board a task waits for a frame of is not deleted from under it.
    const frames = &fixture.boards.privateOf(board).frames;
    var waiter: fixture.frame_state.Waiter = .{ .task = fixture.kexec.FindTask(fixture.kexec.SysBase, null).?, .mask = 0, .left = 2 };
    fixture.frame_state.add(rb.sys_base, frames, &waiter);
    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(board, fixture.base(rb).NextBoard(null).?);
    try testing.expectEqual(other, fixture.base(rb).NextBoard(board).?);
    fixture.fake.endFrame(board);
    try testing.expectEqual(@as(u32, 1), waiter.left);
    // Taken off with a frame still to come: the board is held to say
    // none until the next is said.
    try testing.expectEqual(@as(u32, 1), fixture.frame_state.remove(rb.sys_base, frames, &waiter));
    try testing.expect(!fixture.saysFrames(rb, board));
    fixture.fake.endFrame(board);
    try testing.expect(fixture.saysFrames(rb, board));
    try testing.expectEqual(@as(u32, 1), waiter.left);

    fixture.driverBase(rb).DeleteBoard(other);
    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expect(fixture.base(rb).NextBoard(null) == null);
    try fixture.tearDown(rb);
}
