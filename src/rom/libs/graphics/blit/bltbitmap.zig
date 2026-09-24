// SPDX-License-Identifier: MPL-2.0
//! BltBitMap: moves a rectangle of pixels from one surface to another.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _blit = @import("_blit.zig");
const Rect = graphics.Rect;
const drawing = @import("../draw/_draw.zig");
const rows = @import("../rows/_rows.zig");
const pixelBytes = _blit.pixelBytes;

/// Moves a rectangle of pixels from one surface to another.
///
/// SYNOPSIS:
/// ```zig
/// fn BltBitMap(_: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *rtg.Surface, dest_x: i32, dest_y: i32, width: i32, height: i32) i32
/// ```
///
/// SINCE: 0.13. LVO -152.
///
/// INPUTS:
/// - `src` - the surface to take from. An `RtgBitMap` is one by pointer.
/// - `src_x` - the rectangle's left edge in the source.
/// - `src_y` - its top edge.
/// - `dest` - the surface to put it in, in the same format.
/// - `dest_x` - where its left edge lands.
/// - `dest_y` - where its top edge lands.
/// - `width` - how wide the rectangle is.
/// - `height` - how tall.
///
/// RESULT:
/// `GERR_OK`, or `GERR_BAD_FORMAT` for surfaces of two formats, which are
/// left alone: there is no RastPort to hold the error, so it is the
/// answer. What falls outside either surface is simply not moved, and is
/// no error.
///
/// BEHAVIOR:
/// **Neither side has any drawing state**, so nothing is clipped, no draw
/// mode applies and nothing is handed on to a display - this is the move
/// itself, for a caller that has two pieces of memory and wants one in the
/// other. `BltBitMapRastPort` is the same move landing somewhere that does
/// have state.
///
/// The two may be the same surface and may overlap: rows are taken from
/// the end when moving down and bytes from the end when moving right.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Both surfaces stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltBitMapRastPort`, `BltRastPort`
///
/// EXAMPLES:
/// ```zig
/// if (gb.BltBitMap(sheet, 32, 0, buffer, 0, 0, 16, 16) != graphics.GERR_OK) return;
/// ```
pub fn BltBitMap(_: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *rtg.Surface, dest_x: i32, dest_y: i32, width: i32, height: i32) i32 {
    if (src.format != dest.format) return graphics.GERR_BAD_FORMAT;
    const bytes = pixelBytes(dest);

    // Cut to what the source has and to what the destination will hold, in
    // one step, by moving the rectangle between them.
    var from = Rect{ .min_x = src_x, .min_y = src_y, .max_x = src_x + width, .max_y = src_y + height };
    from = Rect.intersect(from, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(src.width),
        .max_y = @intCast(src.height),
    });
    const dx = dest_x - src_x;
    const dy = dest_y - src_y;
    var landing = Rect{
        .min_x = from.min_x + dx,
        .min_y = from.min_y + dy,
        .max_x = from.max_x + dx,
        .max_y = from.max_y + dy,
    };
    landing = Rect.intersect(landing, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(dest.width),
        .max_y = @intCast(dest.height),
    });
    if (landing.isEmpty()) return graphics.GERR_OK;

    const run: usize = @as(usize, @intCast(landing.width())) * bytes;
    const same = src.pixels.? == dest.pixels.?;
    const backwards = same and dy > 0;

    var i: i32 = 0;
    const landed = landing.height();
    while (i < landed) : (i += 1) {
        const y = if (backwards) landing.max_y - 1 - i else landing.min_y + i;
        const to = dest.pixels.? + @as(usize, @intCast(y)) * dest.pitch +
            @as(usize, @intCast(landing.min_x)) * bytes;
        const at = src.pixels.? + @as(usize, @intCast(y - dy)) * src.pitch +
            @as(usize, @intCast(landing.min_x - dx)) * bytes;
        if (same and dx > 0) rows.copyBack(to, at, run) else rows.copy(to, at, run);
    }
    return graphics.GERR_OK;
}
