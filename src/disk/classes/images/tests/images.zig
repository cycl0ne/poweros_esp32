// SPDX-License-Identifier: MIT
//! Host tests of the image classes, and of the shapes they draw with:
//! each class library made from its ROM tag on the ROM's
//! intuition.library, its images made, asked and drawn into memory.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const host_rom = @import("host_rom");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const shapes = sdk.gadgets.shapes;
const command = sdk.images.command;
const media = sdk.images.media;
const sc = intuition.screens;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const kexec = host_rom.exec;

const command_image = @import("../command/command.zig");
const media_image = @import("../media/media.zig");

test "shapes: a shape of straight edges set in keeps its edges parallel, whichever way round it goes" {
    const square = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var shape = shapes.Shape{ .poly = .{ .corners = undefined, .count = 4 } };
    @memcpy(shape.poly.corners[0..4], &square);
    const in = shape.inset(2);
    const want = [_][2]f32{ .{ 2, 2 }, .{ 8, 2 }, .{ 8, 8 }, .{ 2, 8 } };
    for (want, in.poly.corners[0..4]) |w, c| {
        try testing.expectApproxEqAbs(w[0], c[0], 0.001);
        try testing.expectApproxEqAbs(w[1], c[1], 0.001);
    }
    // The other way round, the same square.
    var back = shape;
    for (0..4) |i| back.poly.corners[i] = square[3 - i];
    const back_in = back.inset(2);
    for (0..4) |i| {
        try testing.expectApproxEqAbs(want[3 - i][0], back_in.poly.corners[i][0], 0.001);
        try testing.expectApproxEqAbs(want[3 - i][1], back_in.poly.corners[i][1], 0.001);
    }
}

test "shapes: a box and a ring set in by their rim, a part of a ring shorter at its ends" {
    const box = (shapes.Shape{ .box = .{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 10, .radius = 3 } }).inset(2);
    try testing.expectEqual(@as(f32, 2), box.box.x0);
    try testing.expectEqual(@as(f32, 18), box.box.x1);
    try testing.expectEqual(@as(f32, 1), box.box.radius);
    const whole = (shapes.Shape{ .arc = .{ .cx = 10, .cy = 10, .radius = 10, .inner = 4, .from = 0, .to = 360 } }).inset(1);
    try testing.expectEqual(@as(f32, 9), whole.arc.radius);
    try testing.expectEqual(@as(f32, 5), whole.arc.inner);
    try testing.expectEqual(@as(f32, 360), whole.arc.to);
    // Its ends in by a pixel along the middle of the band, 7 out: a
    // seventh of a radian, a little over 8 degrees.
    const part = (shapes.Shape{ .arc = .{ .cx = 10, .cy = 10, .radius = 10, .inner = 4, .from = -40, .to = 180 } }).inset(1);
    try testing.expectApproxEqAbs(@as(f32, -31.815), part.arc.from, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 171.815), part.arc.to, 0.01);
}

test "shapes: the palette's colours greyed, mixed and darkened" {
    try testing.expectEqual(@as(Pen, 0xFF80_8080), shapes.grey(0xFF80_8080));
    try testing.expectEqual(@as(Pen, 0x40FF_FFFF), shapes.grey(0x40FF_FFFF));
    try testing.expectEqual(@as(Pen, 0xFF80_8080), shapes.toward(0xFF00_0000, 0xFFFF_FFFF, 128));
    try testing.expectEqual(@as(Pen, 0xFF40_2010), shapes.darker(0xFF80_4020, 128));
    try testing.expectEqual(@as(Pen, 0x8012_3456), shapes.withAlpha(0xFF12_3456, 0x80));
    // A painter's rim is a pixel to 63 and two from 64; detail from 20.
    const frame = shapes.Frame{ .gb = undefined, .rp = undefined, .x = 0, .y = 0, .size = 64, .pens = .{} };
    const p = shapes.Painter.begin(frame, .{});
    try testing.expectEqual(@as(i32, 2), p.rim);
    try testing.expect(p.detail);
    try testing.expectEqual(@as(i32, 32), p.u(50));
}

