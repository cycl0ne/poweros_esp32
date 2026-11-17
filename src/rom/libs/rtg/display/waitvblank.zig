// SPDX-License-Identifier: MPL-2.0
//! WaitVBlank: Wait for `frames` frames of the display to end; 0 is the
//! next one.
//!
//! A board whose driver says its frames (FrameDone) is waited for by
//! them: a waiter on the waiting task's stack is counted down by each
//! frame, and a request to timer.device - a copy of the library's,
//! answered to a port on the same stack - ends the wait when they do not
//! come. Both wake the task on one signal, so one Wait hears whichever is
//! first. A board that says none is waited for by the same request
//! alone, for the frames' time.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const frames_file = @import("../frame/_frame.zig");
const err = rtg.errors;

/// A frame's time, in microseconds, on a board that does not say how
/// often it refreshes: a panel's 60 a second.
const default_frame_us: u64 = 16_667;

/// A frame's time on `board`, in microseconds: by its refresh rate, a
/// sixtieth of a second on a board that names none.
///
/// INPUTS:
/// - `board` - the board, for its refresh rate.
fn frameMicros(board: *const rtg.RtgBoard) u64 {
    const refresh_mhz = board.info.refresh_mhz;
    return if (refresh_mhz == 0) default_frame_us else 1_000_000_000 / @as(u64, refresh_mhz);
}

/// Waits for frames of the display to end.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `board` - the board.
/// - `frames` - how many frames to wait for; 0 is the next one.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_TIMEOUT` when the board's driver says its frames
/// and they did not come within two frames' time for each;
/// `RTGERR_NOT_SUPPORTED` where there is no timer.device to wait by;
/// `RTGERR_NO_MEMORY` without a free signal.
///
/// BEHAVIOR:
/// On a board whose driver says when a frame ends (`FrameDone`,
/// `RTGBC_VBLANK`) the task waits until that many have ended, or for the
/// time limit, whichever is first: two frames of the board's refresh rate
/// for each frame asked for, a frame taken as a sixtieth of a second on
/// a board that names no rate. A wait the frames did not come for
/// answers `RTGERR_TIMEOUT`, and the board is held to say none until its
/// driver says the next.
///
/// On a board that says no frames - one with no frame interrupt, one
/// whose stream has not begun or has stopped, one that is dark - and on
/// one that is asleep (`SetBoardPower`) the
/// task waits by the clock, a frame's time for each frame asked for, and
/// the answer is `RTGERR_OK`: a program that paces itself by the display
/// runs at the speed it would on one that says its frames.
///
/// So the call comes back on every board.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no. It waits.
/// - Locks: no spinlock may be held. The board's lock is not taken: a
///   driver calls it from its `show`, which holds it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A signal is taken for the wait and given back. Nothing is allocated:
/// the waiter, the request and its reply port are on the caller's stack;
/// the waiter is off the board's list and the request back from
/// timer.device when this returns.
///
/// NOTES:
/// `RTGERR_TIMEOUT` says nothing was waited for in step with the display:
/// a caller that paces itself by this call has been held for the limit
/// and no longer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FrameDone`, `GetBoardStats`
///
/// EXAMPLES:
/// ```zig
/// if (rb.WaitVBlank(board, 0) == rtg.errors.RTGERR_TIMEOUT) {
///     // the board sends no frames just now
/// }
/// ```
pub fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32 {
    const sys = rb.sys_base;
    const wanted = if (frames == 0) 1 else frames;
    const state = &boards.privateOf(board).frames;
    // A wait nothing could end is not begun.
    if (rb.timer_io.node.device == null) return err.RTGERR_NOT_SUPPORTED;

    // AllocSignal hands the bit out cleared, so neither an old frame nor
    // an old reply is heard.
    const signal_bit = sys.AllocSignal(-1);
    if (signal_bit < 0) return err.RTGERR_NO_MEMORY;
    defer sys.FreeSignal(signal_bit);
    const mask = @as(u32, 1) << @intCast(signal_bit);
    const task = sys.FindTask(null).?;

    // The clock: a copy of the library's request, answered to this task
    // on the signal the frames come on.
    var port: exec.MsgPort = .{ .sig_bit = @intCast(signal_bit), .sig_task = task };
    port.msg_list.init(.message);
    var clock = rb.timer_io;
    clock.node.message.reply_port = &port;
    clock.node.command = timer.TR_ADDREQUEST;

    if (!frames_file.come(state) or board.info.power == rtg.boards.RTGPWR_ASLEEP) {
        // No frames are said, or the display sleeps: the frames' time,
        // by the clock.
        clock.time = timer.TimeVal.fromMicros(frameMicros(board) * wanted);
        sys.SendIO(&clock.node);
        _ = sys.WaitIO(&clock.node);
        return err.RTGERR_OK;
    }

    var waiter: frames_file.Waiter = .{ .task = task, .mask = mask, .left = wanted };
    // The count is the interrupt's to write: read again at every look.
    const left: *volatile u32 = &waiter.left;
    // The limit: twice the frames' time. A board that says its frames
    // says one every frame, so twice that is one that will not come.
    clock.time = timer.TimeVal.fromMicros(2 * frameMicros(board) * wanted);

    frames_file.add(sys, state, &waiter);
    sys.SendIO(&clock.node);
    while (left.* != 0 and sys.CheckIO(&clock.node) == null) _ = sys.Wait(mask);
    const missing = frames_file.remove(sys, state, &waiter);
    // The request is back before its port goes with this call: taken back
    // where its time has not come, and its reply taken off the port.
    if (sys.CheckIO(&clock.node) == null) _ = sys.AbortIO(&clock.node);
    _ = sys.WaitIO(&clock.node);
    return if (missing == 0) err.RTGERR_OK else err.RTGERR_TIMEOUT;
}
