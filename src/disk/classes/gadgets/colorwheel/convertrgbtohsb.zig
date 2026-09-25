// SPDX-License-Identifier: MIT
//! ConvertRGBToHSB: a colour as red, green and blue to hue, saturation
//! and brightness.

const sdk = @import("sdk");
const gadgets = sdk.gadgets;
const cw = gadgets.colorwheel;
const colour = @import("_colour.zig");

/// A colour as red, green and blue, as hue, saturation and brightness.
///
/// SYNOPSIS:
/// ```zig
/// fn ConvertRGBToHSB(base: *ColorWheelBase, rgb: *const ColorWheelRGB, hsb: *ColorWheelHSB) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `rgb` - the colour: each component a 32-bit fraction, 0 none and
///   0xFFFFFFFF all.
/// - `hsb` - where the answer goes, in the same fractions.
///
/// RESULT:
/// Nothing; the colour is in `hsb`.
///
/// BEHAVIOR:
/// The brightness is the largest component, the saturation how far the
/// smallest is below it, and the hue where the colour lies round the
/// hexagon of red, yellow, green, cyan, blue and magenta. A grey has no
/// saturation, and then a hue of 0. Worked in 16 bits and widened again,
/// as `ConvertHSBToRGB`.
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
/// `ConvertHSBToRGB`, colorwheel.gadget
///
/// EXAMPLES:
/// ```zig
/// var hsb: cw.ColorWheelHSB = .{};
/// wheel_lib.ConvertRGBToHSB(&.{ .red = 0xFFFFFFFF, .green = 0x80008000, .blue = 0 }, &hsb);
/// ```
pub fn ConvertRGBToHSB(_: *gadgets.Base, rgb: *const cw.ColorWheelRGB, hsb: *cw.ColorWheelHSB) void {
    const out = colour.rgbToHsb(.{
        .red = colour.narrow(rgb.red),
        .green = colour.narrow(rgb.green),
        .blue = colour.narrow(rgb.blue),
    });
    hsb.* = .{ .hue = colour.widen(out.hue), .saturation = colour.widen(out.saturation), .brightness = colour.widen(out.brightness) };
}