/// A square of `size` pixels in memory, filled with `ground`.
fn Canvas(comptime size: u32) type {
    return struct {
        pixels: [size * size]u32 = undefined,
        surface: sdk.rtg.Surface = undefined,
        rp: *graphics.RastPort = undefined,

        const Self = @This();

        fn up(c: *Self, gb: anytype, ground: Pen) !void {
            c.surface = .{ .pixels = @ptrCast(&c.pixels), .width = size, .height = size, .pitch = size * 4, .size_bytes = size * size * 4, .format = .rgba32 };
            c.rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&c.surface) }, .{} }) orelse return error.NoRastPort;
            gb.SetRPAttrs(c.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ground }, .{} });
            gb.RectFill(c.rp, &.{ .max_x = size, .max_y = size });
        }

        fn at(c: *Self, gb: anytype, x: i32, y: i32) Pen {
            var out: Pen = 0;
            _ = gb.ReadPixel(c.rp, x, y, &out);
            return out;
        }
    };
}

fn red(c: Pen) i32 {
    return @intCast((c >> 16) & 0xFF);
}
fn green(c: Pen) i32 {
    return @intCast((c >> 8) & 0xFF);
}
fn blue(c: Pen) i32 {
    return @intCast(c & 0xFF);
}

/// The image drawn fitted to the canvas's square, in `state`; how many
/// pixels it changed.
fn drawn(ib: *IntuitionBase, o: *Object, canvas: anytype, size: i32, state: u32) !usize {
    const before = canvas.pixels;
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = canvas.rp, .state = state, .dimensions = .{ .width = size, .height = size } };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(o, @ptrCast(&draw)));
    var changed: usize = 0;
    for (before, canvas.pixels) |was, now| changed += @intFromBool(was != now);
    return changed;
}

fn attr(ib: *IntuitionBase, o: *Object, tag: utility.Tag) usize {
    var value: usize = 0;
    _ = ib.GetAttr(tag, o, &value);
    return value;
}

test "command.image: every picture drawn at every size, over part of its square; none drawn as nothing" {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const gb = kib.graphics_base;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &command_image.Library.resident_tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = command.CMD_SAVE }, .{} }) orelse return error.NoObject;
    try testing.expectEqual(@as(usize, command.CMD_SAVE), attr(ib, o, command.COMMAND_Glyph));
    // Made without a size, it is 24 by 24.
    try testing.expectEqual(@as(usize, 24), attr(ib, o, ic.IA_Width));
    try testing.expectEqual(@as(usize, 24), attr(ib, o, ic.IA_Height));

    var small: Canvas(16) = .{};
    var middle: Canvas(24) = .{};
    var large: Canvas(48) = .{};
    var glyph: u32 = command.CMD_NONE;
    while (glyph <= command.CMD_LAST + 1) : (glyph += 1) {
        try testing.expect(ib.SetAttrsTagList(o, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = glyph }, .{} }) != 0);
        try small.up(gb, 0xFF90_9090);
        try middle.up(gb, 0xFF90_9090);
        try large.up(gb, 0xFF90_9090);
        defer gb.FreeRastPort(small.rp);
        defer gb.FreeRastPort(middle.rp);
        defer gb.FreeRastPort(large.rp);
        const counts = [_]usize{ try drawn(ib, o, &small, 16, ic.IDS_NORMAL), try drawn(ib, o, &middle, 24, ic.IDS_NORMAL), try drawn(ib, o, &large, 48, ic.IDS_NORMAL) };
        for (counts, [_]usize{ 16 * 16, 24 * 24, 48 * 48 }) |count, all| {
            if (glyph == command.CMD_NONE or glyph > command.CMD_LAST) {
                try testing.expectEqual(@as(usize, 0), count);
            } else {
                testing.expect(count > all / 10) catch |err| {
                    std.debug.print("glyph {d}: {d} of {d}\n", .{ glyph, count, all });
                    return err;
                };
                try testing.expect(count < all);
            }
        }
    }
    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try testing.expect(ib.FindClass(command.COMMAND_CLASS) == null);
    try host_rom.intuition.tearDown(kib);
}

