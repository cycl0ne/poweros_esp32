// SPDX-License-Identifier: MIT
//! Movie's subtitles: what videocodec.library says shows at a picture's
//! time, drawn over the picture where it is put.
//!
//! **Text** is set in the screen's font at a size the picture's height
//! asks for - an eighteenth of it - in italics where the subtitle says,
//! white with a black edge all round, each line in the middle, the last
//! at the foot of the picture less a margin. A line too long for the
//! picture is broken between words. The text comes in UTF-8 and the font
//! is Latin-1: the quotes and dashes of typesetting become plain ones, a
//! character past Latin-1 a `?`.
//!
//! **A picture** - a Blu-ray's - is put down where the disc places it,
//! scaled with the film, its coverage mixed with what is under it.
//!
//! **Over the video layer** the film is seen where the box is filled with
//! the layer's key colour, so what is drawn there stays until the key
//! colour is put back - which `show` does where it drew, when what shows
//! changes; and a picture's coverage cannot mix with a film it does not
//! see: a pixel is the subtitle's where it is half covered or more, the
//! film's elsewhere. **Without the layer** the picture is put down anew
//! each frame, over what was drawn, and the subtitle is drawn again on
//! it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const vc = sdk.videocodec;
const rtg = sdk.rtg;
const sc = sdk.intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;

/// The lines a subtitle may make, broken as they are.
const most_lines = 8;
/// The text's bytes as Latin-1.
const text_bytes = 1024;

