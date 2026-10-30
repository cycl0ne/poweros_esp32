// SPDX-License-Identifier: MIT
//! Boing: the Amiga's bouncing ball of 1984, red and white, leaping in front
//! of its purple grid with a shadow behind it and a thud at each touch.
//!
//!   Boing VOLUME/K/N,FRAMES/K/N,CORES/S,TO/K,WINDOW/S,HIRES/S,MORPH/K/N
//!
//! It opens a screen of its own and draws through facet.library, on the GPU
//! where there is one and on the cores if not, or with CORES. Esc, a click of
//! the left button or Ctrl-C ends it. VOLUME is in percent of as recorded (60),
//! 0 for silence. FRAMES ends it after so many frames and says how many were
//! shown a second. TO writes one still picture of 672 x 480 to a file, a PPM,
//! and shows nothing.
//!
//! With WINDOW it bounces in a window on the desktop instead, which can be
//! moved and sized; its close gadget ends it, and the left button is the
//! desktop's. With HIRES the ball is round where it was faceted, lit from the
//! upper left with a shine on it, its shadow soft at the edge and the grid's
//! lines thinner: the checks are the original's still. With MORPH it turns
//! from the one ball into the other every so many seconds, and back.
//!
//! The picture's units are the still's it was measured from, 672 x 480. It
//! fits inside what it is drawn in, and the rest is the same grey.

const std = @import("std");
const sdk = @import("sdk");
const bounce = @import("bounce.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const keyboard = sdk.devices.keyboard;
const ie = sdk.devices.inputevent;
const timer = sdk.devices.timer;
const rdargs = dos.rdargs;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const FacetBase = sdk.interface.facet.FacetBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Boing";
const VERSION_STRING = "\x00$VER: Boing 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "VOLUME/K/N,FRAMES/K/N,CORES/S,TO/K,WINDOW/S,HIRES/S,MORPH/K/N";

// --- the picture ------------------------------------------------------------

const picture_width = 672;
const picture_height = 480;
const middle_x = picture_width / 2;
const middle_y = picture_height / 2;

const background = [3]f32{ 0xAA.0 / 255.0, 0xAA.0 / 255.0, 0xAA.0 / 255.0 };
const purple: u32 = 0xFF80_1A80;
const red: u32 = 0xFFFF_0000;
const white: u32 = 0xFFFF_FFFF;
/// How much of what is under it the shadow takes away.
const shadow_alpha = 0.4;
const shadow_offset = 48;

// The wall and the floor stand in the middle of the picture: the still they
// were measured from is a few pixels off, which shows in a window.
const wall_cell = 32;
const wall_columns = 15;
const wall_rows = 12;
const wall_left = (picture_width - wall_cell * wall_columns) / 2;
const wall_top = 25;
const wall_right = picture_width - wall_left;
const wall_bottom = wall_top + wall_cell * wall_rows;
const floor_left = 36;
const floor_right = picture_width - floor_left;
const floor_rows = [_]f32{ 418, 428, 440, 455 };
const floor_bottom = floor_rows[floor_rows.len - 1];

/// The ball is a little wider than it is high, as it was on the Amiga's
/// pixels.
const ball_across = 111;
const ball_down = 97;
const ball_columns = 16;
const ball_rows = 8;
/// HIRES: facets along each side of a check.
const fine_steps = 8;
/// Its top leans this way to the right and this way towards the eye.
const ball_lean: f32 = 14.4 * std.math.pi / 180.0;
const ball_nod: f32 = 25 * std.math.pi / 180.0;

const Vertex = extern struct {
    position: [3]f32,
    /// 0xAARRGGBB: read as b8g8r8a8_unorm.
    color: u32,
    /// Where it is on the old ball's flat facet: the same place for the grid.
    flat: [3]f32,
};

/// What the vertex functions are told: where it all goes, and how far the
/// ball is from the old one, 0, to the new, 1.
const Constants = extern struct {
    place: [16]f32,
    round: f32 = 0,
};

const attributes = [_]facet.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "position") },
    .{ .location = 1, .binding = 0, .format = .b8g8r8a8_unorm, .offset = @offsetOf(Vertex, "color") },
    .{ .location = 2, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "flat") },
};

fn sceneVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const place = vertices.resources.constants([16]f32);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 1);
        const clip = shader.transform(place, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

/// Which way a point of the ball of radius 1 faces once placed: the rows of
/// `place` are the turning's, scaled. It is drawn only where it faces the eye,
/// so what is left is towards the eye, negative z.
fn facing(place: *const [16]f32, p: [4]f32) [3]f32 {
    const across = @sqrt(place[0] * place[0] + place[4] * place[4] + place[8] * place[8]);
    const down = @sqrt(place[1] * place[1] + place[5] * place[5] + place[9] * place[9]);
    const x = (place[0] * p[0] + place[4] * p[1] + place[8] * p[2]) / across;
    const y = (place[1] * p[0] + place[5] * p[1] + place[9] * p[2]) / down;
    return .{ x, y, -@sqrt(@max(0, 1 - x * x - y * y)) };
}

/// Between where a vertex is on the old ball and where on the new.
fn between(p: [4]f32, flat: [4]f32, round: f32) [3]f32 {
    return .{ flat[0] + (p[0] - flat[0]) * round, flat[1] + (p[1] - flat[1]) * round, flat[2] + (p[2] - flat[2]) * round };
}

/// The ball: plain colours when old; when new, lit from the upper left, with
/// a shine there.
fn ballVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(Constants);
    const place = &given.place;
    const round = given.round;
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 1);
        const clip = shader.transform(place, between(p, vertices.input(@intCast(k), 2), round));
        const n = facing(place, p);
        const lit = 0.35 + 0.75 * @max(0, -0.45 * n[0] - 0.6 * n[1] - 0.66 * n[2]);
        const light = 1 + (lit - 1) * round;
        const towards = @max(0, -0.247 * n[0] - 0.33 * n[1] - 0.912 * n[2]);
        const t2 = towards * towards;
        const t4 = t2 * t2;
        const t8 = t4 * t4;
        const t16 = t8 * t8;
        const shine = 0.55 * t16 * t16 * t16 * round;
        vertices.output(@intCast(k))[0..8].* = .{
            clip[0],
            clip[1],
            clip[2],
            clip[3],
            shader.channel(@min(1, c[0] * light + shine)),
            shader.channel(@min(1, c[1] * light + shine)),
            shader.channel(@min(1, c[2] * light + shine)),
            shader.channel(1),
        };
    }
}

