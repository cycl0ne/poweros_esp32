// SPDX-License-Identifier: MPL-2.0
//! Telling whoever asked that something happened on a board.
//!
//! A server is an exec Interrupt on a list per board and per event, in
//! priority order. The driver calls SignalRtgEvent from its own interrupt
//! and the chain runs there; the first server to answer non-zero ends it.
//!
//! WaitVBlank is built out of the same thing: a board whose driver can
//! wait is asked to, and one that only signals gets a server of the
//! library's own on the stack of the task that is waiting.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");

/// What waits for a blanking when the driver has no wait of its own: an
/// Interrupt on the waiting task's own stack, which signals it and lets
/// the event go on to everyone else.
pub const Waiter = struct {
    interrupt: exec.Interrupt,
    sys: *ExecBase,
    task: *exec.Task,
    mask: u32,
    left: u32,
};

/// The event server `WaitVBlank` hangs on a blanking: it counts down and
/// signals the waiting task at zero.
///
/// INPUTS:
/// - `is_data` - the waiter.
/// - `board` - the board, unused.
/// - `event` - the event, unused.
///
/// RESULT:
/// 0, so the servers after it run too.
pub fn waiterServer(is_data: ?*anyopaque, board: *anyopaque, event: u32) callconv(.c) i32 {
    _ = board;
    _ = event;
    const waiter: *Waiter = @ptrCast(@alignCast(is_data.?));
    if (waiter.left != 0) {
        waiter.left -= 1;
        if (waiter.left == 0) waiter.sys.Signal(waiter.task, waiter.mask);
    }
    return 0;
}
