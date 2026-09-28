// SPDX-License-Identifier: MIT
//! A font's glyphs and measures as one block: the FontImage.
//!
//! Everything a font is lies in one piece of memory, and every reference
//! inside it is an offset from the block's own start, so the block means
//! the same wherever it lies: in the ROM, in a file, or read from one
//! into memory. Nothing in it is a pointer and nothing is fixed up after
//! loading. graphics.library draws from it; a font file holds one after
//! its own header.
//!
//! The block starts with a `FontImage`, and after it, each at the offset
//! the header gives and each four-byte aligned:
//!
//! - **ranges** - `Range`s, sorted by code and not overlapping: a run of
//!   codes that have glyphs, and the index of the first one's glyph. A
//!   Latin-1 font is one or two of them; a font with gaps is more.
//! - **glyphs** - a `Glyph` for each: where its pixels are, the box
//!   they fill, where the box sits from the point, and how far the
//!   point moves.
//! - **palette** - for a colour font only, ARGB entries.
//! - **data** - the pixels, each glyph's rows one after another.
//!
//! A glyph's box is its ink, not its cell: a space has none, an 'x' has
//! only the rows the x fills, and `top` says how far down the line it
//! starts. Its pixels are one of three kinds, the same for the whole
//! font:
//!
//! | kind | a pixel | 0 |
//! |------|---------|---|
//! | `mono1` | one bit, the leftmost in a byte's highest | no ink |
//! | `alpha4` | four bits, two to a byte, the left one high; 15 is full ink | no ink |
//! | `indexed8` | a byte, an entry of the palette | transparent |
//!
//! In a colour font one palette entry can stand for the pen: `pen_index`
//! names it, and that entry is drawn in the RastPort's foreground pen
//! with the entry's own alpha, so a font with a coloured shadow still
//! takes the caller's text colour for its body.
//!
//! Codes are 32 bits, so a font can carry any character set; text drawn
//! today is bytes, each a Latin-1 code. A code the font has no glyph for
//! is drawn as `default_char`, which every image must have.
//!
//! Multi-byte fields are little-endian, which is how this machine reads
//! them in place. The block is a whole number of longwords, and the last
//! header field makes them add up to zero, so a copy that lost or changed
//! a byte on the way is known before anything draws from it.

const graphics = @import("graphics.zig");

/// The first four bytes of every image: "PFNT".
pub const MAGIC: u32 = 0x544E_4650;

/// The layout this file describes. A block of another version is refused.
pub const VERSION: u16 = 1;

/// What a glyph's pixels are.
pub const Kind = enum(u8) {
    /// One bit a pixel: ink or not.
    mono1 = 0,
    /// Four bits a pixel: how much of it the ink covers, 0 to 15.
    alpha4 = 1,
    /// A byte a pixel: an entry of the palette, 0 transparent.
    indexed8 = 2,
    _,
};

/// `pen_index` when no palette entry is drawn in the pen.
pub const NO_PEN: u32 = 0xFFFF_FFFF;

/// The header at the start of the block.
pub const FontImage = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    /// How big this header is, so a later version can add to it and an
    /// older reader still finds the tables.
    header_size: u16 = @sizeOf(FontImage),
    /// The whole block, header, tables and pixels.
    size: u32 = 0,
    /// Rows in a line of text, and rows from its top to the baseline.
    height: u16 = 0,
    baseline: u16 = 0,
    /// The nominal width: the advance of every character of a fixed-width
    /// font, a typical one of a proportional font.
    x_size: u16 = 0,
    /// The widest glyph box, for a caller sizing a cell.
    max_width: u16 = 0,
    /// The styles the font was drawn with (`FSF_`), which are not applied
    /// again on top.
    style: graphics.FontStyle = graphics.FS_NORMAL,
    /// `FPF_PROPORTIONAL` when the advances differ, `FPF_DESIGNED` when
    /// the size was drawn rather than scaled.
    flags: u8 = 0,
    kind: Kind = .mono1,
    /// How far right bold draws the glyph again.
    bold_smear: u8 = 1,
    /// The code drawn for one the font has no glyph for.
    default_char: u32 = 0,
    range_count: u32 = 0,
    ranges: u32 = 0,
    glyph_count: u32 = 0,
    glyphs: u32 = 0,
    palette_count: u32 = 0,
    palette: u32 = 0,
    /// The palette entry drawn in the pen, or `NO_PEN`.
    pen_index: u32 = NO_PEN,
    data_size: u32 = 0,
    data: u32 = 0,
    /// What makes the longwords of the whole block add up to zero, this
    /// one included (`sound`). A font file is an image, and this is how
    /// one read from a disk is known to be whole.
    checksum: u32 = 0,
};

