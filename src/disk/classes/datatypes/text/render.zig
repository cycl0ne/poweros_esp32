// SPDX-License-Identifier: MIT
//! The laid-out lines drawn into the box the object was given.
//!
//! Only the lines that show are drawn, and only the fragments of them
//! that reach into the box across. A marked stretch is drawn the other
//! way round - the fill pen behind, its text pen in front - which means
//! a fragment the mark starts or ends inside is drawn in two or three
//! pieces. Everything else is one call a fragment.
//!
//! **Each piece is cut to the box before it is drawn**, by measuring how
//! many characters of it lie inside. A RastPort's clip region is no help
//! here: a window's RastPort is clipped by the list its layer keeps, and
//! a region is consulted instead of that list rather than as well as it,
//! so setting one would replace the window's own clipping and not narrow
//! it.

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
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Base = gadgets.Base;
const TagItem = sdk.utility.TagItem;

/// The pen a run asks for, as a colour of the screen it is drawn on.
pub fn penOf(which: u32, info: *const classusr.GadgetInfo) graphics.Pen {
    const pens = info.draw_info.pens;
    return switch (which) {
        tdc.TDPEN_TEXT => pens[sc.TEXTPEN],
        tdc.TDPEN_SHINE => pens[sc.SHINEPEN],
        tdc.TDPEN_SHADOW => pens[sc.SHADOWPEN],
        tdc.TDPEN_FILL => pens[sc.FILLPEN],
        tdc.TDPEN_HIGHLIGHTTEXT => pens[sc.HIGHLIGHTTEXTPEN],
        else => which,
    };
}

/// The text drawn into `box`, with the view starting `left` pixels
/// across and `top` pixels down it.
pub fn paint(base: *Base, own: *Data, info: *classusr.GadgetInfo, rp: *graphics.RastPort, box: gc.Box, left: i32, top: i32) void {
    const gb = base.graphics_base;
    const pens = info.draw_info.pens;
    support.fill(gb, rp, box, pens[sc.BACKGROUNDPEN]);
    const lines = own.lines orelse return;
    const buffer = own.buffer orelse return;
    const fragments = own.fragments orelse return;
    const pieces = own.pieces orelse return;

    const mark_from = @min(own.mark_start, own.mark_end);
    const mark_to = @max(own.mark_start, own.mark_end);

    var n: u32 = 0;
    while (n < own.line_count) : (n += 1) {
        const line = lines[n];
        if (line.top + line.height <= top) continue;
        if (line.top - top >= box.height) break;
        const y = box.top + line.top - top;
        var f: u32 = 0;
        while (f < line.count) : (f += 1) {
            const fragment = fragments[line.first + f];
            const x = box.left + fragment.left - left;
            if (x + fragment.width <= box.left or x >= box.left + box.width) continue;
            const piece = &pieces[fragment.piece];
            _text.wearPiece(gb, own, rp, piece);
            drawFragment(base, own, info, rp, .{
                .buffer = buffer,
                .piece = piece,
                .offset = fragment.offset,
                .length = fragment.length,
                .x = x,
                .y = y + line.baseline,
                .mark_from = mark_from,
                .mark_to = mark_to,
                .pens = pens,
                .left = box.left,
                .right = box.left + box.width,
            });
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
    pens: [*]const graphics.Pen,
    /// The edges of the box, which nothing is drawn past.
    left: i32,
    right: i32,
};

/// One fragment drawn, in up to three pieces where a mark starts or
/// ends inside it.
fn drawFragment(base: *Base, own: *Data, info: *classusr.GadgetInfo, rp: *graphics.RastPort, it: Drawing) void {
    const end = it.offset + it.length;
    const marked_from = @max(it.mark_from, it.offset);
    const marked_to = @min(it.mark_to, end);
    var at = it.offset;
    var x = it.x;
    if (marked_from < marked_to) {
        x = drawPart(base, own, info, rp, it, at, marked_from, x, false);
        at = marked_from;
        x = drawPart(base, own, info, rp, it, at, marked_to, x, true);
        at = marked_to;
    }
    _ = drawPart(base, own, info, rp, it, at, end, x, false);
}

/// A stretch of a fragment drawn from `x`, marked or not. Where the
/// next stretch starts.
fn drawPart(base: *Base, own: *Data, info: *classusr.GadgetInfo, rp: *graphics.RastPort, it: Drawing, from: u32, to: u32, x: i32, marked: bool) i32 {
    if (to <= from) return x;
    const gb = base.graphics_base;
    const width = gb.TextLength(rp, it.buffer + from, to - from);
    _ = own;
    // What of it lies inside the box: the characters before the left
    // edge dropped, and the ones past the right edge with them.
    const skipped = countWithin(gb, rp, it.buffer + from, to - from, it.left - x);
    const start = from + skipped;
    if (start >= to) return x + width;
    const at = x + gb.TextLength(rp, it.buffer + from, skipped);
    // A character that does not fit whole is not drawn: nothing cuts it
    // off at the edge, so half of one would be a whole one over
    // whatever stands beside the object.
    const count = countWithin(gb, rp, it.buffer + start, to - start, it.right - at);
    if (count == 0 or at >= it.right) return x + width;

    const ink = if (marked) it.pens[sc.FILLTEXTPEN] else penOf(it.piece.pen, info);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = ink },
        .{ .tag = graphics.RPTAG_BPen, .data = it.pens[sc.FILLPEN] },
        .{ .tag = graphics.RPTAG_DrMd, .data = if (marked) graphics.DRMD_JAM2 else graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, at, it.y);
    gb.Text(rp, it.buffer + start, count);
    return x + width;
}

/// How many characters of a string fit in `room` pixels, none when
/// `room` is nothing.
fn countWithin(gb: *GraphicsBase, rp: *graphics.RastPort, text: [*]const u8, length: u32, room: i32) u32 {
    if (room <= 0) return 0;
    if (gb.TextLength(rp, text, length) <= room) return length;
    var low: u32 = 0;
    var high: u32 = length;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (gb.TextLength(rp, text, middle) <= room) low = middle else high = middle;
    }
    return low;
}
