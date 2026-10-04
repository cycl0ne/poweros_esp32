// SPDX-License-Identifier: MIT
//! Anim: a moving picture drawn with every primitive graphics.library has.
//! Built against the SDK only.
//!
//!   Anim FRAMES/N,SCALE/K/N,RATE/K/N,WINDOW/S,TIMES/S
//!
//! It opens a screen of its own with no title bar, fills it with a window
//! that has no border, and draws into that window. The screen keeps every
//! other window out of the picture; the window is what hears the keyboard
//! and the pointer. Esc or Ctrl-C typed into it, or a click or a touch on
//! the picture, ends it.
//!
//! WINDOW draws into a window on the default public screen instead, two
//! thirds of the screen's size, which may be moved, sized and closed. Its
//! close gadget ends it, and so do Esc and Ctrl-C typed into it; a new
//! size starts the scene again at that size.
//!
//! Either way it runs until then, until Ctrl-C reaches it from its shell,
//! or for FRAMES frames, and then says how many it drew and how fast. RATE
//! is how many frames a second it aims for, 1 to 60, 25 by default. SCALE
//! is how many window pixels a stage pixel becomes, 1 to 4: the stage is
//! the window's inside divided by it, drawn at that size and stretched
//! back up. 2 by default; 1 draws at the window's own size and costs about
//! half the frame rate. TIMES adds a table at the end: what each part of a
//! frame cost, on average, in microseconds of timer.device's E-clock -
//! which is how to find out where a frame goes on a machine rather than
//! guess.
//!
//! Each frame is drawn off the display, into a bitmap of its own, and put
//! into the window in one move - BitMapScale when stretched,
//! BltBitMapRastPort when not - with the window's layer held, since
//! graphics.library knows nothing of layers and cannot take it itself.
//! Drawn straight into the window, every frame would show its own
//! clearing: the background goes down first and everything else after it,
//! and the panel streams whatever is there at that moment. Double
//! buffering is the only way a picture that is cleared and redrawn sixty
//! times a second looks like one that moves. The bitmap is made once, as
//! big as the screen divided by SCALE - the most a window on it can show -
//! and a smaller window's stage is a part of it, so a new size allocates
//! nothing.
//!
//! **The pace is motion.library's clock.** A timer fires RATE times a
//! second; its hook, on the clock's task, only stores how many times it
//! has fired, and its signal wakes the program for the next frame. A frame
//! moves the scene on by every firing since the last one, so the picture
//! goes at the same speed on a machine that cannot draw RATE frames a
//! second - it draws fewer of them. Between frames the program waits,
//! which leaves the time to the rest of the system. Without motion.library
//! it draws as fast as it can, a tick apart.
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
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const LayersBase = sdk.interface.layers.LayersBase;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const RastPort = graphics.RastPort;
const timer = sdk.devices.timer;
const TimerBase = timer.TimerBase;
const motion = sdk.motion;
const MotionBase = sdk.interface.motion.MotionBase;

pub const COMMAND_NAME = "Anim";
const VERSION_STRING = "\x00$VER: Anim 1.2 (4.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,SCALE/K/N,RATE/K/N,WINDOW/S,TIMES/S";
const arg_frames = 0;
const arg_scale = 1;
const arg_rate = 2;
const arg_window = 3;
const arg_times = 4;

const MSG_NOLIBRARY = "No %s - this machine has no drawing layer\n";
const MSG_NOSCREEN = "No screen of its own - error %lu\n";
const MSG_NOPUBSCREEN = "No default screen - no display\n";
const MSG_NOWINDOW = "No window\n";
const MSG_NOSTAGE = "No room for a %dx%d stage - %s\n";
const MSG_BADSCALE = "SCALE must be 1 to 4\n";
const MSG_BADRATE = "RATE must be 1 to 60\n";
const MSG_NOCLOCK = "No %s - drawing as fast as it can\n";
const MSG_ONSCREEN = "Anim %dx%d on a screen of %dx%d - Esc, a click or Ctrl-C stops it\n";
const MSG_INWINDOW = "Anim %dx%d in a window of %dx%d - its close gadget, Esc or Ctrl-C stops it\n";
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

