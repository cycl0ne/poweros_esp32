// SPDX-License-Identifier: MPL-2.0
//! PowerAbilities: what this machine can do about its own power.

const sdk = @import("sdk");
const PowerBase = @import("../power_base.zig").PowerBase;

/// What this machine can do about its own power (POWERF_*).
///
/// SYNOPSIS:
/// ```zig
/// fn PowerAbilities(pb: *PowerBase) u32
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// POWERF_OFF where the machine can turn itself off, POWERF_BUTTON where
/// it has a power button that says when it is pressed; 0 where it can
/// do neither, which is an honest answer and not a failure.
///
/// BEHAVIOR:
/// The answer was worked out once, as the resource started: what the
/// machine can do does not change while it runs. Asking costs nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: it may be called from one.
/// - Locks: none.
/// - Process: any.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// A program that offers to turn the machine off asks this first, so
/// that it offers nothing the machine cannot do.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PowerOff`, `AddPowerNotify`
///
/// EXAMPLES:
/// ```zig
/// if (pb.PowerAbilities() & power.POWERF_OFF != 0) pb.PowerOff();
/// ```
pub fn PowerAbilities(pb: *PowerBase) u32 {
    return pb.abilities;
}
