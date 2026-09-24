// SPDX-License-Identifier: MPL-2.0
//! GPIOOwner: who holds a pad.

const sdk = @import("sdk");
const types = sdk.resources.gpio;
const GpioBase = @import("../gpio_base.zig").GpioBase;

/// Who holds `pad`.
///
/// SYNOPSIS:
/// ```zig
/// fn GPIOOwner(gb: *GpioBase, pad: u32) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `pad` - the pad.
///
/// RESULT:
/// The name it was taken for, or null when nobody holds it or the chip
/// does not have it.
///
/// BEHAVIOR:
/// One read of the list, no lock: what it answers may have changed by the
/// time the caller looks at it, which is fine for a listing and nothing
/// else. To have a pad, take it.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: yes.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is its holder's; read it at once, do not keep it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocGPIO`
///
/// EXAMPLES:
/// ```zig
/// const holder = gb.GPIOOwner(9) orelse "-";
/// ```
pub fn GPIOOwner(gb: *GpioBase, pad: u32) ?[*:0]const u8 {
    if (!types.padExists(pad)) return null;
    return gb.owner[pad];
}
