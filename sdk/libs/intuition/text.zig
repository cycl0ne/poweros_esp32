// SPDX-License-Identifier: MIT
//! A piece of text with the pens and the place to draw it in.
//!
//! It is what a program hands to anything that writes for it - a menu
//! item's words, a requester's message, an `itexticlass` image - so that
//! the caller says once what the text is and how it looks, and whoever
//! draws it needs no arguments of its own.

const graphics = @import("../graphics/graphics.zig");

/// One run of text, and the next one after it.
pub const IntuiText = extern struct {
    /// The pen the letters are drawn in, 0xAARRGGBB.
    front_pen: graphics.Pen = 0,
    /// The pen behind them, used when the draw mode lays paper down.
    back_pen: graphics.Pen = 0,
    /// graphics.library's DRMD_: JAM1 leaves the ground alone, JAM2 lays
    /// the back pen behind every letter.
    draw_mode: u32 = graphics.DRMD_JAM1,
    /// Where it goes, from whatever corner it is drawn at.
    left: i32 = 0,
    top: i32 = 0,
    /// The font to draw it in, or null for the RastPort's own.
    font: ?*graphics.TextFont = null,
    /// The text itself.
    text: ?[*:0]const u8 = null,
    /// The next run, drawn after this one, or null.
    next: ?*IntuiText = null,
};
