// SPDX-License-Identifier: MPL-2.0
//! WaitVBlank: Wait for `frames` blankings; 0 is the next one.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const waiterServer = _event.waiterServer;
const Waiter = _event.Waiter;
const err = rtg.errors;
const _event = @import("../event/_event.zig");

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
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a board that signals no
/// blankings, `RTGERR_NO_MEMORY` without a free signal, or what the
/// driver's own wait answered.
///
/// BEHAVIOR:
/// A driver with a wait of its own does it. Otherwise the task hangs an
/// event server on `RTGEV_VBLANK` that signals it after the count, and
/// waits.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no. It waits.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A signal is taken for the wait and given back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgEventServer`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.WaitVBlank(board, 0);
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

    const signal_bit = sys.AllocSignal(-1);
    if (signal_bit < 0) return err.RTGERR_NO_MEMORY;
    defer sys.FreeSignal(signal_bit);

    var waiter: Waiter = .{
        .interrupt = .{ .node = .{ .type = .interrupt, .pri = 0, .name = "rtg vblank wait" } },
        .sys = sys,
        .task = sys.FindTask(null).?,
        .mask = @as(u32, 1) << @intCast(signal_bit),
        .left = wanted,
    };
    waiter.interrupt.data = @ptrCast(&waiter);
    waiter.interrupt.code = @ptrCast(&waiterServer);

    if (!rtg_lib.AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &waiter.interrupt)) return err.RTGERR_BAD_ARG;
    _ = sys.Wait(waiter.mask);
    rtg_lib.RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &waiter.interrupt);
    return err.RTGERR_OK;
}