/// The ball again, all of it black: the blend makes it a shadow. When new, it
/// fades out towards its edge.
fn shadowVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(Constants);
    const place = &given.place;
    const round = given.round;
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const clip = shader.transform(place, between(p, vertices.input(@intCast(k), 2), round));
        const soft = @min(1, -facing(place, p)[2] * 2.2);
        const alpha = shadow_alpha * (1 + (soft - 1) * round);
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(0), shader.channel(0), shader.channel(0), shader.channel(alpha) };
    }
}

const entries = [_]shader.Entry{
    shader.vertex("scene", &sceneVertex, 4),
    shader.vertex("ball", &ballVertex, 4),
    shader.vertex("shadow", &shadowVertex, 4),
    shader.fixedFragment("flat", .{ .kind = .color }),
};
const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

const line_count = wall_columns + 1 + wall_rows + 1 + wall_columns + 1 + floor_rows.len;
const grid_vertices = line_count * 4;
const grid_indices = line_count * 6;
const coarse_ball_quads = ball_columns * ball_rows;
const fine_ball_quads = coarse_ball_quads * fine_steps * fine_steps;
const most_vertices = grid_vertices + fine_ball_quads * 4;
const most_indices = grid_indices + fine_ball_quads * 6;

const Mesh = struct {
    vertices: [most_vertices]Vertex = undefined,
    indices: [most_indices]u16 = undefined,
    vertex_at: u16 = 0,
    index_at: u32 = 0,

    /// Four corners, each two triangles of them turning the same way.
    fn quad(mesh: *Mesh, corners: [4][3]f32, color: u32) void {
        const first = mesh.vertex_at;
        for (corners, 0..) |corner, k| mesh.vertices[first + k] = .{ .position = corner, .color = color, .flat = corner };
        // Top left, bottom left, top right; top right, bottom left, bottom right.
        const order = [6]u16{ 0, 2, 1, 1, 2, 3 };
        for (order, 0..) |each, k| mesh.indices[mesh.index_at + k] = first + each;
        mesh.vertex_at += 4;
        mesh.index_at += 6;
    }

    /// The grid for a picture of `width` x `height` pixels, each line
    /// `thick` units wide. Its edges are on whole pixels: a line of about a
    /// pixel laid anywhere else may cover no pixel's centre at all and be
    /// gone, and two checks seen as one.
    fn grid(mesh: *Mesh, thick: f32, width: u32, height: u32) void {
        mesh.vertex_at = 0;
        mesh.index_at = 0;
        const raster = Raster.of(thick, width, height);
        for (0..wall_columns + 1) |column| {
            const x: f32 = wall_left + @as(f32, @floatFromInt(column * wall_cell));
            mesh.upright(raster, x, wall_top, x, wall_bottom);
        }
        for (0..wall_rows + 1) |row| {
            const y: f32 = wall_top + @as(f32, @floatFromInt(row * wall_cell));
            mesh.level(raster, wall_left, wall_right, y);
        }
        // Each line of the wall goes on over the floor, fanning out.
        const front_cell = (floor_right - floor_left) / @as(f32, wall_columns);
        for (0..wall_columns + 1) |column| {
            const at: f32 = @floatFromInt(column);
            mesh.upright(raster, wall_left + at * wall_cell, wall_bottom, floor_left + at * front_cell, floor_bottom);
        }
        for (floor_rows) |y| mesh.level(raster, floorAt(y, wall_left, floor_left), floorAt(y, wall_right, floor_right), y);
    }

    /// A line from top to bottom: as many pixels wide in every row.
    fn upright(mesh: *Mesh, raster: Raster, x0: f32, y0: f32, x1: f32, y1: f32) void {
        const top = raster.edgeY(y0);
        const end = raster.edgeY(y1);
        const left0 = raster.edgeX(x0);
        const left1 = raster.edgeX(x1);
        mesh.quad(.{
            .{ raster.unitX(left0), raster.unitY(top), 0 },
            .{ raster.unitX(left0 + raster.pixels), raster.unitY(top), 0 },
            .{ raster.unitX(left1), raster.unitY(end + raster.pixels), 0 },
            .{ raster.unitX(left1 + raster.pixels), raster.unitY(end + raster.pixels), 0 },
        }, purple);
    }

    /// A line from left to right, as many pixels high in every column.
    fn level(mesh: *Mesh, raster: Raster, x0: f32, x1: f32, y: f32) void {
        const left = raster.edgeX(x0);
        const right = raster.edgeX(x1) + raster.pixels;
        const top = raster.edgeY(y);
        mesh.quad(.{
            .{ raster.unitX(left), raster.unitY(top), 0 },
            .{ raster.unitX(right), raster.unitY(top), 0 },
            .{ raster.unitX(left), raster.unitY(top + raster.pixels), 0 },
            .{ raster.unitX(right), raster.unitY(top + raster.pixels), 0 },
        }, purple);
    }

    /// Where the floor's edge is at `y`, left or right, between the wall's
    /// foot and the front.
    fn floorAt(y: f32, wall_edge: f32, front_edge: f32) f32 {
        return wall_edge + (front_edge - wall_edge) * (y - wall_bottom) / (floor_bottom - wall_bottom);
    }

    /// A ball of radius 1, chequered, `steps` facets along each side of a
    /// check, and each corner where it would be on the old ball's facet of
    /// that check: flat, since a check's corners lie in a plane, so that the
    /// new ball can become just the old. Its front, turned to the eye, is at
    /// negative z.
    fn ball(mesh: *Mesh, steps: u32) void {
        mesh.vertex_at = grid_vertices;
        mesh.index_at = grid_indices;
        const rows = ball_rows * steps;
        const columns = ball_columns * steps;
        for (0..rows) |row| for (0..columns) |column| {
            const corners = [4][3]f32{
                ballPoint(row, column, rows, columns),
                ballPoint(row, column + 1, rows, columns),
                ballPoint(row + 1, column, rows, columns),
                ballPoint(row + 1, column + 1, rows, columns),
            };
            const first = mesh.vertex_at;
            mesh.quad(corners, if ((row / steps + column / steps) % 2 == 0) red else white);
            for (0..2) |down| for (0..2) |round| {
                mesh.vertices[first + down * 2 + round].flat = flatPoint(row + down, column + round, row / steps, column / steps, steps);
            };
        };
    }

    /// Corner (`row`, `column`) of a facet in check (`check_row`,
    /// `check_column`), on the plane of the check's four corners.
    fn flatPoint(row: usize, column: usize, check_row: usize, check_column: usize, steps: u32) [3]f32 {
        const v = @as(f32, @floatFromInt(row - check_row * steps)) / @as(f32, @floatFromInt(steps));
        const u = @as(f32, @floatFromInt(column - check_column * steps)) / @as(f32, @floatFromInt(steps));
        const a = ballPoint(check_row, check_column, ball_rows, ball_columns);
        const b = ballPoint(check_row, check_column + 1, ball_rows, ball_columns);
        const c = ballPoint(check_row + 1, check_column, ball_rows, ball_columns);
        const d = ballPoint(check_row + 1, check_column + 1, ball_rows, ball_columns);
        var at: [3]f32 = undefined;
        for (&at, a, b, c, d) |*each, ka, kb, kc, kd| {
            const top = ka + (kb - ka) * u;
            each.* = top + (kc + (kd - kc) * u - top) * v;
        }
        return at;
    }

    fn ballPoint(row: usize, column: usize, rows: u32, columns: u32) [3]f32 {
        const down = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows)) * std.math.pi;
        const round = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(columns)) * 2 * std.math.pi;
        return .{ @sin(down) * @cos(round), -@cos(down), @sin(down) * @sin(round) };
    }
};

