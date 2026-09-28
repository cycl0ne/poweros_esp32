// SPDX-License-Identifier: MPL-2.0
//! Text: draws text at the current point.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const blits = @import("../blit/_blit.zig");
const fontimage = graphics.fontimage;
const Glyph = _text.Glyph;
const TextFont = _text.TextFont;
const Measure = _text.Measure;
const glyphOf = _text.glyphOf;
const softStyles = _text.softStyles;
const Piece = drawing.Piece;

/// Draws text at the current point.
///
/// SYNOPSIS:
/// ```zig
/// fn Text(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) void
/// ```
///
/// SINCE: 0.11. LVO -132.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font, pens, draw mode, style and clip decide
///   the result, and its current point is where the text starts.
/// - `string` - the characters: bytes, each a Latin-1 code. A character
///   the font has no glyph for is drawn as the font's default character.
/// - `count` - how many.
///
/// RESULT:
/// Nothing. With no font set nothing is drawn and the error is
/// `GERR_NO_FONT`: being asked to draw and drawing nothing is a failure,
/// not an answer, and `OpenFont` does not put a font on a RastPort -
/// `RPTAG_Font` does.
///
/// BEHAVIOR:
/// **The point is the left of the baseline**, so
/// letters sit above it and a tail hangs below. Each character moves the
/// point by its own advance, and the point ends just past the last one,
/// so one `Text` follows another. A character's ink may reach back under
/// the one before it, where the font says so.
///
/// The draw mode is the draw mode: `DRMD_JAM1` puts ink down and leaves
/// the paper alone, `DRMD_JAM2` lays the background pen behind the
/// letters, `DRMD_INVERSVID` swaps them, and `DRMD_COMPLEMENT` inverts
/// whatever is underneath. A console wants JAM2 and gets it for nothing,
/// because text goes through the same plot as every other primitive.
///
/// A font of coverage lays the pen over what is there by how much of each
/// pixel the letter covers, so its edges are smooth on any paper; a
/// colour font lays each pixel's own colour, and draws the part it marks
/// as the pen in the pen. Both lay the paper first under `DRMD_JAM2`, and
/// under `DRMD_COMPLEMENT` invert where a pixel is half covered or more.
///
/// The styles are drawn rather than stored: **bold** is the glyph over
/// itself one pixel right (or as far as the font says), *italic* leans each row further right as it
/// goes up, and underlined is a run along the bottom of the whole string.
/// Bold and extended each widen a character by one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free: the string is only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TextLength`, `OpenFont`, `RPTAG_TextStyle`
///
/// EXAMPLES:
/// ```zig
/// gb.Move(rp, 10, 30);
/// gb.Text(rp, "Hello", 5);
/// ```
pub fn Text(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) void {
    rp.last_error = graphics.GERR_OK;
    // Drawing nothing because nobody put a font on the RastPort is a
    // failure to do what was asked, not an answer. Opening a font does not
    // set it - RPTAG_Font does - and silence is what makes that easy to
    // get wrong.
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return;
    };
    if (count == 0) return;

    const style = rp.text_style & softStyles(font);
    const look = Look{
        .font = font,
        .style = style,
        .extra = _text.extraAdvance(style),
        .smear = _text.smearOf(font, style),
        .lean = _text.leanOf(font, style),
    };
    const image = font.image;
    const top = rp.cp_y - @as(i32, image.baseline);
    const start_x = rp.cp_x;
    var pen_x = start_x;

    var done: u32 = 0;
    while (done < count) {
        const run = takeRun(look, string + done, count - done);
        const area = graphics.Rect{
            .min_x = pen_x + run.room.min_x,
            .min_y = top,
            .max_x = pen_x + run.room.max_x,
            .max_y = top + @as(i32, image.height),
        };
        if (image.kind == .mono1) {
            stencilRun(gb, rp, look, string + done, run, area);
        } else {
            composeRun(gb, rp, look, string + done, run, area);
        }
        pen_x += run.room.width;
        done += run.count;
    }

    if (style & graphics.FSF_UNDERLINED != 0) {
        const y = top + @as(i32, image.height) - 1;
        var bound = graphics.Rect{};
        var any = false;
        drawing.fillSpan(rp, start_x, pen_x, y, &bound, &any);
        if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
    }

    // The point ends after the last letter, so one Text follows another.
    rp.cp_x = pen_x;
}

/// How a string is drawn: the font and what the styles make of it.
const Look = struct {
    font: *const TextFont,
    style: graphics.FontStyle,
    /// What the styles add to each advance.
    extra: i32,
    /// How far right bold draws a glyph again.
    smear: i32,
    /// How far italic leans the top row.
    lean: i32,
};