test "command.image: the disk blue with a shadow under it, plain at 16; grey all over when disabled" {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const gb = kib.graphics_base;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &command_image.Library.resident_tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = command.CMD_SAVE }, .{} }) orelse return error.NoObject;
    const ground: Pen = 0xFF90_9090;

    var large: Canvas(48) = .{};
    try large.up(gb, ground);
    _ = try drawn(ib, o, &large, 48, ic.IDS_NORMAL);
    // The disk's body, below its label's left: blue.
    const body = large.at(gb, 8, 30);
    try testing.expect(blue(body) > red(body) + 60);
    // Its bottom edge at 44 of 48; two rows under it, its shadow: the
    // ground darkened, by a little; and under that the ground.
    const shade = large.at(gb, 24, 45);
    try testing.expect(red(shade) < red(ground) - 10);
    try testing.expect(red(shade) > red(ground) - 50);
    try testing.expectEqual(ground, large.at(gb, 24, 47));

    // At 16 the same blue, and no shadow under it.
    var small: Canvas(16) = .{};
    try small.up(gb, ground);
    _ = try drawn(ib, o, &small, 16, ic.IDS_NORMAL);
    const plain = small.at(gb, 2, 5);
    try testing.expect(blue(plain) > red(plain) + 60);
    try testing.expectEqual(ground, small.at(gb, 8, 15));

    // Disabled, on a grey ground, every pixel grey and none darker than
    // half the ground: faded into it.
    var off: Canvas(48) = .{};
    try off.up(gb, ground);
    try testing.expect(try drawn(ib, o, &off, 48, ic.IDS_DISABLED) > 48 * 48 / 4);
    for (off.pixels, 0..) |_, i| {
        const c = off.at(gb, @intCast(i % 48), @intCast(i / 48));
        try testing.expect(@abs(red(c) - green(c)) <= 2 and @abs(green(c) - blue(c)) <= 2);
        try testing.expect(red(c) > @divTrunc(red(ground), 2));
    }

    gb.FreeRastPort(large.rp);
    gb.FreeRastPort(small.rp);
    gb.FreeRastPort(off.rp);
    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try host_rom.intuition.tearDown(kib);
}

test "command.image: drawn in its own box, and in the middle of a box that is not square" {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const gb = kib.graphics_base;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &command_image.Library.resident_tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{
        .{ .tag = command.COMMAND_Glyph, .data = command.CMD_BOLD },
        .{ .tag = ic.IA_Left, .data = 8 },
        .{ .tag = ic.IA_Width, .data = 16 },
        .{ .tag = ic.IA_Height, .data = 16 },
        .{},
    }) orelse return error.NoObject;
    const ground: Pen = 0xFFC0_C0C0;
    var canvas: Canvas(32) = .{};
    try canvas.up(gb, ground);
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAW, .rast_port = canvas.rp, .offset = .{ .x = 0, .y = 8 } };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(o, @ptrCast(&draw)));
    // The B in the text pen - black without a DrawInfo - in 8..24 by
    // 8..24 and nothing round it.
    var inside: usize = 0;
    for (0..32) |y| for (0..32) |x| {
        const c = canvas.at(gb, @intCast(x), @intCast(y));
        const in = x >= 8 and x < 24 and y >= 8 and y < 24;
        if (!in) try testing.expectEqual(ground, c);
        if (in and c == 0xFF00_0000) inside += 1;
    };
    try testing.expect(inside > 16);

    // Fitted to a box twice as wide as it is high, the square in its middle.
    gb.FreeRastPort(canvas.rp);
    try canvas.up(gb, ground);
    var framed = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = canvas.rp, .offset = .{ .x = -8, .y = 0 }, .dimensions = .{ .width = 32, .height = 16 } };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(o, @ptrCast(&framed)));
    for (0..16) |y| for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 24, 25, 26, 27, 28, 29, 30, 31 }) |x| {
        try testing.expectEqual(ground, canvas.at(gb, @intCast(x), @intCast(y)));
    };

    gb.FreeRastPort(canvas.rp);
    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try host_rom.intuition.tearDown(kib);
}

test "media.image: every picture drawn at every size, over part of its square; none drawn as nothing" {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const gb = kib.graphics_base;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &media_image.Library.resident_tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, media.MEDIA_CLASS, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = media.MEDIA_PLAY }, .{} }) orelse return error.NoObject;
    try testing.expectEqual(@as(usize, media.MEDIA_PLAY), attr(ib, o, media.MEDIA_Glyph));
    try testing.expectEqual(@as(usize, 24), attr(ib, o, ic.IA_Width));
    try testing.expectEqual(@as(usize, 24), attr(ib, o, ic.IA_Height));

    var small: Canvas(16) = .{};
    var middle: Canvas(24) = .{};
    var large: Canvas(48) = .{};
    var glyph: u32 = media.MEDIA_NONE;
    while (glyph <= media.MEDIA_LAST + 1) : (glyph += 1) {
        try testing.expect(ib.SetAttrsTagList(o, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = glyph }, .{} }) != 0);
        try small.up(gb, 0xFF90_9090);
        try middle.up(gb, 0xFF90_9090);
        try large.up(gb, 0xFF90_9090);
        defer gb.FreeRastPort(small.rp);
        defer gb.FreeRastPort(middle.rp);
        defer gb.FreeRastPort(large.rp);
        const counts = [_]usize{ try drawn(ib, o, &small, 16, ic.IDS_NORMAL), try drawn(ib, o, &middle, 24, ic.IDS_NORMAL), try drawn(ib, o, &large, 48, ic.IDS_NORMAL) };
        for (counts, [_]usize{ 16 * 16, 24 * 24, 48 * 48 }) |count, all| {
            if (glyph == media.MEDIA_NONE or glyph > media.MEDIA_LAST) {
                try testing.expectEqual(@as(usize, 0), count);
            } else {
                testing.expect(count > all / 10) catch |err| {
                    std.debug.print("glyph {d}: {d} of {d}\n", .{ glyph, count, all });
                    return err;
                };
                try testing.expect(count < all);
            }
        }
    }
    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try testing.expect(ib.FindClass(media.MEDIA_CLASS) == null);
    try host_rom.intuition.tearDown(kib);
}