/// The picture's units on a picture of so many pixels, as `placeOf` fits it.
const Raster = struct {
    /// Pixels a unit.
    scale: f32,
    half_width: f32,
    half_height: f32,
    /// How many pixels wide a line is: one at the least.
    pixels: f32,

    fn of(thick: f32, width: u32, height: u32) Raster {
        const wide: f32 = @floatFromInt(width);
        const high: f32 = @floatFromInt(height);
        const scale = @min(wide / picture_width, high / picture_height);
        return .{ .scale = scale, .half_width = wide / 2, .half_height = high / 2, .pixels = @max(1, @round(thick * scale)) };
    }

    /// The whole pixel a line about `x` starts at, and the same down.
    fn edgeX(raster: Raster, x: f32) f32 {
        return @round((x - middle_x) * raster.scale + raster.half_width - raster.pixels / 2);
    }
    fn edgeY(raster: Raster, y: f32) f32 {
        return @round((y - middle_y) * raster.scale + raster.half_height - raster.pixels / 2);
    }

    fn unitX(raster: Raster, pixel: f32) f32 {
        return (pixel - raster.half_width) / raster.scale + middle_x;
    }
    fn unitY(raster: Raster, pixel: f32) f32 {
        return (pixel - raster.half_height) / raster.scale + middle_y;
    }
};

/// Places in the picture's units as the clip space has them.
fn gridPlace(aspect: f32) [16]f32 {
    return placeOf(aspect, .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 1, 1, 0, 0);
}

/// Turned by `turned`, then leaning as the ball does, scaled, at (x, y).
fn ballPlace(aspect: f32, turned: f32, x: f32, y: f32) [16]f32 {
    const cs = @cos(turned);
    const ss = @sin(turned);
    const cn = @cos(ball_nod);
    const sn = @sin(ball_nod);
    const cl = @cos(ball_lean);
    const sl = @sin(ball_lean);
    // Lean (z) * nod (x) * turning (y), row after row.
    const m = [9]f32{
        cl * cs - sl * sn * ss,
        -sl * cn,
        cl * ss + sl * sn * cs,
        sl * cs + cl * sn * ss,
        cl * cn,
        sl * ss - cl * sn * cs,
        -cn * ss,
        sn,
        cn * cs,
    };
    return placeOf(aspect, m, ball_across, ball_down, x, y);
}

/// `m`, 3 x 3 row after row, scaled by `across` and `down` and moved to (x,
/// y) of the picture, at a depth nothing tests.
fn placeOf(aspect: f32, m: [9]f32, across: f32, down: f32, x: f32, y: f32) [16]f32 {
    const narrow = aspect < @as(f32, picture_width) / picture_height;
    const unit_y = if (narrow) aspect / middle_x else 1.0 / @as(f32, middle_y);
    const unit_x = unit_y / aspect;
    return .{
        unit_x * across * m[0], unit_y * down * m[3], 0, 0,
        unit_x * across * m[1], unit_y * down * m[4], 0, 0,
        unit_x * across * m[2], unit_y * down * m[5], 0, 0,
        unit_x * (x - middle_x), unit_y * (y - middle_y), 0.5, 1,
    };
}

// --- the sound --------------------------------------------------------------

const sound_rate = 22_050;
const sound_frames = sound_rate * 2 / 5;
const sound_voices = 4;

/// The thud the ball makes: a low note dropping fast with a ring over it, and
/// a little noise as it strikes. Made here: the Amiga's sample is not ours.
fn makeThud(into: *[sound_frames]i16) void {
    var phase: f32 = 0;
    var ring: f32 = 0;
    var noise: u32 = 0x1234_5678;
    for (into, 0..) |*sample, k| {
        const t = @as(f32, @floatFromInt(k)) / sound_rate;
        phase += (55 + 110 * @exp(-t * 9)) / sound_rate;
        ring += 410.0 / @as(f32, sound_rate);
        noise = noise *% 1_664_525 +% 1_013_904_223;
        const hiss = @as(f32, @floatFromInt(@as(i32, @bitCast(noise)) >> 16)) / 32768.0;
        const mixed = @sin(phase * 2 * std.math.pi) * @exp(-t * 11) +
            0.25 * @sin(ring * 2 * std.math.pi) * @exp(-t * 26) +
            0.35 * hiss * @exp(-t * 180);
        sample.* = @intFromFloat(std.math.clamp(mixed * 0.7, -1, 1) * 32767);
    }
}