/// How many ticks lie between two stamps, `to` the later one.
///
/// The parts are subtracted before they are scaled: the ticks from the
/// start of the epoch to a date of this decade are far past what 32 bits
/// hold, while the run being measured is seconds long. A clock that went
/// backwards in between gives 0.
fn ticksBetween(from: dos.DateStamp, to: dos.DateStamp) u32 {
    const minutes = (to.days - from.days) * 1440 + (to.minute - from.minute);
    const ticks = minutes * 60 * 50 + (to.tick - from.tick);
    return if (ticks < 0) 0 else @intCast(ticks);
}

/// How many firings a frame catches up at the most.
const max_catch_up = 4;

/// What paces the frames: motion.library's timer, its signal, and the
/// count its hook keeps. With no motion.library, a tick of dos's apart.
const Pace = struct {
    motion_base: ?*MotionBase = null,
    timer: ?*motion.Timer = null,
    signal: i8 = -1,
    hook: sdk.utility.Hook = .{},
    /// How many times the timer has fired: written by the hook on the
    /// clock's task, read by the program.
    fired: u32 = 0,
    /// The count by a tick of dos's, without the timer.
    ticks: u32 = 0,

    /// A firing: the count kept. On motion.library's task.
    fn firing(hook: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const msg: *const motion.TimerMsg = @ptrCast(@alignCast(message.?));
        const pace: *Pace = @ptrCast(@alignCast(hook.data.?));
        @atomicStore(u32, &pace.fired, msg.count, .release);
        return 0;
    }

    fn start(pace: *Pace, sys: *ExecBase, dl: *DosBase, rate: u32) void {
        const lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse {
            _ = Printf(dl, MSG_NOCLOCK, .{motion.MOTIONNAME});
            return;
        };
        pace.motion_base = @ptrCast(lib);
        pace.signal = sys.AllocSignal(-1);
        if (pace.signal < 0) return;
        pace.hook = .{ .entry = &firing, .data = pace };
        pace.timer = pace.motion_base.?.CreateTimerTagList(&[_]TagItem{
            .{ .tag = motion.TIMER_Period, .data = @max(1000 / rate, 1) },
            .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
            .{ .tag = motion.TIMER_Hook, .data = @intFromPtr(&pace.hook) },
            .{ .tag = motion.TIMER_Signal, .data = @intCast(pace.signal) },
            .{},
        });
        if (pace.timer) |made| pace.motion_base.?.StartTimer(made);
    }

    /// The timer's count once it has fired since the last frame; null on
    /// Ctrl-C.
    fn next(pace: *Pace, sys: *ExecBase, dl: *DosBase) ?u32 {
        if (pace.timer == null) {
            // A tick to spare for everything else: the console that reads
            // the Ctrl-C among them.
            dl.Delay(1);
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return null;
            pace.ticks +%= 1;
            return pace.ticks;
        }
        const mask = @as(u32, 1) << @intCast(pace.signal);
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return null;
        return @atomicLoad(u32, &pace.fired, .acquire);
    }

    fn stop(pace: *Pace, sys: *ExecBase) void {
        const mb = pace.motion_base orelse return;
        // Its hook is not running once the timer is deleted.
        if (pace.timer) |made| mb.DeleteTimer(made);
        if (pace.signal >= 0) sys.FreeSignal(pace.signal);
        sys.CloseLibrary(mb.lib());
    }
};

// --- where the frames go -------------------------------------------------

/// The keys that end it, as IDCMP_VANILLAKEY gives them.
const key_ctrl_c = 0x03;
const key_escape = 0x1B;

/// The smallest a WINDOW may be sized to, border and all.
const min_window_width = 160;
const min_window_height = 120;

/// The smallest a stage is made, however small the window: the scene's
/// sky and floor need a few rows each.
const min_stage = 16;

fn screenAttr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
}

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &ask);
    return value;
}

/// The window the frames go into. With WINDOW, an ordinary one on the
/// default public screen, two thirds of its size and in the middle of it,
/// whose inside is a layer of its own so that the picture starts at its
/// `(0, 0)` and never reaches the border. Without, one with no border at
/// the back of the program's own screen, filling it.
fn openWindow(ib: *IntuitionBase, screen: *intuition.Screen, in_window: bool, screen_w: i32, screen_h: i32) ?*intuition.Window {
    if (in_window) {
        return ib.OpenWindowTagList(&[_]TagItem{
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
            .{ .tag = wn.WA_Left, .data = @intCast(@divTrunc(screen_w, 6)) },
            .{ .tag = wn.WA_Top, .data = @intCast(@divTrunc(screen_h, 6)) },
            .{ .tag = wn.WA_InnerWidth, .data = @intCast(@divTrunc(screen_w * 2, 3)) },
            .{ .tag = wn.WA_InnerHeight, .data = @intCast(@divTrunc(screen_h * 2, 3)) },
            .{ .tag = wn.WA_MinWidth, .data = min_window_width },
            .{ .tag = wn.WA_MinHeight, .data = min_window_height },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_Title, .data = @intFromPtr("Anim") },
            .{ .tag = wn.WA_GimmeZeroZero, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_SizeGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_VANILLAKEY },
            .{},
        });
    }
    // The right button trapped, so that it does not bring the screen's
    // menu bar up over the picture.
    return ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = @intCast(screen_w) },
        .{ .tag = wn.WA_Height, .data = @intCast(screen_h) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Backdrop, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_VANILLAKEY | wn.IDCMP_MOUSEBUTTONS },
        .{},
    });
}

