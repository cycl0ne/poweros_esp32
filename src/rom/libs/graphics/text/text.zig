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
const glyphOf = _text.glyphOf;
const advance = _text.advance;
const softStyles = _text.softStyles;

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
/// - `string` - the characters: bytes, and a character the font has no
///   glyph for gets the one at the end of it.
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
/// letters sit above it and a tail hangs below. The point moves to just
/// past the last letter, so one `Text` follows another.
///
/// The draw mode is the draw mode: `DRMD_JAM1` puts ink down and leaves
/// the paper alone, `DRMD_JAM2` lays the background pen behind the
/// letters, `DRMD_INVERSVID` swaps them, and `DRMD_COMPLEMENT` inverts
/// whatever is underneath. A console wants JAM2 and gets it for nothing,
/// because text goes through the same plot as every other primitive.
///
/// The styles are drawn rather than stored: **bold** is the glyph over
/// itself one pixel right, *italic* leans each row further right as it
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
    const graphics_lib = gb.iface();
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
    const step = advance(font, rp.text_style);
    const height: u32 = font.height;
    // Room for a lean: the top row of an italic reaches furthest right.
    const lean: i32 = if (style & graphics.FSF_ITALIC != 0)
        @intCast((height - 1) / 4)
    else
        0;

    const top = rp.cp_y - @as(i32, font.baseline);
    const start_x = rp.cp_x;
    var pen_x = start_x;

    // How many characters fit one strip, so a long line is done in pieces
    // rather than refused or truncated.
    const per_strip: u32 = @intCast(@max(@divTrunc(strip_bytes * 8 - lean, step), 1));

    var done: u32 = 0;
    while (done < count) {
        const run = @min(per_strip, count - done);
        var strip: [strip_rows][strip_bytes]u8 = @splat(@splat(0));

        var i: u32 = 0;
        while (i < run) : (i += 1) {
            const glyph = glyphOf(font, string[done + i]);
            const at = glyph * height;
            const left: i32 = @intCast(i * @as(u32, @intCast(step)));

            var row: u32 = 0;
            while (row < height) : (row += 1) {
                var bits = font.rows[at + row];
                // Bold is the glyph over itself one to the right.
                if (style & graphics.FSF_BOLD != 0) bits |= bits >> 1;
                // Italic leans each row further right as it goes up.
                const slant: i32 = if (style & graphics.FSF_ITALIC != 0)
                    @intCast((height - 1 - row) / 4)
                else
                    0;
                var col: u32 = 0;
                while (col < 16) : (col += 1) {
                    if (bits >> @intCast(15 - col) & 1 == 0) continue;
                    const x = left + @as(i32, @intCast(col)) + slant;
                    if (x < 0 or x >= strip_bytes * 8) continue;
                    // An OR, so a lean that reaches into the next cell
                    // joins what is there instead of erasing it.
                    strip[row][@intCast(@divTrunc(x, 8))] |= @as(u8, 0x80) >> @intCast(@mod(x, 8));
                }
            }
        }

        const wide: i32 = @as(i32, @intCast(run)) * step + lean;
        const area = graphics.Rect{
            .min_x = pen_x,
            .min_y = top,
            .max_x = pen_x + wide,
            .max_y = top + @as(i32, @intCast(height)),
        };
        graphics_lib.BltTemplate(@ptrCast(rp), @ptrCast(&strip), strip_bytes, 0, 0, &area);

        pen_x += @as(i32, @intCast(run)) * step;
        done += run;
    }

    if (style & graphics.FSF_UNDERLINED != 0) {
        const y = top + @as(i32, @intCast(height)) - 1;
        var bound = graphics.Rect{};
        var any = false;
        drawing.fillSpan(rp, start_x, pen_x, y, &bound, &any);
        if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
    }

    // The point ends after the last letter, so one Text follows another.
    rp.cp_x = pen_x;
}

/// As much of a run as is assembled in one pass.
///
/// A whole line of this machine's display in one go: 1024 pixels is 128
/// bytes a row, and the tallest font is sixteen rows.
/// A longer string is done in pieces, which costs only that two characters
/// either side of a join do not overlap - and only italics overlap at all.
const strip_bytes = 128;

const strip_rows = 16;
