// SPDX-License-Identifier: MIT
//! Speed2D: how long the display takes to be drawn over whole - a fill, a
//! colour laid over it at half strength, a picture with coverage laid
//! over it, a picture scaled up twice, a window's worth moved, a pattern
//! and a template - and whether each was drawn right. Built against the
//! SDK only.
//!
//!   Speed2D ROUNDS/K/N
//!
//! A buffer the size of the display is taken from the display board, and
//! as much plain memory beside it. Each case is drawn ROUNDS times (100 if
//! not given) into the buffer through graphics.library - by the board's
//! engine where it takes the job, else in software, and the rows handed
//! on to the display either way - and the time one takes is printed. Then
//! the buffer and the plain memory are painted alike, the case is drawn
//! once into each - into the plain memory by graphics.library in
//! software - and the two are compared pixel by pixel: the engine has to
//! draw what the software does.
//!
//! The move is 800 x 600 within the buffer, 16 to the right and 8 down
//! and back again in turns, as a window dragged over the screen is. Then
//! come the data cache's write-backs alone, which every draw ends with:
//! CacheClearE over 64 KiB, 128 KiB, 256 KiB, 1 MiB and 4 MiB of the buffer, its
//! lines dirty - written just before each, outside the time - and clean,
//! as a second write-back finds them; CachePreDMA over 1 MiB, dirty, which
//! writes back without invalidating; and RefreshBitMap over the whole
//! buffer.
//!
//! Last, the cases that are not whole and even are drawn once each and
//! checked the same way: rectangles that start and end anywhere, and one
//! too small to be shared out; colours laid over at the ends of their
//! strength; a part of the picture scaled by uneven steps, up and down;
//! moves within the buffer in every direction, by one pixel and by half
//! the rectangle, and one that does not overlap; a pattern and a template
//! that do not start at the buffer's corner.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;
const Rect = graphics.Rect;

pub const COMMAND_NAME = "Speed2D";
const VERSION_STRING = "\x00$VER: Speed2D 1.0 (19.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/K/N";

const Case = enum { fill, blend, lay, scale, move, pattern, template };

/// The pens: the fill's, the blend's - orange at half strength - and the
/// pattern's and the template's two.
const fill_pen: u32 = 0xFF30_60C0;
const blend_pen: u32 = 0x80FF_8000;
const front_pen: u32 = 0xFFE0_E0E0;
const back_pen: u32 = 0xFF20_2040;

/// The window moved, and how far.
const move_width = 800;
const move_height = 600;
const move_x = 100;
const move_y = 100;
const move_dx = 16;
const move_dy = 8;

/// A tile of 16 x 16: a diagonal weave.
const tile = blk: {
    var bits: [32]u8 = undefined;
    for (0..16) |row| {
        const word: u16 = @as(u16, 0x8181) >> @intCast(row % 8) | @as(u16, 0x0F00) >> @intCast(row % 4);
        bits[row * 2] = @truncate(word >> 8);
        bits[row * 2 + 1] = @truncate(word);
    }
    break :blk bits;
};

/// What every case works on.
const Bench = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    rb: *RtgBase,
    tb: *TimerBase,
    /// The board's buffer and the RastPort on it; the plain memory and
    /// the RastPort on that.
    bitmap: *rtg.RtgBitMap,
    board_rp: *graphics.RastPort,
    plain: rtg.Surface,
    plain_rp: *graphics.RastPort,
    /// The picture the scale takes, half the display each way; the one
    /// laid over it, the display's size; and the template's shape, the
    /// display's size.
    picture: [*]u32,
    picture_width: u32,
    picture_height: u32,
    overlay: [*]u32,
    shape: [*]u8,
    shape_pitch: u32,
};

/// The colour a buffer starts with at (x, y): every channel different
/// from its neighbours', opaque.
fn patternAt(x: u32, y: u32, seed: u32) u32 {
    const h = (x *% 0x9E37_79B1) ^ (y *% 0x85EB_CA77) ^ (seed *% 0xC2B2_AE3D);
    return 0xFF00_0000 | (h ^ (h >> 15)) & 0x00FF_FFFF;
}

