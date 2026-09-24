// SPDX-License-Identifier: MIT
//! Anim: a moving picture drawn with every primitive graphics.library has.
//! Built against the SDK only.
//!
//!   Anim FRAMES/N,SCALE/K/N,TIMES/S
//!
//! It runs until Ctrl-C, or for FRAMES frames, and then says how many it
//! drew and how fast. SCALE is how many display pixels a stage pixel
//! becomes, 1 to 4: the stage is the display divided by it, drawn at that
//! size and stretched back up. 2 by default; 1 draws at the display's own
//! size and costs about half the frame rate. TIMES adds a table at the
//! end: what each part of a frame cost, on average, in microseconds of
//! timer.device's E-clock - which is how to find out where a frame goes on
//! a machine rather than guess.
//!
//! Each frame is drawn off the display, into a bitmap of its own, and put
//! on the display in one move - BitMapScale when stretched,
//! BltBitMapRastPort when not. Drawn straight onto the display, every
//! frame would show its own clearing: the background goes down first and
//! everything else after it, and the panel streams whatever is there at
//! that moment. Double buffering is the only way a picture that is cleared
//! and redrawn sixty times a second looks like one that moves.
//!
//! What is in it, back to front:
//!
//! - the sky: a black RectFill, three copper bars of DrawHLine runs
//!   swinging on a sine, and a starfield of WritePixels in three layers at
//!   three speeds
//! - the floor: BltPattern in JAM2, a checkerboard tile whose bits are
//!   rotated each frame, so a pattern anchored to the surface still moves
//! - the lines: a trail of Move/Draw lines bouncing about the right of the
//!   sky, clipped to a region of slats that slides down - venetian blinds
//!   built with NewRegion/OrRectRegion and given with RPTAG_ClipRegion
//! - the left: three DrawArcs turning at different speeds round a
//!   DrawCircle that breathes, and a spinning coin of DrawEllipse
//! - the middle: a star of AreaMove/AreaDraw turning, with an AreaCircle
//!   hole in it that the even-odd fill makes on its own, and its outline
//!   in DrawPoly
//! - the floor's edge: a pac-man of AreaArc chewing through RectFill dots
//! - a ball, drawn once into a bitmap of its own, bouncing with
//!   BltMaskBitMapRastPort so its corners do not show
//! - a pointer stencilled with BltTemplate on a Lissajous path
//! - a scanner: a DrawVLine in DRMD_COMPLEMENT sweeping across everything
//! - the title: a DRMD_BLEND panel measured with TextExtent, a DrawRect
//!   round it, Pospaz 16 in bold with SetSoftStyle
//! - the scroller: Pospaz 8 with a shadow, its style changing with
//!   AskSoftStyle/SetSoftStyle as it goes
//! - marching ants: a DrawRect round the stage whose line pattern turns
//!
//! There is no trigonometry at run time: a sine table of 256 steps is
//! built by the compiler, and an angle here is a step of that table.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const RastPort = graphics.RastPort;
const timer = sdk.devices.timer;
const TimerBase = timer.TimerBase;

pub const COMMAND_NAME = "Anim";
const VERSION_STRING = "\x00$VER: Anim 1.0 (18.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,SCALE/K/N,TIMES/S";
const arg_frames = 0;
const arg_scale = 1;
const arg_times = 2;

const MSG_NOLIBRARY = "No %s - this machine has no drawing layer\n";
const MSG_NODISPLAY = "No display - %s\n";
const MSG_NOSTAGE = "No room for a %dx%d stage - %s\n";
const MSG_BADSCALE = "SCALE must be 1 to 4\n";
const MSG_RUNNING = "Anim %dx%d on %dx%d - Ctrl-C to stop\n";
const MSG_DONE = "%d frames in %d.%02d s\n";
const MSG_RATE = "%d.%d frames a second\n";
const MSG_NOTIMER = "No timer.device - no TIMES\n";
const MSG_TIMES_HEAD = "Part        us/frame   share\n";
const MSG_TIMES_ROW = "%-10s %9d   %3d%%\n";

