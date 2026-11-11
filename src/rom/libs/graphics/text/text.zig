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
const utf8 = sdk.utility.utf8;
const BeginDraw = @import("../draw/begindraw.zig").BeginDraw;
const EndDraw = @import("../draw/enddraw.zig").EndDraw;
const fontimage = graphics.fontimage;
const Glyph = _text.Glyph;
const TextFont = _text.TextFont;
const Measure = _text.Measure;
const Look = _text.Look;
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
/// SINCE: 0.11, UTF-8 since 0.38, fonts of 32-bit colour since 0.39,
/// fallback fonts since 0.40, glyphs made when wanted since 0.41.
/// LVO -132.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font, pens, draw mode, style and clip decide
///   the result, and its current point is where the text starts.
/// - `string` - the text, UTF-8; a byte that is no UTF-8 is drawn as the
///   character it reads as (`utility.utf8.read`). A character the font
///   has no glyph for - in its image or made by its hook - is drawn
///   from the first of its fallback fonts that
///   has one (`TextFont.fallback`); when none has, as its base letter -
///   `Ā` as `A` - when it is a letter with marks and the font or one of
///   its fallbacks has that letter, and otherwise as the font's default
///   character.
/// - `count` - its length in bytes.
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
/// pixel the letter covers, so its edges are smooth on any paper. A font
/// of palette entries lays each pixel's own colour, and draws the entry
/// it names as the pen's in the pen. A font of 32-bit colour lays each
/// pixel's colour by how much of the pixel it covers, and nothing of it
/// is the pen's: it looks the same whatever the pens are, and
/// `DRMD_INVERSVID` changes only the paper under it. All three lay the
/// paper first under `DRMD_JAM2`, and under `DRMD_COMPLEMENT` invert
/// where a pixel is half covered or more.
///
/// The styles are drawn rather than stored: **bold** is the glyph over
/// itself one pixel right (or as far as the font says), *italic* leans each row further right as it
/// goes up, and underlined is a run along the bottom of the whole string.
/// Bold and extended each widen a character by one.
///
/// **A glyph from a fallback font stands on the same line.** Its
/// baseline is put on the font's, and the rows of it that would reach
/// above or below the line are left out, so a line is as tall as the
/// RastPort's font whatever it draws from. It moves the point by its own
/// advance, is drawn the way its own font's pixels are - ink, coverage
/// or colour - and gets the styles of the line: the ones set and the
/// ones the RastPort's font is drawn with, less the ones the fallback is
/// already drawn with. The underline is the line's. Under `DRMD_JAM2`
/// the paper of the glyphs of one font is laid before their ink, so the
/// part of a leaning or kerned letter that reaches into a neighbour from
/// another font is covered by that one's paper.
///
/// **A font may hold more glyphs than its image.** A character the
/// image has no glyph for is asked of the font's hook (`TextFont.render`,
/// a font `AddFont` took) the first time it is drawn or measured, here,
/// on the caller's task; the glyph is kept with the font, and every text
/// after draws from what was kept. So the first text with a new
/// character takes the time its glyph takes to make. A glyph the hook
/// could not make this time - there was no memory - is drawn as a
/// character the font lacks, and asked for again by the next text.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the RastPort's lock
///   (`RPTAG_Lock`), if it has one, and while another task makes a glyph
///   of the same font.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Locks: the RastPort's own, taken here; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free: the string is only read. A glyph
/// made for the text is the library's, kept with the font.
///
/// NOTES:
/// A font's hook runs on the caller's stack.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TextLength`, `OpenFont`, `AddFont`, `RPTAG_TextStyle`
///
/// EXAMPLES:
/// ```zig
/// gb.Move(rp, 10, 30);
/// gb.Text(rp, "Hello", 5);
/// ```
pub fn Text(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) void {
    const held = rastport.hold(gb, rp);
    defer rastport.letGo(gb, held);
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
    // A string is drawn in runs and bands of rows; it is handed on to the
    // board once, as the box it was drawn in, not once for each.
    BeginDraw(gb, rp);
    defer EndDraw(gb, rp);

    const style = rp.text_style & softStyles(font);
    const image = font.image;
    const top = rp.cp_y - @as(i32, image.baseline);
    const start_x = rp.cp_x;
    var pen_x = start_x;

    var done: u32 = 0;
    while (done < count) {
        const run = takeRun(gb, font, rp.text_style, string + done, count - done);
        const area = graphics.Rect{
            .min_x = pen_x + run.room.min_x,
            .min_y = top,
            .max_x = pen_x + run.room.max_x,
            .max_y = top + @as(i32, image.height),
        };
        // Each run is of one font, drawn the way that font's pixels are.
        if (run.look.font.image.kind == .mono1) {
            stencilRun(gb, rp, string + done, run, area);
        } else {
            composeRun(gb, rp, string + done, run, area);
        }
        pen_x += run.room.width;
        done += run.count;
    }

    if (style & graphics.FSF_UNDERLINED != 0) {
        const y = top + @as(i32, image.height) - 1;
        var bound = graphics.Rect{};
        var any = false;
        drawing.fillSpan(rp, start_x, pen_x, y, &bound, &any);
        if (any) drawing.handOn(gb, rp, .{ .min_x = start_x, .min_y = y, .max_x = pen_x, .max_y = y + 1 });
    }

    // The point ends after the last letter, so one Text follows another.
    rp.cp_x = pen_x;
}

