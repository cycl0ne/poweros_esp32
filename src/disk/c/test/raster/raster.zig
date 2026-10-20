// SPDX-License-Identifier: MIT
//! Raster: facet.library's rasterizer core drawing on the display, timed
//! and checked. Built against the SDK and the core itself, which is
//! compiled in.
//!
//!   Raster ROUNDS/K/N,HOLD/K/N
//!
//! It opens a screen of its own and draws in its buffer. Each case is
//! drawn ROUNDS times (100 if not given) and the time one takes is
//! printed; then the buffer and plain memory beside it are painted alike,
//! the case is drawn once into the buffer by the core and once into the
//! plain memory by graphics.library in software, and the two are compared
//! pixel by pixel. The screen stays up HOLD seconds at the end (2 if not
//! given), with the last picture drawn on it.
//!
//! The tiles alone: the whole display and an 800 x 600 viewport in its
//! middle filled through the tiles - each tile cleared in a core's own
//! buffer, copied into the display's and handed on - against FillRect
//! over the same rectangle, which fills the display's buffer directly; the
//! difference is what the tiles cost. Then a frame kept from the last with
//! nothing drawn, which has to write no tile at all.
//!
//! Triangles of one colour each, without depth: one whose pixels were
//! worked out by hand, drawn into a corner and checked against them; then
//! 1000 of them, scattered over the viewport, a frame of them drawn
//! ROUNDS times on all the cores and as many on one, with the time each
//! takes to set up, to sort into the tiles and to draw. The frame drawn on
//! all the cores has to be the one drawn on one, to the bit.
//!
//! Depth: two layers of squares over the viewport, the one behind half a
//! square off the other, so that every pixel is covered twice. Drawn
//! without depth, the back layer first, and with depth, the front layer
//! first - where the test keeps the back layer from every pixel - and the
//! back one first, and with the test after the colour; each has to come
//! out as the first did on one core.
//!
//! Textures: the same two layers, each square a quarter of a 256 x 256
//! texture each way - 64 texels over 40 pixels, so its second level -
//! filtered bilinear, with depth: the front layer first, on all the cores
//! and on one, the back one first, and with the test after the colour;
//! then both orders with the depth pre-pass, which shades each pixel once
//! whichever layer comes first.
//! Then nearest in RGB565, and smooth colours, mixed in perspective; and a
//! corridor running away from the eye over the whole viewport, from
//! texels larger than a pixel at its sides to the texture's last level at
//! its end. Each is drawn once on one core into the plain memory, and has
//! to come out the same on all the cores.
//!
//! Large textures: the two layers again, each square a part of its own of
//! one of the textures - a texel of the first level a pixel - the squares
//! dealt out among them in turn, a draw for each texture; once from one
//! texture of 256 x 256, which the L2 holds, and once from four of
//! 1024 x 1024, 45 MB, which it does not: what the cache misses cost. The
//! front layer first and the back one first, which has to come out on all
//! the cores as on one. (8888 kept packed, in 32 bits and spread as it
//! was read, was slower in both: by 5 and 10% with the one texture, by 5
//! and 9% with the four.)

const std = @import("std");
const sdk = @import("sdk");
const raster = @import("raster");
const board = @import("board.zig");
const scenes = @import("scenes.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Raster";
const VERSION_STRING = "\x00$VER: Raster 1.3 (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/K/N,HOLD/K/N";

/// RefreshRect came with this revision.
const rtg_revision = 5;

/// The fill's colour.
const fill_pen: u32 = 0xFF30_60C0;

/// The viewport, in the middle of the display.
const viewport_width = 800;
const viewport_height = 600;

const System = board.System;
const now = board.now;

/// What every case works on.
const Bench = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    tb: *TimerBase,
    system: System,
    /// The screen's buffer, its RastPort, and the plain memory beside it
    /// with a RastPort of its own.
    bitmap: *rtg.RtgBitMap,
    board_rp: *graphics.RastPort,
    plain: rtg.Surface,
    plain_rp: *graphics.RastPort,
    format: raster.Format,
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

/// The buffer as a surface: an RtgBitMap is one by pointer.
fn boardSurface(b: *Bench) *const rtg.Surface {
    return @ptrCast(b.bitmap);
}

/// How the buffer and the plain memory differ: pixels that do, and the
/// first.
const Compared = struct { wrong: u32 = 0, first_x: u32 = 0, first_y: u32 = 0 };

fn compare(b: *Bench) Compared {
    const buffer = boardSurface(b);
    var result = Compared{};
    var y: u32 = 0;
    while (y < buffer.height) : (y += 1) {
        const one: [*]const u32 = @ptrCast(@alignCast(buffer.pixels.? + @as(usize, y) * buffer.pitch));
        const two: [*]const u32 = @ptrCast(@alignCast(b.plain.pixels.? + @as(usize, y) * b.plain.pitch));
        var x: u32 = 0;
        while (x < buffer.width) : (x += 1) {
            if (one[x] == two[x]) continue;
            if (result.wrong == 0) {
                result.first_x = x;
                result.first_y = y;
            }
            result.wrong += 1;
        }
    }
    return result;
}

fn setPen(b: *Bench, rp: *graphics.RastPort, color: u32) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = color },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    b.gb.SetRPAttrs(rp, &tags);
}