const scroll_text = "   PowerOS on the ESP32-S3 ... every primitive graphics.library has, " ++
    "in one picture that moves ... lines, runs, circles, ellipses, arcs, polygons, " ++
    "filled shapes with holes, regions, patterns, templates, masks, blends, " ++
    "complement, text in three sizes and four styles ... Ctrl-C to stop   ";

// --- the sine table -------------------------------------------------------

/// A turn in 256 steps, scaled to 1024. Built by the compiler, so nothing
/// at run time needs floating point.
const sine: [256]i32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]i32 = undefined;
    for (0..256) |i| {
        const angle = @as(f64, @floatFromInt(i)) * (2.0 * 3.14159265358979323846) / 256.0;
        table[i] = @intFromFloat(@round(@sin(angle) * 1024.0));
    }
    break :blk table;
};

fn sin(step: i32) i32 {
    return sine[@intCast(step & 255)];
}

fn cos(step: i32) i32 {
    return sine[@intCast((step + 64) & 255)];
}

/// `amount` times the sine of `step`.
fn wave(step: i32, amount: i32) i32 {
    return @divTrunc(sin(step) * amount, 1024);
}

// --- the pieces that do not change ---------------------------------------

/// A pointer, sixteen by sixteen, one bit to a pixel: what BltTemplate
/// stencils in the pen.
const arrow = [_]u8{
    0b1000_0000, 0b0000_0000,
    0b1100_0000, 0b0000_0000,
    0b1110_0000, 0b0000_0000,
    0b1111_0000, 0b0000_0000,
    0b1111_1000, 0b0000_0000,
    0b1111_1100, 0b0000_0000,
    0b1111_1110, 0b0000_0000,
    0b1111_1111, 0b0000_0000,
    0b1111_1111, 0b1000_0000,
    0b1111_1100, 0b0000_0000,
    0b1101_1110, 0b0000_0000,
    0b1000_1110, 0b0000_0000,
    0b0000_0111, 0b0000_0000,
    0b0000_0111, 0b0000_0000,
    0b0000_0011, 0b1000_0000,
    0b0000_0000, 0b0000_0000,
};

const ball_size = 32;
const ball_radius = 15;
const ball_pitch = ball_size / 8;

