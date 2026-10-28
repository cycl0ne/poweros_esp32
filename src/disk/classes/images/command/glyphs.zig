// SPDX-License-Identifier: MIT
//! The command pictures, each drawn on a `shapes.Painter` in design units:
//! 0 to 100 across and down its square. Kept apart from the class so that
//! a test can draw them alone.

const sdk = @import("sdk");
const shapes = sdk.gadgets.shapes;
const command = sdk.images.command;
const Painter = shapes.Painter;
const Shape = shapes.Shape;
const Hue = shapes.Hue;
const Pen = sdk.graphics.Pen;
const graphics = sdk.graphics;

/// Draws `glyph`; one past the last, or none, draws nothing.
pub fn draw(p: *Painter, glyph: u32) void {
    switch (glyph) {
        command.CMD_NEW => {
            sheet(p, 18, 6, 78, 92, 18, null);
            badge(p, 74, 76, 20, .green, .plus);
        },
        command.CMD_OPEN => {
            // The folder's back, a sheet in it, and its front.
            p.solid(&.{p.poly(&.{ .{ 6, 20 }, .{ 34, 20 }, .{ 42, 28 }, .{ 90, 28 }, .{ 90, 84 }, .{ 6, 84 } })}, .yellow, .{ .shade = true, .no_gloss = true });
            p.solid(&.{p.rr(16, 34, 80, 76, 2)}, .paper, .{ .no_shadow = true, .no_gloss = true });
            p.solid(&.{p.poly(&.{ .{ 20, 46 }, .{ 98, 46 }, .{ 86, 88 }, .{ 4, 88 } })}, .yellow, .{});
        },
        command.CMD_SAVE => {
            // The disk, its shutter and its label.
            p.solid(&.{p.poly(&.{ .{ 8, 8 }, .{ 78, 8 }, .{ 92, 22 }, .{ 92, 92 }, .{ 8, 92 } })}, .blue, .{});
            p.solid(&.{p.rr(26, 8, 70, 36, 2)}, .metal, .{ .no_shadow = true, .no_gloss = true });
            if (p.detail) p.fill(p.rr(54, 13, 62, 31, 1), .{ .colour = shapes.tones(.blue).dark });
            p.solid(&.{p.rr(20, 50, 80, 92, 3)}, .paper, .{ .no_shadow = true, .no_gloss = true });
            if (p.detail) {
                p.stroke(28, 72, 62, 3.5, shapes.tones(.blue).base);
                p.stroke(28, 60, 74, 3.5, shapes.tones(.blue).base);
            }
        },
        command.CMD_PRINT => {
            p.solid(&.{p.rr(26, 6, 74, 40, 2)}, .paper, .{ .no_gloss = true });
            p.solid(&.{p.rr(6, 32, 94, 74, 9)}, .metal, .{});
            p.solid(&.{p.rr(18, 56, 82, 66, 3)}, .iron, .{ .no_shadow = true, .no_gloss = true });
            p.solid(&.{p.rr(24, 62, 76, 94, 2)}, .paper, .{ .no_gloss = true });
            if (p.detail) {
                p.stroke(32, 68, 72, 3.5, shapes.tones(.blue).base);
                p.stroke(32, 58, 82, 3.5, shapes.tones(.blue).base);
                // The lamp that says it is on.
                p.solid(&.{p.disc(82, 44, 5)}, .green, .{ .no_shadow = true, .no_gloss = true });
            }
        },
        command.CMD_CUT => {
            p.solid(&.{ p.poly(&shapes.taper(58, 68, 27, 5, 11, 2)), p.poly(&shapes.taper(42, 68, 73, 5, 11, 2)) }, .metal, .{});
            p.solid(&.{ p.ring(30, 78, 19, 7, 0, 360), p.ring(70, 78, 19, 7, 0, 360) }, .red, .{});
            if (p.detail) p.solid(&.{p.disc(50, 50, 4.5)}, .iron, .{ .no_shadow = true, .no_gloss = true });
        },
        command.CMD_COPY => {
            sheet(p, 6, 4, 60, 70, 14, .blue);
            sheet(p, 36, 28, 92, 96, 16, .blue);
        },
        command.CMD_PASTE => {
            // The board, its clip and the clip's slot, and a sheet on it.
            p.solid(&.{p.rr(8, 12, 74, 94, 7)}, .brown, .{});
            p.solid(&.{p.rr(24, 4, 58, 20, 4)}, .metal, .{ .no_shadow = true });
            if (p.detail) p.fill(p.rr(35, 7.5, 47, 11.5, 2), .{ .colour = shapes.tones(.iron).dark });
            sheet(p, 40, 34, 94, 98, 14, .blue);
        },
        command.CMD_UNDO => undo(p),
        command.CMD_REDO => {
            p.mirror = true;
            defer p.mirror = false;
            undo(p);
        },
        command.CMD_FIND => lens(p, null),
        command.CMD_ZOOM_IN => lens(p, .plus),
        command.CMD_ZOOM_OUT => lens(p, .minus),
        // The stem, three bars 13 thick and two bowls whose bands are as
        // thick, each meeting the middle bar exactly: the upper bowl with
        // its lower band, the wider lower one with its upper band.
        command.CMD_BOLD => p.ink(&.{
            p.rr(22, 10, 38, 90, 0),
            p.rr(22, 10, 50, 23, 0),
            p.ring(50, 31.5, 21.5, 8.5, -90, 90),
            p.rr(22, 40, 51, 53, 0),
            p.ring(51, 65, 25, 12, -90, 90),
            p.rr(22, 77, 51, 90, 0),
        }),
        // One outline, every part of it leaning the same way: a quarter
        // across for every unit down.
        command.CMD_ITALIC => p.ink(&.{p.poly(&.{
            .{ 40, 10 },    .{ 80, 10 },    .{ 77.25, 21 }, .{ 64.25, 21 },
            .{ 49.75, 79 }, .{ 62.75, 79 }, .{ 60, 90 },    .{ 20, 90 },
            .{ 22.75, 79 }, .{ 35.75, 79 }, .{ 50.25, 21 }, .{ 37.25, 21 },
        })}),
        command.CMD_UNDERLINE => {
            p.ink(&.{ p.rr(22, 8, 36, 54, 0), p.rr(64, 8, 78, 54, 0), p.ring(50, 54, 28, 14, 180, 360) });
            p.solid(&.{p.rr(16, 84, 84, 96, 2)}, .red, .{ .no_shadow = true, .no_gloss = true });
        },
        command.CMD_ALIGN_LEFT => alignment(p, .left),
        command.CMD_ALIGN_CENTRE => alignment(p, .centre),
        command.CMD_ALIGN_RIGHT => alignment(p, .right),
        command.CMD_WRAP => {
            p.ink(&.{ p.rr(10, 12, 90, 22, 3), p.rr(10, 67, 38, 77, 3) });
            p.solid(&.{ p.rr(10, 37, 66, 47, 0), p.ring(66, 57, 20, 10, -90, 90), p.poly(&.{ .{ 66, 58 }, .{ 66, 86 }, .{ 44, 72 } }) }, .orange, .{});
        },
        command.CMD_SUM => p.solid(&.{p.poly(&.{
            .{ 16, 8 },  .{ 84, 8 },  .{ 86, 30 }, .{ 76, 30 }, .{ 72, 20 }, .{ 40, 20 }, .{ 62, 50 }, .{ 40, 80 },
            .{ 72, 80 }, .{ 76, 70 }, .{ 86, 70 }, .{ 84, 92 }, .{ 16, 92 }, .{ 16, 86 }, .{ 46, 50 }, .{ 16, 14 },
        })}, .green, .{}),
        command.CMD_SORT => {
            p.ink(&.{ p.rr(52, 12, 72, 24, 2), p.rr(52, 40, 82, 52, 2), p.rr(52, 68, 92, 80, 2) });
            p.solid(&.{ p.poly(&shapes.bar(27, 8, 27, 60, 13)), p.poly(&.{ .{ 9, 56 }, .{ 45, 56 }, .{ 27, 90 } }) }, .violet, .{});
        },
        command.CMD_INSERT_ROW => table(p, .green, .plus, .row),
        command.CMD_DELETE_ROW => table(p, .red, .cross, .row),
        command.CMD_INSERT_COLUMN => table(p, .green, .plus, .column),
        command.CMD_DELETE_COLUMN => table(p, .red, .cross, .column),
        command.CMD_SETTINGS => {
            var cog: [teeth.len + 1]Shape = undefined;
            for (teeth, 0..) |tooth, i| cog[i] = p.poly(&tooth);
            cog[teeth.len] = p.ring(50, 50, 36, 15, 0, 360);
            p.solid(&cog, .metal, .{ .flat = true });
            p.solid(&.{p.ring(50, 50, 22, 15, 0, 360)}, .teal, .{ .no_shadow = true });
        },
        else => {},
    }
}

