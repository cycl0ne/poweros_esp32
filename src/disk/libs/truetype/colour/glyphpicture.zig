// SPDX-License-Identifier: MIT
//! GlyphPicture: a glyph's largest picture in colour - from `sbix`, the
//! pictures of a font that has outlines too, or from `CBDT`, read by
//! `_strike.zig` - and where it goes. `pictureOf` is the reading, for
//! the library's call and for a tool on the host (`outlines.zig`).
//!
//! `sbix` is a list of strikes, one a size the pictures were drawn at,
//! each a list of where every glyph's data is: two offsets from the
//! glyph's point to the picture's lower left corner in the strike's
//! pixels, a kind of file and the file. A glyph whose data is of the
//! kind `dupe` is drawn by the glyph it names, eight times over at most.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _strike = @import("../outline/_strike.zig");
const Font = _outline.Font;
const Table = _outline.Table;

/// How many glyphs of `dupe` are followed to the one drawn.
const most_dupes = 8;

/// A glyph's largest picture in colour, and where it goes.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphPicture(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, picture: *truetype.Picture) bool
/// ```
///
/// SINCE: 1.17. LVO -96.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `picture` - where the picture's file and place go.
///
/// RESULT:
/// True, the picture in `picture`. False for a glyph without one;
/// `picture` is then all 0.
///
/// BEHAVIOR:
/// Of the sizes the font's pictures were drawn at, the largest that has
/// one of the glyph is taken, the first of two alike: of the font's
/// `sbix` table where it has one, else of its `CBDT`. The picture is a
/// file within the font's bytes - a PNG file; of `sbix` also one of the
/// kind the table names, "jpg " or "tiff" - with its width and height
/// where it is a PNG file.
///
/// Where it goes is in the font's units from the glyph's point, y up
/// (`x`, `y`), with how many units a pixel covers (`pixel_x`,
/// `pixel_y`): of `CBDT` its top left corner, at the place its measures
/// give in pixels; of `sbix` its bottom left (`PICTUREF_BOTTOM`), at the
/// glyph's offsets in pixels from the left side bearing and the bottom
/// of the glyph's outline, or from the point for a glyph without one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `picture` is the caller's; the file it points at is the font's, and
/// lasts until `CloseOutline`.
///
/// NOTES:
/// `RenderGlyph` draws a font's `CBDT` pictures itself, of a font that
/// has no outlines. A program draws a glyph by the first of
/// `GlyphPaints`, `GlyphDocument` and `GlyphPicture` that has it.
///
/// BUGS:
/// Pictures of coverage (`EBDT`), and `CBDT`'s pictures of raw pixels
/// rather than PNG files, are not handed out.
///
/// SEE ALSO:
/// `GlyphPaints`, `GlyphDocument`, `RenderGlyph`
///
/// EXAMPLES:
/// ```zig
/// var picture: truetype.Picture = undefined;
/// if (tb.GlyphPicture(outline, glyph, &picture)) {
///     const file = picture.bytes.?[0..picture.size];
///     _ = file;
/// }
/// ```
pub fn GlyphPicture(_: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, picture: *truetype.Picture) bool {
    const font: *const Font = @ptrCast(@alignCast(outline));
    picture.* = pictureOf(font, glyph) orelse {
        picture.* = .{};
        return false;
    };
    return true;
}

/// A glyph's largest picture in colour; null for none.
pub fn pictureOf(font: *const Font, glyph: u32) ?truetype.Picture {
    if (glyph >= font.glyph_count) return null;
    if (_outline.findTable(font, "sbix")) |sbix| {
        if (sbixPicture(font, sbix, glyph)) |found| return found;
        return null;
    }
    // A font with outlines has its strikes read here alone.
    var with_strikes: Font = undefined;
    const reading = if (font.strikes.count != 0) font else opened: {
        with_strikes = font.*;
        with_strikes.strikes = _strike.open(font);
        break :opened &with_strikes;
    };
    if (!reading.strikes.colour) return null;
    const found = _strike.pictureOf(reading, glyph, null) orelse return null;
    if (found.form != .png) return null;
    const units: f32 = @floatFromInt(font.units_per_em);
    const pixel_x = units / @as(f32, @floatFromInt(found.strike.ppem_x));
    const pixel_y = units / @as(f32, @floatFromInt(found.strike.ppem_y));
    var made = fileOf(font, found.bytes, truetype.tableTag("png "));
    made.pixel_x = pixel_x;
    made.pixel_y = pixel_y;
    made.x = @as(f32, @floatFromInt(found.metrics.left)) * pixel_x;
    made.y = @as(f32, @floatFromInt(found.metrics.top)) * pixel_y;
    return made;
}

