// SPDX-License-Identifier: MPL-2.0
//! SetBoardPin: A part's line driven to its asserted level or away from
//! it, whatever kind of line it is.
//!
//! A pad of the chip is put on the GPIO matrix's own output and made an
//! output, its level written before it drives; a pin of the IO expander
//! is set through expander.resource, which does the same for its pins.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const boardpin = sdk.expansion.boardpin;
const BoardPin = boardpin.BoardPin;
const expander = sdk.resources.expander;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// A pad of the chip driven to `high`: on the GPIO matrix's own output,
/// its level written, then an output. False on a chip whose pads this
/// does not drive.
///
/// INPUTS:
/// - `pad` - the pad.
/// - `high` - the level.
fn drivePad(pad: u8, high: bool) bool {
    switch (hardware.chip) {
        .esp32s3, .esp32p4 => {
            const gpio = hardware.gpio;
            gpio.toMatrix(pad);
            gpio.connectOut(pad, gpio.out_of_gpio, true);
            gpio.setLevel(pad, high);
            gpio.outputEnable(pad, true);
            return true;
        },
        .rv64sbi, .a64psci, .x64uefi => return false,
    }
}

/// Drives a part's line.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardPin(eb: *ExpansionBase, pin: usize, asserted: bool) bool
/// ```
///
/// SINCE: 1.6. LVO -68.
///
/// INPUTS:
/// - `pin` - the line, as its tag's `ti_Data` holds it
///   (`BoardPin.data`).
/// - `asserted` - true for the level the line is asserted at - low for
///   one that is asserted low - false for the other.
///
/// RESULT:
/// True when the line was driven. False for a line of no kind and one
/// the part works itself (`BPIN_DRIVER`), which its driver drives its own
/// way; for a pin of an expander the board has no expander.resource for,
/// or that does not answer; and for a pad on a chip whose pads this does
/// not drive.
///
/// BEHAVIOR:
/// A pad of the chip is taken onto the GPIO matrix, its output from the
/// GPIO's own register, its level written and then its driver switched
/// on, so it never drives the other level first. A pin of the expander
/// is set by expander.resource, which makes it an output the same way.
/// The call does not claim the line: a driver claims it first
/// (`ClaimBoardPin`).
///
/// CONTEXT:
/// - Waits: for a pin of the expander, while it is sent over I2C.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A false answer for a line that is wired says the driver must reach
/// the part another way: a panel without a reset line is reset by its
/// own command.
///
/// BUGS:
/// The pads of the ESP32-S3 and the ESP32-P4 are driven; on the other
/// chips a pad answers false.
///
/// SEE ALSO:
/// `ClaimBoardPin`, `ReleaseBoardPin`, expander.resource's `SetPin`
///
/// EXAMPLES:
/// ```zig
/// if (eb.SetBoardPin(reset, true)) {
///     rb.RtgDelay(10 * 1000);
///     _ = eb.SetBoardPin(reset, false);
/// } else {
///     _ = rb.TxParam(io, SWRESET, null, 0);
/// }
/// ```
pub fn SetBoardPin(eb: *ExpansionBase, pin: usize, asserted: bool) bool {
    const line = BoardPin.of(pin);
    const high = asserted == (line.active_low == 0);
    switch (line.kind) {
        boardpin.BPIN_GPIO => return drivePad(line.number, high),
        boardpin.BPIN_EXPANDER => {
            const found = eb.sys_base.OpenResource(expander.EXPANDERNAME) orelse return false;
            const xb: *ExpanderBase = @ptrCast(@alignCast(found));
            return xb.SetPin(line.number, high);
        },
        else => return false,
    }
}
