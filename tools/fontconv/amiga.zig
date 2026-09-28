// SPDX-License-Identifier: MPL-2.0
//! Reading an Amiga font: a family's contents file and its sizes' load
//! files.
//!
//! A contents file (`<family>.font`) is a big-endian word 0x0F00 or
//! 0x0F02, a count, and that many 260-byte entries, each a path from the
//! fonts directory ("topaz/11"), a height, a style and flags.
//!
//! A size is a load file: HUNK_HEADER, one code or data hunk, its RELOC32
//! and HUNK_END. The hunk starts with a return instruction and then the
//! DiskFontHeader: a node (14 bytes), the file id 0x0F80, a revision, a
//! segment long, a 32-byte name - and the TextFont at 54. Every pointer
//! in it is an offset into the hunk, which is what the relocation adds
//! the hunk's address to; read before relocating, it is the offset.
//!
//! The TextFont's glyphs are one strike: `tf_Modulo` bytes a row, and for
//! each character from `tf_LoChar` to `tf_HiChar` and one more, the
//! stand-in, a bit offset and width in `tf_CharLoc`. `tf_CharSpace` is
//! each one's advance (or `tf_XSize` for all) and `tf_CharKern` how far
//! from the point its ink starts (or 0); the point moves by the two
//! added. A colour font (`FSF_COLORFONT` in the style) has up to eight
//! strikes, one per bit of a pixel's colour, and a table of 12-bit
//! colours; its pixels become palette indices, its table the palette, and
//! the colour it marks as the pen's the pen entry.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const Glyph = font_mod.Glyph;
const Allocator = std.mem.Allocator;

pub const Error = error{ NotAmiga, BadHunk, BadFont } || Allocator.Error;

pub const HUNK_HEADER: u32 = 0x3F3;
pub const HUNK_CODE: u32 = 0x3E9;
pub const HUNK_DATA: u32 = 0x3EA;
pub const HUNK_RELOC32: u32 = 0x3EC;
pub const HUNK_END: u32 = 0x3F2;
pub const DFH_ID: u16 = 0x0F80;
pub const FCH_ID: u16 = 0x0F00;
pub const TFCH_ID: u16 = 0x0F02;

/// Where the DiskFontHeader's TextFont starts, from the hunk's start: the
/// return instruction (4), then node 14, id 2, revision 2, segment 4,
/// name 32.
const text_font_at = 4 + 54;
/// The Amiga's style bit for a colour font.
const FSF_COLORFONT = 0x40;
/// A ColorTextFont's flag: `ctf_FgColor` is drawn in the pen.
const CTF_MAPCOLOR = 0x0001;

/// Whether `bytes` start as a load file.
pub fn isHunk(bytes: []const u8) bool {
    return bytes.len >= 4 and be32(bytes, 0) == HUNK_HEADER;
}

/// Whether `bytes` start as a contents file.
pub fn isContents(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const id = be16(bytes, 0);
    return id == FCH_ID or id == TFCH_ID;
}

/// The size files a contents file lists, as paths from its directory.
///
/// INPUTS:
/// - `gpa` - where the list is allocated.
/// - `bytes` - the contents file.
pub fn listed(gpa: Allocator, bytes: []const u8) Error![]const []const u8 {
    if (!isContents(bytes)) return error.NotAmiga;
    const count = be16(bytes, 2);
    const paths = try gpa.alloc([]const u8, count);
    for (paths, 0..) |*path, i| {
        const at = 4 + i * 260;
        if (at + 260 > bytes.len) return error.BadFont;
        const name = bytes[at..][0..256];
        path.* = name[0 .. std.mem.indexOfScalar(u8, name, 0) orelse 256];
    }
    return paths;
}