fn graphicsRect(area: raster.Rect) graphics.Rect {
    return .{
        .min_x = @intCast(area.x),
        .min_y = @intCast(area.y),
        .max_x = @intCast(area.x + area.width),
        .max_y = @intCast(area.y + area.height),
    };
}

/// A target over `area` of the screen's buffer, or null when there is no
/// memory for one.
fn targetOver(b: *Bench, area: raster.Rect, attachments: raster.Attachments) ?raster.Target {
    const surface = raster.Surface{
        .pixels = b.bitmap.pixels.?,
        .pitch = b.bitmap.pitch,
        .width = b.bitmap.width,
        .height = b.bitmap.height,
        .format = b.format,
    };
    return raster.Target.init(b.system.host(), surface, area, attachments) catch null;
}

fn printTime(b: *Bench, name: [*:0]const u8, us: u64, verdict: [*:0]const u8) void {
    _ = Printf(b.dl, "%-36s %4lu.%03lu ms  %s\n", .{ name, us / 1000, us % 1000, verdict });
}

/// How a wrong one was, said; whether it was right.
fn told(b: *Bench, result: Compared) bool {
    if (result.wrong != 0) _ = Printf(b.dl, "  %u pixels differ, the first at %u,%u\n", .{
        result.wrong, result.first_x, result.first_y,
    });
    return result.wrong == 0;
}

/// `area` filled through the tiles, timed over `rounds` and checked
/// against graphics.library's fill; then the same by FillRect, timed.
/// Whether it was right.
fn fills(b: *Bench, name: [*:0]const u8, by_rect: [*:0]const u8, area: raster.Rect, rounds: u32) bool {
    var target = targetOver(b, area, .{}) orelse return noTarget(b);
    defer target.deinit();
    var done: raster.Finished = .{};
    const start = now(b.tb);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        target.attachments.color.clear = fill_pen ^ (round & 1) * 0x0010_1010;
        target.begin();
        done = target.finish();
    }
    const us = (now(b.tb) - start) / rounds;

    paint(boardSurface(b), 1);
    paint(&b.plain, 1);
    target.attachments.color.clear = fill_pen;
    target.begin();
    _ = target.finish();
    setPen(b, b.plain_rp, fill_pen);
    b.gb.RectFill(b.plain_rp, &graphicsRect(area));
    const result = compare(b);
    printTime(b, name, us, if (result.wrong == 0) "ok" else "WRONG");
    _ = Printf(b.dl, "  %u tiles, %u parts\n", .{ done.tiles, done.parts });
    const right = told(b, result);

    const rect = graphicsRect(area);
    const rect_start = now(b.tb);
    round = 0;
    while (round < rounds) : (round += 1) {
        setPen(b, b.board_rp, fill_pen ^ (round & 1) * 0x0010_1010);
        b.gb.RectFill(b.board_rp, &rect);
    }
    printTime(b, by_rect, (now(b.tb) - rect_start) / rounds, "");
    return right;
}

/// A frame kept from the last with nothing drawn: no tile written.
fn kept(b: *Bench, rounds: u32) bool {
    const whole = raster.Rect{ .width = b.bitmap.width, .height = b.bitmap.height };
    var target = targetOver(b, whole, .{ .color = .{ .load = .keep } }) orelse return noTarget(b);
    defer target.deinit();
    paint(boardSurface(b), 2);
    paint(&b.plain, 2);
    var done: raster.Finished = .{};
    var written: u32 = 0;
    const start = now(b.tb);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        target.begin();
        done = target.finish();
        written += done.tiles;
    }
    const us = (now(b.tb) - start) / rounds;
    const result = compare(b);
    const right = result.wrong == 0 and written == 0;
    printTime(b, "frame kept, nothing drawn", us, if (right) "ok" else "WRONG");
    _ = Printf(b.dl, "  %u tiles written\n", .{written});
    _ = told(b, result);
    return right;
}

const Flat = raster.Pipeline(.{ .color = .flat, .front = .clockwise });

/// Worked out by hand: the triangle (1.5, 1.5), (7.5, 1.5), (1.5, 7.5)
/// has a top edge on the centres of row 1 and a left edge on those of
/// column 1, both its own; its long edge runs through the centres where
/// x + y = 9, which are the triangle's on its other side. So it holds the
/// pixels with column >= 1, row >= 1 and column + row <= 7.
const by_hand = [_][]const u8{
    "................",
    ".######.........",
    ".#####..........",
    ".####...........",
    ".###............",
    ".##.............",
    ".#..............",
    "................",
};

/// Where the triangle worked out by hand is drawn.
const hand_x = 64;
const hand_y = 64;