/// Which pixels of the ball's square are ball: the same test the fill
/// uses, so the mask and the picture agree to the pixel.
const ball_mask: [ball_size * ball_pitch]u8 = blk: {
    @setEvalBranchQuota(10000);
    var mask = [_]u8{0} ** (ball_size * ball_pitch);
    for (0..ball_size) |y| {
        for (0..ball_size) |x| {
            const dx = @as(i32, @intCast(x)) - ball_size / 2;
            const dy = @as(i32, @intCast(y)) - ball_size / 2;
            if (dx * dx + dy * dy <= ball_radius * ball_radius) {
                mask[y * ball_pitch + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
            }
        }
    }
    break :blk mask;
};

const star_count = 90;
const trail_length = 14;

// --- the state that does -------------------------------------------------

const Star = struct { x: i32, y: i32 };
const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// Everything that moves, in one place on the program's stack.
const Scene = struct {
    w: i32,
    h: i32,
    horizon: i32,
    stars: [star_count]Star,
    seed: u32,
    trail: [trail_length]Line,
    head: Line,
    velocity: [4]i32,
    ball_x: i32,
    ball_y: i32,
    ball_vx: i32,
    ball_vy: i32,

    fn random(s: *Scene, below: i32) i32 {
        s.seed = s.seed *% 1103515245 +% 12345;
        return @intCast((s.seed >> 16) % @as(u32, @intCast(below)));
    }

    fn init(s: *Scene, w: i32, h: i32) void {
        s.w = w;
        s.h = h;
        s.horizon = @divTrunc(h * 3, 4);
        s.seed = 0x5EED;
        for (&s.stars) |*star| {
            star.* = .{ .x = s.random(w), .y = s.random(s.horizon) };
        }
        const left = @divTrunc(w * 2, 3);
        s.head = .{
            .x0 = left + 10,
            .y0 = 30,
            .x1 = w - 30,
            .y1 = s.horizon - 30,
        };
        s.velocity = .{ 3, 2, -2, -3 };
        s.trail = @splat(s.head);
        s.ball_x = @divTrunc(w, 3);
        s.ball_y = 20;
        s.ball_vx = 3;
        s.ball_vy = 0;
    }

    /// One step of everything that moves on its own.
    fn step(s: *Scene) void {
        for (&s.stars, 0..) |*star, i| {
            star.x -= @as(i32, @intCast(i % 3)) + 1;
            if (star.x < 0) {
                star.x += s.w;
                star.y = s.random(s.horizon);
            }
        }

        // The lines bounce inside the right third of the sky.
        const left = @divTrunc(s.w * 2, 3);
        var ends = [4]*i32{ &s.head.x0, &s.head.y0, &s.head.x1, &s.head.y1 };
        for (&ends, 0..) |end, i| {
            end.* += s.velocity[i];
            const low = if (i % 2 == 0) left else 4;
            const high = if (i % 2 == 0) s.w - 4 else s.horizon - 4;
            if (end.* < low or end.* > high) {
                s.velocity[i] = -s.velocity[i];
                end.* = @max(low, @min(high, end.*));
            }
        }
        var i: usize = trail_length - 1;
        while (i > 0) : (i -= 1) s.trail[i] = s.trail[i - 1];
        s.trail[0] = s.head;

        // The ball falls, and bounces off the floor with the same speed
        // each time, so it never settles.
        s.ball_vy += 1;
        s.ball_x += s.ball_vx;
        s.ball_y += s.ball_vy;
        if (s.ball_y + ball_size >= s.horizon) {
            s.ball_y = s.horizon - ball_size;
            s.ball_vy = -14;
        }
        if (s.ball_x < 0 or s.ball_x + ball_size > s.w) {
            s.ball_vx = -s.ball_vx;
            s.ball_x = @max(0, @min(s.w - ball_size, s.ball_x));
        }
    }
};

// --- small helpers ---------------------------------------------------------

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

fn pen(gb: *GraphicsBase, rp: *RastPort, value: Pen) void {
    set(gb, rp, graphics.RPTAG_APen, value);
}

fn mode(gb: *GraphicsBase, rp: *RastPort, value: graphics.DrawMode) void {
    set(gb, rp, graphics.RPTAG_DrMd, value);
}

/// A colour round the wheel: `step` is 0..255 of a turn.
fn hue(step: i32) Pen {
    const r = 128 + wave(step, 127);
    const g = 128 + wave(step + 85, 127);
    const b = 128 + wave(step + 170, 127);
    return graphics.penRGB(@intCast(r), @intCast(g), @intCast(b));
}

fn rotl16(value: u16, by: u32) u16 {
    const n: u4 = @intCast(by & 15);
    if (n == 0) return value;
    return (value << n) | (value >> @intCast(@as(u5, 16) - n));
}

fn rotl8(value: u8, by: u32) u8 {
    const n: u3 = @intCast(by & 7);
    if (n == 0) return value;
    return (value << n) | (value >> @intCast(@as(u4, 8) - n));
}

fn textLen(s: []const u8) u32 {
    return @intCast(s.len);
}

// --- the frame ------------------------------------------------------------

const Fonts = struct {
    title: ?*graphics.TextFont,
    scroller: ?*graphics.TextFont,
};

fn drawSky(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, graphics.penRGB(0, 0, 16));
    gb.RectFill(rp, &.{ .max_x = s.w, .max_y = s.horizon });

    // Three copper bars, each a run of lines brightest in the middle.
    const tints = [_][3]u8{ .{ 255, 40, 40 }, .{ 40, 255, 80 }, .{ 60, 120, 255 } };
    for (tints, 0..) |tint, k| {
        const middle = @divTrunc(s.horizon, 2) + wave(t * 2 + @as(i32, @intCast(k)) * 40, @divTrunc(s.horizon, 3));
        var row: i32 = -8;
        while (row < 8) : (row += 1) {
            const bright: u32 = @intCast(255 - @as(i32, @intCast(@abs(row))) * 30);
            pen(gb, rp, graphics.penRGB(
                @intCast(tint[0] * bright / 255),
                @intCast(tint[1] * bright / 255),
                @intCast(tint[2] * bright / 255),
            ));
            gb.DrawHLine(rp, 0, middle + row, s.w);
        }
    }

    // The stars, nearest brightest and fastest.
    const shades = [_]Pen{ graphics.penRGB(90, 90, 110), graphics.penRGB(170, 170, 190), graphics.penRGB(255, 255, 255) };
    for (shades, 0..) |shade, layer| {
        pen(gb, rp, shade);
        for (s.stars, 0..) |star, i| {
            if (i % 3 == layer) gb.WritePixel(rp, star.x, star.y);
        }
    }
}