fn paint(surface: *const rtg.Surface, seed: u32) void {
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        const row: [*]u32 = @ptrCast(@alignCast(surface.pixels.? + @as(usize, y) * surface.pitch));
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) row[x] = patternAt(x, y, seed);
    }
}

/// The scale's picture: a smooth wash of colour, opaque but for a strip
/// whose coverage runs from none to full across it.
fn paintPicture(picture: [*]u32, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const alpha: u32 = if (y >= height / 3 and y < height / 2) x * 255 / (width - 1) else 255;
            const red = x * 255 / width;
            const green = y * 255 / height;
            const blue = (x + y) * 127 / (width + height) + (x ^ y) % 64;
            picture[y * width + x] = alpha << 24 | red << 16 | green << 8 | blue;
        }
    }
}

/// The picture laid over the display: colours from its coordinates, and
/// its coverage running through every level, so nearly every pixel is
/// mixed.
fn paintOverlay(picture: [*]u32, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const alpha = (x * 3 + y) & 0xFF;
            const red = x * 255 / width;
            const green = y * 255 / height;
            const blue = (x ^ y) & 0xFF;
            picture[y * width + x] = alpha << 24 | red << 16 | green << 8 | blue;
        }
    }
}

/// The template's shape: rings, as letters are curves and straights.
fn paintShape(shape: [*]u8, pitch: u32, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < pitch) : (x += 1) shape[y * pitch + x] = 0;
        x = 0;
        while (x < width) : (x += 1) {
            const cx: i32 = @as(i32, @intCast(x % 48)) - 24;
            const cy: i32 = @as(i32, @intCast(y % 48)) - 24;
            const r2 = cx * cx + cy * cy;
            if (r2 < 400 and r2 > 196) shape[y * pitch + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
        }
    }
}

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn setPens(b: *Bench, rp: *graphics.RastPort, front: u32, back: u32, mode: graphics.DrawMode, smooth: bool) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = front },
        .{ .tag = graphics.RPTAG_BPen, .data = back },
        .{ .tag = graphics.RPTAG_DrMd, .data = mode },
        .{ .tag = graphics.RPTAG_Smooth, .data = @intFromBool(smooth) },
        .{},
    };
    b.gb.SetRPAttrs(rp, &tags);
}

/// One case drawn once into `rp`, whose surface is `surface`; `round`
/// says which way a move goes.
fn draw(b: *Bench, case: Case, rp: *graphics.RastPort, surface: *const rtg.Surface, round: u32) void {
    const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = @intCast(surface.width), .max_y = @intCast(surface.height) };
    switch (case) {
        .fill => {
            setPens(b, rp, fill_pen ^ (round & 1) * 0x0010_1010, back_pen, graphics.DRMD_JAM1, false);
            b.gb.RectFill(rp, &whole);
        },
        .blend => {
            setPens(b, rp, blend_pen, back_pen, graphics.DRMD_JAM1 | graphics.DRMD_BLEND, false);
            b.gb.RectFill(rp, &whole);
        },
        .lay => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.BlendPixelArray(rp, @ptrCast(b.overlay), surface.width * 4, @intFromEnum(rtg.PixelFormat.bgra32), 0, 0, &whole);
        },
        .scale => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, true);
            const from = Rect{ .min_x = 0, .min_y = 0, .max_x = @intCast(b.picture_width), .max_y = @intCast(b.picture_height) };
            b.gb.ScalePixelArray(rp, @ptrCast(b.picture), b.picture_width * 4, @intFromEnum(rtg.PixelFormat.bgra32), &from, &whole);
        },
        .move => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, false);
            const there = round & 1 != 0;
            const sx: i32 = if (there) move_x + move_dx else move_x;
            const sy: i32 = if (there) move_y + move_dy else move_y;
            const dx: i32 = if (there) move_x else move_x + move_dx;
            const dy: i32 = if (there) move_y else move_y + move_dy;
            b.gb.BltBitMapRastPort(surface, sx, sy, rp, dx, dy, move_width, move_height);
        },
        .pattern => {
            setPens(b, rp, front_pen, back_pen, graphics.DRMD_JAM2, false);
            b.gb.BltPattern(rp, &tile, 2, 16, 16, &whole);
        },
        .template => {
            setPens(b, rp, front_pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.BltTemplate(rp, b.shape, b.shape_pitch, 0, 0, &whole);
        },
    }
}