pub const Subtitles = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    dfb: ?*DiskfontBase,
    /// The screen's font at the size last wanted, upright and slanted.
    upright: ?*graphics.TextFont = null,
    slanted: ?*graphics.TextFont = null,
    rows: u32 = 0,
    /// What was drawn last, into which RastPort, in which box of the
    /// picture, and where: the key colour goes back there.
    drawn: bool = false,
    last: vc.VideoSubtitle = .{},
    rast_port: ?*graphics.RastPort = null,
    box: Rect = .{},
    area: Rect = .{},

    /// The fonts given back.
    pub fn close(subs: *Subtitles) void {
        subs.closeFonts();
    }

    /// Forgets what was drawn: the picture's place has been filled anew.
    pub fn forget(subs: *Subtitles) void {
        subs.drawn = false;
        subs.area = .{};
    }

    /// The subtitle at `time` drawn over the picture just put in `box` of
    /// `rp`, `width` by `height` of the film's pixels: when what shows has
    /// changed - or always, when the picture was put down over it
    /// (`repainted`). `key` is the layer's colour where the film is on
    /// one. Whether anything was drawn.
    pub fn show(subs: *Subtitles, vcb: *VideoCodecBase, film: *vc.VideoStream, time: i64, rp: *graphics.RastPort, box: Rect, width: u32, height: u32, key: ?u32, repainted: bool) bool {
        var now: vc.VideoSubtitle = .{};
        const has = vcb.GetVideoSubtitle(film, time, &now) == vc.VCERR_OK;
        const unchanged = has == subs.drawn and rp == subs.rast_port and same(box, subs.box) and
            (!has or (now.start == subs.last.start and now.end == subs.last.end and now.flags == subs.last.flags));
        if (unchanged and !repainted) return false;
        // What was drawn taken away where the picture was not put again.
        var drew = false;
        if (subs.drawn and !repainted and rp == subs.rast_port and subs.area.width() > 0) {
            if (key) |colour| {
                subs.gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(@truncate(colour >> 16), @truncate(colour >> 8), @truncate(colour))), .{} });
                subs.gb.RectFill(rp, &subs.area);
                drew = true;
            }
        }
        subs.drawn = has;
        subs.last = now;
        subs.rast_port = rp;
        subs.box = box;
        subs.area = .{};
        if (!has or width == 0 or height == 0) return drew;
        if (now.flags & vc.VSUB_BITMAP != 0) {
            subs.picture(rp, box, &now, width, height, key != null);
        } else if (now.text) |text| {
            subs.lines(rp, box, text, now.flags & vc.VSUB_ITALIC != 0);
        }
        return true;
    }

    // --- text ------------------------------------------------------------------

    fn lines(subs: *Subtitles, rp: *graphics.RastPort, box: Rect, utf8: [*:0]const u8, italic: bool) void {
        const gb = subs.gb;
        subs.fonts(@intCast(@max(@divTrunc(box.height(), 18), 8)));
        const face = if (italic) subs.slanted orelse subs.upright else subs.upright;
        if (face) |made| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(made) }, .{} });
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
        var font_height: usize = 0;
        var baseline: usize = 0;
        gb.GetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        });
        const row: i32 = @intCast(@max(font_height, 1));

        var text: [text_bytes]u8 = undefined;
        var given: usize = 0;
        while (utf8[given] != 0) given += 1;
        const length = latin1(utf8[0..given], &text);
        // The lines broken where they are too wide: each a start and a
        // length in `text`.
        const room = @max(@divTrunc(box.width() * 9, 10), 1);
        var starts: [most_lines]usize = undefined;
        var counts: [most_lines]u32 = undefined;
        var count: usize = 0;
        var at: usize = 0;
        while (at <= length and count < most_lines) {
            var end = at;
            while (end < length and text[end] != '\n') end += 1;
            var from = at;
            while (count < most_lines) {
                const taken = fitting(gb, rp, text[from..end], room);
                starts[count] = from;
                counts[count] = @intCast(taken);
                count += 1;
                from += taken;
                while (from < end and text[from] == ' ') from += 1;
                if (from >= end) break;
            }
            at = end + 1;
        }

        const edge: i32 = @max(@divTrunc(row, 16), 1);
        const bottom = box.max_y - @divTrunc(box.height(), 20);
        const top = @max(bottom - @as(i32, @intCast(count)) * row, box.min_y);
        var area = Rect{ .min_x = box.max_x, .min_y = top - edge, .max_x = box.min_x, .max_y = top - edge };
        for (0..count) |n| {
            const line_top = top + @as(i32, @intCast(n)) * row;
            if (line_top + row > box.max_y) break;
            const piece = text[starts[n]..].ptr;
            const wide = gb.TextLength(rp, piece, counts[n]);
            const left = box.min_x + @divTrunc(box.width() - wide, 2);
            const at_y = line_top + @as(i32, @intCast(baseline));
            // The edge: the line in black around where it goes, then white.
            gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(0, 0, 0)), .{} });
            for ([_]i32{ -1, 0, 1 }) |dy| {
                for ([_]i32{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    gb.Move(rp, left + dx * edge, at_y + dy * edge);
                    gb.Text(rp, piece, counts[n]);
                }
            }
            gb.SetRPAttrs(rp, &[_]TagItem{ pen(graphics.penRGB(255, 255, 255)), .{} });
            gb.Move(rp, left, at_y);
            gb.Text(rp, piece, counts[n]);
            area.min_x = @min(area.min_x, left - edge);
            area.max_x = @max(area.max_x, left + wide + edge + 1);
            area.max_y = line_top + row + edge;
        }
        // Slanted letters lean past their width.
        if (italic) area.max_x += @divTrunc(row, 4);
        subs.area = clip(area, box);
    }

    /// The screen's font `rows` high, upright and slanted - opened again
    /// only when the size is another.
    fn fonts(subs: *Subtitles, rows: u32) void {
        if (rows == subs.rows) return;
        subs.closeFonts();
        subs.rows = rows;
        const fonts_lib = subs.dfb orelse return;
        const system = subs.ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return;
        defer subs.gb.CloseFont(system);
        const name = system.node.name orelse return;
        subs.upright = fonts_lib.OpenDiskFont(&.{ .name = name, .y_size = @intCast(rows), .style = graphics.FS_NORMAL });
        subs.slanted = fonts_lib.OpenDiskFont(&.{ .name = name, .y_size = @intCast(rows), .style = graphics.FSF_ITALIC });
    }

    fn closeFonts(subs: *Subtitles) void {
        if (subs.upright) |made| subs.gb.CloseFont(made);
        if (subs.slanted) |made| subs.gb.CloseFont(made);
        subs.upright = null;
        subs.slanted = null;
        subs.rows = 0;
    }

    // --- pictures --------------------------------------------------------------

    /// A picture laid where the disc places it on the film, scaled with
    /// it; over the layer its coverage made all or nothing.
    fn picture(subs: *Subtitles, rp: *graphics.RastPort, box: Rect, shown: *const vc.VideoSubtitle, width: u32, height: u32, keyed: bool) void {
        const pixels = shown.pixels orelse return;
        if (shown.width == 0 or shown.height == 0) return;
        const box_w: i64 = box.width();
        const box_h: i64 = box.height();
        const dest = Rect{
            .min_x = box.min_x + @as(i32, @intCast(@divTrunc(@as(i64, shown.x) * box_w, width))),
            .min_y = box.min_y + @as(i32, @intCast(@divTrunc(@as(i64, shown.y) * box_h, height))),
            .max_x = box.min_x + @as(i32, @intCast(@divTrunc(@as(i64, shown.x + shown.width) * box_w, width))),
            .max_y = box.min_y + @as(i32, @intCast(@divTrunc(@as(i64, shown.y + shown.height) * box_h, height))),
        };
        const area = clip(dest, box);
        if (area.width() <= 0 or area.height() <= 0) return;
        const all = Rect{ .max_x = @intCast(shown.width), .max_y = @intCast(shown.height) };
        const count = @as(usize, shown.width) * shown.height;
        const pitch = shown.width * 4;
        const format: u32 = @intFromEnum(rtg.PixelFormat.bgra32);
        if (!keyed) {
            subs.gb.ScalePixelArray(rp, @ptrCast(pixels), pitch, format, &all, &dest);
        } else {
            const memory = subs.sys.AllocVec(count * 4, exec.MEMF_ANY) orelse return;
            defer subs.sys.FreeVec(memory);
            const copy: [*]u32 = @ptrCast(@alignCast(memory));
            for (pixels[0..count], copy[0..count]) |from, *to| {
                to.* = if (from >> 24 >= 0x80) from | 0xFF00_0000 else 0;
            }
            subs.gb.ScalePixelArray(rp, @ptrCast(copy), pitch, format, &all, &dest);
        }
        subs.area = area;
    }
};

