// SPDX-License-Identifier: MPL-2.0
//! Fonts and text.
//!
//! A font here is a name, a count of who has it open, and a `FontImage`
//! (`sdk.graphics.fontimage`): one block holding the measures, the
//! character ranges, a box and an advance for each glyph, and the
//! pixels. Nothing in the block is a pointer, so the same bytes serve in
//! the ROM and read from a file.
//!
//! Characters are found through the ranges, so a font may start and stop
//! anywhere and leave gaps; a code it has no glyph for is drawn as its
//! base letter, when it is a letter with marks the font has the letter
//! of, and otherwise as its default character. Text arrives as UTF-8,
//! read with the SDK's `utf8`, so a byte that is no UTF-8 is drawn as
//! the character it reads as; counts are bytes.
//!
//! **A font may name a fallback** (`TextFont.fallback`), and that one the
//! next: a character the font has no glyph of its own for is looked for
//! in each of them in turn, and so is its base letter, before the
//! default (`glyphOf`). A glyph from a fallback is drawn on the line of
//! the font the text is in: the two baselines are put together, the rows
//! that would reach past the line are cut, and the line's styles are
//! drawn on it - the ones the fallback is not already drawn with. So a
//! line is as tall as its font whatever it draws from, and `TextLength`,
//! `TextExtent` and `TextFit` measure the same glyphs `Text` draws
//! (`Look`, `lookOf`).
//!
//! **A font may make glyphs as they are wanted** (`TextFont.render`): a
//! character its image has no glyph for is asked of the font's hook the
//! first time a text wants it, and kept with the font from then on
//! (`_kept.zig`). The image is looked in first and the hook asked
//! second, for the font and for each fallback in turn, so a font draws
//! every character it has before one is taken from a fallback.
//!
//! **Each character has its own width.** The point moves by the glyph's
//! advance, and its ink is drawn `left` columns from the point - less
//! than zero reaches back under the character before - and `top` rows
//! down from the top of the line. A fixed-width font is the case where
//! every advance is the same.
//!
//! Two fonts are in the ROM, both called `pospaz.font` and told apart by
//! height (`fonts/_fonts.zig` builds their images):
//!
//! | height | width | baseline |
//! |--------|-------|----------|
//! | 8      | 8     | 6        |
//! | 16     | 8     | 13       |
//!
//! Sixteen is eight with every row drawn twice, for a panel whose pixels
//! are square; the columns stay the same.
//!
//! **A glyph's pixels are ink, coverage or colour.** Ink (`mono1`) is
//! assembled into a one-bit strip and stencilled, so it goes through
//! `BltTemplate` and a board's engine can take it, and the draw modes are
//! the draw modes: `DRMD_JAM1` leaves the paper alone, `DRMD_JAM2` lays
//! the background pen down behind the letters, and `DRMD_COMPLEMENT`
//! inverts them into whatever is there. Coverage (`alpha4`) is the pen
//! laid over what is there by how much of each pixel the letter covers.
//! Colour is each pixel's own laid over: a palette entry (`indexed8`),
//! with the one entry the font names drawn in the pen instead, or four
//! bytes of red, green, blue and coverage (`rgba32`), of which nothing
//! is the pen's. All three are composed here, pixel by pixel, after the
//! paper when there is any.
//!
//! The styles are drawn rather than stored: bold is the glyph drawn over
//! itself the font's `bold_smear` to the right, italic is each row moved
//! right as it goes up, underlined is a line along the bottom.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const exec = sdk.exec;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
pub const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const blits = @import("../blit/_blit.zig");
const utf8 = sdk.utility.utf8;
const unicode = sdk.utility.unicode;

const fontimage = graphics.fontimage;
pub const FontImage = fontimage.FontImage;
pub const Glyph = fontimage.Glyph;
const rom = @import("../fonts/_fonts.zig");
const kept = @import("_kept.zig");

/// A font: a name on the list and an image. The SDK's, since a font
/// built outside the library is handed to `AddFont` as one.
pub const TextFont = graphics.TextFont;

/// The two in this ROM, as they start. `initFonts` copies them into
/// memory of the library's own, since opening one counts and the image
/// cannot be written.
const rom_fonts = [_]TextFont{
    .{ .node = .{ .type = .font, .name = graphics.POSPAZNAME }, .image = @ptrCast(&rom.pospaz8_image), .flags = graphics.FPF_ROMFONT },
    .{ .node = .{ .type = .font, .name = graphics.POSPAZNAME }, .image = @ptrCast(&rom.pospaz16_image), .flags = graphics.FPF_ROMFONT },
};