test "media.image: play in the text pen, in the fill-text pen selected; the arrows blue, sound off red; grey disabled" {
    const kib = try host_rom.intuition.setUp();
    const ib = kib.iface();
    const gb = kib.graphics_base;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &media_image.Library.resident_tag, null) orelse return error.NoClassLibrary));
    const o = ib.NewObjectTagList(null, media.MEDIA_CLASS, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = media.MEDIA_PLAY }, .{} }) orelse return error.NoObject;
    const ground: Pen = 0xFF90_9090;
    var pens: [sc.NUMDRIPENS]Pen = @splat(0xFF80_8080);
    pens[sc.TEXTPEN] = 0xFF10_2030;
    pens[sc.BACKGROUNDPEN] = ground;
    pens[sc.FILLPEN] = 0xFF33_66AA;
    pens[sc.FILLTEXTPEN] = 0xFFF0_E0D0;
    var dri = sc.DrawInfo{ .pens = &pens };

    // The triangle's middle, in the text pen; selected, in the fill-text
    // pen, on whatever the button was filled with.
    var canvas: Canvas(48) = .{};
    try canvas.up(gb, ground);
    var draw = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = canvas.rp, .state = ic.IDS_NORMAL, .draw_info = &dri, .dimensions = .{ .width = 48, .height = 48 } };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(o, @ptrCast(&draw)));
    try testing.expectEqual(pens[sc.TEXTPEN], canvas.at(gb, 24, 24));
    try testing.expectEqual(ground, canvas.at(gb, 4, 4));
    gb.FreeRastPort(canvas.rp);
    try canvas.up(gb, pens[sc.FILLPEN]);
    draw.rast_port = canvas.rp;
    draw.state = ic.IDS_SELECTED;
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(o, @ptrCast(&draw)));
    try testing.expectEqual(pens[sc.FILLTEXTPEN], canvas.at(gb, 24, 24));
    gb.FreeRastPort(canvas.rp);

    // Shuffle's arrows blue where they cross; sound off's badge red.
    _ = ib.SetAttrsTagList(o, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = media.MEDIA_SHUFFLE }, .{} });
    try canvas.up(gb, ground);
    draw.rast_port = canvas.rp;
    draw.state = ic.IDS_NORMAL;
    _ = ib.SendMessage(o, @ptrCast(&draw));
    const crossing = canvas.at(gb, 22, 24);
    try testing.expect(blue(crossing) > red(crossing) + 60);
    gb.FreeRastPort(canvas.rp);
    _ = ib.SetAttrsTagList(o, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = media.MEDIA_MUTE }, .{} });
    try canvas.up(gb, ground);
    draw.rast_port = canvas.rp;
    _ = ib.SendMessage(o, @ptrCast(&draw));
    // Inside the badge, between its cross's arms.
    const badge = canvas.at(gb, 36, 27);
    try testing.expect(red(badge) > blue(badge) + 60);
    gb.FreeRastPort(canvas.rp);

    // Disabled, every pixel grey, none darker than half the ground.
    try canvas.up(gb, ground);
    draw.rast_port = canvas.rp;
    draw.state = ic.IDS_DISABLED;
    _ = ib.SendMessage(o, @ptrCast(&draw));
    for (0..48) |y| for (0..48) |x| {
        const c = canvas.at(gb, @intCast(x), @intCast(y));
        try testing.expect(@abs(red(c) - green(c)) <= 2 and @abs(green(c) - blue(c)) <= 2);
        try testing.expect(red(c) > @divTrunc(red(ground), 2));
    };
    gb.FreeRastPort(canvas.rp);

    ib.DisposeObject(o);
    _ = kexec.SysBase.iface().RemLibrary(lib);
    try host_rom.intuition.tearDown(kib);
}