/// The triangle worked out by hand, drawn into a 16 x 16 corner of the
/// buffer and checked pixel by pixel. Whether it was right.
fn byHand(b: *Bench) bool {
    const side = 16;
    const area = raster.Rect{ .x = hand_x, .y = hand_y, .width = side, .height = side };
    var target = targetOver(b, area, .{ .color = .{ .clear = 0xFF00_0000 } }) orelse return noTarget(b);
    defer target.deinit();
    const pipeline = Flat{ .viewport = .{ .x = hand_x, .y = hand_y, .width = side, .height = side } };
    const color: u32 = 0xFFFF_C000;
    const across: f32 = side;
    const vertices = [_]Flat.Vertex{
        .{ .position = .{ 1.5 * 2 / across - 1, 1.5 * 2 / across - 1, 0.5 }, .color = color },
        .{ .position = .{ 7.5 * 2 / across - 1, 1.5 * 2 / across - 1, 0.5 }, .color = color },
        .{ .position = .{ 1.5 * 2 / across - 1, 7.5 * 2 / across - 1, 0.5 }, .color = color },
    };
    target.begin();
    raster.draw(&target, &pipeline, &vertices, &[_]u16{ 0, 1, 2 }) catch return noTarget(b);
    _ = target.finish();
    const pixel = b.format.pack(color);
    var wrong: u32 = 0;
    for (0..side) |y| {
        const row: [*]const u32 = @ptrCast(@alignCast(b.bitmap.pixels.? + (hand_y + y) * b.bitmap.pitch));
        for (0..side) |x| {
            const want = y < by_hand.len and by_hand[y][x] == '#';
            if (want != (row[hand_x + x] == pixel)) wrong += 1;
        }
    }
    _ = Printf(b.dl, "%-36s            %s\n", .{ @as([*:0]const u8, "triangle worked out by hand"), @as([*:0]const u8, if (wrong == 0) "ok" else "WRONG") });
    if (wrong != 0) _ = Printf(b.dl, "  %u pixels differ\n", .{wrong});
    return wrong == 0;
}

/// How many triangles are scattered, and how far a vertex lies from the
/// triangle's middle at most, in pixels.
const scattered_count = 1000;
const scattered_reach = 40;

/// The 1000 triangles: each round its middle anywhere in the viewport and
/// its corners round it, a colour of its own.
fn scatter(vertices: *[scattered_count * 3]Flat.Vertex, indices: *[scattered_count * 3]u16) void {
    var seed: u32 = 0x2545_F491;
    for (0..scattered_count) |i| {
        const middle_x = @as(f32, @floatFromInt(next(&seed) % viewport_width));
        const middle_y = @as(f32, @floatFromInt(next(&seed) % viewport_height));
        const color = 0xFF00_0000 | next(&seed) & 0x00FF_FFFF;
        var corners: [3][2]f32 = undefined;
        for (&corners) |*corner| {
            corner[0] = middle_x + @as(f32, @floatFromInt(next(&seed) % (2 * scattered_reach))) - scattered_reach;
            corner[1] = middle_y + @as(f32, @floatFromInt(next(&seed) % (2 * scattered_reach))) - scattered_reach;
        }
        // Clockwise on the screen, the pipeline's front, so none is culled.
        const twice = (corners[1][0] - corners[0][0]) * (corners[2][1] - corners[0][1]) - (corners[1][1] - corners[0][1]) * (corners[2][0] - corners[0][0]);
        if (twice < 0) std.mem.swap([2]f32, &corners[1], &corners[2]);
        for (corners, 0..) |corner, k| {
            vertices[i * 3 + k] = .{ .position = .{ corner[0] * 2 / viewport_width - 1, corner[1] * 2 / viewport_height - 1, 0.5 }, .color = color };
            indices[i * 3 + k] = @intCast(i * 3 + k);
        }
    }
}

fn next(seed: *u32) u32 {
    seed.* ^= seed.* << 13;
    seed.* ^= seed.* >> 17;
    seed.* ^= seed.* << 5;
    return seed.*;
}

/// What a frame of the scattered triangles took, a frame on average.
const Timed = struct {
    total_us: u64 = 0,
    setup_us: u64 = 0,
    binning_us: u64 = 0,
    stats: raster.Stats = .{},
    done: raster.Finished = .{},
};

/// A frame of `vertices` drawn `rounds` times.
fn drawFrames(target: *raster.Target, pipeline: anytype, vertices: []const @TypeOf(pipeline.*).Vertex, indices: []const u16, rounds: u32, tb: *TimerBase) ?Timed {
    var timed = Timed{};
    const start = now(tb);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        target.begin();
        raster.draw(target, pipeline, vertices, indices) catch return null;
        timed.setup_us += target.stats.setup_us;
        timed.binning_us += target.stats.binning_us;
        timed.stats = target.stats;
        timed.done = target.finish();
    }
    timed.total_us = (now(tb) - start) / rounds;
    timed.setup_us /= rounds;
    timed.binning_us /= rounds;
    return timed;
}

fn printTimed(b: *Bench, name: [*:0]const u8, timed: Timed, triangles: u32, verdict: [*:0]const u8) void {
    printTime(b, name, timed.total_us, verdict);
    const drawing = timed.total_us -| (timed.setup_us + timed.binning_us);
    const per_triangle_ns = timed.total_us * 1000 / triangles;
    _ = Printf(b.dl, "  set up %lu.%03lu ms, binned %lu.%03lu ms (%lu%%), tiles %lu.%03lu ms; %lu ns a triangle\n", .{
        timed.setup_us / 1000,
        timed.setup_us % 1000,
        timed.binning_us / 1000,
        timed.binning_us % 1000,
        if (timed.total_us == 0) @as(u64, 0) else timed.binning_us * 100 / timed.total_us,
        drawing / 1000,
        drawing % 1000,
        per_triangle_ns,
    });
}

