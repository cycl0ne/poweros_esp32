// SPDX-License-Identifier: MIT
//! A piece of text with the pens and the place to draw it in: an
//! IntuiText.
//!
//! It is what a program hands to anything that writes for it - a menu
//! item's words, a requester's message, a gadget's label, an
//! `itexticlass` image - so that the caller says once what the text is and
//! how it looks, and whoever draws it needs no arguments of its own.
//!
//! An IntuiText is a tag list of `IT_` tags: one run of text, and how it
//! looks. `IT_Next` names the next run, so a chain of runs - several
//! lines, or words in two colours - is drawn by one call. A run says only
//! what it means to: whatever it does not name is the RastPort's own, as
//! it was when the call was made, so a run without `IT_FrontPen` is drawn
//! in the pen the caller set, and one without `IT_Font` in the RastPort's
//! font. What one run names never carries over to the next.
//!
//! ```zig
//! const world = [_]TagItem{
//!     .{ .tag = IT_Text, .data = @intFromPtr("world") },
//!     .{ .tag = IT_Left, .data = 48 },
//!     .{ .tag = IT_Style, .data = graphics.FSF_BOLD },
//!     .{},
//! };
//! const hello = [_]TagItem{
//!     .{ .tag = IT_Text, .data = @intFromPtr("Hello") },
//!     .{ .tag = IT_Next, .data = @intFromPtr(&world) },
//!     .{},
//! };
//! ib.PrintIText(rp, &hello, 10, 10);
//! ```

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const TagItem = utility.TagItem;

pub const IT_Dummy = utility.TAG_USER + 0x3F000;
/// `[*:0]const u8`: the words. A run without them draws nothing; the runs
/// after it are still drawn.
pub const IT_Text = IT_Dummy + 0x01;
/// `graphics.Pen`, 0xAARRGGBB: the pen the letters are drawn in.
pub const IT_FrontPen = IT_Dummy + 0x02;
/// `graphics.Pen`: the pen behind them, where the draw mode lays paper
/// down.
pub const IT_BackPen = IT_Dummy + 0x03;
/// graphics.library's `DRMD_`: `DRMD_JAM1` leaves the ground alone,
/// `DRMD_JAM2` lays the back pen behind every letter.
pub const IT_DrawMode = IT_Dummy + 0x04;
/// `i32`: where the run goes, from the corner it is drawn at. 0 without.
pub const IT_Left = IT_Dummy + 0x05;
pub const IT_Top = IT_Dummy + 0x06;
/// `*graphics.TextFont`, open: the font to draw it in; null names none.
/// It stays the caller's, and open, for as long as the run is used.
pub const IT_Font = IT_Dummy + 0x07;
/// graphics.library's `FontStyle` (`FSF_BOLD`, `FSF_ITALIC`,
/// `FSF_UNDERLINED`): how the letters are drawn on top of the font's own
/// shape.
pub const IT_Style = IT_Dummy + 0x08;
/// `[*]const TagItem`: the next run, another IntuiText.
pub const IT_Next = IT_Dummy + 0x09;

/// A run of `words` in `font` - null names none - and nothing more: what
/// `IntuiTextLength` measures a word with.
pub fn plainRun(words: [*:0]const u8, font: ?*graphics.TextFont) [3]TagItem {
    return .{
        .{ .tag = IT_Text, .data = @intFromPtr(words) },
        .{ .tag = IT_Font, .data = @intFromPtr(font) },
        .{},
    };
}