/// A case that is not whole and even: where it is drawn - for a move,
/// the rectangle moved - with what pen, from what part of the picture or
/// the shape, and for a move how far.
const Check = struct {
    name: [*:0]const u8,
    case: Case,
    area: Rect,
    pen: u32 = fill_pen,
    /// The order of the picture laid over.
    format: rtg.PixelFormat = .bgra32,
    from: Rect = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 },
    dx: i32 = 0,
    dy: i32 = 0,
};

fn rect(x: i32, y: i32, width: i32, height: i32) Rect {
    return .{ .min_x = x, .min_y = y, .max_x = x + width, .max_y = y + height };
}

fn move(name: [*:0]const u8, area: Rect, dx: i32, dy: i32) Check {
    return .{ .name = name, .case = .move, .area = area, .dx = dx, .dy = dy };
}

const window = rect(100, 100, 800, 600);

const checks = [_]Check{
    .{ .name = "fill 400x300 at 13,7", .case = .fill, .area = rect(13, 7, 400, 300) },
    .{ .name = "fill 97x50 at 31,5", .case = .fill, .area = rect(31, 5, 97, 50) },
    .{ .name = "fill 1917x1077 at 1,1", .case = .fill, .area = rect(1, 1, 1917, 1077) },
    .{ .name = "blend 1915x1077 at 3,1, 50%", .case = .blend, .area = rect(3, 1, 1915, 1077), .pen = blend_pen },
    .{ .name = "blend 400x300 at 13,7, 0%", .case = .blend, .area = rect(13, 7, 400, 300), .pen = 0x00FF_8000 },
    .{ .name = "blend 400x300 at 13,7, 1/255", .case = .blend, .area = rect(13, 7, 400, 300), .pen = 0x01FF_8000 },
    .{ .name = "blend 400x300 at 13,7, 254/255", .case = .blend, .area = rect(13, 7, 400, 300), .pen = 0xFE00_C0FF },
    .{ .name = "blend 97x50 at 31,5, 50%", .case = .blend, .area = rect(31, 5, 97, 50), .pen = blend_pen },
    .{ .name = "lay 401x299 at 13,7, from 5,3", .case = .lay, .area = rect(13, 7, 401, 299), .from = rect(5, 3, 0, 0) },
    .{ .name = "lay 1915x1077 at 3,1, rgba32", .case = .lay, .area = rect(3, 1, 1915, 1077), .format = .rgba32 },
    .{ .name = "lay 97x50 at 31,5", .case = .lay, .area = rect(31, 5, 97, 50) },
    .{ .name = "scale 333x250 to 1001x777 at 17,9", .case = .scale, .area = rect(17, 9, 1001, 777), .from = rect(7, 3, 333, 250) },
    .{ .name = "scale 960x540 to 401x301 at 5,5", .case = .scale, .area = rect(5, 5, 401, 301), .from = rect(0, 0, 960, 540) },
    move("move 800x600 by 16,8", window, 16, 8),
    move("move 800x600 by -16,-8", window, -16, -8),
    move("move 800x600 by 16,-8", window, 16, -8),
    move("move 800x600 by -16,8", window, -16, 8),
    move("move 800x600 by 16,0", window, 16, 0),
    move("move 800x600 by -16,0", window, -16, 0),
    move("move 800x600 by 0,8", window, 0, 8),
    move("move 800x600 by 0,-8", window, 0, -8),
    move("move 800x600 by 0,1", window, 0, 1),
    move("move 800x600 by 1,0", window, 1, 0),
    move("move 700x500 by 7,300", rect(200, 100, 700, 500), 7, 300),
    move("move 700x500 by -7,-300", rect(200, 400, 700, 500), -7, -300),
    move("move 800x600 by 900,0", rect(0, 0, 800, 600), 900, 0),
    .{ .name = "pattern 401x299 at 13,7", .case = .pattern, .area = rect(13, 7, 401, 299) },
    .{ .name = "template 1001x501 at 13,7, from 3,5", .case = .template, .area = rect(13, 7, 1001, 501), .from = rect(3, 5, 0, 0) },
};

