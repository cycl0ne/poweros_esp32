// SPDX-License-Identifier: MPL-2.0
//! DrawPart: draws a part of a gadget in a state, from its style.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const style = sdk.intuition.style;
const sc = sdk.intuition.screens;
const Pen = graphics.Pen;
const Rect = graphics.Rect;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _style = @import("_style.zig");
const d = @import("../classes/draw.zig");

/// Draws a part of a gadget in a state, from its style.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawPart(ib: *IntuitionBase, rp: ?*graphics.RastPort,
///     draw_info: ?*const DrawInfo, own: ?*const Style, part: u32,
///     state: u32, flags: u32, box: *const Rect, content: ?*Rect) void
/// ```
///
/// SINCE: 0.20. LVO -476.
///
/// INPUTS:
/// - `rp` - where to draw, or null to draw nothing and only answer
///   `content`.
/// - `draw_info` - the screen's, for its pens and its style; null for the
///   default pens and the system's default style alone.
/// - `own` - a gadget's own style (`GA_Style`, read back), or null.
/// - `part` - a `style.PART_` number, or a class's own (`style.classPart`).
/// - `state` - `style.STATE_` bits, or a mixed state (`style.mixState`):
///   the look part of the way from one state to another, every colour
///   mixed channel by channel and every number rounded.
/// - `flags` - `style.DPF_INVERT` to turn the border the other way,
///   `style.DPF_EDGES_ONLY` to draw the border and leave the inside.
/// - `box` - where the part goes, half-open.
/// - `content` - where to write the room left inside the border and the
///   padding, or null.
///
/// RESULT:
/// Nothing. `content`, when given, is `box` less the border and the
/// padding on each side; a box too small for them gives an empty one at
/// its middle rather than a negative one.
///
/// BEHAVIOR:
/// Every property is found on its own, by the order the styles header
/// describes: the most particular state first, then the gadget's own style
/// before the screen's before the default, then the exact part before the
/// one it falls back to.
///
/// What is drawn, in order:
///
/// - **The inside** in the background - a colour, or a fill style laid
///   across the inside as a gradient or a tile - inside the border, or, for
///   a part with a radius, the whole rounded shape with the border drawn
///   over it. Not with `DPF_EDGES_ONLY`.
/// - **The border**, by its kind: a flat one in the border colour; a raised
///   or recessed bevel in the shine and shadow colours, `STYLE_BorderX`
///   thick at the sides and `STYLE_BorderY` at the top and bottom, its
///   corners meeting as `STYLE_Joins` says; a ridge or a groove as two
///   bevels, one inside the other, turned opposite ways, with
///   `STYLE_BorderGap` thicknesses of the inside between them. A bevel with a
///   radius is drawn by `DrawRoundBevel`: its two colours meet on the
///   diagonal through the top-right and bottom-left corners.
///
/// An opacity below 255 lays every colour over what is there by that much.
/// A part with a radius is drawn with smooth edges (`RPTAG_Smooth`), the
/// RastPort's own setting given back afterwards.
///
/// The RastPort's pens, draw mode and font are put back as they were.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and the styles are only read.
///
/// NOTES:
/// - With nothing set anywhere - a screen given no style - every part looks
///   as frames always have: the default style is written to be that look.
/// - A class measures a part with `rp` null: the content box of a part in
///   a given box is what a frame around contents needs to add.
///
/// BUGS:
/// - A rounded border is as thick all round as the thicker of its two
///   thicknesses.
///
/// SEE ALSO:
/// `GetStyleAttr`, `SA_Style`, `GA_Style`, `DrawImageState`
///
/// EXAMPLES:
/// ```zig
/// // A button's body, and the room for its label inside it.
/// var inside: graphics.Rect = undefined;
/// ib.DrawPart(rp, draw_info, own, style.PART_MAIN,
///     if (pressed) style.STATE_PRESSED else style.STATE_NORMAL, 0,
///     &box, &inside);
/// ```
pub fn DrawPart(ib: *IntuitionBase, rp: ?*graphics.RastPort, draw_info: ?*const sc.DrawInfo, own: ?*const style.Style, part: u32, state: u32, flags: u32, box: *const Rect, content: ?*Rect) void {
    const pens = d.pensOf(draw_info);
    const num_pens: u32 = if (draw_info) |dri| dri.num_pens else sc.NUMDRIPENS;
    const look = _style.lookFor(ib, own, draw_info, part, state, pens, num_pens);

    var kind = look.get(.border);
    if (flags & style.DPF_INVERT != 0) kind = switch (kind) {
        style.BORDER_RAISED => style.BORDER_RECESSED,
        style.BORDER_RECESSED => style.BORDER_RAISED,
        style.BORDER_RIDGE => style.BORDER_GROOVE,
        style.BORDER_GROOVE => style.BORDER_RIDGE,
        else => kind,
    };
    const doubled = kind == style.BORDER_RIDGE or kind == style.BORDER_GROOVE;
    const bx: i32 = @intCast(look.get(.border_x));
    const by: i32 = @intCast(look.get(.border_y));
    // A ridge or a groove is two bevels, the inner one `gap` thicknesses in.
    const gap: i32 = if (doubled) @intCast(look.get(.gap)) else 0;
    const tx: i32 = if (kind == style.BORDER_NONE) 0 else if (doubled) (2 + gap) * bx else bx;
    const ty: i32 = if (kind == style.BORDER_NONE) 0 else if (doubled) (2 + gap) * by else by;

    if (content) |inside| inside.* = inset(box.*, tx + @as(i32, @intCast(look.get(.padding_x))), ty + @as(i32, @intCast(look.get(.padding_y))));
    const target = rp orelse return;
    if (box.isEmpty()) return;

    const gb = ib.graphics_base;
    const saved = d.save(gb, target);
    defer d.restore(gb, target, saved);

    const opacity = look.get(.opacity);
    const colour = struct {
        fn of(l: *const _style.Look, p: _style.Prop, all: [*]const Pen, n: u32, alpha: u32) Pen {
            const value = l.colour(p, all, n);
            if (alpha >= 255) return value;
            return (value & 0x00FF_FFFF) | ((value >> 24) * alpha / 255) << 24;
        }
    }.of;
    const background = colour(&look, .background, pens, num_pens, opacity);
    const shine = colour(&look, .shine, pens, num_pens, opacity);
    const shadow = colour(&look, .shadow, pens, num_pens, opacity);
    const line = colour(&look, .border_colour, pens, num_pens, opacity);
    const radius: i32 = @intCast(look.get(.radius));
    const joins: d.Joins = if (look.get(.joins) == style.JOINS_ANGLED) .angled else .none;
    const fill = flags & style.DPF_EDGES_ONLY == 0;

    const x = box.min_x;
    const y = box.min_y;
    const w = box.width();
    const h = box.height();

    // A background given as a fill style is laid on for the fill alone, with
    // the part's opacity on every stop of it, and taken off again before the
    // border: a flat border is a fill too, and must stay its own colour.
    var gradient: graphics.FillStyle = undefined;
    const fill_style: ?*const graphics.FillStyle = if (look.backgroundFill()) |given| faded: {
        gradient = given.*;
        if (opacity < 255) {
            for (&gradient.stops) |*stop| {
                stop.pen = (stop.pen & 0x00FF_FFFF) | ((stop.pen >> 24) * opacity / 255) << 24;
            }
        }
        break :faded &gradient;
    } else null;

    if (radius > 0) {
        // A round part is drawn with smooth edges: its corners are curves,
        // and a curve without them is a stair.
        gb.SetRPAttrs(target, &[_]sdk.utility.TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
        if (fill) {
            d.pen(gb, target, background);
            if (fill_style) |f| d.fillWith(gb, target, f);
            gb.FillRoundRect(target, box, @intCast(radius));
            if (fill_style != null) d.fillWith(gb, target, null);
        }
        if (kind == style.BORDER_NONE) return;
        // One outline the border's thickness wide, which grows inward and
        // leaves no gap on the corners; a bevel in its two colours, a ridge
        // or a groove as two bevels, the inner one turned the other way.
        const band: i32 = @max(@max(bx, by), 1);
        gb.SetRPAttrs(target, &[_]sdk.utility.TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = @intCast(band) }, .{} });
        switch (kind) {
            style.BORDER_FLAT => {
                d.pen(gb, target, line);
                gb.DrawRoundRect(target, box, @intCast(radius));
            },
            style.BORDER_RAISED => gb.DrawRoundBevel(target, box, @intCast(radius), shine, shadow),
            style.BORDER_RECESSED => gb.DrawRoundBevel(target, box, @intCast(radius), shadow, shine),
            style.BORDER_RIDGE, style.BORDER_GROOVE => {
                const out_light = if (kind == style.BORDER_RIDGE) shine else shadow;
                const out_dark = if (kind == style.BORDER_RIDGE) shadow else shine;
                gb.DrawRoundBevel(target, box, @intCast(radius), out_light, out_dark);
                const inner = inset(box.*, (1 + gap) * band, (1 + gap) * band);
                gb.DrawRoundBevel(target, &inner, @intCast(@max(radius - (1 + gap) * band, 0)), out_dark, out_light);
            },
            else => {},
        }
        return;
    }

    if (fill) {
        if (fill_style) |f| d.fillWith(gb, target, f);
        // Inside the outer bevel: a ridge's inner bevel is drawn over it, and
        // the gap between the two is the inside too.
        const fx = if (doubled) bx else tx;
        const fy = if (doubled) by else ty;
        d.box(gb, target, x + fx, y + fy, w - 2 * fx, h - 2 * fy, background);
        if (fill_style != null) d.fillWith(gb, target, null);
    }
    switch (kind) {
        style.BORDER_FLAT => {
            d.box(gb, target, x, y, w, ty, line);
            d.box(gb, target, x, y + h - ty, w, ty, line);
            d.box(gb, target, x, y + ty, tx, h - 2 * ty, line);
            d.box(gb, target, x + w - tx, y + ty, tx, h - 2 * ty, line);
        },
        style.BORDER_RAISED => d.bevelXY(gb, target, x, y, w, h, shine, shadow, bx, by, joins),
        style.BORDER_RECESSED => d.bevelXY(gb, target, x, y, w, h, shadow, shine, bx, by, joins),
        style.BORDER_RIDGE, style.BORDER_GROOVE => {
            const out_light = if (kind == style.BORDER_RIDGE) shine else shadow;
            const out_dark = if (kind == style.BORDER_RIDGE) shadow else shine;
            d.bevelXY(gb, target, x, y, w, h, out_light, out_dark, bx, by, joins);
            const ix = (1 + gap) * bx;
            const iy = (1 + gap) * by;
            d.bevelXY(gb, target, x + ix, y + iy, w - 2 * ix, h - 2 * iy, out_dark, out_light, bx, by, joins);
        },
        else => {},
    }
}

/// A rectangle with `dx` taken off each side and `dy` off the top and
/// bottom; too small for that, an empty one at its middle.
fn inset(r: Rect, dx: i32, dy: i32) Rect {
    var out = Rect{ .min_x = r.min_x + dx, .min_y = r.min_y + dy, .max_x = r.max_x - dx, .max_y = r.max_y - dy };
    if (out.max_x < out.min_x) {
        const mid = r.min_x + @divTrunc(r.width(), 2);
        out.min_x = mid;
        out.max_x = mid;
    }
    if (out.max_y < out.min_y) {
        const mid = r.min_y + @divTrunc(r.height(), 2);
        out.min_y = mid;
        out.max_y = mid;
    }
    return out;
}