/// How many of `text`'s bytes go in `room` pixels: up to a space where
/// the whole does not - or as many as fit, when no space does - and one
/// at least.
fn fitting(gb: *GraphicsBase, rp: *graphics.RastPort, text: []const u8, room: i32) usize {
    if (text.len == 0) return 0;
    if (gb.TextLength(rp, text.ptr, @intCast(text.len)) <= room) return text.len;
    var count = text.len;
    while (count > 1 and gb.TextLength(rp, text.ptr, @intCast(count)) > room) count -= 1;
    var space = count;
    while (space > 0 and text[space] != ' ') space -= 1;
    return if (space > 0) space else count;
}

/// UTF-8 into Latin-1: typesetting's quotes, dashes and dots as plain
/// ones, what else Latin-1 has not a `?`. How many bytes it made, a NUL
/// after them.
pub fn latin1(text: []const u8, into: []u8) usize {
    var out: usize = 0;
    var at: usize = 0;
    while (at < text.len and out + 3 < into.len) {
        const lead = text[at];
        const length: usize = if (lead < 0x80) 1 else if (lead >= 0xC2 and lead < 0xE0) 2 else if (lead >= 0xE0 and lead < 0xF0) 3 else if (lead >= 0xF0 and lead < 0xF5) 4 else 0;
        if (length <= 1 or at + length > text.len) {
            into[out] = if (length == 1) lead else '?';
            out += 1;
            at += 1;
            continue;
        }
        var code: u32 = lead & (@as(u8, 0x7F) >> @intCast(length));
        for (text[at + 1 .. at + length]) |byte| code = code << 6 | (byte & 0x3F);
        at += length;
        const one = [1]u8{if (code <= 0xFF) @intCast(code) else '?'};
        const plain: []const u8 = switch (code) {
            0x2018, 0x2019, 0x201A, 0x2032 => "'",
            0x201C, 0x201D, 0x201E, 0x2033 => "\"",
            0x2010...0x2015, 0x2212 => "-",
            0x2026 => "...",
            0x00A0, 0x2000...0x200A, 0x202F => " ",
            0x200B...0x200F, 0xFEFF => "",
            else => &one,
        };
        @memcpy(into[out..][0..plain.len], plain);
        out += plain.len;
    }
    into[out] = 0;
    return out;
}

fn pen(colour: graphics.Pen) TagItem {
    return .{ .tag = graphics.RPTAG_APen, .data = colour };
}

fn same(a: Rect, b: Rect) bool {
    return a.min_x == b.min_x and a.min_y == b.min_y and a.max_x == b.max_x and a.max_y == b.max_y;
}

fn clip(area: Rect, box: Rect) Rect {
    const clipped = Rect{
        .min_x = @max(area.min_x, box.min_x),
        .min_y = @max(area.min_y, box.min_y),
        .max_x = @min(area.max_x, box.max_x),
        .max_y = @min(area.max_y, box.max_y),
    };
    if (clipped.max_x <= clipped.min_x or clipped.max_y <= clipped.min_y) return .{};
    return clipped;
}

const std = @import("std");

test "UTF-8 made Latin-1: umlauts kept, typesetting's quotes, dashes and dots plain, the rest a ?" {
    var into: [64]u8 = undefined;
    const made = latin1("„Grüß dich“ – sagte er… ♪", &into);
    try std.testing.expectEqualStrings("\"Gr\xfc\xdf dich\" - sagte er... ?", into[0..made]);
    try std.testing.expectEqual(@as(u8, 0), into[made]);
}
