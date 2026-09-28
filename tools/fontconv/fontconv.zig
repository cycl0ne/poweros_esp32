// SPDX-License-Identifier: MPL-2.0
//! fontconv: fonts from the host's formats into the system's.
//!
//!   fontconv <out dir> <family> [--alpha N] [--shadow] <source>...
//!
//! Each source is one size of the family: a BDF file, an Amiga size load
//! file, or an Amiga contents file, which brings every size it lists. Each
//! becomes `<out dir>/<family>/<rows>`, a font image byte for byte, and
//! `<out dir>/<family>.font` lists them all. A TrueType file is the
//! family's outline: copied to `<out dir>/<family>/<its name>` and listed
//! as the entry diskfont renders any height from.
//!
//! `--alpha N` takes sources drawn N times too large (2 or 4) and makes
//! fonts of coverage at 1/N their size, each pixel the share of its N by N
//! square that is ink. `--shadow` makes colour fonts: the letter in the
//! pen and a translucent shadow one pixel down and right.
//!
//! Characters 32 to 255 are kept: text is bytes, each a Latin-1 code.

const std = @import("std");
const sdk = @import("sdk");
const fontimage = sdk.graphics.fontimage;
const fontfile = sdk.diskfont.fontfile;
const font_mod = @import("font.zig");
const bdf = @import("bdf.zig");
const amiga = @import("amiga.zig");
const Font = font_mod.Font;
const Allocator = std.mem.Allocator;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("fontconv: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// What is done to every source on the way.
const Options = struct {
    alpha: u32 = 0,
    shadow: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: fontconv <out dir> <family> [--alpha N] [--shadow] <source>...", .{});
    const out_dir = args[1];
    const family = args[2];

    var options = Options{};
    var sources: std.ArrayList([]const u8) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--alpha")) {
            i += 1;
            if (i == args.len) fatal("--alpha: how much larger?", .{});
            options.alpha = std.fmt.parseInt(u32, args[i], 10) catch fatal("--alpha {s}: not a number", .{args[i]});
            if (options.alpha != 2 and options.alpha != 4) fatal("--alpha {d}: 2 or 4", .{options.alpha});
        } else if (std.mem.eql(u8, args[i], "--shadow")) {
            options.shadow = true;
        } else {
            try sources.append(arena, args[i]);
        }
    }

    const cwd = std.Io.Dir.cwd();
    var fonts: std.ArrayList(Font) = .empty;
    var outlines: std.ArrayList([]const u8) = .empty;
    const family_dir = try std.fs.path.join(arena, &.{ out_dir, family });
    try cwd.createDirPath(io, family_dir);
    for (sources.items) |source| {
        const bytes = cwd.readFileAlloc(io, source, arena, .unlimited) catch |e| fatal("{s}: {t}", .{ source, e });
        if (sdk.truetype.isTrueType(bytes)) {
            const name = std.fs.path.basename(source);
            const path = try std.fs.path.join(arena, &.{ family_dir, name });
            try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
            try outlines.append(arena, name);
        } else if (amiga.isContents(bytes)) {
            const dir = std.fs.path.dirname(source) orelse ".";
            for (try amiga.listed(arena, bytes)) |size| {
                const path = try std.fs.path.join(arena, &.{ dir, size });
                const size_bytes = cwd.readFileAlloc(io, path, arena, .unlimited) catch |e| fatal("{s}: {t}", .{ path, e });
                try fonts.append(arena, convert(arena, size_bytes, options) catch |e| fatal("{s}: {t}", .{ path, e }));
            }
        } else {
            try fonts.append(arena, convert(arena, bytes, options) catch |e| fatal("{s}: {t}", .{ source, e }));
        }
    }

    const contents = try writeFamily(arena, family, fonts.items, outlines.items, struct {
        io: std.Io,
        dir: []const u8,
        fn write(ctx: @This(), gpa: Allocator, rows: u32, image: []const u8) !void {
            const path = try std.fmt.allocPrint(gpa, "{s}/{d}", .{ ctx.dir, rows });
            try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = image });
        }
    }{ .io = io, .dir = family_dir });
    const contents_path = try std.fmt.allocPrint(arena, "{s}/{s}.font", .{ out_dir, family });
    try cwd.writeFile(io, .{ .sub_path = contents_path, .data = contents });
}

