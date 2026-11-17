// SPDX-License-Identifier: MPL-2.0
//! ReleaseBoardPin: A part's line given back to the resource it was
//! taken from.

const sdk = @import("sdk");
const boardpin = sdk.expansion.boardpin;
const BoardPin = boardpin.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const expander = sdk.resources.expander;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// Gives back a line ClaimBoardPin took.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBoardPin(eb: *ExpansionBase, pin: usize) void
/// ```
///
/// SINCE: 1.6. LVO -64.
///
/// INPUTS:
/// - `pin` - the line, as it was claimed.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A pad goes back to gpio.resource, a pin of the expander to
/// expander.resource. The line keeps the level and the direction it had:
/// a driver that wants it left low or as an input sets that first. A
/// line of no kind and one the part works itself have nothing to give
/// back.
///
/// CONTEXT:
/// - Waits: for the resource's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Only a line the caller claimed: the resources do not check who gives
/// one back.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClaimBoardPin`, `SetBoardPin`
///
/// EXAMPLES:
/// ```zig
/// eb.ReleaseBoardPin(panel.reset_pin.data());
/// ```
pub fn ReleaseBoardPin(eb: *ExpansionBase, pin: usize) void {
    const line = BoardPin.of(pin);
    const sys = eb.sys_base;
    switch (line.kind) {
        boardpin.BPIN_GPIO => {
            const found = sys.OpenResource(gpio_resource.GPIONAME) orelse return;
            const gb: *GpioBase = @ptrCast(@alignCast(found));
            gb.FreeGPIO(line.number);
        },
        boardpin.BPIN_EXPANDER => {
            const found = sys.OpenResource(expander.EXPANDERNAME) orelse return;
            const xb: *ExpanderBase = @ptrCast(@alignCast(found));
            xb.ReleasePin(line.number);
        },
        else => {},
    }
}