/// What the window said since the last frame.
const Heard = struct { stop: bool = false, resized: bool = false };

fn listen(ib: *IntuitionBase, window: *intuition.Window) Heard {
    var heard: Heard = .{};
    while (ib.GetIMsg(window)) |im| {
        const class = im.class;
        const code = im.code;
        ib.ReplyIMsg(im);
        switch (class) {
            wn.IDCMP_CLOSEWINDOW => heard.stop = true,
            wn.IDCMP_NEWSIZE => heard.resized = true,
            wn.IDCMP_VANILLAKEY => {
                if (code == key_escape or code == key_ctrl_c) heard.stop = true;
            },
            wn.IDCMP_MOUSEBUTTONS => {
                if (code == wn.SELECTDOWN) heard.stop = true;
            },
            else => {},
        }
    }
    return heard;
}

/// How much of the stage a window's inside shows, and where it goes.
const Fit = struct {
    /// The scene's size, in stage pixels.
    w: i32,
    h: i32,
    /// Where the stretched stage lands, in the window's inside: in the
    /// middle, with what the division leaves over round it.
    out: Rect,

    fn of(inner_w: i32, inner_h: i32, scale: i32, most_w: i32, most_h: i32) Fit {
        const w: i32 = @min(@max(@divTrunc(inner_w, scale), min_stage), most_w);
        const h: i32 = @min(@max(@divTrunc(inner_h, scale), min_stage), most_h);
        const left = @divTrunc(inner_w - w * scale, 2);
        const top = @divTrunc(inner_h - h * scale, 2);
        return .{
            .w = w,
            .h = h,
            .out = .{ .min_x = left, .min_y = top, .max_x = left + w * scale, .max_y = top + h * scale },
        };
    }
};

