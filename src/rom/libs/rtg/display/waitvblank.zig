// SPDX-License-Identifier: MPL-2.0
//! WaitVBlank: Wait for `frames` blankings; 0 is the next one.
//!
//! A board whose driver has a wait of its own is asked. One that only
//! signals its blankings is waited for here: an event server on the
//! waiting task's stack counts them down, and a request to timer.device -
//! a copy of the library's, answered to a port on the same stack - ends
//! the wait when they do not come. Both wake the task on one signal, so
//! one Wait hears whichever is first.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const RtgBase = @import("../rtg.zig").RtgBase;
const waiterServer = _event.waiterServer;
const Waiter = _event.Waiter;
const err = rtg.errors;
const _event = @import("../event/_event.zig");

/// A frame's time, in microseconds, on a board that does not say how
/// often it refreshes: a panel's 60 a second.
const default_frame_us: u64 = 16_667;

/// How long a wait for `frames` blankings of `board` may take, in
/// microseconds: two frames' time for each. A board that streams sends a
/// blanking every frame, so twice that is one that will not come.
///
/// INPUTS:
/// - `board` - the board, for its refresh rate.
/// - `frames` - how many blankings are waited for; not 0.
fn limitMicros(board: *const rtg.RtgBoard, frames: u32) u64 {
    const refresh_mhz = board.info.refresh_mhz;
    const frame_us: u64 = if (refresh_mhz == 0) default_frame_us else 1_000_000_000 / @as(u64, refresh_mhz);
    return 2 * frame_us * frames;
}

/// Waits for the display's blanking.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `board` - the board.
/// - `frames` - how many blankings to wait for; 0 is the next one.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_TIMEOUT` when the blankings did not come within
/// two frames' time for each; `RTGERR_NOT_SUPPORTED` for a board that
/// signals no blankings, and where there is no timer.device to end the
/// wait by; `RTGERR_NO_MEMORY` without a free signal; or what the driver's
/// own wait answered.
///
/// BEHAVIOR:
/// A driver with a wait of its own does it. Otherwise the task hangs an
/// event server on `RTGEV_VBLANK` that signals it after the count, and
/// waits for that or for the time limit, whichever is first: two frames
/// of the board's refresh rate for each blanking asked for, a frame taken
/// as a sixtieth of a second on a board that names no rate. So the call
/// comes back on a board whose stream has stopped, or has not begun.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no. It waits.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A signal is taken for the wait and given back. Nothing is allocated:
/// the event server, the limit's request and its reply port are on the
/// caller's stack; the server is off the board's list and the request
/// back from timer.device when this returns.
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
/// `AddRtgEventServer`, `GetBoardStats`
///
/// EXAMPLES:
/// ```zig
/// if (rb.WaitVBlank(board, 0) == rtg.errors.RTGERR_TIMEOUT) {
///     // the board sends no frames just now
/// }
/// ```
pub fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32 {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const wanted = if (frames == 0) 1 else frames;

    if (board.ops) |ops| {
        if (ops.wait_vblank) |wait| return wait(board, frames);
    }
    // Nothing to wait for unless the board signals blankings at all.
    if (board.info.flags & rtg.boards.RTGBF_STREAMING == 0) return err.RTGERR_NOT_SUPPORTED;
    // A wait nothing could end is not begun.
    if (rb.timer_io.node.device == null) return err.RTGERR_NOT_SUPPORTED;

    // AllocSignal hands the bit out cleared, so neither an old blanking
    // nor an old reply is heard.
    const signal_bit = sys.AllocSignal(-1);
    if (signal_bit < 0) return err.RTGERR_NO_MEMORY;
    defer sys.FreeSignal(signal_bit);
    const mask = @as(u32, 1) << @intCast(signal_bit);
    const task = sys.FindTask(null).?;

    var waiter: Waiter = .{
        .interrupt = .{ .node = .{ .type = .interrupt, .pri = 0, .name = "rtg vblank wait" } },
        .sys = sys,
        .task = task,
        .mask = mask,
        .left = wanted,
    };
    waiter.interrupt.data = @ptrCast(&waiter);
    waiter.interrupt.code = @ptrCast(&waiterServer);
    // The count is the interrupt's to write: read again at every look.
    const left: *volatile u32 = &waiter.left;

    // The limit: a copy of the library's request, answered to this task
    // on the signal the blankings come on.
    var port: exec.MsgPort = .{ .sig_bit = @intCast(signal_bit), .sig_task = task };
    port.msg_list.init(.message);
    var limit = rb.timer_io;
    limit.node.message.reply_port = &port;
    limit.node.command = timer.TR_ADDREQUEST;
    limit.time = timer.TimeVal.fromMicros(limitMicros(board, wanted));

    if (!rtg_lib.AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &waiter.interrupt)) return err.RTGERR_BAD_ARG;
    sys.SendIO(&limit.node);
    while (left.* != 0 and sys.CheckIO(&limit.node) == null) _ = sys.Wait(mask);
    rtg_lib.RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &waiter.interrupt);
    // The request is back before its port goes with this call: taken back
    // where its time has not come, and its reply taken off the port.
    if (sys.CheckIO(&limit.node) == null) _ = sys.AbortIO(&limit.node);
    _ = sys.WaitIO(&limit.node);
    return if (left.* == 0) err.RTGERR_OK else err.RTGERR_TIMEOUT;
}