/// Codes `first` to `last` have glyphs `glyph` onwards, one each.
pub const Range = extern struct {
    first: u32,
    last: u32,
    glyph: u32,
};

/// One glyph: its box and where it goes.
pub const Glyph = extern struct {
    /// Where its pixels start, from the start of the data.
    data: u32 = 0,
    /// The box: columns and rows of pixels. Zero for a glyph with no ink.
    width: u16 = 0,
    rows: u16 = 0,
    /// Rows from the top of the line down to the box.
    top: i16 = 0,
    /// Columns from the point to the box; less than zero reaches back
    /// under the character before.
    left: i16 = 0,
    /// How far the point moves after it.
    advance: i16 = 0,
    /// Bytes from one row of the box to the next.
    pitch: u16 = 0,
};

/// Bytes one row of `width` pixels takes in `kind`.
///
/// INPUTS:
/// - `kind` - the font's kind.
/// - `width` - pixels in the row.
pub fn pitchOf(kind: Kind, width: u32) u32 {
    return switch (kind) {
        .mono1 => (width + 7) / 8,
        .alpha4 => (width + 1) / 2,
        else => width,
    };
}

/// The ranges of `image`.
///
/// INPUTS:
/// - `image` - a block `check` has passed.
pub fn rangesOf(image: *const FontImage) []const Range {
    const at: [*]const Range = @ptrCast(@alignCast(bytesOf(image) + image.ranges));
    return at[0..image.range_count];
}

/// The glyphs of `image`.
///
/// INPUTS:
/// - `image` - a block `check` has passed.
pub fn glyphsOf(image: *const FontImage) []const Glyph {
    const at: [*]const Glyph = @ptrCast(@alignCast(bytesOf(image) + image.glyphs));
    return at[0..image.glyph_count];
}

/// The palette of `image`, empty for a font that is not colour.
///
/// INPUTS:
/// - `image` - a block `check` has passed.
pub fn paletteOf(image: *const FontImage) []const u32 {
    const at: [*]const u32 = @ptrCast(@alignCast(bytesOf(image) + image.palette));
    return at[0..image.palette_count];
}

/// Where a glyph's first row starts.
///
/// INPUTS:
/// - `image` - the block the glyph is from.
/// - `glyph` - the glyph.
pub fn pixelsOf(image: *const FontImage, glyph: *const Glyph) [*]const u8 {
    return bytesOf(image) + image.data + glyph.data;
}

/// The glyph for `code`, or null if the font has none.
///
/// The ranges are searched by halves, so a font with many of them costs
/// a handful of compares, and one with one or two a compare or two.
///
/// INPUTS:
/// - `image` - a block `check` has passed.
/// - `code` - the character.
pub fn find(image: *const FontImage, code: u32) ?*const Glyph {
    const ranges = rangesOf(image);
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = &ranges[mid];
        if (code < range.first) {
            high = mid;
        } else if (code > range.last) {
            low = mid + 1;
        } else {
            return &glyphsOf(image)[range.glyph + (code - range.first)];
        }
    }
    return null;
}

/// The glyph `code` is drawn with: its own, or the default character's.
///
/// INPUTS:
/// - `image` - a block `check` has passed, which guarantees the default.
/// - `code` - the character.
pub fn glyphFor(image: *const FontImage, code: u32) *const Glyph {
    return find(image, code) orelse find(image, image.default_char).?;
}

