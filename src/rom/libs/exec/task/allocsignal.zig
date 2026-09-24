// SPDX-License-Identifier: MPL-2.0
//! AllocSignal: takes a signal bit for the running task - a given one, or
//! the highest free - and clears it, so an old arrival does not wake the
//! new owner.

const ExecBase = @import("../exec.zig").ExecBase;

/// Takes a signal bit for the calling task's own use.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocSignal(base: *ExecBase, signal_num: i8) i8
/// ```
///
/// SINCE: 1.0. LVO -188.
///
/// INPUTS:
/// - `signal_num` - the bit wanted, 0 to 31; or **-1 for any free one**,
///   which is what nearly every caller passes.
///
/// RESULT:
/// The bit number, 0 to 31, or **-1** if it was taken or out of range. Not
/// a mask: `1 << bit` is the mask.
///
/// BEHAVIOR:
/// Any free bit is searched from 31 down, so the low 16 the system uses are
/// reached last. The bit is cleared as it is handed out, so a stale signal
/// from a previous owner is not delivered to the new one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no - it is the running task's bits.
/// - Forbid: not needed. Only the task itself can allocate its own signals.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bit is the task's until `FreeSignal`. It belongs to **that task
/// alone**: a signal bit allocated by one task means nothing in another,
/// which is why a port carries its bit with it.
///
/// NOTES:
/// There are 16 to hand out and no more. A task that allocates one per
/// request rather than one per port runs out, and -1 is easy to miss
/// because it looks like a bit number until it is shifted.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeSignal`, `Wait`, `CreateMsgPort`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// if (bit < 0) return;
/// defer sys.FreeSignal(bit);
/// const mask = @as(u32, 1) << @intCast(bit);
/// ```
pub fn AllocSignal(base: *ExecBase, signal_num: i8) i8 {
    const sys = base.iface();
    const task = sys.FindTask(null).?;
    const bit: u5 = if (signal_num < 0) blk: {
        var candidate: u6 = 32;
        while (candidate > 0) {
            candidate -= 1;
            if (task.sig_alloc & (@as(u32, 1) << @intCast(candidate)) == 0) break :blk @intCast(candidate);
        }
        return -1;
    } else if (signal_num < 32) @intCast(signal_num) else return -1;
    const mask = @as(u32, 1) << bit;
    if (task.sig_alloc & mask != 0) return -1;
    task.sig_alloc |= mask;
    _ = sys.SetSignal(0, mask);
    return @intCast(bit);
}