/// 1000 triangles over the viewport, on every core and on one. Whether
/// the two came out alike.
fn scattered(b: *Bench, rounds: u32) bool {
    const memory = b.sys.AllocVec(@sizeOf([scattered_count * 3]Flat.Vertex) + @sizeOf([scattered_count * 3]u16), exec.MEMF_ANY) orelse return noTarget(b);
    defer b.sys.FreeVec(memory);
    const vertices: *[scattered_count * 3]Flat.Vertex = @ptrCast(@alignCast(memory));
    const indices: *[scattered_count * 3]u16 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf([scattered_count * 3]Flat.Vertex)));
    scatter(vertices, indices);

    const area = viewportArea(b);
    const attachments = raster.Attachments{ .color = .{ .clear = 0xFF10_1020 } };
    const pipeline = Flat{ .viewport = viewportOf(area) };
    var plain_target = raster.Target.init(b.system.alone(), .{
        .pixels = b.plain.pixels.?,
        .pitch = b.plain.pitch,
        .width = b.plain.width,
        .height = b.plain.height,
        .format = b.format,
    }, area, attachments) catch return noTarget(b);
    defer plain_target.deinit();
    paint(&b.plain, 3);
    paint(boardSurface(b), 3);
    const one = drawFrames(&plain_target, &pipeline, vertices, indices, rounds, b.tb) orelse return noTarget(b);

    var target = targetOver(b, area, attachments) orelse return noTarget(b);
    defer target.deinit();
    const all = drawFrames(&target, &pipeline, vertices, indices, rounds, b.tb) orelse return noTarget(b);
    const result = compare(b);
    printTimed(b, "1000 triangles, 800x600, all cores", all, scattered_count, if (result.wrong == 0) "ok" else "WRONG");
    _ = Printf(b.dl, "  %u set up, %u dropped, %u cut, %u places on %u tiles, %u parts\n", .{
        all.stats.set_up, all.stats.dropped, all.stats.cut, all.stats.binned, all.done.tiles, all.done.parts,
    });
    printTimed(b, "1000 triangles, 800x600, one core", one, scattered_count, "");
    return told(b, result);
}

/// Pipelines with depth: tested before a pixel's colour, and after.
const Deep = raster.Pipeline(.{ .color = .flat, .front = .clockwise, .depth = .less });
const DeepLate = raster.Pipeline(.{ .color = .flat, .front = .clockwise, .depth = .less, .early_depth = false });

/// Two layers of squares over the viewport, the one behind half a square
/// off the front one's grid and one more each way: every pixel covered
/// twice, by the front layer nearer.
const square = 40;
const front_columns = viewport_width / square;
const front_rows = viewport_height / square;
const front_squares = front_columns * front_rows;
const layered_squares = front_squares + (front_columns + 1) * (front_rows + 1);
const layered_triangles = layered_squares * 2;
const front_depth: f32 = 0.3;
const back_depth: f32 = 0.6;

/// The squares' corners, four each, the front layer's first. A square's
/// colour is its first corner's, the others' a little off it; it has a
/// quarter of the texture each way, a quarter on from its neighbours'.
fn layers(comptime Vertex: type, vertices: *[layered_squares * 4]Vertex) void {
    var at: usize = 0;
    for ([_]f32{ 0, -square / 2 }, [_]f32{ front_depth, back_depth }, [_]u32{ 0, 1 }) |offset, depth, more| {
        for (0..front_rows + more) |row| for (0..front_columns + more) |column| {
            const left = offset + @as(f32, @floatFromInt(column * square));
            const top = offset + @as(f32, @floatFromInt(row * square));
            const color = patternAt(@intCast(column), @intCast(row), 4 + more);
            const u = @as(f32, @floatFromInt(column % 4)) / 4;
            const v = @as(f32, @floatFromInt(row % 4)) / 4;
            // Clockwise on the screen.
            const corners = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
            for (corners, 0..) |corner, k| {
                const position = [3]f32{ (left + corner[0] * square) * 2 / viewport_width - 1, (top + corner[1] * square) * 2 / viewport_height - 1, depth };
                const off = @as(u32, @intCast(k)) * 0x0030_5070;
                vertices[at] = scenes.vertexOf(Vertex, position, color ^ off, .{ u + corner[0] / 4, v + corner[1] / 4 });
                at += 1;
            }
        };
    }
}

/// The squares' triangles, the front layer first or the back one.
fn layerIndices(indices: *[layered_triangles * 3]u16, front_first: bool) void {
    var at: usize = 0;
    for (0..layered_squares) |i| {
        const which = if (front_first) i else (i + front_squares) % layered_squares;
        const first: u16 = @intCast(which * 4);
        for ([_]u16{ 0, 1, 2, 0, 2, 3 }) |corner| {
            indices[at] = first + corner;
            at += 1;
        }
    }
}

/// The viewport in the middle of the display.
fn viewportArea(b: *Bench) raster.Rect {
    return .{
        .x = (b.bitmap.width - viewport_width) / 2,
        .y = (b.bitmap.height - viewport_height) / 2,
        .width = viewport_width,
        .height = viewport_height,
    };
}

