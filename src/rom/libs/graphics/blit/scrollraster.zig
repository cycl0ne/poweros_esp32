// SPDX-License-Identifier: MPL-2.0
//! ScrollRaster: moves a rectangle of a RastPort within the RastPort itself.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _blit = @import("_blit.zig");
const Rect = graphics.Rect;
const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const blitInto = _blit.blitInto;

/// Moves a rectangle of a RastPort within the RastPort itself.
///
/// SYNOPSIS:
/// ```zig
/// fn ScrollRaster(gb: *GraphicsBase, rp: *RastPort, dx: i32, dy: i32, area: *const Rect) bool
/// ```
///
/// SINCE: 0.16. LVO -256.
///
/// INPUTS:
/// - `rp` - what is scrolled, and what the pixels are read through.
/// - `dx`, `dy` - how far the contents move left and up. A terminal that
///   scrolls its text up by one row asks for a `dy` of one row's pixels.
/// - `area` - what moves, in the RastPort's coordinates, half-open. It is
///   cut to the RastPort's clip first.
///
/// RESULT:
/// True when all of it moved. False when part of what was to be read is
/// not kept anywhere - the part of a simple window another window covers -
/// and then **nothing** moved: half a scrolled window is worse than one
/// the caller draws again. False as well when the area is in more pieces
/// than this can move at once, which answers the same way and wants the
/// same thing of the caller.
///
/// BEHAVIOR:
/// The pixels are read through the same clip they are written through, so
/// each part of them comes from wherever that part is kept - the display
/// where the RastPort is visible, a keeping surface where it is covered.
/// A blit would instead read the surface at those coordinates, which for a
/// window's RastPort is whatever is on the display there.
///
/// What the move vacates is left as it was: whoever scrolled is about to
/// draw there, and a fill would be drawn over.
///
/// The rows written are handed on to the display before it returns, as
/// every drawing call does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded and it hands rows on at the end.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - This is what makes a scrolling terminal cost one row of drawing
///   rather than a windowful.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltRastPort`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// // The text moves up by a row; the row it leaves is drawn by the caller.
/// if (!gb.ScrollRaster(rp, 0, cell_height, &text_area)) drawEverything();
/// ```
pub fn ScrollRaster(gb: *GraphicsBase, rp: *RastPort, dx: i32, dy: i32, area: *const Rect) bool {
    rp.last_error = graphics.GERR_OK;
    if (dx == 0 and dy == 0) return true;
    const within = Rect.intersect(area.*, rp.clip);
    // What is to be read: the area, less the strip the move brings in from
    // outside it.
    const wanted = Rect.intersect(within, within.offset(dx, dy));
    if (wanted.isEmpty()) return true;

    var pieces: [scroll_pieces]Rect = undefined;
    var count: usize = 0;
    var covered: i64 = 0;
    var it = drawing.visible(rp, wanted);
    while (it.next()) |piece| {
        if (count == pieces.len) return false;
        pieces[count] = piece.rect;
        count += 1;
        covered += @as(i64, piece.rect.width()) * piece.rect.height();
    }
    // Every pixel asked for has to have been somewhere.
    if (covered != @as(i64, wanted.width()) * wanted.height()) return false;

    // A piece is moved over the ones it moves towards, so the order is the
    // direction of travel: the pieces come in order of min_y, then min_x.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const from = pieces[if (dy < 0 or (dy == 0 and dx < 0)) count - 1 - i else i];
        var read = drawing.visible(rp, from);
        while (read.next()) |piece| {
            const on = piece.on(piece.rect);
            blitInto(gb, piece.surface, on.min_x, on.min_y, rp, piece.rect.min_x - dx, piece.rect.min_y - dy, piece.rect.width(), piece.rect.height(), null, 0);
        }
    }
    return true;
}

/// How many pieces of one RastPort a scroll will move. More than this and
/// it answers no: a caller that is told no draws the area again, which is
/// always right and is what it would have done for a covered piece anyway.
const scroll_pieces = 32;