/// The thud played by trigger, several at a time. Without a device it stays
/// silent: the ball bounces all the same.
const Sound = struct {
    sys: *ExecBase,
    port: ?*exec.MsgPort = null,
    opened: bool = false,
    voices: [sound_voices]?*audio.IOAudio = @splat(null),
    busy: [sound_voices]bool = @splat(false),
    samples: ?*[sound_frames]i16 = null,
    volume: u32 = 0,

    fn open(sound: *Sound, percent: u32) void {
        if (percent == 0) return;
        const sys = sound.sys;
        const port = sys.CreateMsgPort() orelse return;
        sound.port = port;
        for (&sound.voices) |*voice| {
            voice.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return));
        }
        const first = sound.voices[0].?;
        if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &first.std.req, audio.AUDIOF_TRIGGER) != 0) return;
        sound.opened = true;
        const made = first.*;
        for (sound.voices[1..]) |voice| voice.?.* = made;
        const memory = sys.AllocVec(@sizeOf([sound_frames]i16), exec.MEMF_ANY) orelse return;
        sound.samples = @ptrCast(@alignCast(memory));
        makeThud(sound.samples.?);
        sound.volume = audiocontrol.volumeOf(percent);
    }

    fn close(sound: *Sound) void {
        const sys = sound.sys;
        for (sound.voices, sound.busy) |voice, busy| if (busy) {
            _ = sys.AbortIO(&voice.?.std.req);
            _ = sys.WaitIO(&voice.?.std.req);
        };
        if (sound.opened) sys.CloseDevice(&sound.voices[0].?.std.req);
        for (sound.voices) |voice| if (voice) |io| sys.DeleteIORequest(&io.std.req);
        if (sound.samples) |memory| sys.FreeVec(memory);
        if (sound.port) |port| sys.DeleteMsgPort(port);
    }

    /// Played at `pan`, -1 left to 1 right, if a voice is free.
    fn play(sound: *Sound, pan: f32) void {
        const samples = sound.samples orelse return;
        const sys = sound.sys;
        for (sound.voices, &sound.busy) |voice, *busy| {
            const io = voice.?;
            if (busy.*) {
                if (sys.CheckIO(&io.std.req) == null) continue;
                _ = sys.WaitIO(&io.std.req);
                busy.* = false;
            }
            io.std.req.message.reply_port = sound.port;
            io.std.req.command = audio.AUDIOCMD_TRIGGER;
            io.std.req.flags = 0;
            io.std.data = @ptrCast(samples);
            io.std.length = @sizeOf([sound_frames]i16);
            io.format = audio.AUDIO_S16;
            io.channels = 1;
            io.rate = sound_rate;
            io.volume = sound.volume;
            io.pan = @intFromFloat(pan * @as(f32, @floatFromInt(audio.AUDIO_PAN_FULL)));
            io.loops = 1;
            sys.SendIO(&io.std.req);
            busy.* = true;
            return;
        }
    }
};

// --- what draws -------------------------------------------------------------

const Failure = error{ NoDevice, NoSurface, NoMemory, Refused, DeviceLost, NoFile };

const most_images = 4;

/// What it draws in.
const Target = union(enum) {
    screen: *intuition.Screen,
    window: *intuition.Window,
};

fn expect(result: facet.Result, failure: Failure) Failure!void {
    if (result == .error_device_lost) return error.DeviceLost;
    if (result != .success) return failure;
}

