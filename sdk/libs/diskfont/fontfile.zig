// SPDX-License-Identifier: MIT
//! A font family's contents file: `FONTS:<family>.font`.
//!
//! It says which sizes of the family there are, where each one's file is,
//! and what each is - height, drawn style, flags, kind of pixels - so a
//! font can be chosen before any size is read. It is written by the tool
//! that converts fonts on the host and by `NewFontContents` on the
//! machine, and read by diskfont.library.
//!
//! A `ContentsHeader`, then `count` `FontContents`, little-endian and in
//! 32-bit alignment. The longwords of the whole file add up to zero, the
//! header's `checksum` making them, so a file that lost a byte is refused
//! rather than half believed.

const graphics = @import("../graphics/graphics.zig");

/// The first four bytes of a contents file: "PFCT".
pub const MAGIC: u32 = 0x5443_4650;

/// The layout this file describes.
pub const VERSION: u16 = 1;

/// How long an entry's path can be, its NUL included.
pub const MAXFONTPATH = 64;

/// The start of the file.
pub const ContentsHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    /// How many entries follow.
    count: u16 = 0,
    /// What makes the longwords of the file add up to zero.
    checksum: u32 = 0,
};

/// One size of the family.
pub const FontContents = extern struct {
    /// The size's file, from `FONTS:`: "spleen/16". NUL-padded.
    path: [MAXFONTPATH]u8 = @splat(0),
    /// Rows tall.
    y_size: u16 = 0,
    /// The styles it was drawn with (`FSF_`).
    style: graphics.FontStyle = graphics.FS_NORMAL,
    /// `FPF_` flags: proportional, designed.
    flags: graphics.FontFlags = 0,
    /// Its pixels: a `fontimage.Kind`.
    kind: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The nominal width.
    x_size: u16 = 0,
    /// 1: `path` is a TrueType file, rendered at whatever height is asked
    /// (truetype.library), and `y_size` is 0. 0: a size file.
    outline: u8 = 0,
    /// Nothing yet; zero.
    reserved: [5]u8 = @splat(0),
};

comptime {
    if (@sizeOf(ContentsHeader) != 12) @compileError("ContentsHeader is not 12 bytes");
    if (@sizeOf(FontContents) != 80) @compileError("FontContents is not 80 bytes");
}

/// How many bytes a contents file of `count` entries is.
///
/// INPUTS:
/// - `count` - how many sizes it lists.
pub fn contentsSize(count: u32) u32 {
    return @sizeOf(ContentsHeader) + count * @sizeOf(FontContents);
}

/// The entries of a contents file `sound` has passed.
///
/// INPUTS:
/// - `block` - the file, four-byte aligned.
pub fn entriesOf(block: [*]const u8) []const FontContents {
    const header: *const ContentsHeader = @ptrCast(@alignCast(block));
    const at: [*]const FontContents = @ptrCast(@alignCast(block + @sizeOf(ContentsHeader)));
    return at[0..header.count];
}

/// An entry's path, without the padding.
///
/// INPUTS:
/// - `entry` - the entry.
pub fn pathOf(entry: *const FontContents) []const u8 {
    var len: usize = 0;
    while (len < MAXFONTPATH and entry.path[len] != 0) len += 1;
    return entry.path[0..len];
}

/// Whether `size` bytes at `block` are a contents file: the magic and
/// version, as many bytes as the count says, every path ended within its
/// field, and the longwords adding up to zero.
///
/// INPUTS:
/// - `block` - the start of the file, four-byte aligned.
/// - `size` - how many bytes were read.
pub fn sound(block: [*]const u8, size: u32) bool {
    if (size < @sizeOf(ContentsHeader) or @intFromPtr(block) % 4 != 0) return false;
    const header: *const ContentsHeader = @ptrCast(@alignCast(block));
    if (header.magic != MAGIC or header.version != VERSION) return false;
    if (size != contentsSize(header.count)) return false;
    if (graphics.fontimage.sumOf(block, size) != 0) return false;
    for (entriesOf(block)) |*entry| {
        if (entry.path[MAXFONTPATH - 1] != 0 or entry.path[0] == 0) return false;
    }
    return true;
}

/// Make the file's checksum right, once everything else is written.
///
/// INPUTS:
/// - `block` - the file, four-byte aligned.
/// - `size` - its size in bytes.
pub fn seal(block: [*]u8, size: u32) void {
    const header: *ContentsHeader = @ptrCast(@alignCast(block));
    header.checksum = 0;
    header.checksum = 0 -% graphics.fontimage.sumOf(block, size);
}

/// The entry of an outline font, whose TrueType file is `path`.
///
/// INPUTS:
/// - `path` - the file, from `FONTS:`; at most `MAXFONTPATH - 1` bytes.
pub fn outlineEntry(path: []const u8) FontContents {
    var entry = FontContents{
        .flags = graphics.FPF_DESIGNED,
        .kind = @intFromEnum(graphics.fontimage.Kind.alpha4),
        .outline = 1,
    };
    const len = @min(path.len, MAXFONTPATH - 1);
    for (path[0..len], 0..) |c, i| entry.path[i] = c;
    return entry;
}

/// The entry that describes the image `image`, whose file is `path`.
///
/// INPUTS:
/// - `path` - the size file, from `FONTS:`; at most `MAXFONTPATH - 1`
///   bytes.
/// - `image` - the size's image.
pub fn entryFor(path: []const u8, image: *const graphics.fontimage.FontImage) FontContents {
    var entry = FontContents{
        .y_size = image.height,
        .style = image.style,
        .flags = image.flags,
        .kind = @intFromEnum(image.kind),
        .x_size = image.x_size,
    };
    const len = @min(path.len, MAXFONTPATH - 1);
    for (path[0..len], 0..) |c, i| entry.path[i] = c;
    return entry;
}
