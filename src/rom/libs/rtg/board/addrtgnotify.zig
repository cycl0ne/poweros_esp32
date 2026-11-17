// SPDX-License-Identifier: MPL-2.0
//! AddRtgNotify: Have a task signalled whenever something about the
//! boards changed.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _board = @import("_board.zig");

/// Asks for a task to be told when something about the boards changes.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgNotify(rb: *RtgBase, task: *exec.Task, signals: u32) ?*rtg.RtgNotify
/// ```
///
/// SINCE: 1.20. LVO -236.
///
/// INPUTS:
/// - `task` - the task to signal.
/// - `signals` - the signals it is sent, as a mask: one the task
///   allocated.
///
/// RESULT:
/// The notification, for `RemRtgNotify`; null for no signals, and without
/// memory.
///
/// BEHAVIOR:
/// From now on the task is signalled whenever a board was made or has
/// gone, a monitor came or went, a board's list of modes was made again,
/// or a board was put in another mode. The signal says only that
/// something changed: the task walks the boards (`NextBoard`) and reads
/// each one's `changes` (`GetBoardInfo`), which is raised with every such
/// change of that board, to see which it was. Several changes before the
/// task runs are one signal.
///
/// CONTEXT:
/// - Waits: while another task holds the notifications' lock.
/// - Interrupts: no.
/// - Locks: takes the notifications' lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The notification is the library's memory and the caller's to give
/// back with `RemRtgNotify`, before the task ends.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgNotify`, `GetBoardInfo`, `GetBoardMonitor`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// const notify = rb.AddRtgNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
/// defer rb.RemRtgNotify(notify);
/// ```
pub fn AddRtgNotify(rb: *RtgBase, task: *exec.Task, signals: u32) ?*rtg.RtgNotify {
    const sys = rb.sys_base;
    if (signals == 0) return null;
    const memory = sys.AllocVec(@sizeOf(_board.Notify), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const notify: *_board.Notify = @ptrCast(@alignCast(memory));
    notify.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&rb.notify_lock);
    sys.AddTail(&rb.notifies, &notify.node);
    sys.ReleaseSemaphore(&rb.notify_lock);
    return @ptrCast(notify);
}