const Gpu = struct {
    fb: *FacetBase,
    instance: ?*facet.Instance = null,
    physical: *facet.PhysicalDevice = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    surface: ?*facet.Surface = null,
    format: facet.Format = .undefined,
    swapchain: ?*facet.Swapchain = null,
    width: u32 = 0,
    height: u32 = 0,
    image_count: u32 = 0,
    images: [most_images]*facet.Image = undefined,
    views: [most_images]?*facet.ImageView = @splat(null),
    framebuffers: [most_images]?*facet.Framebuffer = @splat(null),
    pass: ?*facet.RenderPass = null,
    module: ?*facet.ShaderModule = null,
    layout: ?*facet.PipelineLayout = null,
    flat: ?*facet.Pipeline = null,
    ball: ?*facet.Pipeline = null,
    shadow: ?*facet.Pipeline = null,
    ball_indices: u32 = 0,
    mesh: *Mesh = undefined,
    line_width: f32 = 2,
    grid_pixels: f32 = 0,
    mapped: [*]u8 = undefined,
    buffer: ?*facet.Buffer = null,
    memory: ?*facet.DeviceMemory = null,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    acquired: ?*facet.Semaphore = null,
    rendered: ?*facet.Semaphore = null,
    still_image: ?*facet.Image = null,
    still_view: ?*facet.ImageView = null,
    still_memory: ?*facet.DeviceMemory = null,
    still_framebuffer: ?*facet.Framebuffer = null,

    fn down(gpu: *Gpu) void {
        const fb = gpu.fb;
        if (gpu.device) |device| {
            _ = fb.DeviceWaitIdle(device);
            for (gpu.framebuffers) |each| fb.DestroyFramebuffer(device, each);
            for (gpu.views) |each| fb.DestroyImageView(device, each);
            fb.DestroySwapchain(device, gpu.swapchain);
            fb.DestroyFramebuffer(device, gpu.still_framebuffer);
            fb.DestroyImageView(device, gpu.still_view);
            fb.DestroyImage(device, gpu.still_image);
            fb.FreeMemory(device, gpu.still_memory);
            fb.DestroySemaphore(device, gpu.rendered);
            fb.DestroySemaphore(device, gpu.acquired);
            fb.DestroyFence(device, gpu.fence);
            fb.DestroyCommandPool(device, gpu.command_pool);
            fb.DestroyPipeline(device, gpu.shadow);
            fb.DestroyPipeline(device, gpu.ball);
            fb.DestroyPipeline(device, gpu.flat);
            fb.DestroyPipelineLayout(device, gpu.layout);
            fb.DestroyShaderModule(device, gpu.module);
            fb.DestroyRenderPass(device, gpu.pass);
            fb.DestroyBuffer(device, gpu.buffer);
            fb.FreeMemory(device, gpu.memory);
            fb.DestroyDevice(device);
        }
        if (gpu.instance) |instance| {
            fb.DestroySurface(instance, gpu.surface);
            fb.DestroyInstance(instance);
        }
    }

    /// The instance, the surface over `target`, and a device: the GPU if
    /// there is one that draws on it and it is wanted, the cores if not.
    fn up(gpu: *Gpu, target: Target, on_cores: bool) Failure!void {
        const fb = gpu.fb;
        try expect(fb.CreateInstance(&.{ .application_name = COMMAND_NAME }, &gpu.instance), error.NoDevice);
        try expect(switch (target) {
            .screen => |screen| fb.CreateScreenSurface(gpu.instance.?, &.{ .screen = screen }, &gpu.surface),
            .window => |window| fb.CreateWindowSurface(gpu.instance.?, &.{ .window = window }, &gpu.surface),
        }, error.NoSurface);
        var count: u32 = 4;
        var physical: [4]*facet.PhysicalDevice = undefined;
        if (fb.EnumeratePhysicalDevices(gpu.instance.?, &count, &physical) != .success or count == 0) return error.NoDevice;
        // Asked for in turn, the cores last of all as they are listed first.
        var k: u32 = if (on_cores) 1 else count;
        while (k > 0) {
            k -= 1;
            if (gpu.tryDevice(physical[k])) return;
        }
        return error.NoDevice;
    }

    fn tryDevice(gpu: *Gpu, physical: *facet.PhysicalDevice) bool {
        const fb = gpu.fb;
        var supported = false;
        _ = fb.GetPhysicalDeviceSurfaceSupport(physical, 0, gpu.surface.?, &supported);
        var formats: [1]facet.SurfaceFormat = undefined;
        var count: u32 = 1;
        _ = fb.GetPhysicalDeviceSurfaceFormats(physical, gpu.surface.?, &count, &formats);
        if (!supported or count == 0) return false;
        const queue_info = facet.DeviceQueueCreateInfo{};
        if (fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &gpu.device) != .success) return false;
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(gpu.device.?, 0, 0, &queue);
        gpu.queue = queue.?;
        gpu.physical = physical;
        gpu.format = formats[0].format;
        return true;
    }

    fn typeFor(gpu: *const Gpu, needs: facet.MemoryRequirements, wanted: u32) Failure!u32 {
        var memory: facet.PhysicalDeviceMemoryProperties = undefined;
        gpu.fb.GetPhysicalDeviceMemoryProperties(gpu.physical, &memory);
        for (memory.memory_types[0..memory.memory_type_count], 0..) |kind, k| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(k) != 0 and kind.property_flags & wanted == wanted) return @intCast(k);
        }
        return error.NoMemory;
    }

    fn pipeline(gpu: *Gpu, vertex: [*:0]const u8, front_only: bool, blended: bool) Failure!*facet.Pipeline {
        const stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = gpu.module.?, .name = vertex },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = gpu.module.?, .name = "flat" },
        };
        const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Vertex) };
        const input = facet.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = attributes.len,
            .vertex_attribute_descriptions = &attributes,
        };
        const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list };
        const viewports = facet.PipelineViewportStateCreateInfo{};
        const rasterization = facet.PipelineRasterizationStateCreateInfo{
            .cull_mode = if (front_only) facet.CULL_MODE_BACK else facet.CULL_MODE_NONE,
            .front_face = .counter_clockwise,
        };
        const dynamic_states = [2]facet.DynamicState{ .viewport, .scissor };
        const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = dynamic_states.len, .dynamic_states = &dynamic_states };
        const depth = facet.PipelineDepthStencilStateCreateInfo{};
        const blend_attachment = facet.PipelineColorBlendAttachmentState{
            .blend_enable = blended,
            .src_color_blend_factor = if (blended) .src_alpha else .one,
            .dst_color_blend_factor = if (blended) .one_minus_src_alpha else .zero,
            .src_alpha_blend_factor = if (blended) .zero else .one,
            .dst_alpha_blend_factor = if (blended) .one else .zero,
        };
        const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&blend_attachment) };
        const info = facet.GraphicsPipelineCreateInfo{
            .stage_count = 2,
            .stages = &stages,
            .vertex_input_state = &input,
            .input_assembly_state = &assembly,
            .viewport_state = &viewports,
            .rasterization_state = &rasterization,
            .depth_stencil_state = &depth,
            .color_blend_state = &blend,
            .dynamic_state = &dynamic,
            .layout = gpu.layout.?,
            .render_pass = gpu.pass.?,
        };
        var made: [1]?*facet.Pipeline = undefined;
        try expect(gpu.fb.CreateGraphicsPipelines(gpu.device.?, null, 1, @ptrCast(&info), &made), error.Refused);
        return made[0].?;
    }

    /// The render pass, the pipelines, the mesh and what a frame needs.
    fn prepare(gpu: *Gpu, mesh: *Mesh, round: f32) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const attachment = facet.AttachmentDescription{ .format = gpu.format, .load_op = .clear, .store_op = .store, .final_layout = .present_src };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color) };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &gpu.pass), error.Refused);
        try expect(fb.CreateShaderModule(device, &.{ .code = &code }, &gpu.module), error.Refused);
        const range = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = @sizeOf(Constants) };
        try expect(fb.CreatePipelineLayout(device, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &gpu.layout), error.Refused);
        gpu.flat = try gpu.pipeline("scene", false, false);
        gpu.ball = try gpu.pipeline("ball", true, false);
        gpu.shadow = try gpu.pipeline("shadow", true, true);
        gpu.ball_indices = mesh.index_at - @as(u32, grid_indices);
        gpu.mesh = mesh;
        gpu.line_width = lineWidth(round);

        const vertex_bytes = @sizeOf(@TypeOf(mesh.vertices));
        const index_bytes = @sizeOf(@TypeOf(mesh.indices));
        try expect(fb.CreateBuffer(device, &.{ .size = vertex_bytes + index_bytes, .usage = facet.BUFFER_USAGE_VERTEX_BUFFER | facet.BUFFER_USAGE_INDEX_BUFFER }, &gpu.buffer), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(device, gpu.buffer.?, &needs);
        const memory_type = try gpu.typeFor(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = memory_type }, &gpu.memory), error.NoMemory);
        try expect(fb.BindBufferMemory(device, gpu.buffer.?, gpu.memory.?, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(device, gpu.memory.?, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        const bytes: [*]u8 = @ptrCast(data.?);
        gpu.mapped = bytes;
        @memcpy(bytes[0..vertex_bytes], @as([*]const u8, @ptrCast(&mesh.vertices)));
        @memcpy(bytes[vertex_bytes..][0..index_bytes], @as([*]const u8, @ptrCast(&mesh.indices)));

        try expect(fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &gpu.command_pool), error.Refused);
        var commands: [1]?*facet.CommandBuffer = undefined;
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = gpu.command_pool.?, .command_buffer_count = 1 }, &commands), error.Refused);
        gpu.commands = commands[0];
        try expect(fb.CreateFence(device, &.{}, &gpu.fence), error.Refused);
        try expect(fb.CreateSemaphore(device, &.{}, &gpu.acquired), error.Refused);
        try expect(fb.CreateSemaphore(device, &.{}, &gpu.rendered), error.Refused);
    }

    /// The grid laid again for a picture of this size, nothing drawing.
    fn layGrid(gpu: *Gpu, width: u32, height: u32) void {
        gpu.mesh.grid(gpu.line_width, width, height);
        gpu.grid_pixels = Raster.of(gpu.line_width, width, height).pixels;
        const bytes = grid_vertices * @sizeOf(Vertex);
        @memcpy(gpu.mapped[0..bytes], @as([*]const u8, @ptrCast(&gpu.mesh.vertices)));
    }

    /// The grid's lines as wide as they are at `round`, laid again only when
    /// that is another number of pixels. Nothing is drawing: each frame is
    /// waited for.
    fn thicken(gpu: *Gpu, round: f32) void {
        gpu.line_width = lineWidth(round);
        if (Raster.of(gpu.line_width, gpu.width, gpu.height).pixels != gpu.grid_pixels) gpu.layGrid(gpu.width, gpu.height);
    }

    /// A swapchain at the surface's size, a framebuffer over each image, in
    /// the place of one there was.
    fn chain(gpu: *Gpu) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const old = gpu.swapchain;
        if (old != null) {
            _ = fb.DeviceWaitIdle(device);
            for (&gpu.framebuffers) |*each| {
                fb.DestroyFramebuffer(device, each.*);
                each.* = null;
            }
            for (&gpu.views) |*each| {
                fb.DestroyImageView(device, each.*);
                each.* = null;
            }
        }
        var capabilities: facet.SurfaceCapabilities = undefined;
        _ = fb.GetPhysicalDeviceSurfaceCapabilities(gpu.physical, gpu.surface.?, &capabilities);
        gpu.width = capabilities.current_extent.width;
        gpu.height = capabilities.current_extent.height;
        var info = facet.SwapchainCreateInfo{
            .surface = gpu.surface.?,
            .min_image_count = @min(2, capabilities.max_image_count),
            .image_format = gpu.format,
            .image_extent = capabilities.current_extent,
            .old_swapchain = old,
        };
        var made = fb.CreateSwapchain(device, &info, &gpu.swapchain);
        if (made == .error_out_of_device_memory) {
            info.min_image_count = 1;
            made = fb.CreateSwapchain(device, &info, &gpu.swapchain);
        }
        fb.DestroySwapchain(device, old);
        if (made != .success) gpu.swapchain = null;
        try expect(made, error.NoSurface);
        gpu.layGrid(gpu.width, gpu.height);
        gpu.image_count = most_images;
        _ = fb.GetSwapchainImages(device, gpu.swapchain.?, &gpu.image_count, &gpu.images);
        for (gpu.images[0..gpu.image_count], 0..) |each, k| {
            gpu.views[k] = try gpu.viewOf(each);
            try expect(fb.CreateFramebuffer(device, &.{ .render_pass = gpu.pass.?, .attachment_count = 1, .attachments = @ptrCast(&gpu.views[k]), .width = gpu.width, .height = gpu.height, .layers = 1 }, &gpu.framebuffers[k]), error.Refused);
        }
    }

    fn viewOf(gpu: *Gpu, image: *facet.Image) Failure!*facet.ImageView {
        var made: ?*facet.ImageView = null;
        try expect(gpu.fb.CreateImageView(gpu.device.?, &.{ .image = image, .format = gpu.format, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR, .level_count = 1, .layer_count = 1 } }, &made), error.Refused);
        return made.?;
    }

    /// One frame recorded: the backdrop, the shadow, the ball.
    fn record(gpu: *Gpu, framebuffer: *facet.Framebuffer, width: u32, height: u32, motion: *const bounce.Motion, round: f32) Failure!void {
        const fb = gpu.fb;
        const commands = gpu.commands.?;
        try expect(fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        const area = facet.Rect2D{ .extent = .{ .width = width, .height = height } };
        const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ background[0], background[1], background[2], 1 } } }};
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = gpu.pass.?, .framebuffer = framebuffer, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        const viewport = facet.Viewport{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        fb.CmdSetViewport(commands, 0, 1, @ptrCast(&viewport));
        fb.CmdSetScissor(commands, 0, 1, @ptrCast(&area));
        const offset: u64 = 0;
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&gpu.buffer), @ptrCast(&offset));
        fb.CmdBindIndexBuffer(commands, gpu.buffer.?, @sizeOf([most_vertices]Vertex), .uint16);
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

        const grid = gridPlace(aspect);
        fb.CmdBindPipeline(commands, .graphics, gpu.flat.?);
        fb.CmdPushConstants(commands, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf([16]f32), &grid);
        fb.CmdDrawIndexed(commands, grid_indices, 1, 0, 0, 0);

        const shadow = Constants{ .place = ballPlace(aspect, motion.turned, motion.x + shadow_offset, motion.y), .round = round };
        fb.CmdBindPipeline(commands, .graphics, gpu.shadow.?);
        fb.CmdPushConstants(commands, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(Constants), &shadow);
        fb.CmdDrawIndexed(commands, gpu.ball_indices, 1, grid_indices, 0, 0);

        const ball = Constants{ .place = ballPlace(aspect, motion.turned, motion.x, motion.y), .round = round };
        fb.CmdBindPipeline(commands, .graphics, gpu.ball.?);
        fb.CmdPushConstants(commands, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(Constants), &ball);
        fb.CmdDrawIndexed(commands, gpu.ball_indices, 1, grid_indices, 0, 0);
        fb.CmdEndRenderPass(commands);
        try expect(fb.EndCommandBuffer(commands), error.Refused);
    }

    /// The command buffer played, waiting for `wait`, its fence waited for.
    fn play(gpu: *Gpu, wait: ?*facet.Semaphore, signal: ?*facet.Semaphore) Failure!void {
        const fb = gpu.fb;
        const stage: u32 = facet.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT;
        const submit = facet.SubmitInfo{
            .wait_semaphore_count = @intFromBool(wait != null),
            .wait_semaphores = @ptrCast(&wait),
            .wait_dst_stage_mask = @ptrCast(&stage),
            .command_buffer_count = 1,
            .command_buffers = @ptrCast(&gpu.commands),
            .signal_semaphore_count = @intFromBool(signal != null),
            .signal_semaphores = @ptrCast(&signal),
        };
        try expect(fb.QueueSubmit(gpu.queue, 1, @ptrCast(&submit), gpu.fence), error.Refused);
        try expect(fb.WaitForFences(gpu.device.?, 1, @ptrCast(&gpu.fence), true, facet.WAIT_FOREVER_NS), error.Refused);
        try expect(fb.ResetFences(gpu.device.?, 1, @ptrCast(&gpu.fence)), error.Refused);
    }

    /// One frame acquired, drawn and shown; false once the screen has changed.
    fn frame(gpu: *Gpu, motion: *const bounce.Motion, round: f32) Failure!bool {
        const fb = gpu.fb;
        var index: u32 = 0;
        switch (fb.AcquireNextImage(gpu.device.?, gpu.swapchain.?, facet.WAIT_FOREVER_NS, gpu.acquired, null, &index)) {
            .success, .suboptimal => {},
            .error_out_of_date => return false,
            .error_device_lost => return error.DeviceLost,
            else => return error.NoSurface,
        }
        try gpu.record(gpu.framebuffers[index].?, gpu.width, gpu.height, motion, round);
        try gpu.play(gpu.acquired, gpu.rendered);
        const shown = fb.QueuePresent(gpu.queue, &.{
            .wait_semaphore_count = 1,
            .wait_semaphores = @ptrCast(&gpu.rendered),
            .swapchains = @ptrCast(&gpu.swapchain),
            .image_indices = @ptrCast(&index),
        });
        return switch (shown) {
            .success, .suboptimal => true,
            .error_out_of_date => false,
            .error_device_lost => error.DeviceLost,
            else => error.NoSurface,
        };
    }

    /// One picture drawn where it can be read, and written to `name`.
    fn still(gpu: *Gpu, dl: *DosBase, motion: *const bounce.Motion, round: f32, name: [*:0]const u8) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        try expect(fb.CreateImage(device, &.{ .format = gpu.format, .extent = .{ .width = picture_width, .height = picture_height }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &gpu.still_image), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, gpu.still_image.?, &needs);
        const memory_type = try gpu.typeFor(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = memory_type }, &gpu.still_memory), error.NoMemory);
        try expect(fb.BindImageMemory(device, gpu.still_image.?, gpu.still_memory.?, 0), error.Refused);
        gpu.still_view = try gpu.viewOf(gpu.still_image.?);
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = gpu.pass.?, .attachment_count = 1, .attachments = @ptrCast(&gpu.still_view), .width = picture_width, .height = picture_height, .layers = 1 }, &gpu.still_framebuffer), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(device, gpu.still_memory.?, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        var layout: facet.SubresourceLayout = undefined;
        fb.GetImageSubresourceLayout(device, gpu.still_image.?, &.{}, &layout);
        gpu.layGrid(picture_width, picture_height);
        try gpu.record(gpu.still_framebuffer.?, picture_width, picture_height, motion, round);
        try gpu.play(null, null);
        const pixels = @as([*]const u8, @ptrCast(data.?)) + @as(usize, @intCast(layout.offset));
        if (!writePicture(dl, pixels, @intCast(layout.row_pitch), gpu.format, name)) return error.NoFile;
    }
};