/// The arrow turning back: most of a ring and its head.
fn undo(p: *Painter) void {
    p.solid(&.{ p.ring(54, 58, 35, 17, -40, 180), p.poly(&.{ .{ 6, 55 }, .{ 50, 55 }, .{ 28, 88 } }) }, .blue, .{});
}

/// The cog's eight teeth, bars from the rim outward between the eighths.
const teeth = blk: {
    var out: [8][4][2]f32 = undefined;
    for (&out, 0..) |*tooth, i| {
        const a: f32 = (@as(f32, @floatFromInt(i)) * 45 + 22.5) * (3.14159265 / 180.0);
        tooth.* = shapes.bar(50 + 28 * @cos(a), 50 - 28 * @sin(a), 50 + 45 * @cos(a), 50 - 45 * @sin(a), 16);
    }
    break :blk out;
};

/// A sheet of paper from (`x0`, `y0`) to (`x1`, `y1`), its top right
/// corner folded over by `fold`, with four lines of text on it - in
/// `lines`' hue, or a quiet grey.
fn sheet(p: *Painter, x0: f32, y0: f32, x1: f32, y1: f32, fold: f32, lines: ?Hue) void {
    p.solid(&.{p.poly(&.{ .{ x0, y0 }, .{ x1 - fold, y0 }, .{ x1, y0 + fold }, .{ x1, y1 }, .{ x0, y1 } })}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.poly(&.{ .{ x1 - fold, y0 }, .{ x1 - fold, y0 + fold }, .{ x1, y0 + fold } })}, .metal, .{ .no_shadow = true, .no_gloss = true });
    if (!p.detail) return;
    const colour: Pen = if (lines) |hue| shapes.tones(hue).base else 0xFFC4_CBD5;
    const left = x0 + 9;
    const right = x1 - 9;
    const step = (y1 - y0 - fold - 10) / 4;
    for (0..4) |i| {
        const y = y0 + fold + 6 + @as(f32, @floatFromInt(i)) * step;
        p.stroke(left, if (i == 3) left + (right - left) * 0.6 else right, y, 3.5, colour);
    }
}

