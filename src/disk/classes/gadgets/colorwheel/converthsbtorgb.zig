// SPDX-License-Identifier: MIT
//! ConvertHSBToRGB: a colour as hue, saturation and brightness to red,
//! green and blue.

const sdk = @import("sdk");
const gadgets = sdk.gadgets;
const cw = gadgets.colorwheel;
const colour = @import("_colour.zig");

/// A colour as hue, saturation and brightness, as red, green and blue.
///
/// SYNOPSIS:
/// ```zig
/// fn ConvertHSBToRGB(base: *ColorWheelBase, hsb: *const ColorWheelHSB, rgb: *ColorWheelRGB) void
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `hsb` - the colour: each component a 32-bit fraction, 0 none and
///   0xFFFFFFFF all; hue 0 is red and goes through yellow, green, cyan,
///   blue and magenta back to it.
/// - `rgb` - where the answer goes, in the same fractions.
///
/// RESULT:
/// Nothing; the colour is in `rgb`.
///
/// BEHAVIOR:
/// Worked in 16 bits, the top half of each fraction, and the answer
/// widened again: the top and bottom 16 bits of each component are the
/// same. No saturation is a grey as bright as the brightness.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: callable; it touches nothing but its arguments.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ConvertRGBToHSB`, colorwheel.gadget
///
/// EXAMPLES:
/// ```zig
/// const wheel_lib: *ColorWheelBase = @ptrCast(sys.OpenLibrary(cw.WHEEL_LIBRARY, 0) orelse return);
/// var rgb: cw.ColorWheelRGB = .{};
/// wheel_lib.ConvertHSBToRGB(&.{ .hue = 0, .saturation = 0xFFFFFFFF, .brightness = 0xFFFFFFFF }, &rgb);
/// ```
pub fn ConvertHSBToRGB(_: *gadgets.Base, hsb: *const cw.ColorWheelHSB, rgb: *cw.ColorWheelRGB) void {
    const out = colour.hsbToRgb(.{
        .hue = colour.narrow(hsb.hue),
        .saturation = colour.narrow(hsb.saturation),
        .brightness = colour.narrow(hsb.brightness),
    });
    rgb.* = .{ .red = colour.widen(out.red), .green = colour.widen(out.green), .blue = colour.widen(out.blue) };
}
