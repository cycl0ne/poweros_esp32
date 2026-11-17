// SPDX-License-Identifier: MPL-2.0
//! ClaimBoardPin: A part's line taken for its driver, whatever kind of
//! line it is.
//!
//! A pad of the chip is gpio.resource's to hand out, a pin of the IO
//! expander expander.resource's; this asks the one the line's kind names,
//! so a driver claims every line of its part the same way.

const sdk = @import("sdk");
const boardpin = sdk.expansion.boardpin;
const BoardPin = boardpin.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const expander = sdk.resources.expander;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// Takes a part's line for its driver.
///
/// SYNOPSIS:
/// ```zig
/// fn ClaimBoardPin(eb: *ExpansionBase, pin: usize, owner: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.6. LVO -60.
///
/// INPUTS:
/// - `pin` - the line, as its tag's `ti_Data` holds it
///   (`BoardPin.data`).
/// - `owner` - who takes it, as the resources list their holders; it
///   must outlive the claim.
///
/// RESULT:
/// Null when the line is now the caller's. Otherwise who holds it: the
/// other driver's name, `NO_SUCH_PAD` for a pad the chip has not got,
/// `BPIN_NO_SUCH_PIN` for a pin the expander has not got, and
/// `BPIN_NO_EXPANDER` for a pin of an expander the board has no
/// expander.resource for.
///
/// BEHAVIOR:
/// A pad of the chip (`BPIN_GPIO`) is taken from gpio.resource, a pin of
/// the expander (`BPIN_EXPANDER`) from expander.resource. A line of no
/// kind and one the part works itself (`BPIN_DRIVER`) are nobody's to
/// hold, and the answer is null; so is a pad on a machine without
/// gpio.resource, where nothing keeps a list of pads.
///
/// CONTEXT:
/// - Waits: for the resource's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The line is the caller's until `ReleaseBoardPin`. The answered name
/// is its holder's, to print and not to keep.
///
/// NOTES:
/// A driver claims every line it will drive before it drives the first,
/// so two drivers wired to one line meet at their claim and not at a
/// panel that goes dark when the other starts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBoardPin`, `SetBoardPin`, gpio.resource's `AllocGPIO`,
/// expander.resource's `ClaimPin`
///
/// EXAMPLES:
/// ```zig
/// const reset = rb.GetRtgTagData(st.PART_PinReset, 0, tag_list);
/// if (eb.ClaimBoardPin(reset, "rtg-dcs")) |holder| {
///     exec.kprintf(sys, "rtg-dcs: its reset line is %s's\n", .{holder});
///     return err.RTGERR_IN_USE;
/// }
/// ```
pub fn ClaimBoardPin(eb: *ExpansionBase, pin: usize, owner: [*:0]const u8) ?[*:0]const u8 {
    const line = BoardPin.of(pin);
    const sys = eb.sys_base;
    switch (line.kind) {
        boardpin.BPIN_GPIO => {
            const found = sys.OpenResource(gpio_resource.GPIONAME) orelse return null;
            const gb: *GpioBase = @ptrCast(@alignCast(found));
            return gb.AllocGPIO(line.number, owner);
        },
        boardpin.BPIN_EXPANDER => {
            const found = sys.OpenResource(expander.EXPANDERNAME) orelse return boardpin.BPIN_NO_EXPANDER;
            const xb: *ExpanderBase = @ptrCast(@alignCast(found));
            if (xb.ClaimPin(line.number, owner)) return null;
            return xb.PinOwner(line.number) orelse boardpin.BPIN_NO_SUCH_PIN;
        },
        else => return null,
    }
}