const Mark = enum { plus, minus, cross };

/// A round badge in `hue` with a white mark on it.
fn badge(p: *Painter, cx: f32, cy: f32, r: f32, hue: Hue, mark: Mark) void {
    p.solid(&.{p.disc(cx, cy, r)}, hue, .{});
    const w = r * 0.34;
    const l = r * 0.62;
    const white = shapes.Paint{ .colour = shapes.white };
    switch (mark) {
        .plus, .minus => {
            p.fill(p.rr(cx - l, cy - w / 2, cx + l, cy + w / 2, 0), white);
            if (mark == .plus) p.fill(p.rr(cx - w / 2, cy - l, cx + w / 2, cy + l, 0), white);
        },
        .cross => {
            const e = l * 0.75;
            p.fill(p.poly(&shapes.bar(cx - e, cy - e, cx + e, cy + e, w)), white);
            p.fill(p.poly(&shapes.bar(cx - e, cy + e, cx + e, cy - e, w)), white);
        },
    }
}

/// The magnifying glass: its handle, its rim, the glass shading from
/// light to blue, and a glint on it - or, for a zoom, a plus or a minus.
fn lens(p: *Painter, mark: ?Mark) void {
    p.solid(&.{p.poly(&shapes.bar(62, 62, 91, 91, 15))}, .iron, .{});
    p.solid(&.{p.ring(40, 40, 32, 22, 0, 360)}, .metal, .{});
    const blue = shapes.tones(.blue);
    const glass: shapes.Paint = if (p.detail) .{ .fill = .{
        .kind = graphics.FILL_RADIAL,
        .from_x = graphics.FILL_ONE * 32 / 100,
        .from_y = graphics.FILL_ONE * 28 / 100,
        .to_x = graphics.FILL_ONE,
        .to_y = graphics.FILL_ONE,
        .count = 3,
        .stops = .{
            .{ .at = 0, .pen = 0xFFF4_FBFF },
            .{ .at = graphics.FILL_ONE * 6 / 10, .pen = blue.light },
            .{ .at = graphics.FILL_ONE, .pen = shapes.withAlpha(blue.base, 0xE6) },
            .{},
        },
    } } else .{ .colour = blue.light };
    p.fill(p.disc(40, 40, 22), glass);
    if (mark) |m| {
        const ink = shapes.Paint{ .colour = blue.dark };
        p.fill(p.rr(27, 37, 53, 43, 0), ink);
        if (m == .plus) p.fill(p.rr(37, 27, 43, 53, 0), ink);
    } else if (p.detail) {
        p.fill(p.disc(32, 31, 6), .{ .colour = 0xCCFF_FFFF });
    }
}

