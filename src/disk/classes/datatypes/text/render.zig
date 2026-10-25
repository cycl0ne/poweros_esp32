// SPDX-License-Identifier: MIT
//! The laid-out text drawn into the box the object was given.
//!
//! **The text is a page of its own colours**: GitHub's, light, or dark
//! on a screen whose ground is dark - the page, its text, what is set
//! back, the lines, the grounds of code and of every other row of a
//! table, and links. A marked stretch is drawn the other way round, in
//! the screen's own marking pens.
//!
//! First the page, then what is drawn round the text - grounds, lines,
//! marks - then the lines that reach into the box, each fragment of
//! them that reaches into it across, code inside a line on its own
//! ground. A fragment the mark starts or ends inside is drawn in two or
//! three pieces; everything else is one call a fragment.
//!
//! **Everything is clipped to the box** by the RastPort's clip
//! rectangle, which narrows a window's own clipping rather than
//! replacing it: a line the box's edge cuts is drawn as far as the edge.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const _text = @import("_text.zig");
const Data = _text.Data;
const Deco = _text.Deco;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Base = gadgets.Base;
const TagItem = sdk.utility.TagItem;

/// The colours a page is drawn in, and the screen's marking pens.
const Inks = struct {
    paper: [_text.ink_count]graphics.Pen,
    mark_ground: graphics.Pen,
    mark_text: graphics.Pen,
    screen: [*]const graphics.Pen,
};

/// The pen a run asks for, as a colour of the page.
fn penOf(which: u32, inks: *const Inks) graphics.Pen {
    return switch (which) {
        tdc.TDPEN_TEXT => inks.paper[_text.INK_TEXT],
        tdc.TDPEN_MUTED, tdc.TDPEN_SHADOW => inks.paper[_text.INK_MUTED],
        tdc.TDPEN_LINK, tdc.TDPEN_FILL => inks.paper[_text.INK_LINK],
        tdc.TDPEN_SHINE => inks.screen[sc.SHINEPEN],
        tdc.TDPEN_HIGHLIGHTTEXT => inks.screen[sc.HIGHLIGHTTEXTPEN],
        else => which,
    };
}

/// Where the text is on the screen: the box, and how far it has been
/// scrolled.
const View = struct {
    box: gc.Box,
    left: i32,
    top: i32,

    fn x(v: View, at: i32) i32 {
        return v.box.left + at - v.left;
    }

    fn y(v: View, at: i32) i32 {
        return v.box.top + at - v.top;
    }

    /// Whether a stretch down the text reaches into the box.
    fn showsRows(v: View, top: i32, height: i32) bool {
        return top + height > v.top and top < v.top + v.box.height;
    }
};

/// The text drawn into `box`, with the view starting `left` pixels
/// across and `top` pixels down it.
pub fn paint(base: *Base, own: *Data, info: *classusr.GadgetInfo, rp: *graphics.RastPort, box: gc.Box, left: i32, top: i32) void {
    const gb = base.graphics_base;
    const styled = support.pensFor(base.intuition_base, info.draw_info, null, intuition.style.PART_MAIN, intuition.style.PART_SELECTION);
    const inks = Inks{
        .paper = _text.paperFor(styled[sc.BACKGROUNDPEN]),
        .mark_ground = styled[sc.FILLPEN],
        .mark_text = styled[sc.FILLTEXTPEN],
        .screen = &styled,
    };
    support.fill(gb, rp, box, inks.paper[_text.INK_PAGE]);
    if (box.width <= 0 or box.height <= 0) return;
    const view = View{ .box = box, .left = left, .top = top };

    // Clipped to the box, and the clip put back after.
    var was: graphics.Rect = .{};
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
    const clip = graphics.Rect{ .min_x = box.left, .min_y = box.top, .max_x = box.left + box.width, .max_y = box.top + box.height };
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });

    if (own.decos) |decos| {
        for (decos[0..own.deco_count]) |*deco| drawDeco(base, own, rp, view, &inks, deco);
    }
    const lines = own.lines orelse return;
    const buffer = own.buffer orelse return;
    const fragments = own.fragments orelse return;
    const pieces = own.pieces orelse return;
    const mark_from = @min(own.mark_start, own.mark_end);
    const mark_to = @max(own.mark_start, own.mark_end);

    for (lines[0..own.line_count]) |line| {
        if (!view.showsRows(line.top, line.height)) continue;
        const baseline = view.y(line.top + line.baseline);
        for (fragments[line.first..][0..line.count]) |fragment| {
            const x = view.x(fragment.left);
            if (x + fragment.width <= box.left or x >= box.left + box.width) continue;
            const piece = &pieces[fragment.piece];
            if (piece.style & tdc.TDSTYLE_CODE != 0) codeGround(base, own, rp, &inks, piece, x, fragment.width, baseline);
            _text.wearPiece(gb, own, rp, piece);
            drawFragment(gb, rp, .{
                .buffer = buffer,
                .piece = piece,
                .offset = fragment.offset,
                .length = fragment.length,
                .x = x + fragment.inset,
                .y = baseline,
                .mark_from = mark_from,
                .mark_to = mark_to,
                .inks = &inks,
            });
            if (piece.style & tdc.TDSTYLE_STRUCK != 0) strike(gb, own, rp, &inks, piece, x + fragment.inset, fragment.width - 2 * fragment.inset, baseline);
        }
    }
}

