// SPDX-License-Identifier: MIT
//! Host tests of what the desktop's backfill hook paints (`scene.zig`),
//! on graphics.library brought up as the ROM's tests bring it up: the
//! ground and the icons on it, painted a part at a time - each part
//! through a RastPort clipped to it, as layers.library hands it - come
//! out as one painted whole, whatever the parts.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const utility = sdk.utility;
const anvil_prefs = sdk.prefs.anvil;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const icons = @import("../icons/_icons.zig");
const ground_area = @import("../desktop/ground.zig");
const scene = @import("../desktop/scene.zig");
const host = @import("host_rom");
const kexec = host.exec;

const testing = std.testing;

const width = 72;
const height = 48;

/// A picture of the display's size, and a RastPort on it.
const Canvas = struct {
    surface: *rtg.Surface,
    rp: *graphics.RastPort,

    fn make(gb: *GraphicsBase, format: rtg.PixelFormat) !Canvas {
        const surface = gb.AllocBitMapTagList(&[_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = width },
            .{ .tag = graphics.BMTAG_Height, .data = height },
            .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(format) },
            .{ .tag = graphics.BMTAG_Clear, .data = 1 },
            .{},
        }) orelse return error.NoBitMap;
        const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} }) orelse return error.NoRastPort;
        return .{ .surface = surface, .rp = rp };
    }

    fn free(c: Canvas, gb: *GraphicsBase) void {
        gb.FreeRastPort(c.rp);
        gb.FreeBitMap(c.surface);
    }

    fn bytes(c: Canvas) []const u8 {
        return c.surface.pixels.?[0 .. @as(usize, c.surface.pitch) * height];
    }
};

/// The scene painted over `area` as the hook is called for it: through
/// the RastPort clipped to the area, the clip as it was after.
fn paintPart(the: scene.Scene, rp: *graphics.RastPort, area: Rect) void {
    const gb = the.gb;
    var was: Rect = undefined;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
    const within = Rect.intersect(was, area);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&within) }, .{} });
    scene.paint(the, rp, area);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
}

/// The scene painted whole on one canvas, and on another in random parts
/// that cover it - strips across, strips down, small boxes - many times
/// over; the two the same at every pixel.
fn expectPartsAsWhole(gb: *GraphicsBase, the: scene.Scene, format: rtg.PixelFormat, seed: u64) !void {
    const whole = try Canvas.make(gb, format);
    defer whole.free(gb);
    const parts = try Canvas.make(gb, format);
    defer parts.free(gb);
    scene.paint(the, whole.rp, .{ .max_x = width, .max_y = height });

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var round: u32 = 0;
    while (round < 12) : (round += 1) {
        // Each round covers all of it in parts of its own, over what the
        // last round left: a part painted twice must come out the same.
        const across = rand.intRangeAtMost(i32, 1, 24);
        const down = rand.intRangeAtMost(i32, 1, 16);
        var y: i32 = 0;
        while (y < height) : (y += down) {
            var x: i32 = 0;
            while (x < width) : (x += across) {
                paintPart(the, parts.rp, .{ .min_x = x, .min_y = y, .max_x = @min(x + across, width), .max_y = @min(y + down, height) });
            }
        }
        try testing.expectEqualSlices(u8, whole.bytes(), parts.bytes());
    }
}

/// An icon showing `image`, named `name`, at (`x`, `y`).
fn iconAt(gb: *GraphicsBase, rp: *graphics.RastPort, look: *const icons.Look, image: *const sdk.icon.IconImage, name: []const u8, x: i32, y: i32, picked: bool) icons.Icon {
    var ic = icons.Icon{ .picture = image, .x = x, .y = y, .selected = picked };
    @memcpy(ic.label[0..name.len], name);
    ic.label_len = @intCast(name.len);
    ic.shown_len = ic.label_len;
    ic.measure(gb, rp, look);
    return ic;
}

