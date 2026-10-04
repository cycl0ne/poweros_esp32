// SPDX-License-Identifier: MPL-2.0
//! ReleaseOtherCores: the cores HoldOtherCores held let go.

const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Lets go of the cores `HoldOtherCores` held.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseOtherCores(base: *ExecBase) void
/// ```
///
/// SINCE: 1.4. LVO -512.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing: when it returns, every other core has left its loop.
///
/// BEHAVIOR:
/// Each held core goes back to what it was doing - an interrupt it was in,
/// or a spin it parked from. With one core running, nothing is done.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: masked by the caller, as for `HoldOtherCores`.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HoldOtherCores`
///
/// EXAMPLES:
/// ```zig
/// sys.HoldOtherCores();
/// defer sys.ReleaseOtherCores();
/// ```
pub fn ReleaseOtherCores(_: *ExecBase) void {
    _interrupt.interrupt_hardware.release_others();
}