fn drawFloor(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    // A checkerboard of four-pixel squares, its bits turned by the frame
    // count: the tile is anchored to the surface, so moving the pattern
    // means moving the bits.
    const shift: u32 = @intCast(@mod(t, 8));
    var tile: [8]u8 = undefined;
    for (&tile, 0..) |*row, y| {
        const base: u8 = if (((y + shift) / 4) % 2 == 0) 0xF0 else 0x0F;
        row.* = rotl8(base, shift);
    }
    const colours = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(90, 40, 130) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(30, 10, 50) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{},
    };
    gb.SetRPAttrs(rp, &colours);
    gb.BltPattern(rp, &tile, 1, 8, 8, &.{ .min_y = s.horizon, .max_x = s.w, .max_y = s.h });

    // The edge of the world.
    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, graphics.penRGB(200, 120, 255));
    gb.DrawHLine(rp, 0, s.horizon, s.w);
}

fn drawLines(gb: *GraphicsBase, rp: *RastPort, s: *Scene, slats: ?*graphics.Region, t: i32) void {
    // Blinds: slats of the right third, sliding down a pixel a frame.
    if (slats) |region| {
        gb.ClearRegion(region);
        const left = @divTrunc(s.w * 2, 3);
        var y: i32 = @mod(t, 12) - 12;
        while (y < s.horizon) : (y += 12) {
            _ = gb.OrRectRegion(region, &.{ .min_x = left, .min_y = @max(0, y), .max_x = s.w, .max_y = @min(s.horizon, y + 8) });
        }
        set(gb, rp, graphics.RPTAG_ClipRegion, @intFromPtr(region));
    }
    var i: usize = trail_length;
    while (i > 0) {
        i -= 1;
        const line = s.trail[i];
        pen(gb, rp, hue(t * 3 + @as(i32, @intCast(i)) * 6));
        gb.Move(rp, line.x0, line.y0);
        gb.Draw(rp, line.x1, line.y1);
    }
    if (slats != null) set(gb, rp, graphics.RPTAG_ClipRegion, 0);
}

fn drawLeft(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const cx = @divTrunc(s.w, 6);
    const cy = @divTrunc(s.horizon, 2);

    // A circle that breathes.
    pen(gb, rp, graphics.penRGB(255, 255, 255));
    gb.DrawCircle(rp, cx, cy, 14 + wave(t * 4, 5));

    // Three arcs, a third of a turn each, turning at three speeds and
    // two directions.
    const arcs = [_]struct { r: i32, speed: i32, tint: Pen }{
        .{ .r = 24, .speed = 7, .tint = graphics.penRGB(255, 80, 80) },
        .{ .r = 32, .speed = -5, .tint = graphics.penRGB(80, 255, 120) },
        .{ .r = 40, .speed = 3, .tint = graphics.penRGB(80, 160, 255) },
    };
    for (arcs) |arc| {
        pen(gb, rp, arc.tint);
        const from = @mod(t * arc.speed, 360);
        gb.DrawArc(rp, cx, cy, arc.r, from, from + 120);
        gb.DrawArc(rp, cx, cy, arc.r + 1, from, from + 120);
        gb.DrawArc(rp, cx, cy, arc.r, from + 180, from + 240);
    }

    // A coin spinning on its edge: an ellipse whose width is a cosine.
    const coin_x = cx;
    const coin_y = @divTrunc(s.horizon * 5, 6);
    const rx = @as(i32, @intCast(@abs(wave(t * 3 + 64, 20)))) + 1;
    pen(gb, rp, graphics.penRGB(255, 210, 60));
    gb.DrawEllipse(rp, coin_x, coin_y, rx, 20);
    gb.DrawEllipse(rp, coin_x, coin_y, @max(rx - 4, 0), 16);
}