fn viewportOf(area: raster.Rect) raster.Viewport {
    return .{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y), .width = viewport_width, .height = viewport_height };
}

/// Overdraw 2: the two layers without depth, the back one first, on one
/// core into plain memory - what every case has to come out as - and on
/// all the cores; then with depth on all the cores, the front layer first
/// and the back one, and with the test after the colour. Whether each
/// came out right.
fn overdraw(b: *Bench, rounds: u32) bool {
    const Kinds = struct { flat: [layered_squares * 4]Flat.Vertex, deep: [layered_squares * 4]Deep.Vertex, late: [layered_squares * 4]DeepLate.Vertex, front_first: [layered_triangles * 3]u16, back_first: [layered_triangles * 3]u16 };
    const kinds: *Kinds = @ptrCast(@alignCast(b.sys.AllocVec(@sizeOf(Kinds), exec.MEMF_ANY) orelse return noTarget(b)));
    defer b.sys.FreeVec(kinds);
    layers(Flat.Vertex, &kinds.flat);
    layers(Deep.Vertex, &kinds.deep);
    layers(DeepLate.Vertex, &kinds.late);
    layerIndices(&kinds.front_first, true);
    layerIndices(&kinds.back_first, false);

    const area = viewportArea(b);
    const viewport = viewportOf(area);
    const clear = raster.Attachments.Color{ .clear = 0xFF10_1020 };
    var plain_target = raster.Target.init(b.system.alone(), .{
        .pixels = b.plain.pixels.?,
        .pitch = b.plain.pitch,
        .width = b.plain.width,
        .height = b.plain.height,
        .format = b.format,
    }, area, .{ .color = clear }) catch return noTarget(b);
    defer plain_target.deinit();
    paint(&b.plain, 5);
    paint(boardSurface(b), 5);
    const flat = Flat{ .viewport = viewport };
    _ = drawFrames(&plain_target, &flat, &kinds.flat, &kinds.back_first, 1, b.tb) orelse return noTarget(b);

    var right = true;
    {
        var target = targetOver(b, area, .{ .color = clear }) orelse return noTarget(b);
        defer target.deinit();
        const timed = drawFrames(&target, &flat, &kinds.flat, &kinds.back_first, rounds, b.tb) orelse return noTarget(b);
        right = layered(b, "overdraw 2, no depth, back first", timed) and right;
    }
    var target = targetOver(b, area, .{ .color = clear, .depth = .{ .used = true } }) orelse return noTarget(b);
    defer target.deinit();
    const deep = Deep{ .viewport = viewport };
    const late = DeepLate{ .viewport = viewport };
    const front_first = drawFrames(&target, &deep, &kinds.deep, &kinds.front_first, rounds, b.tb) orelse return noTarget(b);
    right = layered(b, "overdraw 2, depth, front first", front_first) and right;
    const back_first = drawFrames(&target, &deep, &kinds.deep, &kinds.back_first, rounds, b.tb) orelse return noTarget(b);
    right = layered(b, "overdraw 2, depth, back first", back_first) and right;
    const late_first = drawFrames(&target, &late, &kinds.late, &kinds.front_first, rounds, b.tb) orelse return noTarget(b);
    right = layered(b, "overdraw 2, depth after, front first", late_first) and right;
    return right;
}

/// A case of the layers timed, and checked against the plain memory.
fn layered(b: *Bench, name: [*:0]const u8, timed: Timed) bool {
    const result = compare(b);
    printTimed(b, name, timed, layered_triangles, if (result.wrong == 0) "ok" else "WRONG");
    return told(b, result);
}

/// Pipelines whose colour changes over a triangle, with depth, and the
/// corridor's, which needs none: nothing in it is in front of anything.
const Pictured = raster.Pipeline(.{ .color = .texture, .front = .clockwise, .depth = .less });
const PicturedLate = raster.Pipeline(.{ .color = .texture, .front = .clockwise, .depth = .less, .early_depth = false });
const PicturedFirst = raster.Pipeline(.{ .color = .texture, .front = .clockwise, .depth = .less, .prepass = true });
const Nearest = raster.Pipeline(.{ .color = .texture, .sampling = .{ .format = .rgb565, .filter = .nearest }, .front = .clockwise, .depth = .less });
const Smooth = raster.Pipeline(.{ .color = .smooth, .front = .clockwise, .depth = .less });
const Corridor = raster.Pipeline(.{ .color = .texture, .cull = .none });