/// The window's whole inside in black: the pixels round the stage, which
/// no frame covers. Once at the start and once after each new size.
fn blackOut(gb: *GraphicsBase, lb: *LayersBase, target: *RastPort, layer: *sdk.layers.Layer, inner_w: i32, inner_h: i32) void {
    lb.LockLayer(layer);
    defer lb.UnlockLayer(layer);
    mode(gb, target, graphics.DRMD_JAM1);
    pen(gb, target, graphics.penRGB(0, 0, 0));
    gb.RectFill(target, &.{ .max_x = inner_w, .max_y = inner_h });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
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
    const rate: i32 = if (argv[arg_rate] != 0) @as(*const i32, @ptrFromInt(argv[arg_rate])).* else 25;
    if (rate < 1 or rate > 60) {
        _ = Printf(dl, MSG_BADRATE, .{});
        return dos.RETURN_ERROR;
    }
    const in_window = argv[arg_window] != 0;

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const lay_lib = sys.OpenLibrary(sdk.layers.LAYERSNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sdk.layers.LAYERSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lay_lib);
    const lb: *LayersBase = @ptrCast(lay_lib);

    // The screen the window goes on: one of the program's own, or with
    // WINDOW the default public screen, held while the window is on it.
    // Both are given back after the window closes, since the defers run
    // the other way.
    var own: ?*intuition.Screen = null;
    defer if (own) |own_screen| {
        // Behind before it closes, so the display goes straight back to
        // the screen that was in front.
        ib.ScreenToBack(own_screen);
        _ = ib.CloseScreen(own_screen);
    };
    var public: ?*intuition.Screen = null;
    defer if (public) |held| ib.UnlockPubScreen(null, held);
    if (in_window) {
        public = ib.LockPubScreen(null) orelse {
            _ = Printf(dl, MSG_NOPUBSCREEN, .{});
            return dos.RETURN_FAIL;
        };
    } else {
        var screen_error: u32 = 0;
        own = ib.OpenScreenTagList(&[_]TagItem{
            .{ .tag = sc.SA_Quiet, .data = 1 },
            .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&screen_error) },
            .{},
        }) orelse {
            _ = Printf(dl, MSG_NOSCREEN, .{@as(u64, screen_error)});
            return dos.RETURN_FAIL;
        };
    }
    const screen = own orelse public.?;
    const screen_w: i32 = @intCast(screenAttr(ib, screen, sc.SA_Width));
    const screen_h: i32 = @intCast(screenAttr(ib, screen, sc.SA_Height));

    const window = openWindow(ib, screen, in_window, screen_w, screen_h) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);
    const target: *RastPort = @ptrFromInt(windowAttr(ib, window, wn.WA_RastPort));
    const layer: *sdk.layers.Layer = @ptrFromInt(windowAttr(ib, window, wn.WA_Layer));

    // The stage: drawn off the display, as big as the screen divided by
    // the scale, which is the most a window on it can show.
    const most_w = @divTrunc(screen_w, scale);
    const most_h = @divTrunc(screen_h, scale);
    var why: i32 = 0;
    const stage_tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(most_w) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(most_h) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(target) },
        .{ .tag = graphics.BMTAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    const stage = gb.AllocBitMapTagList(&stage_tags) orelse {
        _ = Printf(dl, MSG_NOSTAGE, .{ most_w, most_h, gb.GraphicsErrorText(why) });
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
        .title = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 16 }),
        .scroller = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }),
    };
    defer gb.CloseFont(fonts.title);
    defer gb.CloseFont(fonts.scroller);

    var inner_w: i32 = @intCast(windowAttr(ib, window, wn.WA_InnerWidth));
    var inner_h: i32 = @intCast(windowAttr(ib, window, wn.WA_InnerHeight));
    var fit = Fit.of(inner_w, inner_h, scale, most_w, most_h);
    blackOut(gb, lb, target, layer, inner_w, inner_h);

    if (in_window) {
        _ = Printf(dl, MSG_INWINDOW, .{ fit.w, fit.h, inner_w, inner_h });
    } else {
        _ = Printf(dl, MSG_ONSCREEN, .{ fit.w, fit.h, inner_w, inner_h });
    }

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
    scene.init(fit.w, fit.h);

    // The pace: a timer on motion.library's clock, RATE times a second.
    var pace: Pace = .{};
    pace.start(sys, dl, @intCast(rate));
    defer pace.stop(sys);

    var started: dos.DateStamp = .{};
    _ = dl.DateStamp(&started);

    var drawn: u32 = 0;
    // The scene's own time, in firings of the timer.
    var shown: u32 = 0;
    while (frames == 0 or drawn < frames) {
        const now = pace.next(sys, dl) orelse break;
        const heard = listen(ib, window);
        if (heard.stop) break;
        if (heard.resized) {
            // A new size: the scene starts again at the size it now has.
            inner_w = @intCast(windowAttr(ib, window, wn.WA_InnerWidth));
            inner_h = @intCast(windowAttr(ib, window, wn.WA_InnerHeight));
            fit = Fit.of(inner_w, inner_h, scale, most_w, most_h);
            blackOut(gb, lb, target, layer, inner_w, inner_h);
            scene.init(fit.w, fit.h);
        }
        // On by every firing since the last frame, but never by so many
        // that a long stall makes the picture jump.
        var behind: u32 = @min(now -% shown, max_catch_up);
        while (behind > 1) : (behind -= 1) {
            scene.step();
            shown +%= 1;
        }
        const t: i32 = @intCast(shown % 0x4000_0000);
        drawFrame(gb, rp, &scene, slats, ball, fonts, t, &timing);
        // Into the window with its layer held: graphics.library knows
        // nothing of layers and cannot take it itself.
        lb.LockLayer(layer);
        if (scale == 1) {
            gb.BltBitMapRastPort(stage, 0, 0, target, fit.out.min_x, fit.out.min_y, fit.w, fit.h);
        } else {
            gb.BitMapScale(stage, &.{ .max_x = fit.w, .max_y = fit.h }, target, &fit.out);
        }
        lb.UnlockLayer(layer);
        timing.lap(12);
        scene.step();
        shown = now;
        drawn += 1;
    }

    var ended: dos.DateStamp = .{};
    _ = dl.DateStamp(&ended);
    const ticks = ticksBetween(started, ended);
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