/// The grid's lines in units, 2 for the old ball and 1 for the new.
fn lineWidth(round: f32) f32 {
    return 2 - round;
}

/// The pixels as a PPM, 8 bits a channel.
fn writePicture(dl: *DosBase, pixels: [*]const u8, pitch: usize, format: facet.Format, name: [*:0]const u8) bool {
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse return false;
    const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ picture_width, picture_height });
    var written = dl.Write(file, header.ptr, header.len) == header.len;
    var row: [picture_width * 3]u8 = undefined;
    for (0..picture_height) |y| {
        const from = pixels + y * pitch;
        for (0..picture_width) |x| {
            const out = row[x * 3..][0..3];
            switch (format) {
                .r5g6b5_unorm_pack16 => {
                    const pixel: u32 = @as(*align(1) const u16, @ptrCast(from + x * 2)).*;
                    const r = pixel >> 11;
                    const g = pixel >> 5 & 0x3F;
                    const b = pixel & 0x1F;
                    out.* = .{ @intCast(r << 3 | r >> 2), @intCast(g << 2 | g >> 4), @intCast(b << 3 | b >> 2) };
                },
                .r8g8b8a8_unorm => out.* = from[x * 4..][0..3].*,
                else => out.* = .{ from[x * 4 + 2], from[x * 4 + 1], from[x * 4] },
            }
        }
        written = (dl.Write(file, &row, row.len) == row.len) and written;
    }
    return dl.Close(file) and written;
}

