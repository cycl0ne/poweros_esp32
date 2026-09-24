// SPDX-License-Identifier: MPL-2.0
//! Fonts and text.
//!
//! A font here is the glyphs and four numbers: how wide a character is, how
//! tall, where the baseline sits, and which characters there are. The
//! glyphs are a `u16` a row with the leftmost pixel in the highest bit,
//! which is wide enough for anything this machine draws and costs nothing
//! to shift.
//!
//! Two of them are in the ROM, both called `pospaz.font` and told apart by
//! height:
//!
//! | height | width | baseline |
//! |--------|-------|----------|
//! | 8      | 8     | 6        |
//! | 16     | 8     | 13       |
//!
//! Sixteen is eight with every row drawn twice, for a panel whose pixels
//! are square; the columns stay the same.
//!
//! **Text goes through the same plot as everything else**, so the draw
//! modes are the draw modes: `DRMD_JAM1` leaves the paper alone,
//! `DRMD_JAM2` lays the background pen down behind the letters, and
//! `DRMD_COMPLEMENT` inverts them into whatever is there. A console wants
//! JAM2 and gets it for nothing.
//!
//! The styles are drawn rather than stored, as they always were: bold is
//! the glyph drawn over itself one pixel right, italic is each row moved
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

const pospaz8 = @import("../fonts/pospaz8.zig");
const pospaz16 = @import("../fonts/pospaz16.zig");

/// A font, as the library holds it. Callers have an opaque pointer.
pub const TextFont = struct {
    /// What the library's list holds it by. A font in the ROM is on it
    /// from the start; one built from a file is put on with AddFont.
    node: exec.Node = .{},
    name: [*:0]const u8,
    /// How far along one character moves the point.
    width: u16,
    /// How many rows tall, and how far down the baseline sits in them.
    height: u16,
    baseline: u16,
    /// The first character the glyphs are for, and how many there are -
    /// the last of which stands in for anything outside.
    first_char: u8,
    count: u16,
    /// The styles it was drawn with, which cannot be applied again - a
    /// font drawn extended would be widened twice.
    style: graphics.FontStyle = graphics.FS_NORMAL,
    /// `count * height` rows, the leftmost pixel in the highest bit.
    rows: [*]const u16,
    /// How many callers have it open. A font in the ROM never goes
    /// whatever this says; it is here so that a font that is not in the
    /// ROM can, later, without the calls changing.
    open_count: u16,
};

/// The two in this ROM, as they start. `initFonts` copies them into
/// memory of the library's own, since opening one counts and the image
/// cannot be written.
const rom_fonts = [_]TextFont{
    .{
        .name = graphics.POSPAZNAME,
        .width = 8,
        .height = 8,
        .baseline = 6,
        .first_char = 32,
        .count = pospaz8.font_data.len,
        .rows = @ptrCast(&pospaz8.font_data),
        .open_count = 0,
    },
    .{
        .name = graphics.POSPAZNAME,
        .width = 8,
        .height = 16,
        .baseline = 13,
        .first_char = 32,
        .count = pospaz16.font_data.len,
        .rows = @ptrCast(&pospaz16.font_data),
        .open_count = 0,
    },
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
    gb.sys_base.NewList(&gb.fonts);
    gb.sys_base.InitSemaphore(&gb.font_lock);
    const block = gb.sys_base.AllocVec(@sizeOf(@TypeOf(rom_fonts)), exec.MEMF_ANY) orelse return false;
    const own: *[rom_fonts.len]TextFont = @ptrCast(@alignCast(block));
    own.* = rom_fonts;
    for (own) |*font| {
        font.node.name = font.name;
        gb.sys_base.AddTail(&gb.fonts, &font.node);
    }
    gb.rom_fonts = block;
    return true;
}

/// Which glyph a character is, with anything outside the font standing in
/// as the last one.
///
/// INPUTS:
/// - `font` - the font.
/// - `ch` - the character.
pub fn glyphOf(font: *const TextFont, ch: u8) u32 {
    if (ch < font.first_char) return font.count - 1;
    const at = @as(u32, ch) - font.first_char;
    if (at >= font.count) return font.count - 1;
    return at;
}

/// How far one character moves the point, style and all.
///
/// INPUTS:
/// - `font` - the font.
/// - `style` - the text style: bold and extended each add a pixel.
pub fn advance(font: *const TextFont, style: graphics.FontStyle) i32 {
    const asked = style & softStyles(font);
    var step: i32 = font.width;
    // Bold is the glyph drawn again one to the right, so it needs the room.
    if (asked & graphics.FSF_BOLD != 0) step += 1;
    if (asked & graphics.FSF_EXTENDED != 0) step += 1;
    return step;
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
    return all & ~font.style;
}

/// What a RastPort answers about the font it has, for GetRPAttrs.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font is asked about.
/// - `which` - the `RPTAG_` of the measurement.
pub fn metric(rp: *const RastPort, which: u32) u32 {
    const font = rp.font orelse return 0;
    return switch (which) {
        0 => font.height,
        1 => font.baseline,
        else => @intCast(advance(font, rp.text_style)),
    };
}
