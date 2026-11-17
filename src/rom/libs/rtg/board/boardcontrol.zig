// SPDX-License-Identifier: MPL-2.0
//! BoardControl: Something only this driver knows about (RTGCTRL_*), or
//! RTGCTRL_RESET_STATS, which every board takes.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Asks a board something only its driver knows about.
///
/// SYNOPSIS:
/// ```zig
/// fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `board` - the board.
/// - `what` - an `RTGCTRL_` code: `RTGCTRL_RESET_STATS`, which every board
///   takes, or one of the driver's own.
/// - `value` - the code's argument.
///
/// RESULT:
/// `RTGERR_OK` for `RTGCTRL_RESET_STATS`. For a driver's own code what
/// the driver answered, or `RTGERR_NOT_SUPPORTED` for a code it does not
/// know or a board with no control at all.
///
/// BEHAVIOR:
/// `RTGCTRL_RESET_STATS` clears the library's own count of buffers shown
/// and is then handed to the driver, where it has a control, for the
/// counters it keeps; what the driver answers to it is not looked at.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardStats`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BoardControl(board, rtg.boards.RTGCTRL_RESET_STATS, 0);
/// ```
pub fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize {
    if (what == rtg.boards.RTGCTRL_RESET_STATS) {
        // The library's own count, and the driver's where it keeps any:
        // every board takes this one, whatever its driver knows.
        privateOf(board).buffer_swaps = 0;
        if (board.ops) |ops| {
            if (ops.control) |control| _ = control(board, what, value);
        }
        return err.RTGERR_OK;
    }
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const control = ops.control orelse return err.RTGERR_NOT_SUPPORTED;
    return control(board, what, value);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "the counters are reset on every board, with a control of its own or without" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const reset = rtg.boards.RTGCTRL_RESET_STATS;

    // A board whose driver has a control: the library's count is cleared,
    // the driver is handed the code for its own, and the answer is the
    // library's, whatever the driver made of it.
    const board = try fixture.makeDisplay(rb, 16, 16);
    const shown = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, shown));
    try testing.expectEqual(@as(u32, 1), fixture.swapsOf(rb, board));
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), fixture.base(rb).BoardControl(board, reset, 7));
    try testing.expectEqual(reset, fk.log.last_control);
    try testing.expectEqual(@as(u32, 0), fixture.swapsOf(rb, board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(shown);
    fixture.driverBase(rb).DeleteBoard(board);

    // A board whose driver has none takes it all the same, and no other
    // code.
    fk.without_engine = true;
    const plain = try fixture.makeDisplay(rb, 16, 16);
    const picture = fixture.base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, picture));
    try testing.expectEqual(@as(u32, 1), fixture.swapsOf(rb, plain));
    const controls = fk.log.control_calls;
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), fixture.base(rb).BoardControl(plain, reset, 0));
    try testing.expectEqual(@as(u32, 0), fixture.swapsOf(rb, plain));
    try testing.expectEqual(controls, fk.log.control_calls);
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_NOT_SUPPORTED), fixture.base(rb).BoardControl(plain, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(plain);
    try fixture.tearDown(rb);
}