/// Whether `size` bytes at `block` are an image that can be drawn from
/// without reading outside it.
///
/// Every table and every glyph's pixels are inside the block, the ranges
/// are sorted and name glyphs that exist, the kind is known, a colour
/// font has a palette and its pen entry is in it, and the default
/// character has a glyph.
///
/// INPUTS:
/// - `block` - the start of the block, four-byte aligned.
/// - `size` - how many bytes there are.
pub fn check(block: [*]const u8, size: u32) bool {
    if (size < @sizeOf(FontImage) or @intFromPtr(block) % 4 != 0) return false;
    const image: *const FontImage = @ptrCast(@alignCast(block));
    if (image.magic != MAGIC or image.version != VERSION) return false;
    if (image.header_size < @sizeOf(FontImage) or image.size > size) return false;
    if (image.height == 0 or image.baseline > image.height) return false;
    switch (image.kind) {
        .mono1, .alpha4 => {},
        .indexed8 => {
            if (image.palette_count == 0 or image.palette_count > 256) return false;
            if (image.pen_index != NO_PEN and image.pen_index >= image.palette_count) return false;
        },
        else => return false,
    }
    if (!inside(image, image.ranges, image.range_count, @sizeOf(Range))) return false;
    if (!inside(image, image.glyphs, image.glyph_count, @sizeOf(Glyph))) return false;
    if (!inside(image, image.palette, image.palette_count, 4)) return false;
    if (!inside(image, image.data, image.data_size, 1)) return false;

    var next_code: u64 = 0;
    for (rangesOf(image)) |range| {
        if (range.first < next_code or range.last < range.first) return false;
        const count: u64 = @as(u64, range.last) - range.first + 1;
        if (range.glyph + count > image.glyph_count) return false;
        next_code = @as(u64, range.last) + 1;
    }
    for (glyphsOf(image)) |*glyph| {
        if (glyph.pitch < pitchOf(image.kind, glyph.width)) return false;
        const bytes: u64 = @as(u64, glyph.pitch) * glyph.rows;
        if (glyph.data + bytes > image.data_size) return false;
    }
    return find(image, image.default_char) != null;
}

/// Whether `count` things of `each` bytes from `offset` lie inside the
/// block, four-byte aligned when they are bigger than a byte.
fn inside(image: *const FontImage, offset: u32, count: u32, each: u32) bool {
    if (count == 0) return true;
    if (each > 1 and offset % 4 != 0) return false;
    const end: u64 = @as(u64, offset) + @as(u64, count) * each;
    return offset >= image.header_size and end <= image.size;
}

/// The longwords of a block added up: 0 for a sound image.
///
/// INPUTS:
/// - `block` - the start of the block.
/// - `size` - how many bytes, a multiple of four.
pub fn sumOf(block: [*]const u8, size: u32) u32 {
    var total: u32 = 0;
    var at: u32 = 0;
    while (at + 4 <= size) : (at += 4) {
        total +%= @as(u32, block[at]) | @as(u32, block[at + 1]) << 8 |
            @as(u32, block[at + 2]) << 16 | @as(u32, block[at + 3]) << 24;
    }
    return total;
}

/// The value an image's `checksum` must hold, whatever it holds now.
///
/// INPUTS:
/// - `block` - the image.
/// - `size` - its size in bytes, a multiple of four.
pub fn checksumOf(block: [*]const u8, size: u32) u32 {
    const image: *const FontImage = @ptrCast(@alignCast(block));
    return 0 -% (sumOf(block, size) -% image.checksum);
}

/// Whether a block's longwords add up to zero: it is whole, as it was
/// written. `check` says whether it holds together; this says it is the
/// block that was meant.
///
/// INPUTS:
/// - `block` - the start of the block, four-byte aligned.
/// - `size` - how many bytes there are.
pub fn sound(block: [*]const u8, size: u32) bool {
    if (size % 4 != 0 or size < @sizeOf(FontImage)) return false;
    return sumOf(block, size) == 0;
}

fn bytesOf(image: *const FontImage) [*]const u8 {
    return @ptrCast(image);
}

/// One glyph as `build` takes it.
pub const GlyphSpec = struct {
    code: u32,
    advance: i16,
    left: i16 = 0,
    top: i16 = 0,
    width: u16 = 0,
    rows: u16 = 0,
    /// `rows` rows of `pitchOf(kind, width)` bytes, in the font's kind.
    pixels: []const u8 = &.{},
};

/// A font as `build` takes it: the header's measures and the glyphs,
/// sorted by code.
pub const Spec = struct {
    height: u16,
    baseline: u16,
    x_size: u16,
    style: graphics.FontStyle = graphics.FS_NORMAL,
    flags: u8 = 0,
    kind: Kind = .mono1,
    bold_smear: u8 = 1,
    default_char: u32,
    palette: []const u32 = &.{},
    pen_index: u32 = NO_PEN,
    glyphs: []const GlyphSpec,
};

/// How many ranges the glyphs of `spec` fall into: a new one wherever a
/// code does not follow the one before.
fn rangeCount(comptime spec: Spec) u32 {
    var count: u32 = 0;
    for (spec.glyphs, 0..) |glyph, i| {
        if (i == 0 or glyph.code != spec.glyphs[i - 1].code + 1) count += 1;
    }
    return count;
}

fn align4(value: u32) u32 {
    return (value + 3) & ~@as(u32, 3);
}

