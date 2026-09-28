// SPDX-License-Identifier: MIT
//! diskfont.library's types and constants, and the files a font is kept
//! in on a disk.
//!
//! A font family on a disk is a directory and a contents file beside it
//! in `FONTS:`: `FONTS:spleen.font` lists the sizes, and each size is a
//! file of its own, `FONTS:spleen/16`. A size file is a font image
//! (`graphics.fontimage`) byte for byte, so it is read with one Read and
//! drawn from where it lies. The contents file is `fontfile`.

const graphics = @import("../graphics/graphics.zig");

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

/// The layout of a family's contents file.
pub const fontfile = @import("fontfile.zig");