/// The layers textured, nearest in 565 and smooth, and the corridor:
/// whether each came out on all the cores as on one.
fn textured(b: *Bench, rounds: u32) bool {
    const Kinds = struct {
        pictured: [layered_squares * 4]Pictured.Vertex,
        late: [layered_squares * 4]PicturedLate.Vertex,
        first: [layered_squares * 4]PicturedFirst.Vertex,
        nearest: [layered_squares * 4]Nearest.Vertex,
        smooth: [layered_squares * 4]Smooth.Vertex,
        corridor: [scenes.corridor_vertices]Corridor.Vertex,
        front_first: [layered_triangles * 3]u16,
        back_first: [layered_triangles * 3]u16,
    };
    const kinds: *Kinds = @ptrCast(@alignCast(b.sys.AllocVec(@sizeOf(Kinds), exec.MEMF_ANY) orelse return noTarget(b)));
    defer b.sys.FreeVec(kinds);
    const full = b.sys.AllocVec(scenes.textureBytes(.rgba8888), exec.MEMF_ANY) orelse return noTarget(b);
    defer b.sys.FreeVec(full);
    const half = b.sys.AllocVec(scenes.textureBytes(.rgb565), exec.MEMF_ANY) orelse return noTarget(b);
    defer b.sys.FreeVec(half);
    const rgba = scenes.patternTexture(.rgba8888, @ptrCast(full));
    const rgb565 = scenes.patternTexture(.rgb565, @ptrCast(half));
    layers(Pictured.Vertex, &kinds.pictured);
    layers(PicturedLate.Vertex, &kinds.late);
    layers(PicturedFirst.Vertex, &kinds.first);
    layers(Nearest.Vertex, &kinds.nearest);
    layers(Smooth.Vertex, &kinds.smooth);
    kinds.corridor = scenes.corridor(Corridor.Vertex);
    layerIndices(&kinds.front_first, true);
    layerIndices(&kinds.back_first, false);

    const viewport = viewportOf(viewportArea(b));
    const deep = raster.Attachments{ .color = .{ .clear = 0xFF10_1020 }, .depth = .{ .used = true } };
    const pictured = Pictured{ .viewport = viewport, .texture = &rgba };
    const late = PicturedLate{ .viewport = viewport, .texture = &rgba };
    const first = PicturedFirst{ .viewport = viewport, .texture = &rgba };
    const nearest = Nearest{ .viewport = viewport, .texture = &rgb565 };
    const smooth = Smooth{ .viewport = viewport };
    var corridor = Corridor{ .viewport = viewport, .texture = &rgba };
    corridor.transform = scenes.corridorTransform(@as(f32, viewport_width) / viewport_height);
    var right = true;
    right = checked(b, "textured overdraw 2, front first", deep, &pictured, &kinds.pictured, &kinds.front_first, layered_triangles, rounds, rounds) and right;
    right = checked(b, "textured overdraw 2, back first", deep, &pictured, &kinds.pictured, &kinds.back_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "textured overdraw 2, depth after", deep, &late, &kinds.late, &kinds.front_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "textured overdraw 2, pre-pass, front first", deep, &first, &kinds.first, &kinds.front_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "textured overdraw 2, pre-pass, back first", deep, &first, &kinds.first, &kinds.back_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "nearest 565 overdraw 2, front first", deep, &nearest, &kinds.nearest, &kinds.front_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "smooth overdraw 2, front first", deep, &smooth, &kinds.smooth, &kinds.front_first, layered_triangles, rounds, 1) and right;
    right = checked(b, "corridor 800x600, bilinear", .{ .color = .{ .clear = 0xFF10_1020 } }, &corridor, &kinds.corridor, &scenes.corridor_indices, scenes.corridor_triangles, rounds, 1) and right;
    return right;
}

/// A case drawn on one core into the plain memory - `one_rounds` times,
/// and timed when that is more than once - and `rounds` times on all the
/// cores into the buffer, timed: whether the two came out alike.
/// The scenes of large textures: how many textures, their side and their
/// levels.
const Large = struct { count: u32, side: u32, levels: u32, name: [*:0]const u8 };
const large_scenes = [_]Large{
    .{ .count = 1, .side = 256, .levels = 9, .name = "1 texture of 256" },
    .{ .count = 4, .side = 1024, .levels = 11, .name = "4 textures of 1024" },
};
const most_large = 4;

/// The squares' triangles for each layer - the front's, the back's - and
/// each texture, and how many indices each list has.
const LargeLists = struct {
    indices: [2][most_large][layered_triangles * 3]u16,
    counts: [2][most_large]u32,
};

/// Each scene of large textures timed: whether each came out on all the
/// cores as on one.
fn largeTextures(b: *Bench, rounds: u32) bool {
    const Kinds = struct { vertices: [layered_squares * 4]Pictured.Vertex, lists: LargeLists };
    const kinds: *Kinds = @ptrCast(@alignCast(b.sys.AllocVec(@sizeOf(Kinds), exec.MEMF_ANY) orelse return noTarget(b)));
    defer b.sys.FreeVec(kinds);
    layers(Pictured.Vertex, &kinds.vertices);
    var right = true;
    for (large_scenes) |scene| {
        largeLists(&kinds.lists, scene.count);
        largeCoordinates(&kinds.vertices, scene);
        right = largeCase(b, scene, &kinds.vertices, &kinds.lists, rounds) and right;
    }
    return right;
}

/// The squares dealt out among `count` textures in turn, into a list for
/// each layer and texture.
fn largeLists(lists: *LargeLists, count: u32) void {
    lists.counts = @splat(@splat(0));
    for (0..layered_squares) |square_index| {
        const layer: usize = @intFromBool(square_index >= front_squares);
        const k = square_index % count;
        const first: u16 = @intCast(square_index * 4);
        for ([_]u16{ 0, 1, 2, 0, 2, 3 }) |corner| {
            lists.indices[layer][k][lists.counts[layer][k]] = first + corner;
            lists.counts[layer][k] += 1;
        }
    }
}

