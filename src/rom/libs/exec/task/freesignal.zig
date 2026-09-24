// SPDX-License-Identifier: MPL-2.0
//! FreeSignal: gives a signal bit of the running task back.

const ExecBase = @import("../exec.zig").ExecBase;

/// Gives a signal bit back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeSignal(base: *ExecBase, signal_num: i8) void
/// ```
///
/// SINCE: 1.0. LVO -192.
///
/// INPUTS:
/// - `signal_num` - a bit from `AllocSignal`. Out of range does nothing, so
///   a failed allocation's -1 may be passed on without testing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The bit is free to be allocated again. Whether it is currently *set* is
/// not looked at, so anything still signalling it will set a bit its next
/// owner did not expect - which is why what signals it is taken down first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no - it is the running task's bits.
/// - Forbid: not needed.
/// - Process: a Task will do, and it must be **the task that allocated
///   it**.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocSignal`, `DeleteMsgPort`
///
/// EXAMPLES:
/// ```zig
/// defer sys.FreeSignal(bit);
/// ```
pub fn FreeSignal(base: *ExecBase, signal_num: i8) void {
    if (signal_num < 0 or signal_num >= 32) return;
    base.iface().FindTask(null).?.sig_alloc &= ~(@as(u32, 1) << @intCast(signal_num));
}