/// One size from its file's bytes, with the options applied.
fn convert(gpa: Allocator, bytes: []const u8, options: Options) !Font {
    var font = if (amiga.isHunk(bytes))
        try amiga.read(gpa, bytes)
    else
        try bdf.read(gpa, bytes);
    if (options.alpha != 0) {
        if (font.kind != .mono1) return error.NotInk;
        font = try font_mod.coverage(gpa, &font, options.alpha);
    }
    if (options.shadow) {
        if (font.kind != .mono1) return error.NotInk;
        font = try font_mod.shadowed(gpa, &font);
    }
    return font;
}

/// Each font's image handed to `sink.write` under its height, and the
/// family's contents file listing them, sorted by height, and after them
/// the outlines (file names in the family's directory), answered.
fn writeFamily(gpa: Allocator, family: []const u8, fonts: []Font, outlines: []const []const u8, sink: anytype) ![]align(4) u8 {
    std.mem.sort(Font, fonts, {}, struct {
        fn less(_: void, a: Font, b: Font) bool {
            return a.height < b.height;
        }
    }.less);
    const size = fontfile.contentsSize(@intCast(fonts.len + outlines.len));
    const contents = try gpa.alignedAlloc(u8, .@"4", size);
    @memset(contents, 0);
    const header: *fontfile.ContentsHeader = @ptrCast(contents.ptr);
    header.* = .{ .count = @intCast(fonts.len + outlines.len) };
    const entries: [*]fontfile.FontContents = @ptrCast(@alignCast(contents.ptr + @sizeOf(fontfile.ContentsHeader)));
    for (fonts, 0..) |*font, i| {
        if (i != 0 and fonts[i - 1].height == font.height) return error.TwoOfOneHeight;
        const image = try font_mod.encode(gpa, font);
        if (!fontimage.check(image.ptr, @intCast(image.len))) return error.BadImage;
        try sink.write(gpa, font.height, image);
        const path = try std.fmt.allocPrint(gpa, "{s}/{d}", .{ family, font.height });
        if (path.len >= fontfile.MAXFONTPATH) return error.NameTooLong;
        entries[i] = fontfile.entryFor(path, @ptrCast(image.ptr));
    }
    for (outlines, fonts.len..) |name, i| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ family, name });
        if (path.len >= fontfile.MAXFONTPATH) return error.NameTooLong;
        entries[i] = fontfile.outlineEntry(path);
    }
    fontfile.seal(contents.ptr, size);
    return contents;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// A BDF of three characters at 6 rows, ascent 5: 'A' 3 wide, 'i' one
/// column set one in with an advance of 2, and '?'; plus a character 0
/// and one past Latin-1, which are dropped.
const small_bdf =
    \\STARTFONT 2.1
    \\FONT -test-small
    \\SIZE 6 75 75
    \\FONTBOUNDINGBOX 4 6 0 -1
    \\STARTPROPERTIES 2
    \\FONT_ASCENT 5
    \\FONT_DESCENT 1
    \\ENDPROPERTIES
    \\CHARS 5
    \\STARTCHAR nul
    \\ENCODING 0
    \\DWIDTH 4 0
    \\BBX 1 1 0 0
    \\BITMAP
    \\80
    \\ENDCHAR
    \\STARTCHAR question
    \\ENCODING 63
    \\DWIDTH 4 0
    \\BBX 3 5 0 0
    \\BITMAP
    \\E0
    \\20
    \\40
    \\00
    \\40
    \\ENDCHAR
    \\STARTCHAR A
    \\ENCODING 65
    \\DWIDTH 4 0
    \\BBX 4 6 0 -1
    \\BITMAP
    \\40
    \\A0
    \\E0
    \\A0
    \\A0
    \\00
    \\ENDCHAR
    \\STARTCHAR i
    \\ENCODING 105
    \\DWIDTH 2 0
    \\BBX 2 4 0 0
    \\BITMAP
    \\40
    \\00
    \\40
    \\40
    \\ENDCHAR
    \\STARTCHAR euro
    \\ENCODING 8364
    \\DWIDTH 4 0
    \\BBX 1 1 0 0
    \\BITMAP
    \\80
    \\ENDCHAR
    \\ENDFONT
    \\