fn drawCheck(b: *Bench, check: *const Check, rp: *graphics.RastPort, surface: *const rtg.Surface) void {
    const area = check.area;
    switch (check.case) {
        .fill => {
            setPens(b, rp, check.pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.RectFill(rp, &area);
        },
        .blend => {
            setPens(b, rp, check.pen, back_pen, graphics.DRMD_JAM1 | graphics.DRMD_BLEND, false);
            b.gb.RectFill(rp, &area);
        },
        .lay => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.BlendPixelArray(rp, @ptrCast(b.overlay), surface.width * 4, @intFromEnum(check.format), check.from.min_x, check.from.min_y, &area);
        },
        .scale => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, true);
            b.gb.ScalePixelArray(rp, @ptrCast(b.picture), b.picture_width * 4, @intFromEnum(rtg.PixelFormat.bgra32), &check.from, &area);
        },
        .move => {
            setPens(b, rp, fill_pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.BltBitMapRastPort(surface, area.min_x, area.min_y, rp, area.min_x + check.dx, area.min_y + check.dy, area.max_x - area.min_x, area.max_y - area.min_y);
        },
        .pattern => {
            setPens(b, rp, front_pen, back_pen, graphics.DRMD_JAM2, false);
            b.gb.BltPattern(rp, &tile, 2, 16, 16, &area);
        },
        .template => {
            setPens(b, rp, front_pen, back_pen, graphics.DRMD_JAM1, false);
            b.gb.BltTemplate(rp, b.shape, b.shape_pitch, check.from.min_x, check.from.min_y, &area);
        },
    }
}

/// The buffer as a surface: an RtgBitMap is one by pointer.
fn boardSurface(b: *Bench) *const rtg.Surface {
    return @ptrCast(b.bitmap);
}

/// How the buffer and the plain memory differ: pixels that do, and the
/// most any channel is off by.
const Compared = struct { wrong: u32 = 0, worst: u32 = 0, first_x: u32 = 0, first_y: u32 = 0 };

fn compare(b: *Bench) Compared {
    const board = boardSurface(b);
    var result = Compared{};
    var y: u32 = 0;
    while (y < board.height) : (y += 1) {
        const one: [*]const u32 = @ptrCast(@alignCast(board.pixels.? + @as(usize, y) * board.pitch));
        const two: [*]const u32 = @ptrCast(@alignCast(b.plain.pixels.? + @as(usize, y) * b.plain.pitch));
        var x: u32 = 0;
        while (x < board.width) : (x += 1) {
            if (one[x] == two[x]) continue;
            if (result.wrong == 0) {
                result.first_x = x;
                result.first_y = y;
            }
            result.wrong += 1;
            var shift: u5 = 0;
            while (true) : (shift += 8) {
                const p: i32 = @intCast(one[x] >> shift & 0xFF);
                const q: i32 = @intCast(two[x] >> shift & 0xFF);
                result.worst = @max(result.worst, @abs(p - q));
                if (shift == 24) break;
            }
        }
    }
    return result;
}

const names = [_][*:0]const u8{
    "fill 1920x1080",
    "blend 1920x1080, 50%",
    "picture 1920x1080 laid over",
    "scale 2x, 960x540 to 1920x1080",
    "move 800x600 by 16,8",
    "pattern 16x16 over 1920x1080",
    "template 1920x1080",
};