fn drawStar(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const cx = @divTrunc(s.w, 2) - @divTrunc(s.w, 12);
    const cy = @divTrunc(s.horizon, 2);
    const reach = @divTrunc(s.horizon, 3) + wave(t * 2, 8);

    // Ten corners, every other one pulled in: a five-pointed star,
    // turning a step a frame.
    var corners: [11]graphics.Point = undefined;
    for (0..10) |i| {
        const angle = t + @divTrunc(@as(i32, @intCast(i)) * 256, 10);
        const far = if (i % 2 == 0) reach else @divTrunc(reach * 2, 5);
        corners[i] = .{
            .x = cx + @divTrunc(cos(angle) * far, 1024),
            .y = cy + @divTrunc(sin(angle) * far, 1024),
        };
    }
    corners[10] = corners[0];

    // Filled, with a hole the even-odd rule cuts on its own.
    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, hue(t));
    _ = gb.AreaMove(rp, corners[0].x, corners[0].y);
    for (corners[1..10]) |corner| _ = gb.AreaDraw(rp, corner.x, corner.y);
    _ = gb.AreaCircle(rp, cx, cy, @divTrunc(reach, 5));
    _ = gb.AreaEnd(rp);

    // And its outline over the top.
    pen(gb, rp, graphics.penRGB(255, 255, 255));
    gb.Move(rp, corners[0].x, corners[0].y);
    gb.DrawPoly(rp, 10, corners[1..].ptr);
}

fn drawPacman(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const span = s.w + 60;
    const x = @mod(t * 2, span) - 30;
    const y = s.horizon + @divTrunc(s.h - s.horizon, 2);
    const radius: i32 = 14;

    // The dots it has not reached yet.
    pen(gb, rp, graphics.penRGB(255, 220, 180));
    var dot: i32 = 12;
    while (dot < s.w) : (dot += 24) {
        if (dot > x + 4) gb.RectFill(rp, &.{ .min_x = dot - 2, .min_y = y - 2, .max_x = dot + 2, .max_y = y + 2 });
    }

    // A wedge whose mouth opens and shuts.
    const mouth = @as(i32, @intCast(@abs(wave(t * 8, 40)))) + 2;
    pen(gb, rp, graphics.penRGB(255, 230, 0));
    _ = gb.AreaArc(rp, x, y, radius, mouth, 360 - mouth);
    _ = gb.AreaEnd(rp);
    pen(gb, rp, graphics.penRGB(0, 0, 0));
    gb.RectFill(rp, &.{ .min_x = x + 1, .min_y = y - 9, .max_x = x + 4, .max_y = y - 6 });
}

fn drawBall(gb: *GraphicsBase, rp: *RastPort, ball: ?*rtg.Surface, s: *Scene) void {
    const surface = ball orelse return;
    // Its shadow first, blended onto the floor, squashed by height.
    const lift = s.horizon - (s.ball_y + ball_size);
    const width = @max(ball_radius - @divTrunc(lift, 8), 4);
    mode(gb, rp, graphics.DRMD_BLEND);
    pen(gb, rp, graphics.penARGB(120, 0, 0, 0));
    _ = gb.AreaEllipse(rp, s.ball_x + ball_size / 2, s.horizon + 4, width, 3);
    _ = gb.AreaEnd(rp);
    mode(gb, rp, graphics.DRMD_JAM1);
    gb.BltMaskBitMapRastPort(surface, 0, 0, rp, s.ball_x, s.ball_y, ball_size, ball_size, &ball_mask, ball_pitch);
}

fn drawPointer(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const x = @divTrunc(s.w, 2) + wave(t * 3, @divTrunc(s.w, 3));
    const y = @divTrunc(s.horizon, 2) + wave(t * 2 + 40, @divTrunc(s.horizon, 3));
    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, graphics.penRGB(0, 0, 0));
    gb.BltTemplate(rp, &arrow, 2, 0, 0, &.{ .min_x = x + 1, .min_y = y + 1, .max_x = x + 17, .max_y = y + 17 });
    pen(gb, rp, graphics.penRGB(255, 255, 255));
    gb.BltTemplate(rp, &arrow, 2, 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + 16, .max_y = y + 16 });
}

