// SPDX-License-Identifier: MIT
//! spinner.gadget: a ring of dots going round, while something goes on.
//!
//! Eight dots on a circle in the gadget's box, one lit and the ones behind
//! it fading, the lit one moving round a dot at a time on motion.library's
//! clock. It says "wait" without saying how long: a gauge
//! (`fuelgauge.gadget`) is for work whose end is known.
//!
//! It turns while `SPINNER_Running` is on and it is in a window. A gadget
//! or a screen that does not move (`GA_Animate`, `SA_Animate`), or a
//! system without motion.library, shows the ring still, all its dots lit.
//! The lit dot is the style's indicator (`PART_INDICATOR`), the rest fade
//! towards the gadget's background. It is never pressed.
//!
//!   const spinner = ib.NewObjectTagList(null, sp.SPINNER_CLASS, &.{
//!       .{ .tag = gc.GA_Width, .data = 32 },
//!       .{ .tag = gc.GA_Height, .data = 32 },
//!       .{},
//!   });
//!   // ... when the work is done
//!   _ = ib.SetGadgetAttrsTagList(spinner, window, &.{
//!       .{ .tag = sp.SPINNER_Running, .data = 0 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const SPINNER_LIBRARY = "gadgets/spinner.gadget";
pub const SPINNER_CLASS = "spinner.gadget";

pub const SPINNER_Dummy = gadgets.GADGETS_Dummy + 19 * gadgets.GADGETS_Step;
/// Bool: it turns (true unless given). Made, set and read.
pub const SPINNER_Running = SPINNER_Dummy + 0x01;
/// How long one turn takes, in milliseconds (1000 unless given). Made and
/// set.
pub const SPINNER_Period = SPINNER_Dummy + 0x02;

/// How many dots go round.
pub const SPINNER_DOTS = 8;