;

test "BDF: glyphs, boxes cropped to ink, advances, and only Latin-1 kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const font = try bdf.read(gpa, small_bdf);
    try testing.expectEqual(@as(u32, 6), font.height);
    try testing.expectEqual(@as(u32, 5), font.baseline);
    try testing.expectEqual(@as(u32, '?'), font.default_char);
    try testing.expectEqual(@as(usize, 3), font.glyphs.len);

    const image = try font_mod.encode(gpa, &font);
    try testing.expect(fontimage.check(image.ptr, @intCast(image.len)));
    try testing.expect(fontimage.sound(image.ptr, @intCast(image.len)));
    const header: *const fontimage.FontImage = @ptrCast(image.ptr);
    try testing.expect(header.flags & sdk.graphics.FPF_PROPORTIONAL != 0);
    // 'A': three wide, five tall once its empty row and column go, from
    // the top of the line.
    const a = fontimage.find(header, 'A').?;
    try testing.expectEqual(@as(u16, 3), a.width);
    try testing.expectEqual(@as(u16, 5), a.rows);
    try testing.expectEqual(@as(i16, 0), a.top);
    try testing.expectEqual(@as(u8, 0x40), fontimage.pixelsOf(header, a)[0]);
    try testing.expectEqual(@as(u8, 0xE0), fontimage.pixelsOf(header, a)[2]);
    // 'i': one column, set one in, two rows down; its gap stays.
    const i = fontimage.find(header, 'i').?;
    try testing.expectEqual(@as(i16, 1), i.left);
    try testing.expectEqual(@as(i16, 1), i.top);
    try testing.expectEqual(@as(u16, 4), i.rows);
    try testing.expectEqual(@as(i16, 2), i.advance);
    try testing.expect(fontimage.find(header, 0) == null);
    try testing.expect(fontimage.find(header, 8364) == null);
}

test "coverage from a font drawn twice as large" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // A 4 by 4 box, lit in its top-left 2 by 2 and in one pixel of its
    // bottom-right quarter: full, empty, empty, a quarter.
    var pixels = [_]u8{ 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    var glyphs = [_]font_mod.Glyph{.{ .code = 'x', .advance = 4, .width = 4, .rows = 4, .pixels = &pixels }};
    const big = Font{ .height = 4, .baseline = 4, .x_size = 4, .default_char = 'x', .glyphs = &glyphs };
    const small = try font_mod.coverage(gpa, &big, 2);
    try testing.expectEqual(fontimage.Kind.alpha4, small.kind);
    try testing.expectEqual(@as(u32, 2), small.height);
    const x = small.glyphs[0];
    try testing.expectEqual(@as(u32, 2), x.width);
    try testing.expectEqual(@as(i32, 2), x.advance);
    try testing.expectEqualSlices(u8, &.{ 15, 0, 0, 4 }, x.pixels);

    const image = try font_mod.encode(gpa, &small);
    try testing.expect(fontimage.check(image.ptr, @intCast(image.len)));
    const header: *const fontimage.FontImage = @ptrCast(image.ptr);
    const packed_glyph = fontimage.find(header, 'x').?;
    try testing.expectEqual(@as(u8, 0xF0), fontimage.pixelsOf(header, packed_glyph)[0]);
    try testing.expectEqual(@as(u8, 0x04), fontimage.pixelsOf(header, packed_glyph)[1]);
}

