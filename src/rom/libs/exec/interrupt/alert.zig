// SPDX-License-Identifier: MPL-2.0
//! Alert: raises an alert - the Guru. A dead end does not come back.
//!
//! It goes through nothing replaceable and allocates nothing: the code that
//! reports a broken machine cannot depend on a vector something may have
//! replaced, nor on memory when what is broken may be the memory.

const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Reports that the system has a problem, and for a dead end stops.
///
/// SYNOPSIS:
/// ```zig
/// fn Alert(_: *ExecBase, alert_num: u32) void
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `alert_num` - what went wrong, with `AT_DeadEnd` set if the machine
///   cannot carry on and `AT_Recovery` if it can.
///
/// RESULT:
/// Nothing, and for `AT_DeadEnd` it does not return at all.
///
/// BEHAVIOR:
/// The alert goes to whatever the kernel installed to show it, with the
/// **caller's own return address** as the second number - which is what
/// makes the display worth reading, since it names where the trouble was
/// found. The wrapper takes that address itself rather than calling
/// `Alert`, which would name the wrapper.
///
/// CONTEXT:
/// - Waits: no, and it must not: the machine it would wait for is the one
///   being reported.
/// - Interrupts: safe, and it is reached from one - a CPU exception ends
///   here when no trap code takes it.
/// - Forbid: not needed, and not taken. It cannot be, since what is broken
///   may be the scheduler.
/// - Process: a Task will do. It must work with no task at all, since it is
///   reached before there are any.
///
/// OWNERSHIP:
/// Nothing is allocated, on purpose: allocating to report a failure fails
/// when the failure is memory.
///
/// NOTES:
/// The path that reports a broken machine does not go through the jump
/// table, and must not: a patched vector is one of the things that may be
/// what is broken.
///
/// The alert goes to exec's raw port, which needs no display and no
/// library: a library that shows the alert has to be working for the
/// alert to appear, and what is being reported may be the reason it is
/// not.
///
/// This names *its* caller as the place the trouble was found, which is
/// right for kernel code calling it directly. The jump-table wrapper takes
/// its own return address instead, so that a caller coming through the
/// table is named rather than the wrapper.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetTrapCode`, `ColdReboot`
///
/// EXAMPLES:
/// ```zig
/// sys.Alert(exec.AT_DeadEnd | exec.AN_KernelPanic);
/// ```
pub fn Alert(_: *ExecBase, alert_num: u32) void {
    _interrupt.alertAt(alert_num, @returnAddress());
}