test "the scene: the ground and its icons painted a part at a time are the scene painted whole" {
    const kib = try host.intuition.setUp();
    const gb: *GraphicsBase = @ptrCast(kib.graphics_base);

    // A picture of 12 by 12: a disc, soft at its edge.
    var picture: [12 * 12 * 4]u8 = undefined;
    for (0..12) |py| for (0..12) |px| {
        const dx: i32 = @as(i32, @intCast(px)) * 2 - 11;
        const dy: i32 = @as(i32, @intCast(py)) * 2 - 11;
        const d2 = dx * dx + dy * dy;
        const at = (py * 12 + px) * 4;
        picture[at] = @intCast(px * 20);
        picture[at + 1] = @intCast(py * 20);
        picture[at + 2] = 200;
        picture[at + 3] = if (d2 < 64) 255 else if (d2 < 121) 128 else 0;
    };
    var look = icons.Look{ .icon_size = 12, .cell = .{ .width = 24, .height = 26 }, .text = 0xFFFF_FFFF, .shadow = 0xFF00_0000 };
    const measure = try Canvas.make(gb, .bgra32);
    var font_height: usize = 8;
    var baseline: usize = 6;
    gb.GetRPAttrs(measure.rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    });
    look.font_height = @intCast(font_height);
    look.baseline = @intCast(baseline);

    // Two icons that overlap, one picked; a third across the edge.
    var list: exec.List = .{};
    list.init(.unknown);
    const image = sdk.icon.IconImage{ .width = 12, .height = 12, .pixels = &picture };
    var first = iconAt(gb, measure.rp, &look, &image, "Work", 6, 4, false);
    var second = iconAt(gb, measure.rp, &look, &image, "System", 14, 10, true);
    var third = iconAt(gb, measure.rp, &look, &image, "Ram Disk", 60, 30, false);
    const sys = kexec.SysBase.iface();
    for ([_]*icons.Icon{ &first, &second, &third }) |ic| sys.AddTail(&list, &ic.node);

    var tile: [5 * 3 * 4]u8 = undefined;
    for (0..15) |i| {
        tile[i * 4] = @intCast(i * 16);
        tile[i * 4 + 1] = 90;
        tile[i * 4 + 2] = @intCast(255 - i * 16);
        tile[i * 4 + 3] = if (i % 3 == 0) 255 else 100;
    }
    var big: [40 * 30 * 4]u8 = undefined;
    for (0..40 * 30) |i| {
        big[i * 4] = @intCast(i % 256);
        big[i * 4 + 1] = @intCast(i / 7 % 256);
        big[i * 4 + 2] = 40;
        big[i * 4 + 3] = if (i % 5 == 0) 60 else 220;
    }
    const grounds = [_]ground_area.Ground{
        .{ .width = width, .height = height, .top = 0xFF33_6699, .bottom = 0xFF33_6699, .light = false },
        .{ .width = width, .height = height, .top = 0xFF10_2040, .bottom = 0xFFE0_C080, .light = false },
        .{ .width = width, .height = height, .top = 0xFF10_2040, .bottom = 0xFFE0_C080, .pixels = &tile, .picture_width = 5, .picture_height = 3, .place = .tiled, .light = false },
        .{ .width = width, .height = height, .top = 0xFF80_8080, .bottom = 0xFF20_2020, .pixels = &big, .picture_width = 40, .picture_height = 30, .place = .centred, .light = false },
    };
    for (&grounds, 0..) |*ground, i| {
        for ([_]rtg.PixelFormat{ .bgra32, .rgb565 }) |format| {
            var the = scene.Scene{ .gb = gb, .ground = ground, .background = 0, .icons = &list, .look = &look };
            try expectPartsAsWhole(gb, the, format, 0x5CE0 + i);
            // A box being drawn round icons, its edge over them.
            the.band = .{ .min_x = 3, .min_y = 2, .max_x = 40, .max_y = 37 };
            try expectPartsAsWhole(gb, the, format, 0xB0C5 + i);
        }
    }

    measure.free(gb);
    try host.intuition.tearDown(kib);
}

test "the scene: a box's edges are the four lines round it" {
    const box = Rect{ .min_x = 2, .min_y = 3, .max_x = 10, .max_y = 7 };
    const lines = scene.edges(box);
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 3, .max_x = 10, .max_y = 4 }, lines[0]);
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 6, .max_x = 10, .max_y = 7 }, lines[1]);
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 3, .max_x = 3, .max_y = 7 }, lines[2]);
    try testing.expectEqual(Rect{ .min_x = 9, .min_y = 3, .max_x = 10, .max_y = 7 }, lines[3]);
}