/// The font in a size's load file, its glyphs tidy.
///
/// INPUTS:
/// - `gpa` - where the glyphs are allocated.
/// - `bytes` - the load file.
pub fn read(gpa: Allocator, bytes: []const u8) Error!Font {
    const hunk = try firstHunk(bytes);
    if (hunk.len < text_font_at + 52) return error.BadFont;
    if (be16(hunk, 4 + 14) != DFH_ID) return error.BadFont;
    const tf = hunk[text_font_at..];

    const y_size = be16(tf, 20);
    const style = tf[22];
    const flags = tf[23];
    const x_size = be16(tf, 24);
    const baseline = be16(tf, 26);
    const bold_smear = be16(tf, 28);
    const lo: u32 = tf[32];
    const hi: u32 = tf[33];
    const char_data = be32(tf, 34);
    const modulo: u32 = be16(tf, 38);
    const char_loc = be32(tf, 40);
    const char_space = be32(tf, 44);
    const char_kern = be32(tf, 48);
    if (hi < lo or y_size == 0) return error.BadFont;

    // The planes: one for a font of ink, up to eight for a colour one.
    var planes: [8]?u32 = @splat(null);
    var depth: u32 = 1;
    var palette: []u32 = &.{};
    var pen_index: u32 = graphics.fontimage.NO_PEN;
    var plane_on_off: u8 = 0;
    const colour = style & FSF_COLORFONT != 0;
    if (colour) {
        if (tf.len < 96) return error.BadFont;
        const ctf_flags = be16(tf, 52);
        depth = tf[54];
        const fg_colour = tf[55];
        const pick = tf[58];
        plane_on_off = tf[59];
        if (depth == 0 or depth > 8) return error.BadFont;
        for (0..depth) |p| {
            if (pick >> @intCast(p) & 1 != 0) planes[p] = be32(tf, 64 + @as(u32, @intCast(p)) * 4);
        }
        palette = try readColours(gpa, hunk, be32(tf, 60), depth);
        if (ctf_flags & CTF_MAPCOLOR != 0 and fg_colour < palette.len) pen_index = fg_colour;
    } else {
        planes[0] = char_data;
    }

    const count = hi - lo + 2;
    if (char_kern != 0 and char_kern + count * 2 > hunk.len) return error.BadFont;
    if (char_space != 0 and char_space + count * 2 > hunk.len) return error.BadFont;
    const glyphs = try gpa.alloc(Glyph, count);
    for (glyphs, 0..) |*glyph, i| {
        const loc = char_loc + @as(u32, @intCast(i)) * 4;
        if (loc + 4 > hunk.len) return error.BadFont;
        const bit: u32 = be16(hunk, loc);
        const width: u32 = be16(hunk, loc + 2);
        const kern: i32 = if (char_kern != 0) sbe16(hunk, char_kern + @as(u32, @intCast(i)) * 2) else 0;
        const space: i32 = if (char_space != 0) sbe16(hunk, char_space + @as(u32, @intCast(i)) * 2) else x_size;
        const pixels = try gpa.alloc(u8, width * y_size);
        for (0..y_size) |y| for (0..width) |x| {
            var value: u8 = 0;
            for (0..depth) |p| {
                const on = if (planes[p]) |plane|
                    try bitAt(hunk, plane + @as(u32, @intCast(y)) * modulo, bit + @as(u32, @intCast(x)))
                else
                    plane_on_off >> @intCast(p) & 1 != 0;
                if (on) value |= @as(u8, 1) << @intCast(p);
            }
            pixels[y * width + x] = value;
        };
        glyph.* = .{
            // The one after the last character is the stand-in, which a
            // string of bytes cannot name.
            .code = if (i == count - 1) 256 else lo + @as(u32, @intCast(i)),
            .advance = kern + space,
            .left = kern,
            .top = 0,
            .width = width,
            .rows = y_size,
            .pixels = pixels,
        };
    }

    var font = Font{
        .height = y_size,
        .baseline = baseline,
        .x_size = x_size,
        // The Amiga's style bits in this system's order; colour is the
        // image's kind, not a style.
        .style = amigaStyle(style),
        .flags = graphics.FPF_DESIGNED | (flags & graphics.FPF_PROPORTIONAL),
        .kind = if (colour) .indexed8 else .mono1,
        .bold_smear = @intCast(@max(bold_smear, 1)),
        .default_char = 256,
        .palette = palette,
        .pen_index = pen_index,
        .glyphs = glyphs,
    };
    font_mod.tidy(&font);
    return font;
}

/// The Amiga's FSF_UNDERLINED 1, BOLD 2, ITALIC 4, EXTENDED 8 as this
/// system's bits.
fn amigaStyle(style: u8) graphics.FontStyle {
    var out: graphics.FontStyle = 0;
    if (style & 1 != 0) out |= graphics.FSF_UNDERLINED;
    if (style & 2 != 0) out |= graphics.FSF_BOLD;
    if (style & 4 != 0) out |= graphics.FSF_ITALIC;
    if (style & 8 != 0) out |= graphics.FSF_EXTENDED;
    return out;
}

/// A colour font's table: `cfc_Count` 12-bit colours, each four bits of
/// red, green and blue, as opaque ARGB with 0 left transparent. As many
/// entries as the depth can name.
fn readColours(gpa: Allocator, hunk: []const u8, table_at: u32, depth: u32) Error![]u32 {
    const entries = @as(u32, 1) << @intCast(depth);
    const palette = try gpa.alloc(u32, entries);
    @memset(palette, 0);
    if (table_at == 0 or table_at + 8 > hunk.len) return palette;
    const count = be16(hunk, table_at + 2);
    const colours = be32(hunk, table_at + 4);
    for (0..@min(count, entries)) |i| {
        if (i == 0) continue;
        const at = colours + @as(u32, @intCast(i)) * 2;
        if (at + 2 > hunk.len) return error.BadFont;
        const rgb = be16(hunk, at);
        const r: u32 = (rgb >> 8 & 0xF) * 17;
        const g: u32 = (rgb >> 4 & 0xF) * 17;
        const b: u32 = (rgb & 0xF) * 17;
        palette[i] = 0xFF00_0000 | r << 16 | g << 8 | b;
    }
    return palette;
}

/// The data of the first code or data hunk of a load file.
fn firstHunk(bytes: []const u8) Error![]const u8 {
    if (!isHunk(bytes)) return error.NotAmiga;
    var at: u32 = 4;
    // Resident library names: longword counts and names, ended by 0.
    while (true) {
        const n = try long(bytes, at);
        at += 4;
        if (n == 0) break;
        at += n * 4;
    }
    const first = try long(bytes, at + 4);
    const last = try long(bytes, at + 8);
    at += 12 + (last - first + 1) * 4;
    const kind = (try long(bytes, at)) & 0x3FFF_FFFF;
    if (kind != HUNK_CODE and kind != HUNK_DATA) return error.BadHunk;
    const longs = (try long(bytes, at + 4)) & 0x3FFF_FFFF;
    const start = at + 8;
    if (start + longs * 4 > bytes.len) return error.BadHunk;
    return bytes[start..][0 .. longs * 4];
}

fn bitAt(hunk: []const u8, row: u32, bit: u32) Error!bool {
    const at = row + bit / 8;
    if (at >= hunk.len) return error.BadFont;
    return hunk[at] >> @intCast(7 - bit % 8) & 1 != 0;
}

fn long(bytes: []const u8, at: u32) Error!u32 {
    if (at + 4 > bytes.len) return error.BadHunk;
    return be32(bytes, at);
}

fn be32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}

fn be16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}

fn sbe16(bytes: []const u8, at: usize) i32 {
    return std.mem.readInt(i16, bytes[at..][0..2], .big);
}
