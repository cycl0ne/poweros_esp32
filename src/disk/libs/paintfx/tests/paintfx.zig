// SPDX-License-Identifier: MIT
//! Host tests of paintfx.library: the library made from its ROM tag on
//! the ROM's exec and opened, every call made through its jump table on
//! small pictures whose answers can be worked out by hand - colours
//! changed one way at a time, a dot blurred and an edge sharpened, a
//! picture scaled both ways, turned and shifted - and nothing left
//! behind.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const paintfx = sdk.paintfx;
const host = @import("host_rom");
const kexec = host.exec;
const paintfx_init = @import("../paintfx_init.zig");

const testing = std.testing;
const PaintFXBase = sdk.interface.paintfx.PaintFXBase;

test {
    _ = @import("../paintfx_lvo.zig");
}

/// exec, with paintfx made and opened.
const Rig = struct {
    library: *exec.Library = undefined,
    fx: *PaintFXBase = undefined,

    fn init(rig: *Rig) !void {
        try kexec.setUp();
        const made = kexec.InitResident(kexec.SysBase, &paintfx_init.paintfx_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(made));
        rig.fx = @ptrCast(kexec.SysBase.iface().OpenLibrary(paintfx.PAINTFXNAME, 1) orelse return error.NoBase);
    }

    /// The library closed and expunged, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.fx.lib());
        _ = sys.RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, paintfx.PAINTFXNAME) == null);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn view(pixels: []u32, width: u32, height: u32) paintfx.Pixels {
    return .{ .pixels = pixels.ptr, .width = width, .height = height, .pitch = width };
}

fn channel(pixel: u32, shift: u5) u32 {
    return pixel >> shift & 0xFF;
}

test "paintfx: colours changed one way at a time, the alpha kept" {
    var rig = Rig{};
    try rig.init();
    const fx = rig.fx;

    var pixels = [_]u32{ 0x80102030, 0xFFFF0000, 0x00FFFFFF, 0xFF808080 };
    const all = view(&pixels, 4, 1);
    const before = pixels;
    // Nothing asked, nothing changed.
    fx.AdjustColours(&all, &.{});
    try testing.expectEqualSlices(u32, &before, &pixels);

    // Inverted whole, and back; the alpha as it was.
    fx.AdjustColours(&all, &.{ .invert = 100 });
    try testing.expectEqual(@as(u32, 0x80EFDFCF), pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF00FFFF), pixels[1]);
    fx.AdjustColours(&all, &.{ .invert = 100 });
    try testing.expectEqualSlices(u32, &before, &pixels);
    // Half way, everything grey.
    fx.AdjustColours(&all, &.{ .invert = 50 });
    for (pixels) |pixel| try testing.expect(channel(pixel, 16) >= 127 and channel(pixel, 16) <= 128);
    pixels = before;

    // Brightness: up to 128 added, held to 255.
    fx.AdjustColours(&all, &.{ .brightness = 100 });
    try testing.expectEqual(@as(u32, 0x8090A0B0), pixels[0]);
    try testing.expectEqual(@as(u32, 0xFFFF8080), pixels[1]);
    pixels = before;

    // Contrast at -100: all grey; at 100: two levels.
    fx.AdjustColours(&all, &.{ .contrast = -100 });
    for (pixels) |pixel| try testing.expectEqual(@as(u32, 0x808080), pixel & 0xFFFFFF);
    pixels = before;
    fx.AdjustColours(&all, &.{ .contrast = 100 });
    try testing.expectEqual(@as(u32, 0x80000000), pixels[0]);
    try testing.expectEqual(@as(u32, 0xFFFF0000), pixels[1]);
    pixels = before;

    // Saturation at -100: red becomes its grey, about a fifth of white.
    fx.AdjustColours(&all, &.{ .saturation = -100 });
    try testing.expectEqual(channel(pixels[1], 16), channel(pixels[1], 8));
    try testing.expectEqual(channel(pixels[1], 8), channel(pixels[1], 0));
    try testing.expect(channel(pixels[1], 0) >= 53 and channel(pixels[1], 0) <= 55);
    // A grey stays grey whatever is turned.
    pixels = before;
    fx.AdjustColours(&all, &.{ .hue = 180, .saturation = 50 });
    try testing.expectEqual(@as(u32, 0xFF808080), pixels[3]);
    // Red turned half way round is a cyan: no red left, green and blue
    // alike.
    try testing.expect(channel(pixels[1], 16) < channel(pixels[1], 8));
    try testing.expectEqual(channel(pixels[1], 8), channel(pixels[1], 0));
    pixels = before;

    // Sepia: a grey becomes brown - more red than green than blue.
    fx.AdjustColours(&all, &.{ .sepia = 100 });
    try testing.expect(channel(pixels[3], 16) > channel(pixels[3], 8));
    try testing.expect(channel(pixels[3], 8) > channel(pixels[3], 0));
    pixels = before;

    // The balance: red to full, blue to none.
    fx.AdjustColours(&all, &.{ .red = 100, .blue = -100 });
    try testing.expectEqual(@as(u32, 0xFFFF8000), pixels[3]);
    try testing.expectEqual(@as(u32, 0x80FF2000), pixels[0]);
    try rig.deinit();
}