/// The size `build` makes of `spec`.
///
/// INPUTS:
/// - `spec` - the font.
pub fn imageSize(comptime spec: Spec) u32 {
    @setEvalBranchQuota(1_000_000);
    var data: u32 = 0;
    for (spec.glyphs) |glyph| data += pitchOf(spec.kind, glyph.width) * glyph.rows;
    return @sizeOf(FontImage) + rangeCount(spec) * @sizeOf(Range) +
        @as(u32, spec.glyphs.len) * @sizeOf(Glyph) + @as(u32, spec.palette.len) * 4 + align4(data);
}

/// The image of `spec`, made at compile time: how the ROM's fonts and
/// the tests' are built. Store the result four-byte aligned.
///
/// INPUTS:
/// - `spec` - the font, its glyphs sorted by code.
pub fn build(comptime spec: Spec) [imageSize(spec)]u8 {
    @setEvalBranchQuota(10_000_000);
    const size = imageSize(spec);
    var out: [size]u8 = @splat(0);
    const ranges_at: u32 = @sizeOf(FontImage);
    const range_count = rangeCount(spec);
    const glyphs_at = ranges_at + range_count * @sizeOf(Range);
    const palette_at = glyphs_at + @as(u32, spec.glyphs.len) * @sizeOf(Glyph);
    const data_at = palette_at + @as(u32, spec.palette.len) * 4;

    var max_width: u16 = 0;
    var proportional = false;
    var data: u32 = 0;
    var range_index: u32 = 0;
    for (spec.glyphs, 0..) |glyph, i| {
        if (i == 0 or glyph.code != spec.glyphs[i - 1].code + 1) {
            const range_at = ranges_at + range_index * @sizeOf(Range);
            var last = glyph.code;
            var j = i + 1;
            while (j < spec.glyphs.len and spec.glyphs[j].code == last + 1) : (j += 1) last += 1;
            put32(&out, range_at, glyph.code);
            put32(&out, range_at + 4, last);
            put32(&out, range_at + 8, i);
            range_index += 1;
        }
        const pitch = pitchOf(spec.kind, glyph.width);
        const glyph_at = glyphs_at + @as(u32, i) * @sizeOf(Glyph);
        put32(&out, glyph_at, data);
        put16(&out, glyph_at + 4, glyph.width);
        put16(&out, glyph_at + 6, glyph.rows);
        put16(&out, glyph_at + 8, @bitCast(glyph.top));
        put16(&out, glyph_at + 10, @bitCast(glyph.left));
        put16(&out, glyph_at + 12, @bitCast(glyph.advance));
        put16(&out, glyph_at + 14, pitch);
        const bytes = pitch * glyph.rows;
        if (glyph.pixels.len != bytes) @compileError("a glyph's pixels are not rows times pitch");
        for (glyph.pixels, 0..) |byte, k| out[data_at + data + k] = byte;
        data += bytes;
        if (glyph.width > max_width) max_width = glyph.width;
        if (glyph.advance != spec.x_size and glyph.code != spec.default_char) proportional = true;
    }
    for (spec.palette, 0..) |entry, i| put32(&out, palette_at + @as(u32, i) * 4, entry);

    const flags = spec.flags | if (proportional) graphics.FPF_PROPORTIONAL else 0;
    const header = FontImage{
        .size = size,
        .height = spec.height,
        .baseline = spec.baseline,
        .x_size = spec.x_size,
        .max_width = max_width,
        .style = spec.style,
        .flags = flags,
        .kind = spec.kind,
        .bold_smear = spec.bold_smear,
        .default_char = spec.default_char,
        .range_count = range_count,
        .ranges = ranges_at,
        .glyph_count = spec.glyphs.len,
        .glyphs = glyphs_at,
        .palette_count = spec.palette.len,
        .palette = if (spec.palette.len != 0) palette_at else 0,
        .pen_index = spec.pen_index,
        .data_size = data,
        .data = data_at,
    };
    const header_bytes: [@sizeOf(FontImage)]u8 = @bitCast(header);
    for (header_bytes, 0..) |byte, i| out[i] = byte;
    // The field is 0 still, so the sum is of everything else.
    put32(&out, @offsetOf(FontImage, "checksum"), 0 -% sumOf(&out, size));
    return out;
}

fn put32(out: []u8, at: u32, value: u32) void {
    for (0..4) |i| out[at + i] = @truncate(value >> @intCast(i * 8));
}

fn put16(out: []u8, at: u32, value: u16) void {
    out[at] = @truncate(value);
    out[at + 1] = @truncate(value >> 8);
}