test "a shadow: the letter in the pen, a shadow down and right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const font = try bdf.read(gpa, small_bdf);
    const shadow = try font_mod.shadowed(gpa, &font);
    try testing.expectEqual(fontimage.Kind.indexed8, shadow.kind);
    try testing.expectEqual(@as(u32, 1), shadow.pen_index);
    try testing.expectEqual(@as(u32, 7), shadow.height);
    const image = try font_mod.encode(gpa, &shadow);
    try testing.expect(fontimage.check(image.ptr, @intCast(image.len)));
    const header: *const fontimage.FontImage = @ptrCast(image.ptr);
    // 'i' is a column with a gap: its shadow is the column moved one
    // down and right, where the letter is not.
    const i = fontimage.find(header, 'i').?;
    try testing.expectEqual(@as(u16, 2), i.width);
    const px = fontimage.pixelsOf(header, i);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 2, 1, 0, 1, 2, 0, 2 }, px[0..10]);
}

test "a family: the contents file lists every size, sorted, and is sound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var fonts = [_]Font{ try bdf.read(gpa, small_bdf), undefined };
    fonts[1] = try font_mod.coverage(gpa, &fonts[0], 2);
    const Sink = struct {
        written: u32 = 0,
        fn write(sink: *@This(), _: Allocator, rows: u32, image: []const u8) !void {
            try testing.expect(fontimage.sound(@alignCast(image.ptr), @intCast(image.len)));
            sink.written += rows;
        }
    };
    var sink = Sink{};
    const contents = try writeFamily(gpa, "small", &fonts, &.{"small.ttf"}, &sink);
    try testing.expectEqual(@as(u32, 6 + 3), sink.written);
    try testing.expect(fontfile.sound(contents.ptr, @intCast(contents.len)));
    const entries = fontfile.entriesOf(contents.ptr);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(@as(u8, 1), entries[2].outline);
    try testing.expectEqualStrings("small/small.ttf", fontfile.pathOf(&entries[2]));
    try testing.expectEqualStrings("small/3", fontfile.pathOf(&entries[0]));
    try testing.expectEqualStrings("small/6", fontfile.pathOf(&entries[1]));
    try testing.expectEqual(@intFromEnum(fontimage.Kind.alpha4), entries[0].kind);
    contents[20] ^= 1;
    try testing.expect(!fontfile.sound(contents.ptr, @intCast(contents.len)));
}

/// A load file of a font at 2 rows with two characters, 'a' and 'b', and
/// the stand-in, as an Amiga size file is laid out; `colour` makes it a
/// two-plane colour font whose second colour is the pen's.
fn amigaFont(colour: bool) [32 + 256 + 4]u8 {
    {
        var hunk: [256]u8 = @splat(0);
        const tf = 4 + 54;
        // The return instruction, then the DiskFontHeader's id.
        put16(&hunk, 0, 0x7000);
        put16(&hunk, 2, 0x4E75);
        put16(&hunk, 4 + 14, amiga.DFH_ID);
        put16(&hunk, tf + 20, 2); // YSize
        hunk[tf + 22] = if (colour) 0x40 | 2 else 2; // bold (and colour)
        hunk[tf + 23] = 0x20; // proportional
        put16(&hunk, tf + 24, 3); // XSize
        put16(&hunk, tf + 26, 1); // Baseline
        put16(&hunk, tf + 28, 1); // BoldSmear
        hunk[tf + 32] = 'a';
        hunk[tf + 33] = 'b';
        const strike = 160;
        const loc = 180;
        const kern = 200;
        const space = 210;
        put32(&hunk, tf + 34, strike);
        put16(&hunk, tf + 38, 2); // Modulo
        put32(&hunk, tf + 40, loc);
        put32(&hunk, tf + 44, space);
        put32(&hunk, tf + 48, kern);
        // The strike: 'a' is bits 0-1, 'b' bits 2-4, the stand-in 5.
        hunk[strike] = 0b1111_1100;
        hunk[strike + 2] = 0b1001_0100;
        for ([_][2]u16{ .{ 0, 2 }, .{ 2, 3 }, .{ 5, 1 } }, 0..) |l, i| {
            put16(&hunk, loc + i * 4, l[0]);
            put16(&hunk, loc + i * 4 + 2, l[1]);
        }
        // 'b' kerns one back; each moves on by its space.
        put16(&hunk, kern + 2, 0xFFFF);
        for ([_]u16{ 3, 4, 2 }, 0..) |s, i| put16(&hunk, space + i * 2, s);
        if (colour) {
            put16(&hunk, tf + 52, 1); // CTF_MAPCOLOR
            hunk[tf + 54] = 2; // depth
            hunk[tf + 55] = 2; // the pen's colour
            hunk[tf + 58] = 0b11; // both planes stored
            put32(&hunk, tf + 60, 220);
            put32(&hunk, tf + 64, strike);
            put32(&hunk, tf + 68, strike + 4);
            // The second plane: the top rows of 'a'.
            hunk[strike + 4] = 0b1100_0000;
            put16(&hunk, 220 + 2, 4);
            put32(&hunk, 220 + 4, 230);
            for ([_]u16{ 0, 0xF00, 0x0F0, 0x00F }, 0..) |c, i| put16(&hunk, 230 + i * 2, c);
        }
        var file: [32 + 256 + 4]u8 = undefined;
        for ([_]u32{ amiga.HUNK_HEADER, 0, 1, 0, 0, 64, amiga.HUNK_CODE, 64 }, 0..) |v, i| put32(&file, i * 4, v);
        for (hunk, 0..) |b, i| file[32 + i] = b;
        put32(&file, 32 + 256, amiga.HUNK_END);
        return file;
    }
}