test "paintfx: the haze taken away stretches the rest over the whole range" {
    var rig = Rig{};
    try rig.init();
    // Nothing darker than 0x40 in any channel; a see-through pixel does
    // not count.
    var pixels = [_]u32{ 0xFF404850, 0xFF8090A0, 0xFFFFFFFF, 0x00000000 };
    rig.fx.AdjustColours(&view(&pixels, 4, 1), &.{ .dehaze = 100 });
    try testing.expectEqual(@as(u32, 0), channel(pixels[0], 16));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[2]);
    try testing.expect(channel(pixels[1], 16) < 0x80);
    try rig.deinit();
}

test "paintfx: a dot blurred spreads evenly and no further than three passes reach" {
    var rig = Rig{};
    try rig.init();
    const size = 11;
    var pixels = [_]u32{0xFF000000} ** (size * size);
    pixels[5 * size + 5] = 0xFFFFFFFF;
    const all = view(&pixels, size, size);
    try testing.expectEqual(@as(i32, 0), rig.fx.BlurPixels(&all, &all, 1));
    const middle = channel(pixels[5 * size + 5], 16);
    try testing.expect(middle > 0 and middle < 255);
    // Even each way.
    try testing.expectEqual(pixels[5 * size + 4], pixels[5 * size + 6]);
    try testing.expectEqual(pixels[4 * size + 5], pixels[6 * size + 5]);
    try testing.expectEqual(pixels[5 * size + 4], pixels[4 * size + 5]);
    // Three passes of one reach three pixels, and no further.
    try testing.expect(channel(pixels[5 * size + 2], 16) > 0 or channel(pixels[5 * size + 3], 16) > 0);
    try testing.expectEqual(@as(u32, 0xFF000000), pixels[5 * size + 1]);
    try testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    // Every pixel still shows whole.
    for (pixels) |pixel| try testing.expectEqual(@as(u32, 0xFF), pixel >> 24);
    try rig.deinit();
}

test "paintfx: a blur thins a colour's alpha into the see-through without darkening it" {
    var rig = Rig{};
    try rig.init();
    var from = [_]u32{ 0, 0, 0, 0xFFFF0000, 0, 0, 0 };
    var into = [_]u32{0} ** 7;
    try testing.expectEqual(@as(i32, 0), rig.fx.BlurPixels(&view(&from, 7, 1), &view(&into, 7, 1), 1));
    for (into) |pixel| {
        if (pixel >> 24 == 0) continue;
        try testing.expectEqual(@as(u32, 0xFF0000), pixel & 0xFFFFFF);
    }
    try testing.expect(into[3] >> 24 < 255 and into[2] >> 24 > 0);
    // Not the same size: refused.
    try testing.expect(rig.fx.BlurPixels(&view(&from, 7, 1), &view(into[0..6], 6, 1), 1) != 0);
    try rig.deinit();
}

test "paintfx: sharpening leaves flat colour alone and steepens an edge" {
    var rig = Rig{};
    try rig.init();
    var flat = [_]u32{0xFF507090} ** 8;
    const flat_view = view(&flat, 8, 1);
    try testing.expectEqual(@as(i32, 0), rig.fx.SharpenPixels(&flat_view, &flat_view, 200, 1));
    for (flat) |pixel| try testing.expectEqual(@as(u32, 0xFF507090), pixel);

    var edge = [_]u32{ 0xFF646464, 0xFF646464, 0xFF646464, 0xFF646464, 0xFF969696, 0xFF969696, 0xFF969696, 0xFF969696 };
    const edge_view = view(&edge, 8, 1);
    try testing.expectEqual(@as(i32, 0), rig.fx.SharpenPixels(&edge_view, &edge_view, 100, 1));
    try testing.expect(channel(edge[3], 16) < 0x64);
    try testing.expect(channel(edge[4], 16) > 0x96);
    try testing.expectEqual(@as(u32, 0xFF646464), edge[0]);
    try rig.deinit();
}

