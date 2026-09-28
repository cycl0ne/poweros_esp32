// SPDX-License-Identifier: MPL-2.0
//! SetLogSignal: a task woken when the system log grows.

const sdk = @import("sdk");
const _log = @import("_log.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Asks for signals when something is added to the system log, or stops
/// them.
///
/// SYNOPSIS:
/// ```zig
/// fn SetLogSignal(base: *ExecBase, task: ?*Task, signal_mask: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -478.
///
/// INPUTS:
/// - `task` - the task to signal; null for the caller.
/// - `signal_mask` - the signals it is sent; 0 to send none any more.
///
/// RESULT:
/// True when the task follows the log as asked (or, for 0, no longer
/// does); false when there is no room for another follower.
///
/// BEHAVIOR:
/// A follower is signalled at most every ten ticks, and only when
/// something was added since the last time - not for every line - so it
/// reads with `ReadLog` what came in a batch. A task that asks again gets
/// the new mask in place of the old one.
///
/// Four tasks may follow the log at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed. It holds interrupts off while it changes the
///   followers.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// exec keeps the task's address until it is set to 0 again: a task must
/// stop following before it ends.
///
/// NOTES:
/// The signals are the task's own, allocated with `AllocSignal`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadLog`, `AllocSignal`, `Wait`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// _ = sys.SetLogSignal(null, @as(u32, 1) << @intCast(bit));
/// // ... Wait, ReadLog ...
/// _ = sys.SetLogSignal(null, 0);
/// sys.FreeSignal(bit);
/// ```
pub fn SetLogSignal(base: *ExecBase, task: ?*Task, signal_mask: u32) bool {
    const sys = base.iface();
    const who = task orelse sys.FindTask(null).?;
    sys.Disable();
    defer sys.Enable();
    var free: ?*_log.Follower = null;
    for (&base.log_followers) |*follower| {
        if (follower.task == who) {
            follower.* = if (signal_mask == 0) .{} else .{ .task = who, .signal_mask = signal_mask };
            return true;
        }
        if (follower.task == null and free == null) free = follower;
    }
    if (signal_mask == 0) return true;
    const slot = free orelse return false;
    slot.* = .{ .task = who, .signal_mask = signal_mask };
    return true;
}