/// What one fragment needs to be drawn.
const Drawing = struct {
    buffer: [*]const u8,
    piece: *const tdc.Piece,
    offset: u32,
    length: u32,
    x: i32,
    y: i32,
    mark_from: u32,
    mark_to: u32,
    inks: *const Inks,
};

/// One fragment drawn, in up to three pieces where a mark starts or
/// ends inside it.
fn drawFragment(gb: *GraphicsBase, rp: *graphics.RastPort, it: Drawing) void {
    const end = it.offset + it.length;
    const marked_from = @max(it.mark_from, it.offset);
    const marked_to = @min(it.mark_to, end);
    var at = it.offset;
    var x = it.x;
    if (marked_from < marked_to) {
        x = drawPart(gb, rp, it, at, marked_from, x, false);
        at = marked_from;
        x = drawPart(gb, rp, it, at, marked_to, x, true);
        at = marked_to;
    }
    _ = drawPart(gb, rp, it, at, end, x, false);
}

/// A stretch of a fragment drawn from `x`, marked or not. Where the
/// next stretch starts.
fn drawPart(gb: *GraphicsBase, rp: *graphics.RastPort, it: Drawing, from: u32, to: u32, x: i32, marked: bool) i32 {
    if (to <= from) return x;
    const width = gb.TextLength(rp, it.buffer + from, to - from);
    const ink = if (marked) it.inks.mark_text else penOf(it.piece.pen, it.inks);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = ink },
        .{ .tag = graphics.RPTAG_BPen, .data = it.inks.mark_ground },
        .{ .tag = graphics.RPTAG_DrMd, .data = if (marked) graphics.DRMD_JAM2 else graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, x, it.y);
    gb.Text(rp, it.buffer + from, to - from);
    return x + width;
}

/// The ground of code inside a line: a little taller than its letters,
/// with round corners.
fn codeGround(base: *Base, own: *const Data, rp: *graphics.RastPort, inks: *const Inks, piece: *const tdc.Piece, x: i32, width: i32, baseline: i32) void {
    const size = _text.heightOf(own, piece);
    const pad = @max(@divTrunc(size.height, 8), 1);
    const top = baseline - size.baseline - pad;
    const height = size.height + 2 * pad;
    const radius: u32 = @intCast(@max(@min(@divTrunc(size.height * 3, 8), @divTrunc(height, 2)), 1));
    shape(base.graphics_base, rp, inks.paper[_text.INK_CODE]);
    base.graphics_base.FillRoundRect(rp, &.{ .min_x = x, .min_y = top, .max_x = x + width, .max_y = top + height }, radius);
    plain(base.graphics_base, rp);
}

/// A line through the middle of a run's small letters.
fn strike(gb: *GraphicsBase, own: *const Data, rp: *graphics.RastPort, inks: *const Inks, piece: *const tdc.Piece, x: i32, width: i32, baseline: i32) void {
    const size = _text.heightOf(own, piece);
    const thick = @max(@divTrunc(size.height, 16), 1);
    const y = baseline - @divTrunc(size.height * 5, 16);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = penOf(piece.pen, inks) }, .{} });
    gb.RectFill(rp, &.{ .min_x = x, .min_y = y, .max_x = x + width, .max_y = y + thick });
}

/// A pen set for a shape with smooth edges.
fn shape(gb: *GraphicsBase, rp: *graphics.RastPort, pen: graphics.Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
        .{},
    });
}

/// Hard edges and thin lines again, as the RastPort had them.
fn plain(gb: *GraphicsBase, rp: *graphics.RastPort) void {
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_Smooth, .data = 0 },
        .{ .tag = graphics.RPTAG_LineWidth, .data = 1 },
        .{},
    });
}