fn drawScanner(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const x = @divTrunc(s.w, 2) + wave(t, @divTrunc(s.w, 2) - 1);
    mode(gb, rp, graphics.DRMD_COMPLEMENT);
    gb.DrawVLine(rp, x, 0, s.h);
    mode(gb, rp, graphics.DRMD_JAM1);
}

fn drawTitle(gb: *GraphicsBase, rp: *RastPort, s: *Scene, fonts: Fonts, t: i32) void {
    const font = fonts.title orelse return;
    graphics.SetFont(gb, rp, font);
    _ = gb.SetSoftStyle(rp, graphics.FSF_BOLD, gb.AskSoftStyle(rp));

    const title = "PowerOS graphics.library";
    var extent: graphics.TextExtent = .{};
    gb.TextExtent(rp, title, textLen(title), &extent);
    const x = @divTrunc(s.w - extent.width, 2);
    const baseline: i32 = 8 - extent.extent.min_y;
    const box = Rect{
        .min_x = x + extent.extent.min_x - 8,
        .min_y = baseline + extent.extent.min_y - 4,
        .max_x = x + extent.extent.max_x + 8,
        .max_y = baseline + extent.extent.max_y + 4,
    };

    mode(gb, rp, graphics.DRMD_BLEND);
    pen(gb, rp, graphics.penARGB(150, 0, 0, 0));
    gb.RectFill(rp, &box);
    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, hue(t * 2));
    gb.DrawRect(rp, &box);
    pen(gb, rp, graphics.penRGB(255, 255, 255));
    gb.Move(rp, x, baseline);
    gb.Text(rp, title, textLen(title));
    _ = gb.SetSoftStyle(rp, graphics.FS_NORMAL, 0xFF);
}

fn drawScroller(gb: *GraphicsBase, rp: *RastPort, s: *Scene, fonts: Fonts, t: i32) void {
    const font = fonts.scroller orelse return;
    graphics.SetFont(gb, rp, font);

    // A new style every two seconds or so, of the ones the font allows.
    const styles = [_]u32{ graphics.FS_NORMAL, graphics.FSF_BOLD, graphics.FSF_ITALIC, graphics.FSF_UNDERLINED };
    const style = styles[@intCast(@mod(@divTrunc(t, 120), styles.len))];
    _ = gb.SetSoftStyle(rp, style, gb.AskSoftStyle(rp));

    const length = gb.TextLength(rp, scroll_text, textLen(scroll_text));
    const x = s.w - @mod(t * 2, length + s.w);
    const y = s.h - 8;

    mode(gb, rp, graphics.DRMD_JAM1);
    pen(gb, rp, graphics.penRGB(0, 0, 0));
    gb.Move(rp, x + 1, y + 1);
    gb.Text(rp, scroll_text, textLen(scroll_text));
    pen(gb, rp, hue(t * 2 + 128));
    gb.Move(rp, x, y);
    gb.Text(rp, scroll_text, textLen(scroll_text));
    _ = gb.SetSoftStyle(rp, graphics.FS_NORMAL, 0xFF);
}

fn drawAnts(gb: *GraphicsBase, rp: *RastPort, s: *Scene, t: i32) void {
    const ants = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 0) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 0) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{ .tag = graphics.RPTAG_LinePattern, .data = rotl16(0xF0F0, @intCast(@mod(t, 16))) },
        .{},
    };
    gb.SetRPAttrs(rp, &ants);
    gb.DrawRect(rp, &.{ .max_x = s.w, .max_y = s.h });
    set(gb, rp, graphics.RPTAG_LinePattern, graphics.LINE_SOLID);
    mode(gb, rp, graphics.DRMD_JAM1);
}

// --- timing ---------------------------------------------------------------

/// The parts of a frame, in the order they are drawn, for TIMES.
const part_names = [_][*:0]const u8{
    "sky",     "floor",   "lines", "left",   "star", "pacman",  "ball",
    "pointer", "scanner", "title", "scroll", "ants", "present",
};

