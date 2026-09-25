// SPDX-License-Identifier: MIT
//! colorwheel.gadget: a wheel of every hue around and every saturation
//! from its middle out, on which a dot is dragged to pick a colour. Its
//! library has two calls of its own, between a colour as hue, saturation
//! and brightness and as red, green and blue (`ConvertHSBToRGB`,
//! `ConvertRGBToHSB`, through `sdk.interface.colorwheel`).
//!
//! Every component is a fraction in 32 bits: 0 is none, 0xFFFFFFFF all.
//! Hue 0 is red, at the top of the wheel, and goes round through yellow,
//! green, cyan, blue and magenta. The wheel is shown at full brightness;
//! `WHEEL_Brightness` is kept with the colour and counts in its red,
//! green and blue.
//!
//! A press on the wheel moves the dot there and holds it; the dot follows
//! the pointer, and the target hears `WHEEL_Hue` and `WHEEL_Saturation`
//! with the gadget's `GA_ID` at every change. Let go, the window hears
//! `IDCMP_GADGETUP`; the right button while it is held puts the colour
//! back as it was before the press.
//!
//!   const lib = sys.OpenLibrary(cw.WHEEL_LIBRARY, 0) orelse return;
//!   const wheel = ib.NewObjectTagList(null, cw.WHEEL_CLASS, &.{
//!       .{ .tag = gc.GA_Width, .data = 120 },
//!       .{ .tag = gc.GA_Height, .data = 120 },
//!       .{ .tag = cw.WHEEL_RGB, .data = @intFromPtr(&start) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const WHEEL_LIBRARY = "gadgets/colorwheel.gadget";
pub const WHEEL_CLASS = "colorwheel.gadget";

/// A colour as hue, saturation and brightness.
pub const ColorWheelHSB = extern struct {
    hue: u32 = 0,
    saturation: u32 = 0,
    brightness: u32 = 0,
};

/// A colour as red, green and blue.
pub const ColorWheelRGB = extern struct {
    red: u32 = 0,
    green: u32 = 0,
    blue: u32 = 0,
};

pub const WHEEL_Dummy = gadgets.GADGETS_Dummy + 9 * gadgets.GADGETS_Step;
/// The colour's components, each set and read on its own: made, set and
/// read. Hue and saturation are told to the target as the dot moves.
pub const WHEEL_Hue = WHEEL_Dummy + 1;
pub const WHEEL_Saturation = WHEEL_Dummy + 2;
pub const WHEEL_Brightness = WHEEL_Dummy + 3;
/// All three at once: a `*const ColorWheelHSB` to set; read, the
/// `ColorWheelHSB` whose address is given to `GetAttr` as its storage is
/// filled in.
pub const WHEEL_HSB = WHEEL_Dummy + 4;
/// The colour as red, green and blue, each on its own: made, set and read.
/// Setting one keeps the other two as they are.
pub const WHEEL_Red = WHEEL_Dummy + 5;
pub const WHEEL_Green = WHEEL_Dummy + 6;
pub const WHEEL_Blue = WHEEL_Dummy + 7;
/// All three at once, as `WHEEL_HSB`: a `ColorWheelRGB`.
pub const WHEEL_RGB = WHEEL_Dummy + 8;
/// Bool, made only: the wheel in a button bevel, which fills the gadget's
/// box, and pressed anywhere in it.
pub const WHEEL_BevelBox = WHEEL_Dummy + 12;