/// Each square's coordinates: a cell of its own of 40 x 40 texels of its
/// texture's first level, the cells taken row by row - round again once
/// all are.
fn largeCoordinates(vertices: *[layered_squares * 4]Pictured.Vertex, scene: Large) void {
    const per_row = scene.side / square;
    const side: f32 = @floatFromInt(scene.side);
    const corners = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    for (0..layered_squares) |square_index| {
        const cell: u32 = @intCast(square_index / scene.count);
        const u: f32 = @floatFromInt(cell % per_row * square);
        const v: f32 = @floatFromInt(cell / per_row % per_row * square);
        for (corners, 0..) |corner, k| vertices[square_index * 4 + k].uv = .{ (u + corner[0] * square) / side, (v + corner[1] * square) / side };
    }
}

/// A scene's textures made and its frames timed on all the cores, the
/// front layer first and the back one first, the back one first drawn once
/// on one core into the plain memory as well: whether the two came out
/// alike. True, said, where there is no memory for the textures.
fn largeCase(b: *Bench, scene: Large, vertices: []const Pictured.Vertex, lists: *const LargeLists, rounds: u32) bool {
    const bytes = raster.Texture.bytes(.rgba8888, scene.side, scene.side, scene.levels) catch unreachable;
    const memory: [*]u8 = @ptrCast(b.sys.AllocVec(bytes * scene.count, exec.MEMF_ANY) orelse {
        _ = Printf(b.dl, "%s: no memory for the textures\n", .{scene.name});
        return true;
    });
    defer b.sys.FreeVec(memory);
    var textures: [most_large]raster.Texture = undefined;
    for (textures[0..scene.count], 0..) |*made, k| {
        made.* = raster.Texture.init(.rgba8888, scene.side, scene.side, scene.levels, memory + k * bytes) catch unreachable;
        for (0..scene.levels) |lod| {
            const level: u32 = @intCast(lod);
            for (0..made.height(level)) |y| for (0..made.width(level)) |x| {
                made.put(level, @intCast(x), @intCast(y), scenes.patternAt(@intCast(x << @intCast(lod)), @intCast(y << @intCast(lod))) ^ @as(u32, @intCast(k)) * 0x0020_3040);
            };
        }
    }
    const area = viewportArea(b);
    const viewport = viewportOf(area);
    const deep = raster.Attachments{ .color = .{ .clear = 0xFF10_1020 }, .depth = .{ .used = true } };
    var plain_target = raster.Target.init(b.system.alone(), .{
        .pixels = b.plain.pixels.?,
        .pitch = b.plain.pitch,
        .width = b.plain.width,
        .height = b.plain.height,
        .format = b.format,
    }, area, deep) catch return noTarget(b);
    defer plain_target.deinit();
    var target = targetOver(b, area, deep) orelse return noTarget(b);
    defer target.deinit();
    paint(&b.plain, 7);
    paint(boardSurface(b), 7);
    const front_first = [2]usize{ 0, 1 };
    const back_first = [2]usize{ 1, 0 };
    const scene_frames = LargeFrames{ .scene = scene, .viewport = viewport, .textures = &textures, .vertices = vertices, .lists = lists };
    var name: [64]u8 = undefined;
    const front_us = scene_frames.timed(&target, front_first, rounds, b.tb) orelse return noTarget(b);
    printTime(b, std.fmt.bufPrintZ(&name, "{s}, front first", .{std.mem.span(scene.name)}) catch "", front_us, "");
    _ = scene_frames.timed(&plain_target, back_first, 1, b.tb) orelse return noTarget(b);
    const back_us = scene_frames.timed(&target, back_first, rounds, b.tb) orelse return noTarget(b);
    const result = compare(b);
    printTime(b, std.fmt.bufPrintZ(&name, "{s}, back first", .{std.mem.span(scene.name)}) catch "", back_us, if (result.wrong == 0) "ok" else "WRONG");
    return told(b, result);
}

/// A frame of a scene of large textures: a draw for each layer and
/// texture, the layers in the order given.
const LargeFrames = struct {
    scene: Large,
    viewport: raster.Viewport,
    textures: *const [most_large]raster.Texture,
    vertices: []const Pictured.Vertex,
    lists: *const LargeLists,

    /// The microseconds a frame takes, over `rounds`; null when the
    /// frame's memory ran out.
    fn timed(frames: LargeFrames, target: *raster.Target, layers_in_turn: [2]usize, rounds: u32, tb: *TimerBase) ?u64 {
        const start = now(tb);
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            target.begin();
            for (layers_in_turn) |layer| for (0..frames.scene.count) |k| {
                const pipeline = Pictured{ .viewport = frames.viewport, .texture = &frames.textures[k] };
                raster.draw(target, &pipeline, frames.vertices, frames.lists.indices[layer][k][0..frames.lists.counts[layer][k]]) catch return null;
            };
            _ = target.finish();
        }
        return (now(tb) - start) / rounds;
    }
};