/// What each part has cost so far, in E-clock ticks. With no timer every
/// lap is free and nothing is counted.
const Timing = struct {
    timer: ?*TimerBase = null,
    rate: u32 = 0,
    last: u64 align(4) = 0,
    spent: [part_names.len]u64 align(4) = @splat(0),

    fn now(t: *Timing) u64 {
        const tb = t.timer orelse return 0;
        var ev: timer.EClockVal = .{};
        t.rate = tb.ReadEClock(&ev);
        return ev.toTicks();
    }

    fn start(t: *Timing) void {
        t.last = t.now();
    }

    /// The time since the last lap goes to `part`.
    fn lap(t: *Timing, part: usize) void {
        if (t.timer == null) return;
        const at = t.now();
        t.spent[part] += at - t.last;
        t.last = at;
    }
};

fn drawFrame(gb: *GraphicsBase, rp: *RastPort, s: *Scene, slats: ?*graphics.Region, ball: ?*rtg.Surface, fonts: Fonts, t: i32, timing: *Timing) void {
    timing.start();
    drawSky(gb, rp, s, t);
    timing.lap(0);
    drawFloor(gb, rp, s, t);
    timing.lap(1);
    drawLines(gb, rp, s, slats, t);
    timing.lap(2);
    drawLeft(gb, rp, s, t);
    timing.lap(3);
    drawStar(gb, rp, s, t);
    timing.lap(4);
    drawPacman(gb, rp, s, t);
    timing.lap(5);
    drawBall(gb, rp, ball, s);
    timing.lap(6);
    drawPointer(gb, rp, s, t);
    timing.lap(7);
    drawScanner(gb, rp, s, t);
    timing.lap(8);
    drawTitle(gb, rp, s, fonts, t);
    timing.lap(9);
    drawScroller(gb, rp, s, fonts, t);
    timing.lap(10);
    drawAnts(gb, rp, s, t);
    timing.lap(11);
}

/// The ball, drawn once: a red disc with a blended highlight, on black -
/// the black never shows, since the mask leaves the corners alone.
fn makeBall(gb: *GraphicsBase, stage_rp: *RastPort) ?*rtg.Surface {
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = ball_size },
        .{ .tag = graphics.BMTAG_Height, .data = ball_size },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(stage_rp) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    defer gb.FreeRastPort(rp);
    if (gb.InitArea(rp, 256)) {
        pen(gb, rp, graphics.penRGB(200, 20, 30));
        _ = gb.AreaCircle(rp, ball_size / 2, ball_size / 2, ball_radius);
        _ = gb.AreaEnd(rp);
        mode(gb, rp, graphics.DRMD_BLEND);
        pen(gb, rp, graphics.penARGB(150, 255, 255, 255));
        _ = gb.AreaCircle(rp, ball_size / 2 - 5, ball_size / 2 - 5, 5);
        _ = gb.AreaEnd(rp);
        _ = gb.InitArea(rp, 0);
    }
    return surface;
}

