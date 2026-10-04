// SPDX-License-Identifier: MPL-2.0
//! AllocGPIO: take a pad.

const sdk = @import("sdk");
const types = sdk.resources.gpio;
const GpioBase = @import("../gpio_base.zig").GpioBase;

/// Take `pad` for `name`.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocGPIO(gb: *GpioBase, pad: u32, name: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `pad` - the pad, 0 to GPIO_PADS - 1.
/// - `name` - who takes it, as GPIOOwner will say: the driver's name.
///
/// RESULT:
/// Null when the pad is now the caller's. Otherwise who has it - its
/// holder's name, or NO_SUCH_PAD for a pad the chip does not have - and
/// nothing has changed.
///
/// BEHAVIOR:
/// The test and the take are one step under the resource's lock, so of two
/// drivers asking at once - on either core - exactly one gets the pad. Taking a pad sets nothing up:
/// the caller routes it with `sdk.hardware.gpio` afterwards, as before.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no.
/// - Locks: takes the resource's spinlock, around the test and the take.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `name` is kept, not copied: it must stay valid until FreeGPIO. A
/// string literal in the driver does.
///
/// NOTES:
/// A driver takes every pad a part of the board gives it before it drives
/// any of them, and gives back the ones it did get when one is refused.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeGPIO`, `GPIOOwner`
///
/// EXAMPLES:
/// ```zig
/// if (gb.AllocGPIO(pad, "sdcard.device")) |holder| {
///     sdk.exec.kprintf(sys, "sdcard.device: GPIO%d is %s's\n", .{ pad, holder });
///     return false;
/// }
/// ```
pub fn AllocGPIO(gb: *GpioBase, pad: u32, name: [*:0]const u8) ?[*:0]const u8 {
    if (!types.padExists(pad)) return types.NO_SUCH_PAD;
    const sys = gb.sys_base;
    sys.AcquireLock(&gb.lock);
    defer sys.ReleaseLock(&gb.lock);
    if (gb.owner[pad]) |holder| return holder;
    gb.owner[pad] = name;
    return null;
}