/// Put the two in this ROM on the library's list. Called by the init,
/// once, before anything can ask for a font.
///
/// INPUTS:
/// - `gb` - the library, whose font list and base it fills.
///
/// RESULT:
/// False without memory for the fonts.
pub fn initFonts(gb: *GraphicsBase) bool {
    gb.screen_dpi = screenDpi(gb);
    gb.sys_base.NewList(&gb.fonts);
    gb.sys_base.InitSemaphore(&gb.font_lock);
    const block = gb.sys_base.AllocVec(@sizeOf(@TypeOf(rom_fonts)), exec.MEMF_ANY) orelse return false;
    const own: *[rom_fonts.len]TextFont = @ptrCast(@alignCast(block));
    own.* = rom_fonts;
    for (own) |*font| gb.sys_base.AddTail(&gb.fonts, &font.node);
    gb.rom_fonts = block;
    return true;
}

/// The screen's dots per inch, as the board's system tags say; 72 where
/// they say nothing, or there is no expansion.library to ask.
fn screenDpi(gb: *GraphicsBase) u32 {
    const sys = gb.sys_base;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return points_per_inch;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const dpi: u32 = @truncate(gb.utility_base.GetTagData(sdk.expansion.systemtags.SYSTAG_ScreenDPI, points_per_inch, eb.SystemTags()));
    return if (dpi == 0) points_per_inch else dpi;
}

/// Points in an inch.
pub const points_per_inch = 72;

/// A request in rows: a size in points turned into rows by the screen's
/// DPI, and the points mark taken off.
///
/// INPUTS:
/// - `gb` - the library, for the DPI.
/// - `text_attr` - the request.
pub fn inRows(gb: *GraphicsBase, text_attr: *const graphics.TextAttr) graphics.TextAttr {
    var rows = text_attr.*;
    rows.y_size = @intCast(gb.iface().FontRows(text_attr));
    rows.flags &= ~graphics.FPF_POINTS;
    return rows;
}

/// A font off the list, unless something has it open. The caller holds
/// the font list's lock.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font; not being on the list is no error.
///
/// RESULT:
/// False while it is open; true once it is off the list.
pub fn takeOff(gb: *GraphicsBase, font: *TextFont) bool {
    if (font.open_count != 0) return false;
    var at = gb.fonts.first();
    while (at) |node| : (at = node.next()) {
        if (node == &font.node) {
            gb.sys_base.Remove(&font.node);
            // Nothing has it open and nothing can open it now: the
            // glyphs made for it go with it.
            kept.free(gb, font);
            break;
        }
    }
    return true;
}

/// A glyph and the font it is of.
pub const Found = struct {
    glyph: *const Glyph,
    /// The font the text is in, or the fallback of it the glyph was
    /// found in.
    font: *const TextFont,
};

/// The glyph a character is drawn with, and whose it is: the font's own,
/// or the first of its fallbacks' that has one; for a letter with marks
/// that none of them has, its base letter's, the first of the letters it
/// is written on that one of them has (`Ǻ`, then `Å`, then `A`), each
/// looked for in the font and then in its fallbacks; or the font's
/// default.
///
/// A glyph a font makes when it is wanted is made here, the first time,
/// by the font's hook, and a glyph that could not be made this time is
/// passed over like one the font does not have: asked for twice, a
/// character may be answered with two glyphs.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font the text is in.
/// - `code` - the character, a code point.
pub fn glyphOf(gb: *GraphicsBase, font: *const TextFont, code: u32) Found {
    if (ownGlyph(gb, font, code)) |found| return found;
    var letter = code;
    while (unicode.base(letter)) |under| : (letter = under) {
        if (ownGlyph(gb, font, under)) |found| return found;
    }
    return .{ .glyph = fontimage.find(font.image, font.image.default_char).?, .font = font };
}

/// The glyph a font has under a number of its own, made by its hook the
/// first time it is wanted. Null for a font that makes no glyphs, a
/// number the font has no glyph for, and a glyph that could not be made
/// this time.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font.
/// - `number` - the glyph's number in the font, below 0x8000_0000.
pub fn glyphByNumber(gb: *GraphicsBase, font: *const TextFont, number: u32) ?*const Glyph {
    if (number & kept.by_number != 0) return null;
    return kept.glyphFor(gb, font, kept.by_number | number);
}