fn explain(err: Failure) [*:0]const u8 {
    return switch (err) {
        error.NoDevice => "No device of facet.library's draws on this screen",
        error.NoSurface => "No surface over the screen",
        error.NoMemory => "Not enough memory",
        error.Refused => "facet.library refused something",
        error.DeviceLost => "The device is lost: it stopped drawing",
        error.NoFile => "The picture could not be written",
    };
}

/// A key or a button that ends it, among the window's messages.
fn ending(ib: *IntuitionBase, window: *intuition.Window) bool {
    var ends = false;
    while (ib.GetIMsg(window)) |message| {
        switch (message.class) {
            wn.IDCMP_CLOSEWINDOW => ends = true,
            wn.IDCMP_RAWKEY => if (message.code == keyboard.RAWKEY_ESC) {
                ends = true;
            },
            wn.IDCMP_MOUSEBUTTONS => if (message.code == ie.IECODE_LBUTTON) {
                ends = true;
            },
            else => {},
        }
        ib.ReplyIMsg(message);
    }
    return ends;
}

/// Microseconds from the timer's start.
fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn say(dl: *DosBase, text: [*:0]const u8) i32 {
    _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
    return dos.RETURN_FAIL;
}

/// A window on the desktop, of the picture's size until it is sized.
fn desktopWindow(ib: *IntuitionBase) ?*intuition.Window {
    const as_large_as_the_screen: usize = @bitCast(@as(isize, -1));
    return ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_InnerWidth, .data = picture_width },
        .{ .tag = wn.WA_InnerHeight, .data = picture_height },
        .{ .tag = wn.WA_Position, .data = wn.WPOS_CENTERSCREEN },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_MinWidth, .data = 168 },
        .{ .tag = wn.WA_MinHeight, .data = 120 },
        .{ .tag = wn.WA_MaxWidth, .data = as_large_as_the_screen },
        .{ .tag = wn.WA_MaxHeight, .data = as_large_as_the_screen },
        // Every picture covers the whole inside: nothing to keep of what is
        // covered, nothing to draw again when it is not.
        .{ .tag = wn.WA_SimpleRefresh, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY },
        .{},
    });
}