/// As many characters as are drawn in one go, and the room they take.
const Run = struct {
    count: u32,
    room: Measure,
};

/// The characters from `string` that fit one strip, at least one.
///
/// A run ends where the next character would take the room past
/// `strip_bytes * 8` columns, so a long line is drawn in pieces rather
/// than refused; a join between two pieces costs only that the ink of two
/// characters either side of it is not ORed together, which only
/// kerning and italics can make overlap.
fn takeRun(look: Look, string: [*]const u8, left: u32) Run {
    var room = Measure{};
    var count: u32 = 0;
    while (count < left) {
        const glyph = glyphOf(look.font, string[count]);
        const next = _text.grow(room, glyph, look.extra, look.smear, look.lean);
        if (count != 0 and next.max_x - next.min_x > strip_bytes * 8) break;
        room = next;
        count += 1;
    }
    return .{ .count = count, .room = room };
}

/// A run of one-bit glyphs: assembled into a strip a band of rows at a
/// time, and each band stencilled with `BltTemplate`, which a board's
/// engine can take.
fn stencilRun(gb: *GraphicsBase, rp: *RastPort, look: Look, string: [*]const u8, run: Run, area: graphics.Rect) void {
    const graphics_lib = gb.iface();
    const image = look.font.image;
    const height: i32 = image.height;
    var band: i32 = 0;
    while (band < height) : (band += strip_rows) {
        const band_rows = @min(strip_rows, height - band);
        var strip: [strip_rows][strip_bytes]u8 = @splat(@splat(0));
        // Where the point is in the strip: the strip starts at the room's
        // left, which a kern back can put before the point.
        var at: i32 = -run.room.min_x;
        var i: u32 = 0;
        while (i < run.count) : (i += 1) {
            const glyph = glyphOf(look.font, string[i]);
            placeGlyph(&strip, look, glyph, at, band, band_rows);
            at += glyph.advance + look.extra;
        }
        const piece = graphics.Rect{
            .min_x = area.min_x,
            .min_y = area.min_y + band,
            .max_x = area.max_x,
            .max_y = area.min_y + band + band_rows,
        };
        graphics_lib.BltTemplate(@ptrCast(rp), @ptrCast(&strip), strip_bytes, 0, 0, &piece);
    }
}

/// The rows of `glyph` that fall in the band from `band`, ORed into the
/// strip with the point at column `at`. An OR, so a lean or a kern that
/// reaches into the next cell joins what is there instead of erasing it.
fn placeGlyph(strip: *[strip_rows][strip_bytes]u8, look: Look, glyph: *const Glyph, at: i32, band: i32, band_rows: i32) void {
    if (glyph.width == 0) return;
    const pixels = fontimage.pixelsOf(look.font.image, glyph);
    var row: u32 = 0;
    while (row < glyph.rows) : (row += 1) {
        const line = @as(i32, glyph.top) + @as(i32, @intCast(row));
        if (line < band or line >= band + band_rows) continue;
        const col = at + glyph.left + _text.slantOf(look.font, look.style, line);
        const source = pixels + row * glyph.pitch;
        const dest = &strip[@intCast(line - band)];
        orBits(dest, source, glyph.width, col);
        // Bold is the glyph over itself, moved right.
        if (look.smear != 0) orBits(dest, source, glyph.width, col + look.smear);
    }
}

/// `width` bits from `source` ORed into `dest` from bit `col` on. Bits
/// that would land outside it are left out.
fn orBits(dest: *[strip_bytes]u8, source: [*]const u8, width: u32, col: i32) void {
    if (col < 0) {
        var bit: u32 = 0;
        while (bit < width) : (bit += 1) {
            const x = col + @as(i32, @intCast(bit));
            if (x < 0 or x >= strip_bytes * 8) continue;
            if (source[bit / 8] >> @intCast(7 - bit % 8) & 1 == 0) continue;
            dest[@intCast(@divTrunc(x, 8))] |= @as(u8, 0x80) >> @intCast(@mod(x, 8));
        }
        return;
    }
    const shift: u3 = @intCast(@mod(col, 8));
    var to: usize = @intCast(@divTrunc(col, 8));
    const bytes = (width + 7) / 8;
    var from: u32 = 0;
    while (from < bytes and to < strip_bytes) : ({
        from += 1;
        to += 1;
    }) {
        var byte = source[from];
        // The last byte's bits past the width are not the glyph's.
        if (from == bytes - 1 and width % 8 != 0) byte &= @as(u8, 0xFF) << @intCast(8 - width % 8);
        dest[to] |= byte >> shift;
        if (shift != 0 and to + 1 < strip_bytes) dest[to + 1] |= byte << @intCast(@as(u4, 8) - shift);
    }
}