/// Where a glyph's first row starts.
///
/// INPUTS:
/// - `font` - the font the glyph is of, as `glyphOf` named it.
/// - `glyph` - the glyph.
pub fn pixelsOf(font: *const TextFont, glyph: *const Glyph) [*]const u8 {
    return kept.pixelsOf(font, glyph);
}

/// The glyph one of the fonts has for exactly `code`: the font's, or the
/// first of its fallbacks' that has one. Null when none has.
///
/// The fallbacks are walked for at most `FONT_FALLBACKS` fonts, so a
/// chain that was closed into a ring by mistake ends the search rather
/// than the task.
fn ownGlyph(gb: *GraphicsBase, font: *const TextFont, code: u32) ?Found {
    if (glyphIn(gb, font, code)) |own| return .{ .glyph = own, .font = font };
    var at = font.fallback;
    var left: u32 = graphics.FONT_FALLBACKS;
    while (at) |fallback| : (at = fallback.fallback) {
        if (left == 0) break;
        left -= 1;
        if (glyphIn(gb, fallback, code)) |theirs| return .{ .glyph = theirs, .font = fallback };
    }
    return null;
}

/// The glyph one font has for exactly `code`: its image's, or the one
/// its hook makes.
fn glyphIn(gb: *GraphicsBase, font: *const TextFont, code: u32) ?*const Glyph {
    if (fontimage.find(font.image, code)) |held| return held;
    return kept.glyphFor(gb, font, code);
}

/// How the glyphs of one font are put on a line: whose they are, whose
/// the line is, and what the styles make of them.
pub const Look = struct {
    /// The font the glyphs are of: the text's, or a fallback of it.
    font: *const TextFont,
    /// The font the text is in. Its height is the line's, its baseline
    /// where every glyph stands, and italic leans by its rows.
    line: *const TextFont,
    /// The styles drawn on the glyphs: the ones asked for and the ones
    /// the line's font is drawn with, less the ones `font` already is.
    style: graphics.FontStyle,
    /// What the styles add to each advance.
    extra: i32,
    /// How far right bold draws a glyph again.
    smear: i32,
    /// How far italic leans the line's top row.
    lean: i32,
    /// How many rows below the line's top the glyphs' own top is: the
    /// two baselines apart, less than zero for a font that stands taller
    /// over its baseline than the line does.
    drop: i32,
};

/// How the glyphs of `font` are put on the line of `line`.
///
/// INPUTS:
/// - `line` - the font the text is in.
/// - `font` - the font the glyphs are of: `line`, or a fallback of it.
/// - `style` - the RastPort's style.
pub fn lookOf(line: *const TextFont, font: *const TextFont, style: graphics.FontStyle) Look {
    // A fallback under a line of a bold face is drawn bold too, unless
    // it is a bold face itself.
    const drawn = (style | line.image.style) & softStyles(font);
    return .{
        .font = font,
        .line = line,
        .style = drawn,
        .extra = extraAdvance(drawn),
        .smear = smearOf(font, drawn),
        .lean = leanOf(line, drawn),
        .drop = @as(i32, line.image.baseline) - @as(i32, font.image.baseline),
    };
}

/// What the styles add to every character's advance: bold and extended
/// each a pixel. `style` is what is left after `softStyles`.
///
/// INPUTS:
/// - `style` - the styles that are drawn.
pub fn extraAdvance(style: graphics.FontStyle) i32 {
    var extra: i32 = 0;
    // Bold is the glyph drawn again to the right, so it needs the room.
    if (style & graphics.FSF_BOLD != 0) extra += 1;
    if (style & graphics.FSF_EXTENDED != 0) extra += 1;
    return extra;
}

/// How far bold draws the glyph again to the right, 0 when not bold.
///
/// INPUTS:
/// - `font` - the font.
/// - `style` - the styles that are drawn.
pub fn smearOf(font: *const TextFont, style: graphics.FontStyle) i32 {
    return if (style & graphics.FSF_BOLD != 0) font.image.bold_smear else 0;
}

/// How far right the top row of an italic leans, 0 when not italic.
///
/// INPUTS:
/// - `font` - the font.
/// - `style` - the styles that are drawn.
pub fn leanOf(font: *const TextFont, style: graphics.FontStyle) i32 {
    if (style & graphics.FSF_ITALIC == 0) return 0;
    return @divTrunc(@as(i32, font.image.height) - 1, 4);
}