/// One case: timed over `rounds`, then checked. Whether it was right.
fn runCase(b: *Bench, case: Case, rounds: u32) bool {
    const board = boardSurface(b);
    paint(board, 1);
    const start = now(b.tb);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) draw(b, case, b.board_rp, board, round);
    const took = now(b.tb) - start;
    const us = took / rounds;

    paint(board, 2);
    paint(&b.plain, 2);
    draw(b, case, b.board_rp, board, 0);
    draw(b, case, b.plain_rp, &b.plain, 0);
    const result = compare(b);
    _ = Printf(b.dl, "%-32s %4lu.%03lu ms  %s\n", .{
        names[@intFromEnum(case)], us / 1000, us % 1000, verdict(result),
    });
    return told(b, result);
}

/// One case that is not whole and even, drawn once and checked.
fn runCheck(b: *Bench, check: *const Check) bool {
    const board = boardSurface(b);
    paint(board, 3);
    paint(&b.plain, 3);
    drawCheck(b, check, b.board_rp, board);
    drawCheck(b, check, b.plain_rp, &b.plain);
    const result = compare(b);
    _ = Printf(b.dl, "%-40s %s\n", .{ check.name, verdict(result) });
    return told(b, result);
}

fn verdict(result: Compared) [*:0]const u8 {
    return if (result.wrong == 0) "ok" else "WRONG";
}

/// How a wrong one was, said; whether it was right.
fn told(b: *Bench, result: Compared) bool {
    if (result.wrong != 0) _ = Printf(b.dl, "  %u pixels differ, the first at %u,%u, by up to %u\n", .{
        result.wrong, result.first_x, result.first_y, result.worst,
    });
    return result.wrong == 0;
}

/// A write-back over the buffer's first bytes.
const Flush = struct { name: [*:0]const u8, size: u32, dirty: bool, pre_dma: bool = false };

const flush_cases = [_]Flush{
    .{ .name = "CacheClearE 64 KiB, dirty", .size = 64 << 10, .dirty = true },
    .{ .name = "CacheClearE 64 KiB, clean", .size = 64 << 10, .dirty = false },
    .{ .name = "CacheClearE 128 KiB, dirty", .size = 128 << 10, .dirty = true },
    .{ .name = "CacheClearE 128 KiB, clean", .size = 128 << 10, .dirty = false },
    .{ .name = "CacheClearE 256 KiB, dirty", .size = 256 << 10, .dirty = true },
    .{ .name = "CacheClearE 256 KiB, clean", .size = 256 << 10, .dirty = false },
    .{ .name = "CacheClearE 1 MiB, dirty", .size = 1 << 20, .dirty = true },
    .{ .name = "CacheClearE 1 MiB, clean", .size = 1 << 20, .dirty = false },
    .{ .name = "CacheClearE 4 MiB, dirty", .size = 4 << 20, .dirty = true },
    .{ .name = "CacheClearE 4 MiB, clean", .size = 4 << 20, .dirty = false },
    .{ .name = "CachePreDMA 1 MiB, dirty", .size = 1 << 20, .dirty = true, .pre_dma = true },
};

