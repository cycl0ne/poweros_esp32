// SPDX-License-Identifier: MPL-2.0
//! Permit: undoes one `Forbid`. The outermost one lets task switching
//! happen again and takes a switch that came due while it was held, so a
//! Permit is a point at which the caller may lose the processor.

const ExecBase = @import("../exec.zig").ExecBase;

/// Lets task switching happen again, and takes any switch that came due.
///
/// SYNOPSIS:
/// ```zig
/// fn Permit(base: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It drops the nesting count, and when that takes it below zero - no
/// Forbid outstanding - a switch that fell due while the scheduler was held
/// is taken here. So `Permit` is a point at which the caller may lose the
/// processor, which the call before it was not.
///
/// This is also what starts multitasking: the boot code holds Forbid from
/// before there are any tasks, and the `Permit` that matches it is the
/// moment the machine becomes preemptive.
///
/// CONTEXT:
/// - Waits: no, but it may switch, which looks the same to the caller.
/// - Interrupts: no. An interrupt that let the scheduler go would switch
///   tasks from inside an interrupt.
/// - Forbid: it is the release of it. One more `Permit` than `Forbid`
///   leaves the count wrong and the next Forbid holding nothing.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Because a switch may happen here, nothing may be held across it that a
/// switch would invalidate - a pointer into a list that another task is now
/// free to change has to be finished with before the Permit, not after.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Forbid`, `Enable`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// defer sys.Permit();
/// ```
pub fn Permit(base: *ExecBase) void {
    // Counted with the interrupts off, for the reason `Forbid` gives: the
    // count is read and written back, and losing that between the two
    // would leave a Forbid that nothing can undo. A switch that came due
    // while forbidden is taken by the `Enable`, once the interrupts are
    // back and the count is negative again - this is where the caller may
    // lose the processor, and it must not do that with them held off.
    const sys = base.iface();
    sys.Disable();
    base.tdn_nest_cnt -= 1;
    sys.Enable();
}