/// A run of coverage or colour glyphs, composed pixel by pixel onto each
/// piece of the surface the clip leaves: the paper first under JAM2,
/// then each glyph over it.
fn composeRun(gb: *GraphicsBase, rp: *RastPort, look: Look, string: [*]const u8, run: Run, area: graphics.Rect) void {
    const top = area.min_y;
    const jam2 = rp.draw_mode & graphics.DRMD_JAM2 != 0;
    var it = drawing.visible(rp, area);
    var bound = graphics.Rect{};
    var any = false;
    while (it.next()) |piece| {
        const r = piece.rect;
        if (jam2) {
            var y: i32 = r.min_y;
            while (y < r.max_y) : (y += 1) {
                var x: i32 = r.min_x;
                while (x < r.max_x) : (x += 1) blits.stencil(rp, piece, x, y, false);
            }
        }
        var at: i32 = area.min_x - run.room.min_x;
        var i: u32 = 0;
        while (i < run.count) : (i += 1) {
            const glyph = glyphOf(look.font, string[i]);
            composeGlyph(rp, piece, look, glyph, at, top);
            at += glyph.advance + look.extra;
        }
        drawing.grow(&bound, r.min_y, &any);
        drawing.grow(&bound, r.max_y - 1, &any);
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}

/// One glyph of coverage or colour onto one piece, with the point at `at`
/// and the line's top at `top`.
fn composeGlyph(rp: *RastPort, piece: Piece, look: Look, glyph: *const Glyph, at: i32, top: i32) void {
    if (glyph.width == 0) return;
    const image = look.font.image;
    const pixels = fontimage.pixelsOf(image, glyph);
    const r = piece.rect;
    const wide: i32 = @as(i32, glyph.width) + look.smear;
    var row: u32 = 0;
    while (row < glyph.rows) : (row += 1) {
        const line = @as(i32, glyph.top) + @as(i32, @intCast(row));
        const y = top + line;
        if (y < r.min_y or y >= r.max_y) continue;
        const left = at + glyph.left + _text.slantOf(look.font, look.style, line);
        const source = pixels + row * glyph.pitch;
        var col: i32 = @max(0, r.min_x - left);
        const end = @min(wide, r.max_x - left);
        while (col < end) : (col += 1) {
            var value = sample(image.kind, source, glyph.width, col);
            // Bold is the glyph over itself, moved right: the stronger of
            // the two where they meet.
            if (look.smear != 0) {
                const behind = sample(image.kind, source, glyph.width, col - look.smear);
                value = if (image.kind == .alpha4) @max(value, behind) else if (value == 0) behind else value;
            }
            if (value != 0) inkPixel(rp, piece, image, left + col, y, value);
        }
    }
}

/// The pixel at `col` of a glyph's row, 0 outside it.
fn sample(kind: fontimage.Kind, source: [*]const u8, width: u16, col: i32) u8 {
    if (col < 0 or col >= width) return 0;
    const at: u32 = @intCast(col);
    if (kind == .alpha4) {
        const byte = source[at / 2];
        return if (at % 2 == 0) byte >> 4 else byte & 0x0F;
    }
    return source[at];
}

/// One pixel of a glyph that is not ink alone: a coverage of 1 to 15, or
/// a palette entry other than 0.
fn inkPixel(rp: *RastPort, piece: Piece, image: *const fontimage.FontImage, x: i32, y: i32, value: u8) void {
    const pen = if (rp.draw_mode & graphics.DRMD_INVERSVID != 0) rp.bg_pen else rp.fg_pen;
    const colour: graphics.Pen = if (image.kind == .alpha4)
        withAlpha(pen, (pen >> 24) * value / 15)
    else blk: {
        const entry = fontimage.paletteOf(image)[value];
        if (value == image.pen_index) break :blk withAlpha(pen, (pen >> 24) * (entry >> 24) / 255);
        break :blk entry;
    };
    // Inverting has no amount: a pixel half covered or more is the
    // letter, and is inverted.
    if (rp.draw_mode & graphics.DRMD_COMPLEMENT != 0) {
        if (colour >> 24 >= 0x80) drawing.plot(rp, piece, x, y);
        return;
    }
    drawing.plotOver(piece, x, y, colour);
}

/// `pen` with its alpha replaced.
fn withAlpha(pen: graphics.Pen, alpha: u32) graphics.Pen {
    return (pen & 0x00FF_FFFF) | (alpha << 24);
}

/// How wide one strip is, in bytes: a whole line of this machine's
/// display, 1024 pixels, in one go.
const strip_bytes = 128;

/// How many rows one strip holds. A taller font is drawn in bands of
/// this many.
const strip_rows = 16;