/// Nothing is drawn in it: it is what hears the keys and the button.
fn screenWindow(ib: *IntuitionBase, screen: *intuition.Screen) ?*intuition.Window {
    var width: usize = 0;
    var height: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{
        .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
        .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
        .{},
    });
    return ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = width },
        .{ .tag = wn.WA_Height, .data = height },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Backdrop, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEBUTTONS },
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const percent: u32 = @intCast(std.math.clamp(rdargs.number(argv[0]) orelse 60, 0, 100));
    const frames: u32 = @intCast(@max(rdargs.number(argv[1]) orelse 0, 0));
    const on_cores = argv[2] != 0;
    const to: ?[*:0]const u8 = if (argv[3] != 0) @ptrFromInt(argv[3]) else null;
    const in_window = argv[4] != 0;
    const every = rdargs.number(argv[6]);
    const fine = argv[5] != 0 or every != null;
    // As the ball starts: the old where it turns from that, the new with HIRES.
    const round_from: f32 = @floatFromInt(@intFromBool(argv[5] != 0 and every == null));

    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1) orelse return say(dl, "No facet.library");
    defer sys.CloseLibrary(facet_lib);
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse return say(dl, "No intuition.library");
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const mesh_memory = sys.AllocVec(@sizeOf(Mesh), exec.MEMF_ANY) orelse return say(dl, "Not enough memory");
    defer sys.FreeVec(mesh_memory);
    const mesh: *Mesh = @ptrCast(@alignCast(mesh_memory));
    mesh.* = .{};
    mesh.grid(lineWidth(round_from), picture_width, picture_height);
    mesh.ball(if (fine) fine_steps else 1);

    var screen: ?*intuition.Screen = null;
    defer if (screen) |opened| {
        ib.ScreenToBack(opened);
        _ = ib.CloseScreen(opened);
    };
    const opened_window = if (in_window) desktopWindow(ib) else blk: {
        var why: u32 = 0;
        screen = ib.OpenScreenTagList(&[_]TagItem{
            .{ .tag = sc.SA_Quiet, .data = 1 },
            .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
            .{},
        }) orelse return say(dl, "No screen");
        break :blk screenWindow(ib, screen.?);
    };
    const window = opened_window orelse return say(dl, "No window");
    defer ib.CloseWindow(window);

    var sound = Sound{ .sys = sys };
    defer sound.close();
    if (to == null) sound.open(percent);

    var gpu = Gpu{ .fb = @ptrCast(facet_lib) };
    defer gpu.down();
    const target: Target = if (in_window) .{ .window = window } else .{ .screen = screen.? };
    gpu.up(target, on_cores) catch |err| return say(dl, explain(err));
    gpu.prepare(mesh, round_from) catch |err| return say(dl, explain(err));

    var motion = bounce.Motion{};
    if (to) |name| {
        gpu.still(dl, &motion, round_from, name) catch |err| return say(dl, explain(err));
        return dos.RETURN_OK;
    }
    gpu.chain() catch |err| return say(dl, explain(err));

    var turning: ?bounce.Morph = if (every) |seconds| .{ .every = @floatFromInt(@max(seconds, 1)) } else null;
    const began = now(tb);
    var last = began;
    var drawn: u32 = 0;
    while (frames == 0 or drawn < frames) : (drawn += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0 or ending(ib, window)) break;
        const round = if (turning) |morph| morph.round() else round_from;
        if (turning != null) gpu.thicken(round);
        const shown = gpu.frame(&motion, round) catch |err| return say(dl, explain(err));
        // The window was sized: drawn from now on at its new size.
        if (!shown) {
            gpu.chain() catch |err| return say(dl, explain(err));
            continue;
        }
        const at = now(tb);
        // However long the display made it wait, and no more than a tenth
        // of a second at a time, or it would jump through a wall.
        const seconds = @min(@as(f32, @floatFromInt(at - last)) / 1_000_000, 0.1);
        last = at;
        if (turning) |*morph| morph.step(seconds);
        const hits = motion.step(seconds);
        if (hits.floor or hits.wall) sound.play(motion.pan());
    }
    if (frames != 0) {
        const elapsed = now(tb) - began;
        _ = Printf(dl, "%s: %u frames of %ux%u, %lu shown a second\n", .{
            @as([*:0]const u8, COMMAND_NAME),
            drawn,
            gpu.width,
            gpu.height,
            if (elapsed == 0) @as(u64, 0) else @as(u64, drawn) * 1_000_000 / elapsed,
        });
    }
    return dos.RETURN_OK;
}