/// A file within the font, its kind, and a PNG file's size.
fn fileOf(font: *const Font, bytes: Table, kind: u32) truetype.Picture {
    var made: truetype.Picture = .{ .bytes = font.data + bytes.at, .size = bytes.len, .kind = kind };
    // A PNG file: its signature, then its header's length and type, and
    // the width and height.
    if (kind == truetype.tableTag("png ") and bytes.len >= 24) {
        made.width = _outline.longIn(font, bytes, 16);
        made.height = _outline.longIn(font, bytes, 20);
    }
    return made;
}

/// The largest picture of `glyph` in `sbix`.
fn sbixPicture(font: *const Font, sbix: Table, glyph: u32) ?truetype.Picture {
    const count = _outline.longIn(font, sbix, 4);
    if (count > (sbix.len -| 8) / 4) return null;
    var best: ?truetype.Picture = null;
    var best_ppem: u32 = 0;
    var nth: u32 = 0;
    while (nth < @min(count, _strike.most_strikes)) : (nth += 1) {
        const offset = _outline.longIn(font, sbix, 8 + nth * 4);
        if (offset >= sbix.len) continue;
        const strike: Table = .{ .at = sbix.at + offset, .len = sbix.len - offset };
        const ppem: u32 = _outline.wordIn(font, strike, 0);
        if (ppem == 0 or (best != null and ppem <= best_ppem)) continue;
        const found = strikePicture(font, strike, glyph) orelse continue;
        best = found;
        best_ppem = ppem;
    }
    return best;
}

/// The picture of `glyph` in one strike of `sbix`, its `dupe`s followed.
fn strikePicture(font: *const Font, strike: Table, glyph: u32) ?truetype.Picture {
    const ppem: u32 = _outline.wordIn(font, strike, 0);
    var drawn = glyph;
    var dupes: u32 = 0;
    while (dupes <= most_dupes) : (dupes += 1) {
        if (drawn >= font.glyph_count) return null;
        const start = _outline.longIn(font, strike, 4 + drawn * 4);
        const end = _outline.longIn(font, strike, 8 + drawn * 4);
        if (end <= start or end > strike.len or end - start < 8) return null;
        const data: Table = .{ .at = strike.at + start, .len = end - start };
        const kind = _outline.longIn(font, data, 4);
        const file: Table = .{ .at = data.at + 8, .len = data.len - 8 };
        if (kind == truetype.tableTag("dupe")) {
            drawn = _outline.wordIn(font, file, 0);
            continue;
        }
        if (kind == truetype.tableTag("png ")) {
            const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
            if (file.len < 24) return null;
            for (signature, 0..) |expected, at| {
                if (_outline.byteIn(font, file, @intCast(at)) != expected) return null;
            }
        } else if (kind != truetype.tableTag("jpg ") and kind != truetype.tableTag("tiff")) return null;
        var made = fileOf(font, file, kind);
        if (made.width >= 1 << 16 or made.height >= 1 << 16) return null;
        const pixel = @as(f32, @floatFromInt(font.units_per_em)) / @as(f32, @floatFromInt(ppem));
        made.pixel_x = pixel;
        made.pixel_y = pixel;
        made.flags = truetype.PICTUREF_BOTTOM;
        // From the left side bearing and the bottom of the outline of the
        // glyph asked for, where it has one.
        var left: i32 = 0;
        var bottom: i32 = 0;
        if (_outline.glyphData(font, glyph)) |outline| {
            if (outline.len >= 10 and _outline.signedIn(font, outline, 0) != 0) {
                left = _outline.leftBearingOf(font, glyph);
                bottom = _outline.signedIn(font, outline, 4);
            }
        }
        made.x = @as(f32, @floatFromInt(left)) + @as(f32, @floatFromInt(_outline.signedIn(font, data, 0))) * pixel;
        made.y = @as(f32, @floatFromInt(bottom)) + @as(f32, @floatFromInt(_outline.signedIn(font, data, 2))) * pixel;
        return made;
    }
    return null;
}
