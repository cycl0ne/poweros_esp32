// SPDX-License-Identifier: MIT
//! A line through a row of points, with the pens to draw it in.
//!
//! It is what a program hands to `DrawBorder` for an outline of its own -
//! a box around a group of gadgets, a rule under a heading - so that the
//! shape and its look are written down once and drawn wherever they are
//! wanted.

const graphics = @import("../graphics/graphics.zig");

/// One line, and the next one after it.
pub const Border = extern struct {
    /// Where the points are measured from, added to wherever it is drawn.
    left: i32 = 0,
    top: i32 = 0,
    /// The pen the line is drawn in, 0xAARRGGBB.
    front_pen: graphics.Pen = 0,
    /// The pen the gaps of a patterned line are filled with, when the
    /// draw mode lays paper down.
    back_pen: graphics.Pen = 0,
    /// graphics.library's DRMD_.
    draw_mode: u32 = graphics.DRMD_JAM1,
    /// How many points `xy` holds. The line runs from the first to each
    /// next one in turn, so one point draws nothing.
    count: u32 = 0,
    /// The points, x then y, `count` pairs of them.
    xy: ?[*]const i32 = null,
    /// The next line, drawn after this one, or null.
    next: ?*const Border = null,
};