fn checked(
    b: *Bench,
    name: [*:0]const u8,
    attachments: raster.Attachments,
    pipeline: anytype,
    vertices: []const @TypeOf(pipeline.*).Vertex,
    indices: []const u16,
    triangles: u32,
    rounds: u32,
    one_rounds: u32,
) bool {
    const area = viewportArea(b);
    var plain_target = raster.Target.init(b.system.alone(), .{
        .pixels = b.plain.pixels.?,
        .pitch = b.plain.pitch,
        .width = b.plain.width,
        .height = b.plain.height,
        .format = b.format,
    }, area, attachments) catch return noTarget(b);
    defer plain_target.deinit();
    paint(&b.plain, 6);
    paint(boardSurface(b), 6);
    const one = drawFrames(&plain_target, pipeline, vertices, indices, one_rounds, b.tb) orelse return noTarget(b);
    var target = targetOver(b, area, attachments) orelse return noTarget(b);
    defer target.deinit();
    const all = drawFrames(&target, pipeline, vertices, indices, rounds, b.tb) orelse return noTarget(b);
    const result = compare(b);
    printTimed(b, name, all, triangles, if (result.wrong == 0) "ok" else "WRONG");
    if (one_rounds > 1) printTimed(b, "  the same on one core", one, triangles, "");
    return told(b, result);
}

fn noTarget(b: *Bench) bool {
    _ = Printf(b.dl, "Not enough memory for a target\n", .{});
    return false;
}

fn attr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 100;
    const hold: u32 = if (argv[1] != 0) @intCast(@max(0, @as(*const i32, @ptrFromInt(argv[1])).*)) else 2;

    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    if (rtg_lib.revision < rtg_revision) {
        _ = Printf(dl, "%s is older than 1.%u\n", .{ rtg.RTGNAME, @as(u32, rtg_revision) });
        return dos.RETURN_FAIL;
    }
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(graphics_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);

    var why: u32 = 0;
    const screen = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Quiet, .data = 1 },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    }) orelse {
        _ = Printf(dl, "No screen (%lu)\n", .{@as(u64, why)});
        return dos.RETURN_FAIL;
    };
    defer _ = ib.CloseScreen(screen);
    defer ib.ScreenToBack(screen);
    const own = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, "No buffer of the screen's\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.FreeScreenBuffer(screen, own);
    const bitmap = own.bitmap;
    const format: raster.Format = switch (bitmap.format) {
        .bgra32 => .bgra32,
        .rgba32 => .rgba32,
        else => {
            _ = Printf(dl, "The display's pixels are %s: C:test/Raster measures 32 bits a pixel, bgra32 or rgba32\n", .{board.pixelsNamed(bitmap.format)});
            return dos.RETURN_FAIL;
        },
    };

    const bytes: usize = @as(usize, bitmap.pitch) * bitmap.height;
    const plain_memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(plain_memory);

    var b = Bench{
        .sys = sys,
        .dl = dl,
        .gb = gb,
        .tb = @ptrCast(timer_req.node.device.?),
        .system = .{ .sys = sys, .rb = rb, .tb = @ptrCast(timer_req.node.device.?), .bitmap = bitmap },
        .bitmap = bitmap,
        .board_rp = own.rast_port,
        .plain = .{ .pixels = @ptrCast(plain_memory), .width = bitmap.width, .height = bitmap.height, .pitch = bitmap.pitch, .size_bytes = bytes, .format = bitmap.format },
        .plain_rp = undefined,
        .format = format,
    };
    const plain_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&b.plain) }, .{} };
    b.plain_rp = gb.CreateRastPortTagList(&plain_tags) orelse return noMemory(dl);
    defer gb.FreeRastPort(b.plain_rp);

    _ = Printf(dl, "Screen %ux%u, %s; tiles of %u, %u rounds each, the time one takes:\n", .{
        bitmap.width,
        bitmap.height,
        @as([*:0]const u8, if (format == .bgra32) "bgra32" else "rgba32"),
        @as(u32, raster.tile_size),
        rounds,
    });
    var failures: u32 = 0;
    const whole = raster.Rect{ .width = bitmap.width, .height = bitmap.height };
    if (!fills(&b, "fill whole by tiles", "fill whole by FillRect", whole, rounds)) failures += 1;
    if (bitmap.width >= viewport_width and bitmap.height >= viewport_height) {
        const viewport = raster.Rect{
            .x = (bitmap.width - viewport_width) / 2,
            .y = (bitmap.height - viewport_height) / 2,
            .width = viewport_width,
            .height = viewport_height,
        };
        if (!fills(&b, "fill 800x600 by tiles", "fill 800x600 by FillRect", viewport, rounds)) failures += 1;
    }
    if (!kept(&b, rounds)) failures += 1;
    if (!byHand(&b)) failures += 1;
    if (bitmap.width >= viewport_width and bitmap.height >= viewport_height) {
        if (!scattered(&b, rounds)) failures += 1;
        if (!overdraw(&b, rounds)) failures += 1;
        if (!textured(&b, rounds)) failures += 1;
        if (!largeTextures(&b, rounds)) failures += 1;
    }

    dl.Delay(hold * 50);
    return if (failures == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

fn noMemory(dl: *DosBase) i32 {
    _ = Printf(dl, "Not enough memory\n", .{});
    return dos.RETURN_FAIL;
}
