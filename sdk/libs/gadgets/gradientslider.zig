// SPDX-License-Identifier: MIT
//! gradientslider.gadget: a slider whose container is a gradient through
//! a row of colours, with a small knob that picks a value from 0 to
//! `GRAD_MaxVal`. What a colour wheel's brightness is picked with.
//!
//! A press beside the knob moves the value by `GRAD_SkipVal` that way and
//! ends at once; a press on it drags it. Let go, the window hears
//! `IDCMP_GADGETUP`; the right button while dragging puts the value back.
//! The target hears `GRAD_CurVal` with the gadget's `GA_ID` at every
//! change, and once more when the press ends.
//!
//! Across (`PGA_Freedom` `FREEHORIZ`, the default) the value grows to the
//! right; up and down (`FREEVERT`) it grows downwards.
//!
//!   const shades = [_]graphics.Pen{ orange, black, gs.GRAD_PEN_END };
//!   const brightness = ib.NewObjectTagList(null, gs.GRAD_CLASS, &.{
//!       .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
//!       .{ .tag = gs.GRAD_PenArray, .data = @intFromPtr(&shades) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");
const graphics = @import("../graphics/graphics.zig");

/// What a program opens, and the class it then asks for.
pub const GRAD_LIBRARY = "gadgets/gradientslider.gadget";
pub const GRAD_CLASS = "gradientslider.gadget";

pub const GRAD_Dummy = gadgets.GADGETS_Dummy + 10 * gadgets.GADGETS_Step;
/// The largest value; 0xFFFF unless given. Made and set.
pub const GRAD_MaxVal = GRAD_Dummy + 1;
/// The value, from 0 to `GRAD_MaxVal`. Made, set and read; told to the
/// target as it changes.
pub const GRAD_CurVal = GRAD_Dummy + 2;
/// How far a press beside the knob moves the value; 0x1111 unless given.
/// Made and set.
pub const GRAD_SkipVal = GRAD_Dummy + 3;
/// How long the knob is, in pixels; 5 unless given. Made only.
pub const GRAD_KnobPixels = GRAD_Dummy + 4;
/// The colours the container runs through, from the start to the end: a
/// `[*]const graphics.Pen` ended by `GRAD_PEN_END`, not copied. Without
/// it, or with no colour in it, the container is the background pen and
/// the knob a plain box. Made and set.
pub const GRAD_PenArray = GRAD_Dummy + 5;

/// The end of `GRAD_PenArray`: a pen no colour is, as every colour has its
/// alpha.
pub const GRAD_PEN_END: graphics.Pen = 0;