/// As many characters as are drawn in one go, and the room they take.
const Run = struct {
    /// Their bytes.
    count: u32,
    room: Measure,
    /// Whose glyphs they all are, and how those are put on the line.
    look: Look,
};

/// The characters from `string` that fit one strip and are drawn from
/// one font, at least one.
///
/// A run ends where the next character would take the room past
/// `strip_bytes * 8` columns, so a long line is drawn in pieces rather
/// than refused, and where the next character's glyph is of another font
/// than the first one's - the font of the text or one of its fallbacks.
/// A join between two pieces costs only that the ink of two characters
/// either side of it is not ORed together, which only kerning and
/// italics can make overlap.
///
/// INPUTS:
/// - `gb` - the library.
/// - `line` - the font the text is in.
/// - `style` - the RastPort's style.
/// - `string` - the text, UTF-8.
/// - `left` - its length in bytes, not 0.
fn takeRun(gb: *GraphicsBase, line: *const TextFont, style: graphics.FontStyle, string: [*]const u8, left: u32) Run {
    const bytes = string[0..left];
    var look = _text.lookOf(line, line, style);
    var room = Measure{};
    var count: usize = 0;
    while (count < bytes.len) {
        var after = count;
        const found = glyphOf(gb, line, utf8.next(bytes, &after));
        if (found.font != look.font) {
            if (count != 0) break;
            look = _text.lookOf(line, found.font, style);
        }
        const next = _text.grow(room, found.glyph, look.extra, look.smear, look.lean);
        if (count != 0 and next.max_x - next.min_x > strip_bytes * 8) break;
        room = next;
        count = after;
    }
    return .{ .count = @intCast(count), .room = room, .look = look };
}