fn ticksOf(date: dos.DateStamp) u32 {
    return @intCast((date.days * 1440 + date.minute) * 60 * 50 + date.tick);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const frames: u32 = if (argv[arg_frames] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_frames])).*) else 0;
    const scale: i32 = if (argv[arg_scale] != 0) @as(*const i32, @ptrFromInt(argv[arg_scale])).* else 2;
    if (scale < 1 or scale > 4) {
        _ = Printf(dl, MSG_BADSCALE, .{});
        return dos.RETURN_ERROR;
    }

    const lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const gb: *GraphicsBase = @ptrCast(lib);

    var why: i32 = 0;
    const display_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_ErrorPtr, .data = @intFromPtr(&why) }, .{} };
    const screen = gb.CreateRastPortTagList(&display_tags) orelse {
        _ = Printf(dl, MSG_NODISPLAY, .{gb.GraphicsErrorText(why)});
        return dos.RETURN_FAIL;
    };
    defer gb.FreeRastPort(screen);

    var bounds: Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(screen, &ask);

    // The stage: the display divided by the scale, drawn off-screen.
    const w = @divTrunc(bounds.width(), scale);
    const h = @divTrunc(bounds.height(), scale);
    const stage_tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(w) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(h) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(screen) },
        .{ .tag = graphics.BMTAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    const stage = gb.AllocBitMapTagList(&stage_tags) orelse {
        _ = Printf(dl, MSG_NOSTAGE, .{ w, h, gb.GraphicsErrorText(why) });
        return dos.RETURN_FAIL;
    };
    defer gb.FreeBitMap(stage);

    const on_stage = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(stage) }, .{} };
    const rp = gb.CreateRastPortTagList(&on_stage) orelse return dos.RETURN_FAIL;
    defer gb.FreeRastPort(rp);
    // Room for the biggest shape collected at once: the star and its hole.
    if (!gb.InitArea(rp, 1024)) return dos.RETURN_FAIL;
    defer _ = gb.InitArea(rp, 0);

    const ball = makeBall(gb, rp);
    defer gb.FreeBitMap(ball);

    const slats = gb.NewRegion();
    defer gb.DisposeRegion(slats);

    const fonts = Fonts{
        .title = gb.OpenFont(graphics.POSPAZNAME, 16),
        .scroller = gb.OpenFont(graphics.POSPAZNAME, 8),
    };
    defer gb.CloseFont(fonts.title);
    defer gb.CloseFont(fonts.scroller);

    // The border round a stage smaller than the display, cleared once.
    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(screen, &black);
    gb.RectFill(screen, &bounds);

    const out = Rect{
        .min_x = @divTrunc(bounds.width() - w * scale, 2),
        .min_y = @divTrunc(bounds.height() - h * scale, 2),
        .max_x = @divTrunc(bounds.width() - w * scale, 2) + w * scale,
        .max_y = @divTrunc(bounds.height() - h * scale, 2) + h * scale,
    };
    const whole = Rect{ .max_x = w, .max_y = h };

    _ = Printf(dl, MSG_RUNNING, .{ w, h, bounds.width(), bounds.height() });

    // The E-clock, for TIMES: a request opened only to reach the device's
    // functions, never sent.
    var timing: Timing = .{};
    var timer_req: timer.TimeRequest = .{};
    var timer_open = false;
    if (argv[arg_times] != 0) {
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) == 0) {
            timer_open = true;
            timing.timer = @ptrCast(timer_req.node.device.?);
        } else {
            _ = Printf(dl, MSG_NOTIMER, .{});
        }
    }
    defer if (timer_open) sys.CloseDevice(&timer_req.node);

    var scene: Scene = undefined;
    scene.init(w, h);

    var started: dos.DateStamp = .{};
    _ = dl.DateStamp(&started);

    var drawn: u32 = 0;
    while (frames == 0 or drawn < frames) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        const t: i32 = @intCast(drawn);
        drawFrame(gb, rp, &scene, slats, ball, fonts, t, &timing);
        if (scale == 1) {
            gb.BltBitMapRastPort(stage, 0, 0, screen, out.min_x, out.min_y, w, h);
        } else {
            gb.BitMapScale(stage, &whole, screen, &out);
        }
        timing.lap(12);
        scene.step();
        drawn += 1;
        // A tick to spare for everything else: the console that reads the
        // Ctrl-C among them.
        dl.Delay(1);
    }

    var ended: dos.DateStamp = .{};
    _ = dl.DateStamp(&ended);
    const ticks = ticksOf(ended) -% ticksOf(started);
    _ = Printf(dl, MSG_DONE, .{ drawn, ticks / 50, (ticks % 50) * 2 });
    if (ticks != 0) {
        const tenths = drawn * 500 / ticks;
        _ = Printf(dl, MSG_RATE, .{ tenths / 10, tenths % 10 });
    }
    if (timing.timer != null and drawn != 0 and timing.rate != 0) {
        var total: u64 = 0;
        for (timing.spent) |ticks_spent| total += ticks_spent;
        _ = Printf(dl, MSG_TIMES_HEAD, .{});
        for (part_names, timing.spent) |name, ticks_spent| {
            const us: u32 = @intCast(ticks_spent * 1_000_000 / timing.rate / drawn);
            const share: u32 = if (total != 0) @intCast(ticks_spent * 100 / total) else 0;
            _ = Printf(dl, MSG_TIMES_ROW, .{ name, us, share });
        }
    }
    return dos.RETURN_OK;
}