const Lines = enum { row, column };

/// A small table, its heading blue, a row or a column picked out in
/// `hue`, and a badge in the same hue.
fn table(p: *Painter, hue: Hue, mark: Mark, picked: Lines) void {
    p.solid(&.{p.rr(6, 14, 80, 86, 4)}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.rr(6, 14, 80, 32, 3)}, .blue, .{ .no_shadow = true, .no_gloss = true });
    // Inside the rim, in pixels.
    const d = p.rim;
    const left = p.u(6) + d;
    const right = p.u(80) - d;
    const bottom = p.u(86) - d;
    const light = shapes.Paint{ .colour = shapes.tones(hue).light };
    switch (picked) {
        .row => p.fill(box(left, p.u(50), right, p.u(68)), light),
        .column => p.fill(box(p.u(31) + d, p.u(32), p.u(56), bottom), light),
    }
    if (p.detail) {
        const grid = shapes.Paint{ .colour = 0xFFB0_B8C4 };
        for ([_]f32{ 31, 56 }) |x| p.fill(box(p.u(x), p.u(32), p.u(x) + d, bottom), grid);
        for ([_]f32{ 50, 68 }) |y| p.fill(box(left, p.u(y), right, p.u(y) + d), grid);
    }
    badge(p, 78, 78, 21, hue, mark);
}

/// A box in pixels, not design units.
fn box(x0: i32, y0: i32, x1: i32, y1: i32) Shape {
    return .{ .box = .{ .x0 = @floatFromInt(x0), .y0 = @floatFromInt(y0), .x1 = @floatFromInt(x1), .y1 = @floatFromInt(y1), .radius = 0 } };
}

const Flush = enum { left, centre, right };

/// Four lines of text in the ink, of two lengths, flush to a side or
/// centred.
fn alignment(p: *Painter, flush: Flush) void {
    for ([_]f32{ 76, 52, 76, 44 }, 0..) |w, i| {
        const y = 14 + @as(f32, @floatFromInt(i)) * 20;
        const x0: f32 = switch (flush) {
            .left => 12,
            .centre => 50 - w / 2,
            .right => 88 - w,
        };
        p.ink(&.{p.rr(x0, y, x0 + w, y + 10, 2)});
    }
}