/// The write-backs alone.
fn flushes(b: *Bench, rounds: u32) void {
    const pixels = b.bitmap.pixels.?;
    for (flush_cases) |case| {
        var took: u64 = 0;
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            if (case.dirty) @memset(pixels[0..case.size], @truncate(round));
            const start = now(b.tb);
            if (case.pre_dma) {
                var length: u32 = case.size;
                _ = b.sys.CachePreDMA(pixels, &length, exec.DMAF_ReadFromRAM);
            } else {
                b.sys.CacheClearE(pixels, case.size, exec.CACRF_ClearD);
            }
            took += now(b.tb) - start;
        }
        const us = took / rounds;
        _ = Printf(b.dl, "%-32s %4lu.%03lu ms\n", .{ case.name, us / 1000, us % 1000 });
    }
    const start = now(b.tb);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) _ = b.rb.RefreshBitMap(b.bitmap, 0, 0);
    const us = (now(b.tb) - start) / rounds;
    _ = Printf(b.dl, "%-32s %4lu.%03lu ms\n", .{ @as([*:0]const u8, "RefreshBitMap 1920x1080"), us / 1000, us % 1000 });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 100;

    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(graphics_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);
    const board = rb.FindBoard(graphics.DISPLAY_BOARD) orelse {
        _ = Printf(dl, "No display board\n", .{});
        return dos.RETURN_FAIL;
    };
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (info.format != .bgra32) {
        _ = Printf(dl, "The display is not 32 bits a pixel\n", .{});
        return dos.RETURN_FAIL;
    }
    const caps = info.caps;
    const B = rtg.boards;
    _ = Printf(dl, "Board %s, %ux%u: engine %s (fill %s, copy %s, blend %s, scale %s, pattern %s, template %s)\n", .{
        info.driver orelse "?",
        info.width,
        info.height,
        yes(caps & B.RTGBC_ENGINE),
        yes(caps & B.RTGBC_FILL_RECT),
        yes(caps & B.RTGBC_COPY_RECT),
        yes(caps & B.RTGBC_BLEND_RECT),
        yes(caps & B.RTGBC_SCALE_PIXELS),
        yes(caps & B.RTGBC_BLIT_PATTERN),
        yes(caps & B.RTGBC_BLIT_TEMPLATE),
    });

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);

    const bitmap = rb.AllocBitMap(board, info.width, info.height, @intFromEnum(rtg.PixelFormat.bgra32), 0) orelse {
        _ = Printf(dl, "No buffer free on the board\n", .{});
        return dos.RETURN_FAIL;
    };
    defer rb.FreeBitMap(bitmap);
    const bytes: usize = @as(usize, bitmap.pitch) * bitmap.height;
    const plain_memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(plain_memory);
    const picture_width = info.width / 2;
    const picture_height = info.height / 2;
    const picture_memory = sys.AllocVec(picture_width * picture_height * 4, exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(picture_memory);
    const overlay_memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(overlay_memory);
    const shape_pitch = (info.width + 7) / 8;
    const shape_memory = sys.AllocVec(shape_pitch * info.height, exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(shape_memory);

    var b = Bench{
        .sys = sys,
        .dl = dl,
        .gb = gb,
        .rb = rb,
        .tb = @ptrCast(timer_req.node.device.?),
        .bitmap = bitmap,
        .board_rp = undefined,
        .plain = .{ .pixels = @ptrCast(plain_memory), .width = bitmap.width, .height = bitmap.height, .pitch = bitmap.pitch, .size_bytes = bytes, .format = .bgra32 },
        .plain_rp = undefined,
        .picture = @ptrCast(@alignCast(picture_memory)),
        .picture_width = picture_width,
        .picture_height = picture_height,
        .overlay = @ptrCast(@alignCast(overlay_memory)),
        .shape = @ptrCast(shape_memory),
        .shape_pitch = shape_pitch,
    };
    const board_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} };
    b.board_rp = gb.CreateRastPortTagList(&board_tags) orelse return noMemory(dl);
    defer gb.FreeRastPort(b.board_rp);
    const plain_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&b.plain) }, .{} };
    b.plain_rp = gb.CreateRastPortTagList(&plain_tags) orelse return noMemory(dl);
    defer gb.FreeRastPort(b.plain_rp);
    paintPicture(b.picture, picture_width, picture_height);
    paintOverlay(b.overlay, info.width, info.height);
    paintShape(b.shape, shape_pitch, info.width, info.height);

    _ = Printf(dl, "%u rounds each, the time one takes:\n", .{rounds});
    var failures: u32 = 0;
    for ([_]Case{ .fill, .blend, .lay, .scale, .move, .pattern, .template }) |case| {
        if (!runCase(&b, case, rounds)) failures += 1;
    }
    flushes(&b, rounds);
    _ = Printf(dl, "Drawn once each and checked:\n", .{});
    for (&checks) |*check| {
        if (!runCheck(&b, check)) failures += 1;
    }
    return if (failures == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

fn yes(bit: u32) [*:0]const u8 {
    return if (bit != 0) "yes" else "no";
}

fn noMemory(dl: *DosBase) i32 {
    _ = Printf(dl, "Not enough memory\n", .{});
    return dos.RETURN_FAIL;
}
