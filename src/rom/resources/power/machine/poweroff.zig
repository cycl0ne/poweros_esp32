// SPDX-License-Identifier: MPL-2.0
//! PowerOff: the machine off.

const sdk = @import("sdk");
const PowerBase = @import("../power_base.zig").PowerBase;
const _machine = @import("_machine.zig");

/// The machine turned off.
///
/// SYNOPSIS:
/// ```zig
/// fn PowerOff(pb: *PowerBase) void
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None. It does not return on a machine that goes off.
///
/// BEHAVIOR:
/// The machine is turned off, through its firmware, which is what knows
/// how this machine is to be put into that state. Nothing is written out
/// first and nothing is asked: the caller has already done whatever is to
/// be done - stopping the drives, so that what a file system holds is
/// written - because once this is called there is no afterwards.
///
/// It returns where the machine did not go off: one that cannot do it at
/// all (PowerAbilities answers without POWERF_OFF), and one that was
/// asked and went on running. The caller then still has a working
/// machine, and says so rather than leaving it looking hung.
///
/// CONTEXT:
/// - Waits: no, but the firmware's call may take as long as it takes.
/// - Interrupts: no - it is called with interrupts on, from a task.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// Restarting the machine is exec's ColdReboot, not this: the two go
/// different ways and a restart wants no firmware that can turn a machine
/// off.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PowerAbilities`, exec's `ColdReboot`
///
/// EXAMPLES:
/// ```zig
/// pb.PowerOff();
/// _ = Printf(dl, "this machine does not turn itself off\n", .{});
/// ```
pub fn PowerOff(pb: *PowerBase) void {
    _ = pb;
    _machine.off();
}
