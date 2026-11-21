// SPDX-License-Identifier: MIT
//! diskfont.library's types and constants, and the files a font is kept
//! in on a disk.
//!
//! A font family on a disk is a directory and a contents file beside it
//! in `FONTS:`: `FONTS:spleen.font` lists the sizes, and each size is a
//! file of its own, `FONTS:spleen/16`. A size file is a font image
//! (`graphics.fontimage`) byte for byte, so it is read with one Read and
//! drawn from where it lies. The contents file is `fontfile`.
//!
//! Since 1.4 a family with an outline is opened as the outline itself
//! (`OpenOutlineFont`): its font file read, for a program that draws
//! its glyphs at any size and angle with truetype.library's calls. A
//! program that needs this looks for revision 4 or later in the library
//! it opened. Since 1.13 a variable font is a family with an entry for
//! each style it has, and bold or italic asked of it is the font at
//! that place on its axes. Since 1.14 a contents file's entry names a
//! font of a collection, and the collection's families share the file.

const graphics = @import("../graphics/graphics.zig");
const truetype = @import("../truetype/truetype.zig");
const utility = @import("../utility/utility.zig");

/// The name to open it by.
pub const DISKFONTNAME = "diskfont.library";
/// The version a caller of this SDK asks for.
pub const DISKFONT_VERSION = 1;

/// The assign fonts are looked for in.
pub const FONTSNAME = "FONTS:";

// What AvailFonts looks at (its `flags`), and what it found (`type`).
/// Fonts in memory: on graphics' list.
pub const AFF_MEMORY: u32 = 0x0001;
/// Fonts on a disk: every contents file in FONTS:.
pub const AFF_DISK: u32 = 0x0002;
/// Memory fonts scaled from another size too; and on an entry, that it
/// is one.
pub const AFF_SCALED: u32 = 0x0004;
/// On an entry: an outline font on the disk, made at any height asked
/// for; its `y_size` is 0.
pub const AFF_SCALABLE: u32 = 0x0008;

/// What AvailFonts fills a buffer with: this, `count` `AvailFonts`
/// entries from `avail_entries_at`, and the names they point at.
pub const AvailFontsHeader = extern struct {
    count: u32 = 0,
};

/// One font AvailFonts found: where (`AFF_MEMORY`, `AFF_DISK`, with
/// `AFF_SCALED` for a memory font made by scaling) and what, as the
/// TextAttr that opens it.
pub const AvailFonts = extern struct {
    type: u32 = 0,
    attr: graphics.TextAttr,
};

/// Where the entries start after the header: aligned for the pointer in
/// each.
pub const avail_entries_at = (@sizeOf(AvailFontsHeader) + @alignOf(AvailFonts) - 1) & ~@as(usize, @alignOf(AvailFonts) - 1);

/// The entries of a buffer AvailFonts filled.
///
/// INPUTS:
/// - `header` - the start of the buffer.
pub fn availEntries(header: *const AvailFontsHeader) []const AvailFonts {
    const bytes: [*]const u8 = @ptrCast(header);
    const at: [*]const AvailFonts = @ptrCast(@alignCast(bytes + avail_entries_at));
    return at[0..header.count];
}

/// A family's outline, opened by `OpenOutlineFont` (since 1.4): the face
/// of the styles asked - or a variable font at the place of those
/// styles - its font file read and opened. The library's, shared by
/// everyone who opened it, until `CloseOutlineFont`.
pub const OutlineFont = extern struct {
    /// For truetype.library's calls: `GlyphIndex`, `GlyphSegments`,
    /// `FontMetrics` and the rest. Not to be closed by the caller.
    outline: *truetype.Outline,
    /// The styles the face is drawn in, `FSF_BOLD` and `FSF_ITALIC`: what
    /// was asked and the family has a face or an entry for. What it is not drawn in
    /// a program draws itself, if it will - leaning it for italic.
    style: graphics.FontStyle,
};

// --- choosing a face (since 1.16) ------------------------------------------------

/// The generic families `GenericFamily` names, as a document asks for
/// them: a serif, a sans-serif, a fixed-width font, a handwriting one,
/// a decorative one.
pub const GENERIC_SERIF: u32 = 0;
pub const GENERIC_SANS: u32 = 1;
pub const GENERIC_MONO: u32 = 2;
pub const GENERIC_CURSIVE: u32 = 3;
pub const GENERIC_FANTASY: u32 = 4;

/// The tags of `OpenOutlineFontTagList`: the face asked for.
pub const DFA_Dummy = utility.TAG_USER + 0x61300;
/// How heavy, 1 to 1000: 400 regular, 700 bold. Default 400.
pub const DFA_Weight = DFA_Dummy + 1;
/// How wide, in tenths of a percent of the normal width: 1000 normal,
/// 750 condensed, 1250 expanded. Default 1000.
pub const DFA_Stretch = DFA_Dummy + 2;
/// Nonzero: an italic face. Default 0.
pub const DFA_Italic = DFA_Dummy + 3;
/// `[*]const truetype.AxisValue`: values on the axes of a variable font,
/// set after the weight and the width it was chosen by and the later of
/// two for one axis winning. An axis the font has not is passed over.
pub const DFA_Axes = DFA_Dummy + 4;
/// How many values `DFA_Axes` holds. Default 0.
pub const DFA_AxisCount = DFA_Dummy + 5;

/// The layout of a family's contents file.
pub const fontfile = @import("fontfile.zig");
