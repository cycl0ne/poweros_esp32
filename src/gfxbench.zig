// SPDX-License-Identifier: MPL-2.0
//! gfxbench: how fast graphics.library draws in software on this host -
//! the way every pixel of the ESP32-S3's is drawn, and what a board's
//! engine leaves to it on the others. Run by `./zig build gfx-bench`.
//!
//! The library is stood up as the host tests stand it up, on exec's test
//! RAM, and draws into a surface of plain memory, 1024 by 768, in RGB565
//! and then in BGRA32: no board, so no engine and nothing handed on. Each
//! case is drawn over and over, three times, and what one call costs at
//! best is printed - a measure to compare one change of the drawing with
//! the one before, on the same host. A board's own figures are `Gfx
//! SPEED`'s and `Speed2D`'s.
//!
//! It is a test, because exec stands up on the host only in a test build,
//! run as a program rather than by the test runner, so that it may print.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const exec = sdk.exec;
const TagItem = sdk.utility.TagItem;
const Rect = graphics.Rect;
const Interface = sdk.interface.graphics.GraphicsBase;

const kexec = @import("rom/libs/exec/exec.zig");
const kutility = @import("rom/libs/utility/utility.zig");
const krtg = @import("rom/libs/rtg/rtg.zig");
const kgraphics = @import("rom/libs/graphics/graphics.zig");

const width = 1024;
const height = 768;

var target: [width * height * 4]u8 align(64) = undefined;
var picture: [256 * 256 * 4]u8 align(64) = undefined;
var indices: [256 * 256]u8 align(64) = undefined;
var lut: [256]graphics.Pen = undefined;

const Case = struct {
    name: []const u8,
    rounds: u32,
    draw: *const fn (*Bench, u32) void,
};

const Bench = struct {
    gb: *Interface,
    rp: *graphics.RastPort,
    source: rtg.Surface,
    font8: *graphics.TextFont,
    font16: *graphics.TextFont,

    fn set(b: *Bench, tags: []const TagItem) void {
        b.gb.SetRPAttrs(b.rp, tags.ptr);
    }

    fn pen(b: *Bench, round: u32) void {
        b.set(&.{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(@truncate(round *% 37), @truncate(round *% 91), 200) }, .{} });
    }
};

/// Somewhere new each round, so no two calls hit the same cache lines.
fn at(round: u32, room: u32) i32 {
    return @intCast(round *% 7919 % room);
}

fn rectSmall(b: *Bench, round: u32) void {
    b.pen(round);
    const x = at(round, width - 64);
    const y = at(round *% 13, height - 64);
    b.gb.RectFill(b.rp, &.{ .min_x = x, .min_y = y, .max_x = x + 64, .max_y = y + 64 });
}

fn rectWhole(b: *Bench, round: u32) void {
    b.pen(round);
    b.gb.RectFill(b.rp, &.{ .max_x = width, .max_y = height });
}

fn copy(b: *Bench, round: u32) void {
    b.gb.BltBitMapRastPort(&b.source, 0, 0, b.rp, at(round, width - 256), at(round *% 13, height - 256), 256, 256);
}

fn hline(b: *Bench, round: u32) void {
    b.pen(round);
    b.gb.DrawHLine(b.rp, at(round, width - 512), at(round *% 13, height), 512);
}

fn vline(b: *Bench, round: u32) void {
    b.pen(round);
    b.gb.DrawVLine(b.rp, at(round, width), at(round *% 13, height - 512), 512);
}

fn across(b: *Bench, round: u32) void {
    b.pen(round);
    const x = at(round, width - 512);
    const y = at(round *% 13, height);
    b.gb.Move(b.rp, x, y);
    b.gb.Draw(b.rp, x + 511, y);
}

fn down(b: *Bench, round: u32) void {
    b.pen(round);
    const x = at(round, width);
    const y = at(round *% 13, height - 512);
    b.gb.Move(b.rp, x, y);
    b.gb.Draw(b.rp, x, y + 511);
}

fn slanted(b: *Bench, round: u32) void {
    b.pen(round);
    const x = at(round, width - 400);
    const y = at(round *% 13, height - 300);
    b.gb.Move(b.rp, x, y);
    b.gb.Draw(b.rp, x + 399, y + 299);
}

fn ellipse(b: *Bench, round: u32) void {
    b.pen(round);
    _ = b.gb.AreaEllipse(b.rp, 200 + at(round, width - 400), 150 + at(round *% 13, height - 300), 200, 150);
    _ = b.gb.AreaEnd(b.rp);
}

fn roundRect(b: *Bench, round: u32) void {
    b.pen(round);
    const x = at(round, width - 200);
    const y = at(round *% 13, height - 100);
    b.gb.FillRoundRect(b.rp, &.{ .min_x = x, .min_y = y, .max_x = x + 200, .max_y = y + 100 }, 8);
}

const letters = "The quick brown fox jumps over the lazy";

fn text(b: *Bench, round: u32, font: *graphics.TextFont, mode: graphics.DrawMode) void {
    b.set(&.{
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{ .tag = graphics.RPTAG_DrMd, .data = mode },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(@truncate(round *% 37), 0, 0) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(255, 255, 255) },
        .{},
    });
    b.gb.Move(b.rp, at(round, width - 400), 20 + at(round *% 13, height - 40));
    b.gb.Text(b.rp, letters, letters.len);
}

fn text8(b: *Bench, round: u32) void {
    text(b, round, b.font8, graphics.DRMD_JAM1);
}

