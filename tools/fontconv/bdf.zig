// SPDX-License-Identifier: MPL-2.0
//! Reading a BDF font: the text format bitmap fonts are published in.
//!
//! The line is `FONT_ASCENT` rows above the baseline and `FONT_DESCENT`
//! below (the bounding box's when those are missing). Each character is
//! an ENCODING, a DWIDTH - how far it moves the point - a BBX - its box's
//! size and where its lower left corner sits from the point on the
//! baseline - and BITMAP rows in hex, the leftmost pixel in the highest
//! bit. Codes 32 to 255 are kept, the Latin-1 a string of bytes can name,
//! and the default character whatever its code.

const std = @import("std");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const Glyph = font_mod.Glyph;
const Allocator = std.mem.Allocator;

pub const Error = error{ NotBdf, BadLine, NoGlyphs, NoDefault } || Allocator.Error;

/// The font `text` describes, its glyphs tidy.
///
/// INPUTS:
/// - `gpa` - where the glyphs are allocated.
/// - `text` - the whole BDF file.
pub fn read(gpa: Allocator, text: []const u8) Error!Font {
    if (!std.mem.startsWith(u8, text, "STARTFONT")) return error.NotBdf;
    var ascent: ?i32 = null;
    var descent: ?i32 = null;
    var box_height: i32 = 0;
    var box_y: i32 = 0;
    var default_char: ?u32 = null;
    var glyphs: std.ArrayList(Glyph) = .empty;

    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const key = words.next() orelse continue;
        if (eql(key, "FONT_ASCENT")) {
            ascent = try int(&words);
        } else if (eql(key, "FONT_DESCENT")) {
            descent = try int(&words);
        } else if (eql(key, "DEFAULT_CHAR")) {
            default_char = @intCast(try int(&words));
        } else if (eql(key, "FONTBOUNDINGBOX")) {
            _ = try int(&words);
            box_height = try int(&words);
            _ = try int(&words);
            box_y = try int(&words);
        } else if (eql(key, "STARTCHAR")) {
            const glyph = try readChar(gpa, &lines);
            if (glyph) |kept| try glyphs.append(gpa, kept);
        }
    }
    const up = ascent orelse box_height + box_y;
    const down = descent orelse -box_y;
    if (glyphs.items.len == 0) return error.NoGlyphs;

    // Boxes are placed from the baseline; the image places them from the
    // top of the line.
    for (glyphs.items) |*glyph| glyph.top = up - glyph.top;

    var font = Font{
        .height = @intCast(up + down),
        .baseline = @intCast(up),
        .x_size = 0,
        .default_char = 0,
        .glyphs = glyphs.items,
    };
    font.default_char = pickDefault(glyphs.items, default_char) orelse return error.NoDefault;
    font.x_size = typicalAdvance(glyphs.items);
    // A default character outside Latin-1 was kept for being the default;
    // anything else outside it goes.
    var kept: usize = 0;
    for (glyphs.items) |glyph| {
        if (glyph.code > 255 and glyph.code != font.default_char) continue;
        glyphs.items[kept] = glyph;
        kept += 1;
    }
    font.glyphs = glyphs.items[0..kept];
    font_mod.tidy(&font);
    return font;
}

/// One character from its ENCODING to its ENDCHAR, or null for one that
/// is not kept - a code below 32, or one with no code.
fn readChar(gpa: Allocator, lines: *std.mem.TokenIterator(u8, .any)) Error!?Glyph {
    var code: ?i32 = null;
    var advance: i32 = 0;
    var width: u32 = 0;
    var rows: u32 = 0;
    var left: i32 = 0;
    var bottom: i32 = 0;
    var pixels: []u8 = &.{};
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const key = words.next() orelse continue;
        if (eql(key, "ENCODING")) {
            code = try int(&words);
        } else if (eql(key, "DWIDTH")) {
            advance = try int(&words);
        } else if (eql(key, "BBX")) {
            width = @intCast(try int(&words));
            rows = @intCast(try int(&words));
            left = try int(&words);
            bottom = try int(&words);
        } else if (eql(key, "BITMAP")) {
            pixels = try gpa.alloc(u8, width * rows);
            @memset(pixels, 0);
            for (0..rows) |y| {
                const hex = lines.next() orelse return error.BadLine;
                for (0..width) |x| {
                    const digit = x / 4;
                    if (digit >= hex.len) break;
                    const nibble = std.fmt.charToDigit(hex[digit], 16) catch return error.BadLine;
                    if (nibble >> @intCast(3 - x % 4) & 1 != 0) pixels[y * width + x] = 1;
                }
            }
        } else if (eql(key, "ENDCHAR")) {
            const at = code orelse return null;
            if (at < 32) return null;
            return .{
                .code = @intCast(at),
                .advance = advance,
                .left = left,
                // From the baseline up to the box's top, turned into rows
                // from the line's top once the ascent is known.
                .top = bottom + @as(i32, @intCast(rows)),
                .width = width,
                .rows = rows,
                .pixels = pixels,
            };
        }
    }
    return error.BadLine;
}

/// The default character: the file's own if it has that glyph, else '?',
/// else the first there is.
fn pickDefault(glyphs: []const Glyph, asked: ?u32) ?u32 {
    if (asked) |code| for (glyphs) |glyph| if (glyph.code == code) return code;
    for (glyphs) |glyph| if (glyph.code == '?') return '?';
    return if (glyphs.len != 0) glyphs[0].code else null;
}

/// The nominal width: the advance of '0' if there is one, else of the
/// first glyph. Every advance of a fixed-width font.
fn typicalAdvance(glyphs: []const Glyph) u32 {
    for (glyphs) |glyph| if (glyph.code == '0') return @intCast(glyph.advance);
    return @intCast(glyphs[0].advance);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn int(words: *std.mem.TokenIterator(u8, .scalar)) Error!i32 {
    const word = words.next() orelse return error.BadLine;
    return std.fmt.parseInt(i32, word, 10) catch error.BadLine;
}