fn put16(out: []u8, at: usize, v: u16) void {
    out[at] = @truncate(v >> 8);
    out[at + 1] = @truncate(v);
}

fn put32(out: []u8, at: usize, v: u32) void {
    put16(out, at, @truncate(v >> 16));
    put16(out, at + 2, @truncate(v));
}

test "an Amiga size file: the strike, kerning, spacing and the stand-in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const font = try amiga.read(gpa, &amigaFont(false));
    try testing.expectEqual(@as(u32, 2), font.height);
    try testing.expectEqual(sdk.graphics.FSF_BOLD, font.style);
    try testing.expectEqual(@as(u32, 256), font.default_char);
    const image = try font_mod.encode(gpa, &font);
    try testing.expect(fontimage.check(image.ptr, @intCast(image.len)));
    const header: *const fontimage.FontImage = @ptrCast(image.ptr);
    const a = fontimage.find(header, 'a').?;
    try testing.expectEqual(@as(i16, 3), a.advance);
    try testing.expectEqual(@as(u16, 2), a.width);
    try testing.expectEqual(@as(u8, 0xC0), fontimage.pixelsOf(header, a)[0]);
    try testing.expectEqual(@as(u8, 0x80), fontimage.pixelsOf(header, a)[1]);
    // 'b' is 3 wide, kerned one back: it starts left of the point, and
    // moves the point by its space and kern together.
    const b = fontimage.find(header, 'b').?;
    try testing.expectEqual(@as(i16, -1), b.left);
    try testing.expectEqual(@as(i16, 3), b.advance);
    try testing.expectEqual(fontimage.find(header, 256).?, fontimage.glyphFor(header, 'z'));
}

test "an Amiga colour font: planes into indices, the table into the palette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const font = try amiga.read(gpa, &amigaFont(true));
    try testing.expectEqual(fontimage.Kind.indexed8, font.kind);
    try testing.expectEqual(@as(u32, 2), font.pen_index);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), font.palette[1]);
    const image = try font_mod.encode(gpa, &font);
    try testing.expect(fontimage.check(image.ptr, @intCast(image.len)));
    const header: *const fontimage.FontImage = @ptrCast(image.ptr);
    // 'a': its top row in both planes (3), its second row in the first
    // only (1).
    const a = fontimage.find(header, 'a').?;
    try testing.expectEqualSlices(u8, &.{ 3, 3, 1, 0 }, fontimage.pixelsOf(header, a)[0..4]);
}
