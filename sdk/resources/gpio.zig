// SPDX-License-Identifier: MIT
//! gpio.resource: who holds which of the chip's pads. A pad is one wire,
//! and two drivers that each think it is theirs fight over it without
//! either noticing - a card slot's clock that is also a panel's reset. A
//! driver takes each pad it routes with AllocGPIO, which answers who has it
//! when someone else does, and gives it back with FreeGPIO.
//!
//! It only keeps the list. Setting a pad up is the SDK's
//! `sdk.hardware.gpio`, as before; holding the pad is what makes that the
//! caller's business alone.
//!
//! The pads the system itself uses are taken when the resource starts:
//! the flash's, the PSRAM's, the USB port's and UART0's.
//!
//! Get its base with OpenResource(GPIONAME); its functions are in
//! sdk/interface/gpio.zig.

/// The resource's name, for OpenResource.
pub const GPIONAME = "gpio.resource";

/// Pads 0 to 48. 22 to 25 are not brought out on this chip and are
/// never handed out.
pub const GPIO_PADS: u32 = 49;

/// Whether `pad` is one the chip has.
pub fn padExists(pad: u32) bool {
    return pad < GPIO_PADS and (pad < 22 or pad > 25);
}

/// What AllocGPIO answers for a pad the chip does not have: a name no
/// driver is called, so the caller sees a refusal it can print.
pub const NO_SUCH_PAD = "(no such pad)";

/// The resource's base, with its functions.
pub const GpioBase = @import("../interface/gpio.zig").GpioBase;

/// A pad AllocPads could not have, and who has it.
pub const Refusal = struct { pad: u32, holder: [*:0]const u8 };

/// Take every pad in `pads` for `name`, or none of them: at the first
/// refusal the ones already taken are given back, and the refusal is
/// answered. Null when all are the caller's.
pub fn allocPads(gb: *GpioBase, pads: []const u8, name: [*:0]const u8) ?Refusal {
    for (pads, 0..) |pad, taken| {
        if (gb.AllocGPIO(pad, name)) |holder| {
            freePads(gb, pads[0..taken]);
            return .{ .pad = pad, .holder = holder };
        }
    }
    return null;
}

/// Give back every pad in `pads`.
pub fn freePads(gb: *GpioBase, pads: []const u8) void {
    for (pads) |pad| gb.FreeGPIO(pad);
}
