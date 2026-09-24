// SPDX-License-Identifier: MPL-2.0
//! FreeGPIO: give a pad back.

const sdk = @import("sdk");
const types = sdk.resources.gpio;
const GpioBase = @import("../gpio_base.zig").GpioBase;

/// Give `pad` back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeGPIO(gb: *GpioBase, pad: u32) void
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `pad` - a pad the caller took with AllocGPIO.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The pad is free for the next AllocGPIO. How it is set up - its
/// function, its level, its pulls - is left as it is: a line let go of
/// mid-level stays there until its next holder sets it.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no.
/// - Forbid: taken here.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name given to AllocGPIO is no longer kept.
///
/// NOTES:
/// Only the holder gives a pad back; nothing checks who calls.
///
/// BUGS:
/// A pad the chip does not have is ignored.
///
/// SEE ALSO:
/// `AllocGPIO`
///
/// EXAMPLES:
/// ```zig
/// gb.FreeGPIO(pad);
/// ```
pub fn FreeGPIO(gb: *GpioBase, pad: u32) void {
    if (!types.padExists(pad)) return;
    const sys = gb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    gb.owner[pad] = null;
}