fn text16(b: *Bench, round: u32) void {
    text(b, round, b.font16, graphics.DRMD_JAM2);
}

fn blendRect(b: *Bench, round: u32) void {
    b.set(&.{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penARGB(128, @truncate(round *% 37), 90, 200) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 | graphics.DRMD_BLEND },
        .{},
    });
    const x = at(round, width - 64);
    const y = at(round *% 13, height - 64);
    b.gb.RectFill(b.rp, &.{ .min_x = x, .min_y = y, .max_x = x + 64, .max_y = y + 64 });
    b.set(&.{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
}

fn blendPicture(b: *Bench, round: u32) void {
    const x = at(round, width - 256);
    const y = at(round *% 13, height - 256);
    b.gb.BlendPixelArray(b.rp, &picture, 256 * 4, @intFromEnum(rtg.PixelFormat.rgba32), 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + 256, .max_y = y + 256 });
}

fn lutPicture(b: *Bench, round: u32) void {
    const x = at(round, width - 256);
    const y = at(round *% 13, height - 256);
    b.gb.WriteLUTPixelArray(b.rp, &indices, 256, &lut, 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + 256, .max_y = y + 256 });
}

const cases = [_]Case{
    .{ .name = "RectFill 64x64", .rounds = 20000, .draw = &rectSmall },
    .{ .name = "RectFill 1024x768", .rounds = 200, .draw = &rectWhole },
    .{ .name = "BltBitMapRastPort 256x256", .rounds = 2000, .draw = &copy },
    .{ .name = "DrawHLine 512", .rounds = 20000, .draw = &hline },
    .{ .name = "DrawVLine 512", .rounds = 20000, .draw = &vline },
    .{ .name = "Draw 512 across", .rounds = 20000, .draw = &across },
    .{ .name = "Draw 512 down", .rounds = 20000, .draw = &down },
    .{ .name = "Draw 400x300 slanted", .rounds = 20000, .draw = &slanted },
    .{ .name = "AreaEllipse 400x300", .rounds = 1000, .draw = &ellipse },
    .{ .name = "FillRoundRect 200x100", .rounds = 5000, .draw = &roundRect },
    .{ .name = "Text 39, 8 rows, JAM1", .rounds = 5000, .draw = &text8 },
    .{ .name = "Text 39, 16 rows, JAM2", .rounds = 5000, .draw = &text16 },
    .{ .name = "RectFill 64x64 at half", .rounds = 2000, .draw = &blendRect },
    .{ .name = "BlendPixelArray 256x256", .rounds = 200, .draw = &blendPicture },
    .{ .name = "WriteLUTPixelArray 256x256", .rounds = 500, .draw = &lutPicture },
};

test "gfx-bench" {
    const io = std.testing.io;
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    const gb: *Interface = @ptrCast(@alignCast(made));

    for (0..256 * 256) |i| {
        const x: u32 = @intCast(i % 256);
        const y: u32 = @intCast(i / 256);
        picture[i * 4 + 0] = @truncate(x);
        picture[i * 4 + 1] = @truncate(y);
        picture[i * 4 + 2] = @truncate(x ^ y);
        picture[i * 4 + 3] = @truncate((x + y) / 2);
        indices[i] = @truncate(x +% y);
    }
    for (&lut, 0..) |*p, i| p.* = graphics.penRGB(@truncate(i), @truncate(255 - i), @truncate(i *% 3));

    const font8 = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }) orelse return error.NoFont;
    const font16 = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 16 }) orelse return error.NoFont;

    std.debug.print("graphics.library in software, {d}x{d}, a call each\n", .{ width, height });
    for ([_]rtg.PixelFormat{ .rgb565, .bgra32 }) |format| {
        const bytes: u32 = if (format == .rgb565) 2 else 4;
        var surface = rtg.Surface{
            .pixels = &target,
            .width = width,
            .height = height,
            .pitch = width * bytes,
            .size_bytes = width * height * bytes,
            .format = format,
        };
        @memset(&target, 0);
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} };
        const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
        defer gb.FreeRastPort(rp);
        // An ellipse arrives as corners about a pixel apart.
        if (!gb.InitArea(rp, 2048)) return error.NoArea;
        var b = Bench{
            .gb = gb,
            .rp = rp,
            .source = .{
                .pixels = &picture,
                .width = 256,
                .height = 256,
                .pitch = 256 * bytes,
                .size_bytes = 256 * 256 * bytes,
                .format = format,
            },
            .font8 = font8,
            .font16 = font16,
        };
        std.debug.print("{s}:\n", .{@tagName(format)});
        for (cases) |case| {
            // Each case has to draw something, or its time says nothing.
            @memset(&target, 0);
            case.draw(&b, 1);
            if (std.mem.allEqual(u8, &target, 0)) {
                std.debug.print("  {s:<28} draws nothing\n", .{case.name});
                return error.NothingDrawn;
            }
            // The best of three: what is left over is the drawing, not
            // whatever else the host was doing.
            var each: u64 = std.math.maxInt(u64);
            for (0..3) |_| {
                const start = std.Io.Timestamp.now(io, .awake);
                var round: u32 = 0;
                while (round < case.rounds) : (round += 1) case.draw(&b, round);
                const end = std.Io.Timestamp.now(io, .awake);
                const ns: u64 = @intCast(start.durationTo(end).nanoseconds);
                each = @min(each, ns / case.rounds);
            }
            std.debug.print("  {s:<28} {d:>8}.{d:0>3} us\n", .{ case.name, each / 1000, each % 1000 });
        }
    }
}