test "paintfx: scaled hard, each pixel a block; smooth, averaged and mixed" {
    var rig = Rig{};
    try rig.init();
    const fx = rig.fx;
    var small = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF0000FF };
    var large = [_]u32{0} ** 16;
    try testing.expectEqual(@as(i32, 0), fx.ScalePixels(&view(&small, 2, 2), &view(&large, 4, 4), paintfx.PFXSCALE_HARD));
    try testing.expectEqualSlices(u32, &.{ 0xFF000000, 0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF }, large[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0xFFFF0000, 0xFFFF0000, 0xFF0000FF, 0xFF0000FF }, large[12..16]);
    // And back, hard: the pixels it lands on.
    var back = [_]u32{0} ** 4;
    try testing.expectEqual(@as(i32, 0), fx.ScalePixels(&view(&large, 4, 4), &view(&back, 2, 2), paintfx.PFXSCALE_HARD));
    try testing.expectEqualSlices(u32, &small, &back);

    // Smooth, shrunk: each pair averaged.
    var row = [_]u32{ 0xFF000000, 0xFFC8C8C8, 0xFF0000FF, 0xFF0000FF };
    var half = [_]u32{ 0, 0 };
    try testing.expectEqual(@as(i32, 0), fx.ScalePixels(&view(&row, 4, 1), &view(&half, 2, 1), paintfx.PFXSCALE_SMOOTH));
    try testing.expectEqualSlices(u32, &.{ 0xFF646464, 0xFF0000FF }, &half);
    // A see-through half: the colour stays, the alpha halves.
    var faded = [_]u32{ 0xFFFF0000, 0 };
    var one_pixel = [_]u32{0};
    try testing.expectEqual(@as(i32, 0), fx.ScalePixels(&view(&faded, 2, 1), &view(&one_pixel, 1, 1), paintfx.PFXSCALE_SMOOTH));
    try testing.expectEqual(@as(u32, 0xFF0000), one_pixel[0] & 0xFFFFFF);
    try testing.expect(one_pixel[0] >> 24 >= 127 and one_pixel[0] >> 24 <= 128);
    // Smooth, grown: the ends as they were, between them a mix.
    var pair = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var four = [_]u32{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(i32, 0), fx.ScalePixels(&view(&pair, 2, 1), &view(&four, 4, 1), paintfx.PFXSCALE_SMOOTH));
    try testing.expectEqual(@as(u32, 0xFF000000), four[0]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), four[3]);
    try testing.expect(channel(four[1], 16) > 0 and channel(four[1], 16) < channel(four[2], 16));
    try rig.deinit();
}

test "paintfx: a matrix copies, turns a quarter, and is see-through outside" {
    var rig = Rig{};
    try rig.init();
    const fx = rig.fx;
    const one = paintfx.MATRIX_ONE;
    // 3 x 2:  a b c
    //         d e f
    var from = [_]u32{ 0xFF000001, 0xFF000002, 0xFF000003, 0xFF000004, 0xFF000005, 0xFF000006 };
    var same = [_]u32{0} ** 6;
    inline for (.{ paintfx.PFXSCALE_HARD, paintfx.PFXSCALE_SMOOTH }) |how| {
        fx.TransformPixels(&view(&from, 3, 2), &view(&same, 3, 2), &.{}, how);
        try testing.expectEqualSlices(u32, &from, &same);
    }
    // Turned a quarter clockwise, 2 x 3:  d a
    //                                     e b
    //                                     f c
    // The way back: (x, y) of the turned from (y, 2 - x).
    var turned = [_]u32{0} ** 6;
    fx.TransformPixels(&view(&from, 3, 2), &view(&turned, 2, 3), &.{ .xx = 0, .xy = one, .yx = -one, .yy = 0, .dy = 2 * one }, paintfx.PFXSCALE_HARD);
    try testing.expectEqualSlices(u32, &.{ 0xFF000004, 0xFF000001, 0xFF000005, 0xFF000002, 0xFF000006, 0xFF000003 }, &turned);
    // Moved a whole pixel right: the first column is outside.
    var moved = [_]u32{0xDEADBEEF} ** 6;
    fx.TransformPixels(&view(&from, 3, 2), &view(&moved, 3, 2), &.{ .dx = -one }, paintfx.PFXSCALE_SMOOTH);
    try testing.expectEqualSlices(u32, &.{ 0, 0xFF000001, 0xFF000002, 0, 0xFF000004, 0xFF000005 }, &moved);
    // Half a pixel: two neighbours mixed, the edge half see-through.
    var grey = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var shifted = [_]u32{ 0, 0 };
    fx.TransformPixels(&view(&grey, 2, 1), &view(&shifted, 2, 1), &.{ .dx = one / 2 }, paintfx.PFXSCALE_SMOOTH);
    try testing.expect(channel(shifted[0], 16) >= 127 and channel(shifted[0], 16) <= 128);
    try testing.expectEqual(@as(u32, 0xFFFFFF), shifted[1] & 0xFFFFFF);
    try testing.expect(shifted[1] >> 24 >= 127 and shifted[1] >> 24 <= 128);
    try rig.deinit();
}
