// SPDX-License-Identifier: MPL-2.0
//! What the image classes draw with: borrowing a RastPort and giving it
//! back as it was, a pen at a time, and the bevel every frame is made of.
//!
//! A RastPort handed to an image is its caller's state, and an image is
//! only passing through: `save` reads the pens and the draw mode before
//! anything is drawn and `restore` puts them back after.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const Pen = graphics.Pen;
const sc = sdk.intuition.screens;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const default_pens = @import("../screen/_screen.zig").default_pens;

/// What a RastPort was set to before an image borrowed it.
///
/// The font is in here because an image whose shape is words sets one, and
/// an image is only passing through: the caller's next line of text would
/// otherwise come out in a font it never asked for.
pub const Saved = struct { apen: u32 = 0, bpen: u32 = 0, mode: u32 = 0, font: usize = 0 };

pub fn save(gb: *GraphicsBase, rp: *graphics.RastPort) Saved {
    var s: Saved = .{};
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&s.apen) },
        .{ .tag = graphics.RPTAG_BPen, .data = @intFromPtr(&s.bpen) },
        .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&s.mode) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&s.font) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    return s;
}

pub fn restore(gb: *GraphicsBase, rp: *graphics.RastPort, s: Saved) void {
    const put = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = s.apen },
        .{ .tag = graphics.RPTAG_BPen, .data = s.bpen },
        .{ .tag = graphics.RPTAG_DrMd, .data = s.mode },
        .{ .tag = graphics.RPTAG_Font, .data = s.font },
        .{},
    };
    gb.SetRPAttrs(rp, &put);
}

/// Draw from now on in one opaque pen, plainly.
pub fn pen(gb: *GraphicsBase, rp: *graphics.RastPort, value: Pen) void {
    const put = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = value },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &put);
}

/// The ghost laid over a disabled gadget: one pixel in four, in rows that
/// alternate, the leftmost pixel in each byte's highest bit.
const ghost_tile = [_]u8{ 0x44, 0x44, 0x11, 0x11 };

/// A disabled gadget's look: the ghost over its box, x/y/width/height, in
/// `value` - the window's block pen - with the pixels between left as they
/// were, so what the gadget shows stays readable under it.
pub fn ghost(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, w: i32, h: i32, value: Pen) void {
    if (w <= 0 or h <= 0) return;
    pen(gb, rp, value);
    gb.BltPattern(rp, &ghost_tile, 2, 16, 2, &.{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h });
}

/// The pens of a DrawInfo, or the default ones when there is none.
pub fn pensOf(draw_info: ?*const sc.DrawInfo) [*]const Pen {
    const dri = draw_info orelse return &default_pens;
    return dri.pens;
}

/// A filled rectangle, x/y/width/height.
pub fn box(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, w: i32, h: i32, value: Pen) void {
    if (w <= 0 or h <= 0) return;
    pen(gb, rp, value);
    gb.RectFill(rp, &.{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h });
}

/// A one-pixel outline, x/y/width/height.
pub fn outline(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, w: i32, h: i32, value: Pen) void {
    if (w <= 0 or h <= 0) return;
    pen(gb, rp, value);
    gb.DrawRect(rp, &.{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h });
}

/// A bevel `thick` pixels wide at the sides and one at the top and
/// bottom: `light` along the top and left, `dark` along the bottom and
/// right, and the two corners where they meet in `dark`, so the light
/// seems to come from the top left. Swapping the two sinks it.
/// How the light and dark edges meet at the other two corners.
pub const Joins = enum {
    /// Each edge stops short of the corner the other owns, so the top-left
    /// and bottom-right corners are square and the other two are bare.
    none,
    /// The light edge carries on into the bottom-left corner and the dark
    /// one into the top-right, so the join reads as a diagonal. Every frame
    /// but the plainest is drawn this way.
    angled,
};

/// A box lit from the top left: `light` along the top and down the left,
/// `dark` down the right and along the bottom.
///
/// `thick` is how many pixels wide the two upright edges are. The flat ones
/// are always one pixel, because a frame drawn square reads as heavy - the
/// displays this shape came from had pixels taller than they were wide, and
/// the look outlived them.
///
/// Each edge is drawn one stroke at a time, and each stroke stops one pixel
/// further from the corner the other colour owns - which is what makes the
/// join a diagonal rather than a step.
pub fn bevel(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, w: i32, h: i32, light: Pen, dark: Pen, thick: i32, joins: Joins) void {
    if (w <= 1 or h <= 1 or thick < 1) return;
    const flat: i32 = 1;
    const right = x + w - 1;
    const bottom = y + h - 1;
    // How far each edge keeps clear of the corner the other colour owns. An
    // angled join gives the bottom-left to the light edge and the top-right
    // to the dark one, so those two start at nothing.
    const clear_top: i32 = 1;
    const clear_left: i32 = if (joins == .angled) 0 else 1;
    const clear_right: i32 = if (joins == .angled) 0 else 1;
    const clear_bottom: i32 = 1;

    pen(gb, rp, light);
    var cnt = clear_top;
    var i: i32 = 0;
    while (i < flat) : (i += 1) {
        gb.DrawHLine(rp, x, y + i, w - cnt);
        if (cnt < thick) cnt += 1;
    }
    cnt = clear_left;
    i = 0;
    while (i < thick) : (i += 1) {
        gb.DrawVLine(rp, x + i, y + flat, bottom - cnt - (y + flat) + 1);
        if (cnt < flat) cnt += 1;
    }

    pen(gb, rp, dark);
    cnt = clear_right;
    i = 0;
    while (i < thick) : (i += 1) {
        gb.DrawVLine(rp, right - i, y + cnt, bottom - flat - (y + cnt) + 1);
        if (cnt < flat) cnt += 1;
    }
    cnt = clear_bottom;
    i = 0;
    while (i < flat) : (i += 1) {
        gb.DrawHLine(rp, x + cnt, bottom - i, right - (x + cnt) + 1);
        if (cnt < thick) cnt += 1;
    }
}