/// How far right the row `line` of the line leans under italic.
///
/// INPUTS:
/// - `font` - the font.
/// - `style` - the styles that are drawn.
/// - `line` - the row, from the top of the line.
pub fn slantOf(font: *const TextFont, style: graphics.FontStyle, line: i32) i32 {
    if (style & graphics.FSF_ITALIC == 0) return 0;
    return @divTrunc(@as(i32, font.image.height) - 1 - line, 4);
}

/// Where some text goes, measured from the point it starts at.
pub const Measure = struct {
    /// How far the point moves: the advances added up.
    width: i32 = 0,
    /// The leftmost and one past the rightmost column the text touches,
    /// ink or paper: the paper is the advances, the ink can reach back
    /// by a negative `left` and on past the end by bold and a lean.
    min_x: i32 = 0,
    max_x: i32 = 0,
};

/// The room one more character takes after `m`: `m` grown by it.
///
/// INPUTS:
/// - `m` - what the text so far takes.
/// - `glyph` - the next character's glyph.
/// - `extra` - what the styles add to its advance.
/// - `smear` - how far bold draws it again.
/// - `lean` - how far italic leans its top row.
pub fn grow(m: Measure, glyph: *const Glyph, extra: i32, smear: i32, lean: i32) Measure {
    var next = m;
    const at = m.width;
    next.width = at + glyph.advance + extra;
    next.max_x = @max(next.max_x, next.width + lean);
    if (glyph.width != 0 and glyph.rows != 0) {
        const ink_left = at + glyph.left;
        next.min_x = @min(next.min_x, ink_left);
        next.max_x = @max(next.max_x, ink_left + @as(i32, glyph.width) + smear + lean);
    }
    return next;
}

/// The room one more character takes before `m`: `m` moved right by its
/// advance and it put in front. How a string is measured from its end.
///
/// INPUTS:
/// - as `grow`.
pub fn growBack(m: Measure, glyph: *const Glyph, extra: i32, smear: i32, lean: i32) Measure {
    const first = grow(.{}, glyph, extra, smear, lean);
    return .{
        .width = first.width + m.width,
        .min_x = @min(first.min_x, m.min_x + first.width),
        .max_x = @max(first.max_x, m.max_x + first.width),
    };
}

/// What the `count` bytes of `string` take in `font` with `style`, each
/// character measured as the glyph it is drawn with, a fallback's
/// included.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font the text is in.
/// - `style` - the RastPort's style; what a font already is is left out.
/// - `string` - the text, UTF-8.
/// - `count` - its length in bytes.
pub fn measure(gb: *GraphicsBase, font: *const TextFont, style: graphics.FontStyle, string: [*]const u8, count: u32) Measure {
    var look = lookOf(font, font, style);
    var m = Measure{};
    const bytes = string[0..count];
    var at: usize = 0;
    while (at < bytes.len) {
        const found = glyphOf(gb, font, utf8.next(bytes, &at));
        if (found.font != look.font) look = lookOf(font, found.font, style);
        m = grow(m, found.glyph, look.extra, look.smear, look.lean);
    }
    return m;
}

/// Which styles can still be asked for: the ones the font was not already
/// drawn with. Asking a wide font to be extended again would widen it
/// twice, which is the sort of thing nobody notices until a column of text
/// does not line up.
///
/// INPUTS:
/// - `font` - the font.
pub fn softStyles(font: *const TextFont) graphics.FontStyle {
    const all = graphics.FSF_BOLD | graphics.FSF_ITALIC |
        graphics.FSF_UNDERLINED | graphics.FSF_EXTENDED;
    return all & ~font.image.style;
}

/// A font's own description, as `WeighTAMatch` compares it: its name,
/// height and drawn styles, and its image's flags with where it came
/// from.
///
/// INPUTS:
/// - `font` - the font.
pub fn attrOf(font: *const TextFont) graphics.TextAttr {
    return .{
        .name = font.node.name orelse "",
        .y_size = font.image.height,
        .style = font.image.style,
        .flags = font.image.flags | font.flags,
    };
}

/// What a RastPort answers about the font it has, for GetRPAttrs.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font is asked about.
/// - `which` - the `RPTAG_` of the measurement.
pub fn metric(rp: *const RastPort, which: u32) u32 {
    const font = rp.font orelse return 0;
    const image = font.image;
    return switch (which) {
        graphics.RPTAG_FontHeight => image.height,
        graphics.RPTAG_FontBaseline => image.baseline,
        graphics.RPTAG_FontProportional => @intFromBool(image.flags & graphics.FPF_PROPORTIONAL != 0),
        else => @intCast(image.x_size + extraAdvance(rp.text_style & softStyles(font))),
    };
}