/// A run of one-bit glyphs: assembled into a strip a band of rows at a
/// time, and each band stencilled with `BltTemplate`, which a board's
/// engine can take.
fn stencilRun(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, run: Run, area: graphics.Rect) void {
    const graphics_lib = gb.iface();
    const look = run.look;
    // The line's rows, not the glyphs' font's: what a fallback's glyph
    // has outside them is never put into the strip.
    const height: i32 = look.line.image.height;
    var band: i32 = 0;
    while (band < height) : (band += strip_rows) {
        const band_rows = @min(strip_rows, height - band);
        var strip: [strip_rows][strip_bytes]u8 = @splat(@splat(0));
        // Where the point is in the strip: the strip starts at the room's
        // left, which a kern back can put before the point.
        var at: i32 = -run.room.min_x;
        const bytes = string[0..run.count];
        var i: usize = 0;
        while (i < bytes.len) {
            const found = glyphOf(gb, look.line, utf8.next(bytes, &i));
            const glyph = found.glyph;
            // A glyph that could not be made when the run was taken and
            // can be now is another font's than the run's: its pixels
            // are not the run's kind, and it is left out this once.
            if (found.font == look.font) placeGlyph(&strip, look, glyph, at, band, band_rows);
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
/// A row is counted from the line's top, `look.drop` below the glyph's
/// own, so one above or below the line falls in no band.
fn placeGlyph(strip: *[strip_rows][strip_bytes]u8, look: Look, glyph: *const Glyph, at: i32, band: i32, band_rows: i32) void {
    if (glyph.width == 0) return;
    const pixels = _text.pixelsOf(look.font, glyph);
    var row: u32 = 0;
    while (row < glyph.rows) : (row += 1) {
        const line = look.drop + @as(i32, glyph.top) + @as(i32, @intCast(row));
        if (line < band or line >= band + band_rows) continue;
        const col = at + glyph.left + _text.slantOf(look.line, look.style, line);
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
fn composeRun(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, run: Run, area: graphics.Rect) void {
    const look = run.look;
    const top = area.min_y;
    const jam2 = rp.draw_mode & graphics.DRMD_JAM2 != 0;
    var it = drawing.visible(rp, area);
    var bound = graphics.Rect{};
    var any = false;
    while (it.next()) |piece| {
        const r = piece.rect;
        if (jam2) {
            // The ground under the letters: what a clear bit puts down.
            const ground = blits.Stencil.of(rp, piece.surface.format).clear.?;
            var y: i32 = r.min_y;
            while (y < r.max_y) : (y += 1) ground.run(drawing.address(piece, r.min_x, y), ground.bytes, @intCast(r.width()));
        }
        var at: i32 = area.min_x - run.room.min_x;
        const bytes = string[0..run.count];
        var i: usize = 0;
        while (i < bytes.len) {
            const found = glyphOf(gb, look.line, utf8.next(bytes, &i));
            const glyph = found.glyph;
            // As in `stencilRun`: only the run's own font's glyphs.
            if (found.font == look.font) composeGlyph(rp, piece, look, glyph, at, top);
            at += glyph.advance + look.extra;
        }
        drawing.grow(&bound, r.min_y, &any);
        drawing.grow(&bound, r.max_y - 1, &any);
    }
    if (any) drawing.handOn(gb, rp, drawing.written(area, bound));
}

/// One glyph of coverage or colour onto one piece, with the point at `at`
/// and the line's top at `top`. The piece lies inside the line, so the
/// rows of a fallback's glyph above or below it are not drawn.
fn composeGlyph(rp: *RastPort, piece: Piece, look: Look, glyph: *const Glyph, at: i32, top: i32) void {
    if (glyph.width == 0) return;
    const image = look.font.image;
    const pixels = _text.pixelsOf(look.font, glyph);
    const r = piece.rect;
    const wide: i32 = @as(i32, glyph.width) + look.smear;
    var row: u32 = 0;
    while (row < glyph.rows) : (row += 1) {
        const line = look.drop + @as(i32, glyph.top) + @as(i32, @intCast(row));
        const y = top + line;
        if (y < r.min_y or y >= r.max_y) continue;
        const left = at + glyph.left + _text.slantOf(look.line, look.style, line);
        const source = pixels + row * glyph.pitch;
        var col: i32 = @max(0, r.min_x - left);
        const end = @min(wide, r.max_x - left);
        while (col < end) : (col += 1) {
            if (image.kind == .rgba32) {
                var colour = colourAt(source, glyph.width, col);
                // Bold is the glyph over itself, moved right: where the
                // two meet, the one that covers more of the pixel.
                if (look.smear != 0) {
                    const behind = colourAt(source, glyph.width, col - look.smear);
                    if (behind >> 24 > colour >> 24) colour = behind;
                }
                layPixel(rp, piece, left + col, y, colour);
                continue;
            }
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

/// The pixel at `col` of a row of 32-bit colour, as a pen: its colour
/// with its coverage as the alpha, transparent outside the row.
fn colourAt(source: [*]const u8, width: u16, col: i32) graphics.Pen {
    if (col < 0 or col >= width) return 0;
    const pixel = source + @as(u32, @intCast(col)) * 4;
    return graphics.penARGB(pixel[3], pixel[0], pixel[1], pixel[2]);
}

/// The pixel at `col` of a glyph's row of coverage or palette entries, 0
/// outside it.
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
    layPixel(rp, piece, x, y, colour);
}

/// One pixel of a glyph in `colour`, laid over what is there by the
/// colour's alpha, or under `DRMD_COMPLEMENT` inverting it.
fn layPixel(rp: *RastPort, piece: Piece, x: i32, y: i32, colour: graphics.Pen) void {
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