/// One of the things drawn round the text, where it reaches into the
/// box.
fn drawDeco(base: *Base, own: *const Data, rp: *graphics.RastPort, view: View, inks: *const Inks, deco: *const Deco) void {
    const gb = base.graphics_base;
    const pen = inks.paper[deco.ink];
    switch (deco.kind) {
        _text.DECO_DISC, _text.DECO_CIRCLE => {
            if (!view.showsRows(deco.y - deco.width, 2 * deco.width + 1)) return;
            shape(gb, rp, pen);
            gb.FillArc(rp, &.{
                .cx = view.x(deco.x),
                .cy = view.y(deco.y),
                .radius = deco.width,
                .inner = if (deco.kind == _text.DECO_CIRCLE) @max(deco.width - 1, 1) else 0,
            });
            plain(gb, rp);
        },
        _text.DECO_NUMBER, _text.DECO_ROMAN, _text.DECO_LETTER => {
            const font = _text.fontOf(own, tdc.TDFONT_NORMAL) orelse return;
            if (!view.showsRows(deco.y - font.image.baseline, font.image.height)) return;
            var text: [16]u8 = undefined;
            const n = numberText(deco.kind, deco.number, &text);
            gb.SetRPAttrs(rp, &[_]TagItem{
                .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
                .{ .tag = graphics.RPTAG_TextStyle, .data = 0 },
                .{ .tag = graphics.RPTAG_APen, .data = pen },
                .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
                .{},
            });
            const width = gb.TextLength(rp, &text, @intCast(n));
            gb.Move(rp, view.x(deco.x) - width, view.y(deco.y));
            gb.Text(rp, &text, @intCast(n));
        },
        else => {
            if (!view.showsRows(deco.y, deco.height)) return;
            const area = graphics.Rect{
                .min_x = view.x(deco.x),
                .min_y = view.y(deco.y),
                .max_x = view.x(deco.x) + deco.width,
                .max_y = view.y(deco.y) + deco.height,
            };
            switch (deco.kind) {
                _text.DECO_ROUND => {
                    shape(gb, rp, pen);
                    gb.FillRoundRect(rp, &area, deco.number);
                    plain(gb, rp);
                },
                _text.DECO_TASK => {
                    shape(gb, rp, inks.paper[_text.INK_PAGE]);
                    gb.FillRoundRect(rp, &area, deco.number);
                    shape(gb, rp, pen);
                    gb.DrawRoundRect(rp, &area, deco.number);
                    plain(gb, rp);
                },
                _text.DECO_DONE => {
                    shape(gb, rp, pen);
                    gb.FillRoundRect(rp, &area, deco.number);
                    tick(gb, rp, area, inks.paper[_text.INK_ON_LINK]);
                    plain(gb, rp);
                },
                else => {
                    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
                    gb.RectFill(rp, &area);
                },
            }
        },
    }
}

/// A tick in a box, two strokes thick.
fn tick(gb: *GraphicsBase, rp: *graphics.RastPort, area: graphics.Rect, pen: graphics.Pen) void {
    const w = area.max_x - area.min_x;
    const h = area.max_y - area.min_y;
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_Smooth, .data = 0 },
        .{ .tag = graphics.RPTAG_LineWidth, .data = @max(@divTrunc(w, 7), 2) },
        .{},
    });
    gb.Move(rp, area.min_x + @divTrunc(w * 2, 9), area.min_y + @divTrunc(h, 2));
    gb.Draw(rp, area.min_x + @divTrunc(w * 4, 10), area.min_y + @divTrunc(h * 7, 10));
    gb.Draw(rp, area.min_x + @divTrunc(w * 7, 9), area.min_y + @divTrunc(h * 3, 10));
}

/// An item's number as its list counts: `3.`, `iii.` or `c.`.
fn numberText(kind: u8, number: u32, into: *[16]u8) usize {
    var n: usize = 0;
    switch (kind) {
        _text.DECO_ROMAN => {
            const values = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
            const names = [_][]const u8{ "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
            var left: u32 = @min(number, 3999);
            for (values, names) |value, name| {
                while (left >= value and n + name.len < into.len - 1) {
                    @memcpy(into[n..][0..name.len], name);
                    n += name.len;
                    left -= value;
                }
            }
        },
        _text.DECO_LETTER => {
            // a to z, then aa, ab and on.
            var digits: [8]u8 = undefined;
            var count: usize = 0;
            var left = @max(number, 1);
            while (left > 0 and count < digits.len) {
                left -= 1;
                digits[count] = 'a' + @as(u8, @intCast(left % 26));
                count += 1;
                left /= 26;
            }
            while (count > 0) {
                count -= 1;
                into[n] = digits[count];
                n += 1;
            }
        },
        else => {
            var digits: [10]u8 = undefined;
            var count: usize = 0;
            var left = number;
            while (true) {
                digits[count] = '0' + @as(u8, @intCast(left % 10));
                count += 1;
                left /= 10;
                if (left == 0) break;
            }
            while (count > 0) {
                count -= 1;
                into[n] = digits[count];
                n += 1;
            }
        },
    }
    into[n] = '.';
    return n + 1;
}
