// SPDX-License-Identifier: MIT
//! Cobra: the Cobra Mk III of ELITE (1984), its own corners and faces, flying
//! through space: past a planet and the sun, stars behind it and dust going by.
//!
//!   Cobra FRAMES/K/N,CORES/S,WINDOW/S,WIRE/S
//!
//! It opens a screen of its own and draws through facet.library, on the GPU
//! where there is one and on the cores if not, or with CORES. Esc, a click of
//! the left button or Ctrl-C ends it. FRAMES ends it after so many frames and
//! says how many were shown a second. With WINDOW it flies in a window on the
//! desktop instead, which can be moved and sized; its close gadget ends it.
//! With WIRE it is as ELITE drew it: white lines, those behind hidden, on the
//! stars and the dust alone.
//!
//! What it shows of facet.library: a depth buffer, faces culled, blending, a
//! texture, push constants, and vertex functions doing the lighting and laying
//! the lines. All of it is fixed forms of fragment function, as a GPU needs.

const std = @import("std");
const sdk = @import("sdk");
const ship = @import("ship.zig");
const flight = @import("flight.zig");
const planet = @import("planet.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
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
const Matrix = flight.Matrix;

pub const COMMAND_NAME = "Cobra";
const VERSION_STRING = "\x00$VER: Cobra 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/K/N,CORES/S,WINDOW/S,WIRE/S";

// --- what it looks like -----------------------------------------------------

const star_count = 3000;
const dust_count = 1200;
const planet_rows = 48;
const planet_columns = 96;
const sun_segments = 48;

/// Where the sun and the planet stand, seen from the ship: too far for its
/// flight to move them.
const sun_towards = [3]f32{ 0.7276, 0.4851, 0.4851 };
const planet_towards = [3]f32{ -0.3219, -0.1656, 0.9322 };
const planet_far: f32 = 1000;
const planet_radius: f32 = 200;
/// How far ahead of the eye the planet must be for any of it to be seen:
/// short of it the eye could be level with the planet, which cannot be drawn.
const planet_seen_from: f32 = 0.3;
const air_above: f32 = 1.03;

/// Where the sky is drawn from: the sky's directions times this are inside
/// what the eye sees.
const sky_far: f32 = 1000;
const dust_reach: f32 = flight.dust_box / 2;
const dust_streak: f32 = 26;

const Vertex = extern struct {
    position: [3]f32,
    /// A face's normal; the other end of a line; a place on the planet's
    /// picture; how far along a flame.
    other: [3]f32 = .{ 0, 0, 0 },
    /// 0xAARRGGBB: read as b8g8r8a8_unorm.
    color: u32 = 0,
    /// A line's corner: which end, 0 or 1, and which side, -1 or 1. A point
    /// of the sky: how far from where it is.
    corner: [2]f32 = .{ 0, 0 },
};

const attributes = [_]facet.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "position") },
    .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "other") },
    .{ .location = 2, .binding = 0, .format = .b8g8r8a8_unorm, .offset = @offsetOf(Vertex, "color") },
    .{ .location = 3, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "corner") },
};

// --- the vertex functions ---------------------------------------------------

const HullConstants = extern struct {
    place: Matrix,
    /// In the ship's space: towards the sun, towards the planet, and where
    /// the eye is. A face that shines by itself burns at `glow`.
    sun: [3]f32,
    glow: f32,
    eye: [3]f32,
    pad: f32 = 0,
    planet: [3]f32,
    pad2: f32 = 0,
};

const FlameConstants = extern struct {
    place: Matrix,
    length: f32,
    strength: f32,
};

const SkyConstants = extern struct {
    place: Matrix,
    /// How far a point's `corner` of 1 takes it across and down, in clip space.
    scale: [2]f32,
};

const PlanetConstants = extern struct {
    place: Matrix,
    /// In the planet's space: towards the sun, and towards the eye.
    sun: [3]f32,
    pad: f32 = 0,
    eye: [3]f32,
    pad2: f32 = 0,
};

const LineConstants = extern struct {
    place: Matrix,
    /// The eye in the world, and how far the ship has gone: where the dust is.
    eye: [3]f32 = .{ 0, 0, 0 },
    gone: f32 = 0,
    /// Clip space's width of a pixel, across and down, and a line's in pixels.
    pixel: [2]f32,
    width: f32,
    /// How much of its colour a line of the ship has.
    bright: f32 = 1,
};

const biggest_constants = @max(@max(@sizeOf(HullConstants), @sizeOf(FlameConstants)), @max(@sizeOf(SkyConstants), @max(@sizeOf(PlanetConstants), @sizeOf(LineConstants))));

/// A place outside the picture: every corner of what must not be seen goes
/// there, and it is no triangle at all.
const nowhere = [4]f32{ 2, 2, 0.5, 1 };

inline fn dot(a: [4]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline fn normalised(v: [3]f32) [3]f32 {
    const length = @sqrt(dot3(v, v));
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

/// The face's own colour by the sun, a little of the planet's light from its
/// side and the glint of the sun on it: a face all of one light is the ship
/// ELITE's later versions drew, its corners only a little apart in the glint.
fn hullVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(HullConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const n = vertices.input(@intCast(k), 1);
        const c = vertices.input(@intCast(k), 2);
        const clip = shader.transform(&given.place, .{ p[0], p[1], p[2] });
        const sunward = @max(0, dot(n, given.sun));
        const planetward = @max(0, dot(n, given.planet)) * 0.22;
        // Some light always, and some back from what the sun lights behind it.
        const light = 0.2 + 0.8 * sunward + 0.14 * @max(0, -dot(n, given.sun));
        const looking = normalised(.{ given.eye[0] - p[0], given.eye[1] - p[1], given.eye[2] - p[2] });
        const halfway = normalised(.{ given.sun[0] + looking[0], given.sun[1] + looking[1], given.sun[2] + looking[2] });
        const towards = @max(0, dot(n, halfway));
        const t2 = towards * towards;
        const t4 = t2 * t2;
        const t8 = t4 * t4;
        const t16 = t8 * t8;
        const glint = 0.7 * t16 * t16 * @min(sunward * 8, 1);
        // The alpha says how much of it does not hang on any light.
        const own = (1 - c[3]) * given.glow;
        const lit = c[3];
        vertices.output(@intCast(k))[0..8].* = .{
            clip[0],
            clip[1],
            clip[2],
            clip[3],
            shader.channel(@min(1, c[0] * (own + lit * (light + planetward * 0.3)) + glint * lit)),
            shader.channel(@min(1, c[1] * (own + lit * (light + planetward * 0.5)) + glint * lit)),
            shader.channel(@min(1, c[2] * (own + lit * (light + planetward)) + glint * lit)),
            shader.channel(1),
        };
    }
}

/// All black: what hides the lines behind it, with WIRE.
fn blackVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(HullConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const clip = shader.transform(&given.place, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(0), shader.channel(0), shader.channel(0), shader.channel(1) };
    }
}

/// A flame's tip goes back from the engine, as long as it burns.
fn flameVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(FlameConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 2);
        const along = vertices.input(@intCast(k), 1)[0];
        const clip = shader.transform(&given.place, .{ p[0], p[1], p[2] - along * given.length });
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3] * given.strength) };
    }
}

/// A point of the sky: its corners so far from where the direction is seen.
fn skyVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(SkyConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 2);
        const corner = vertices.input(@intCast(k), 3);
        var clip = shader.transform(&given.place, .{ p[0] * sky_far, p[1] * sky_far, p[2] * sky_far });
        if (clip[3] < flight.near + 1) {
            clip = nowhere;
        } else {
            clip[0] += corner[0] * given.scale[0] * clip[3];
            clip[1] += corner[1] * given.scale[1] * clip[3];
        }
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

/// Its picture, by the sun: past the edge of the day a little of it still
/// falls, then none.
fn planetVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(PlanetConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const uv = vertices.input(@intCast(k), 1);
        const clip = shader.transform(&given.place, .{ p[0], p[1], p[2] });
        const lit = shader.channel(std.math.clamp(dot(p, given.sun) * 1.2 + 0.1, 0.025, 1));
        vertices.output(@intCast(k))[0..10].* = .{ clip[0], clip[1], clip[2], clip[3], uv[0], uv[1], lit, lit, lit, shader.channel(1) };
    }
}

/// The air round it: thin ahead, thick at the edge the eye sees it through,
/// gone at its outside, and on the side of the sun alone.
fn airVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(PlanetConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const clip = shader.transform(&given.place, .{ p[0], p[1], p[2] });
        const facing = @max(0, dot(p, given.eye));
        const away = 1 - facing;
        const away2 = away * away;
        const sunlit = std.math.clamp(dot(p, given.sun) * 1.6 + 0.35, 0, 1);
        const thick = @min(1, facing * away2 * away2 * 5.5);
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(0.45), shader.channel(0.68), shader.channel(1), shader.channel(thick * sunlit) };
    }
}

/// A line from `a` to `b`, in clip space, `given.width` pixels wide: this
/// vertex's corner of it. It is not seen if an end is too near the eye.
inline fn lineCorner(a: [4]f32, b: [4]f32, corner: [4]f32, given: *const LineConstants) [4]f32 {
    if (a[3] < flight.near or b[3] < flight.near) return nowhere;
    const across = (b[0] / b[3] - a[0] / a[3]) / given.pixel[0];
    const down = (b[1] / b[3] - a[1] / a[3]) / given.pixel[1];
    const length = @max(@sqrt(across * across + down * down), 0.001);
    const half = given.width * 0.5 * corner[1];
    const end = if (corner[0] > 0.5) b else a;
    return .{
        end[0] - down / length * half * given.pixel[0] * end[3],
        end[1] + across / length * half * given.pixel[1] * end[3],
        end[2],
        end[3],
    };
}

/// One of ELITE's lines, a little nearer than the faces it lies on.
fn wireVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(LineConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const o = vertices.input(@intCast(k), 1);
        const c = vertices.input(@intCast(k), 2);
        const a = shader.transform(&given.place, .{ p[0], p[1], p[2] });
        const b = shader.transform(&given.place, .{ o[0], o[1], o[2] });
        const clip = lineCorner(a, b, vertices.input(@intCast(k), 3), given);
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2] - 0.0005 * clip[3], clip[3], shader.channel(c[0] * given.bright), shader.channel(c[1] * given.bright), shader.channel(c[2] * given.bright), shader.channel(1) };
    }
}

/// A speck going past: the box it lies in repeats all round the eye, it is
/// drawn where it came from to where it is, and it fades out before the box
/// ends, so that it comes and goes unseen.
fn dustVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const given = vertices.resources.constants(LineConstants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 2);
        const x = flight.wrapped(p[0] - given.eye[0]);
        const y = flight.wrapped(p[1] - given.eye[1]);
        const z = flight.wrapped(p[2] - given.gone - given.eye[2]);
        const a = shader.transform(&given.place, .{ x, y, z });
        const b = shader.transform(&given.place, .{ x, y, z + dust_streak });
        const clip = lineCorner(a, b, vertices.input(@intCast(k), 3), given);
        const out = @max(0, 1 - (x * x + y * y + z * z) / (dust_reach * dust_reach));
        vertices.output(@intCast(k))[0..8].* = .{ clip[0], clip[1], clip[2], clip[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3] * out) };
    }
}

const entries = [_]shader.Entry{
    shader.vertex("hull", &hullVertex, 4),
    shader.vertex("black", &blackVertex, 4),
    shader.vertex("flame", &flameVertex, 4),
    shader.vertex("sky", &skyVertex, 4),
    shader.vertex("planet", &planetVertex, 6),
    shader.vertex("air", &airVertex, 4),
    shader.vertex("wire", &wireVertex, 4),
    shader.vertex("dust", &dustVertex, 4),
    shader.fixedFragment("flat", .{ .kind = .color }),
    shader.fixedFragment("pictured", .{ .kind = .texture_color, .sampling = .{ .filter = .bilinear } }),
};
const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

// --- the mesh ---------------------------------------------------------------

const flame_corners = ship.engines.len * 4 * 3;
const sun_corners = 1 + sun_segments * 3;
const sun_indices = sun_segments * 3 + sun_segments * 12;
const planet_corners = (planet_rows + 1) * (planet_columns + 1);
const planet_indices = planet_rows * planet_columns * 6;
const most_vertices = ship.meshCorners() + flame_corners + sun_corners + planet_corners + (star_count + dust_count + ship.edges.len) * 4;
const most_indices = ship.meshCorners() * 3 + flame_corners + sun_indices + planet_indices + (star_count + dust_count + ship.edges.len) * 6;

/// Which of the indices something is.
const Part = struct {
    first: u32 = 0,
    count: u32 = 0,
};

const Mesh = struct {
    vertices: [most_vertices]Vertex = undefined,
    indices: [most_indices]u16 = undefined,
    vertex_at: u16 = 0,
    index_at: u32 = 0,
    hull: Part = .{},
    flames: Part = .{},
    stars: Part = .{},
    sun: Part = .{},
    planet: Part = .{},
    wire: Part = .{},
    dust: Part = .{},
    /// For the stars and the dust.
    seed: u32 = 0,

    fn index(mesh: *Mesh, at: u16) void {
        mesh.indices[mesh.index_at] = at;
        mesh.index_at += 1;
    }

    fn add(mesh: *Mesh, vertex: Vertex) u16 {
        const at = mesh.vertex_at;
        mesh.vertices[at] = vertex;
        mesh.vertex_at += 1;
        return at;
    }

    fn begin(mesh: *const Mesh) Part {
        return .{ .first = mesh.index_at };
    }

    fn end(mesh: *const Mesh, part: Part) Part {
        return .{ .first = part.first, .count = mesh.index_at - part.first };
    }

    /// A number from 0 up to 1.
    fn random(mesh: *Mesh) f32 {
        mesh.seed = mesh.seed *% 1_664_525 +% 1_013_904_223;
        return @as(f32, @floatFromInt(mesh.seed >> 8)) / 16_777_216.0;
    }

    /// A face made into triangles, each with the face's normal, `out` units
    /// out of it.
    fn face(mesh: *Mesh, each: ship.Face, out: f32) void {
        const normal = ship.normalOf(each);
        const first = mesh.vertex_at;
        for (each.at) |at| {
            const p = ship.corners[at];
            _ = mesh.add(.{
                .position = .{ p[0] + normal[0] * out, p[1] + normal[1] * out, p[2] + normal[2] * out },
                .other = normal,
                .color = each.color,
            });
        }
        for (1..each.at.len - 1) |k| {
            mesh.index(first);
            mesh.index(first + @as(u16, @intCast(k)));
            mesh.index(first + @as(u16, @intCast(k + 1)));
        }
    }

    fn makeHull(mesh: *Mesh) void {
        const part = mesh.begin();
        for (ship.hull) |each| mesh.face(each, 0);
        for (ship.decals) |each| mesh.face(each, 1);
        for (ship.gun) |each| mesh.face(each, 0);
        mesh.hull = mesh.end(part);
    }

    /// Four triangles for each engine, from its corners to a tip behind its
    /// middle.
    fn makeFlames(mesh: *Mesh) void {
        const part = mesh.begin();
        const base: u32 = 0x90FFB060;
        const tip: u32 = 0x00FF2800;
        for (ship.engines) |engine| {
            var middle = [3]f32{ 0, 0, -41 };
            for (engine) |at| {
                middle[0] += ship.corners[at][0] / 4;
                middle[1] += ship.corners[at][1] / 4;
            }
            for (engine, 0..) |at, k| {
                const a = ship.corners[at];
                const b = ship.corners[engine[(k + 1) % 4]];
                mesh.index(mesh.add(.{ .position = .{ a[0], a[1], -41 }, .color = base }));
                mesh.index(mesh.add(.{ .position = .{ b[0], b[1], -41 }, .color = base }));
                mesh.index(mesh.add(.{ .position = middle, .other = .{ 1, 0, 0 }, .color = tip }));
            }
        }
        mesh.flames = mesh.end(part);
    }

    /// Four corners about one place, or two lines' ends: two triangles.
    fn square(mesh: *Mesh, position: [3]f32, other: [3]f32, color: u32, corners: [4][2]f32) void {
        const first = mesh.vertex_at;
        for (corners) |corner| _ = mesh.add(.{ .position = position, .other = other, .color = color, .corner = corner });
        for ([6]u16{ 0, 1, 2, 2, 1, 3 }) |each| mesh.index(first + each);
    }

    const line_corners = [4][2]f32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, -1 }, .{ 1, 1 } };

    /// Stars all over the sky, more of them in a band across it, most of them
    /// faint, some a little blue or a little red.
    fn makeStars(mesh: *Mesh) void {
        const part = mesh.begin();
        for (0..star_count) |k| {
            const round = mesh.random() * 2 * std.math.pi;
            const band = k % 5 < 3;
            const high = (mesh.random() * 2 - 1) * @as(f32, @floatFromInt(@intFromBool(!band))) +
                (mesh.random() * mesh.random() * 0.6 - 0.15) * @as(f32, @floatFromInt(@intFromBool(band)));
            const wide = @sqrt(1 - @min(high * high, 1));
            const flat = [3]f32{ wide * @cos(round), high, wide * @sin(round) };
            // The band leans across the sky.
            const direction = [3]f32{ flat[0], flat[1] * 0.82 + flat[2] * 0.57, flat[2] * 0.82 - flat[1] * 0.57 };
            const bright = mesh.random();
            const strength = 0.12 + 0.88 * bright * bright * bright;
            const big = 1 + @as(f32, @floatFromInt(@intFromBool(bright > 0.97))) * 0.6;
            const tint = mesh.random() - 0.5;
            const color = opaque255(strength * (1 + @max(tint, 0) * 0.3), strength * (1 - @abs(tint) * 0.1), strength * (1 - @max(tint, 0) * 0.3 + @max(-tint, 0) * 0.3));
            mesh.square(direction, .{ 0, 0, 0 }, color, .{ .{ -big, -big }, .{ big, -big }, .{ -big, big }, .{ big, big } });
        }
        mesh.stars = mesh.end(part);
    }

    /// A white disc, a bright yellow glow close round it and a faint one far
    /// out, which goes to nothing.
    fn makeSun(mesh: *Mesh) void {
        const part = mesh.begin();
        const rings = [3]struct { reach: f32, color: u32 }{
            .{ .reach = 0.045, .color = 0xFFFFFCE8 },
            .{ .reach = 0.1, .color = 0x70FFE090 },
            .{ .reach = 0.4, .color = 0x00FFB050 },
        };
        const middle = mesh.add(.{ .position = sun_towards, .color = 0xFFFFFFFF });
        const first = mesh.vertex_at;
        for (0..sun_segments) |k| {
            const round = @as(f32, @floatFromInt(k)) / sun_segments * 2 * std.math.pi;
            for (rings) |ring| _ = mesh.add(.{ .position = sun_towards, .color = ring.color, .corner = .{ @cos(round) * ring.reach, @sin(round) * ring.reach } });
        }
        for (0..sun_segments) |k| {
            const here: u16 = first + @as(u16, @intCast(k * rings.len));
            const next: u16 = first + @as(u16, @intCast((k + 1) % sun_segments * rings.len));
            mesh.index(middle);
            mesh.index(here);
            mesh.index(next);
            for (0..rings.len - 1) |ring| {
                const r: u16 = @intCast(ring);
                for ([6]u16{ here + r, here + r + 1, next + r, next + r, here + r + 1, next + r + 1 }) |each| mesh.index(each);
            }
        }
        mesh.sun = mesh.end(part);
    }

    fn makePlanet(mesh: *Mesh) void {
        const part = mesh.begin();
        const first = mesh.vertex_at;
        for (0..planet_rows + 1) |row| for (0..planet_columns + 1) |column| {
            const u = @as(f32, @floatFromInt(column)) / planet_columns;
            const v = @as(f32, @floatFromInt(row)) / planet_rows;
            _ = mesh.add(.{ .position = planet.pointAt(u, v), .other = .{ u, v, 0 } });
        };
        const across: u16 = planet_columns + 1;
        for (0..planet_rows) |row| for (0..planet_columns) |column| {
            const a = first + @as(u16, @intCast(row)) * across + @as(u16, @intCast(column));
            // Their cross product out of the sphere, as a face of the ship's.
            for ([6]u16{ a, a + across, a + 1, a + 1, a + across, a + across + 1 }) |each| mesh.index(each);
        };
        mesh.planet = mesh.end(part);
    }

    fn makeWire(mesh: *Mesh) void {
        const part = mesh.begin();
        for (ship.edges) |edge| mesh.square(ship.corners[edge[0]], ship.corners[edge[1]], 0xFFFFFFFF, line_corners);
        mesh.wire = mesh.end(part);
    }

    fn makeDust(mesh: *Mesh) void {
        const part = mesh.begin();
        for (0..dust_count) |_| {
            const place = [3]f32{ mesh.random() * flight.dust_box, mesh.random() * flight.dust_box, mesh.random() * flight.dust_box };
            const alpha: u32 = @intFromFloat(60 + mesh.random() * 130);
            mesh.square(place, .{ 0, 0, 0 }, alpha << 24 | 0xDCE6FF, line_corners);
        }
        mesh.dust = mesh.end(part);
    }

    fn make(mesh: *Mesh) void {
        // The same sky every time.
        mesh.seed = 0x2F6E_2B1D;
        mesh.makeHull();
        mesh.makeFlames();
        mesh.makeStars();
        mesh.makeSun();
        mesh.makePlanet();
        mesh.makeWire();
        mesh.makeDust();
    }
};

fn opaque255(r: f32, g: f32, b: f32) u32 {
    const red: u32 = @intFromFloat(@min(r, 1) * 255);
    const green: u32 = @intFromFloat(@min(g, 1) * 255);
    const blue: u32 = @intFromFloat(@min(b, 1) * 255);
    return 0xFF00_0000 | red << 16 | green << 8 | blue;
}

/// `m` made `size` times as big, standing at `at`.
fn sized(m: Matrix, size: f32, at: [3]f32) Matrix {
    return .{
        m[0] * size, m[1] * size, m[2] * size,  0,
        m[4] * size, m[5] * size, m[6] * size,  0,
        m[8] * size, m[9] * size, m[10] * size, 0,
        at[0],       at[1],       at[2],        1,
    };
}

// --- what draws -------------------------------------------------------------

const Failure = error{ NoDevice, NoSurface, NoMemory, Refused, DeviceLost };

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

/// How a pipeline treats the depth buffer.
const Depth = enum { none, read, write };

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
    depth: ?*facet.Image = null,
    depth_memory: ?*facet.DeviceMemory = null,
    depth_view: ?*facet.ImageView = null,
    pass: ?*facet.RenderPass = null,
    module: ?*facet.ShaderModule = null,
    set_layout: ?*facet.DescriptorSetLayout = null,
    descriptor_pool: ?*facet.DescriptorPool = null,
    picture_set: ?*facet.DescriptorSet = null,
    picture: ?*facet.Image = null,
    picture_memory: ?*facet.DeviceMemory = null,
    picture_view: ?*facet.ImageView = null,
    layout: ?*facet.PipelineLayout = null,
    hull: ?*facet.Pipeline = null,
    black: ?*facet.Pipeline = null,
    flame: ?*facet.Pipeline = null,
    stars: ?*facet.Pipeline = null,
    glow: ?*facet.Pipeline = null,
    globe: ?*facet.Pipeline = null,
    air: ?*facet.Pipeline = null,
    wire: ?*facet.Pipeline = null,
    dust: ?*facet.Pipeline = null,
    mesh: *const Mesh = undefined,
    buffer: ?*facet.Buffer = null,
    memory: ?*facet.DeviceMemory = null,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    acquired: ?*facet.Semaphore = null,
    rendered: ?*facet.Semaphore = null,

    fn down(gpu: *Gpu) void {
        const fb = gpu.fb;
        if (gpu.device) |device| {
            _ = fb.DeviceWaitIdle(device);
            gpu.unchain();
            fb.DestroySwapchain(device, gpu.swapchain);
            fb.DestroySemaphore(device, gpu.rendered);
            fb.DestroySemaphore(device, gpu.acquired);
            fb.DestroyFence(device, gpu.fence);
            fb.DestroyCommandPool(device, gpu.command_pool);
            for ([_]?*facet.Pipeline{ gpu.dust, gpu.wire, gpu.air, gpu.globe, gpu.glow, gpu.stars, gpu.flame, gpu.black, gpu.hull }) |each| fb.DestroyPipeline(device, each);
            fb.DestroyPipelineLayout(device, gpu.layout);
            fb.DestroyShaderModule(device, gpu.module);
            fb.DestroyRenderPass(device, gpu.pass);
            fb.DestroyImageView(device, gpu.picture_view);
            fb.DestroyImage(device, gpu.picture);
            fb.FreeMemory(device, gpu.picture_memory);
            fb.DestroyDescriptorPool(device, gpu.descriptor_pool);
            fb.DestroyDescriptorSetLayout(device, gpu.set_layout);
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

    fn pipeline(gpu: *Gpu, vertex: [*:0]const u8, fragment: [*:0]const u8, front_only: bool, blended: bool, depth_use: Depth) Failure!*facet.Pipeline {
        const stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = gpu.module.?, .name = vertex },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = gpu.module.?, .name = fragment },
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
            .front_face = .clockwise,
        };
        const dynamic_states = [2]facet.DynamicState{ .viewport, .scissor };
        const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = dynamic_states.len, .dynamic_states = &dynamic_states };
        const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = depth_use != .none, .depth_write_enable = depth_use == .write };
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
    fn prepare(gpu: *Gpu, mesh: *const Mesh) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = gpu.format, .load_op = .clear, .store_op = .store, .final_layout = .present_src },
            .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &gpu.pass), error.Refused);
        try expect(fb.CreateShaderModule(device, &.{ .code = &code }, &gpu.module), error.Refused);
        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &gpu.set_layout), error.Refused);
        const range = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = biggest_constants };
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&gpu.set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &gpu.layout), error.Refused);
        gpu.hull = try gpu.pipeline("hull", "flat", true, false, .write);
        gpu.black = try gpu.pipeline("black", "flat", true, false, .write);
        gpu.flame = try gpu.pipeline("flame", "flat", false, true, .read);
        gpu.stars = try gpu.pipeline("sky", "flat", false, false, .none);
        gpu.glow = try gpu.pipeline("sky", "flat", false, true, .none);
        gpu.globe = try gpu.pipeline("planet", "pictured", true, false, .none);
        gpu.air = try gpu.pipeline("air", "flat", true, true, .none);
        gpu.wire = try gpu.pipeline("wire", "flat", false, false, .read);
        gpu.dust = try gpu.pipeline("dust", "flat", false, true, .read);
        gpu.mesh = mesh;

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

    /// The planet's picture made, and copied to where the device reads it.
    fn loadPicture(gpu: *Gpu) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const extent = facet.Extent3D{ .width = planet.width, .height = planet.height };
        try expect(fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, &gpu.picture), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, gpu.picture.?, &needs);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = try gpu.typeFor(needs, 0) }, &gpu.picture_memory), error.NoMemory);
        try expect(fb.BindImageMemory(device, gpu.picture.?, gpu.picture_memory.?, 0), error.Refused);
        try expect(fb.CreateImageView(device, &.{ .image = gpu.picture.?, .format = .b8g8r8a8_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR, .level_count = 1, .layer_count = 1 } }, &gpu.picture_view), error.Refused);
        try expect(fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &gpu.descriptor_pool), error.Refused);
        var sets: [1]?*facet.DescriptorSet = undefined;
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = gpu.descriptor_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&gpu.set_layout) }, &sets), error.Refused);
        gpu.picture_set = sets[0];
        const image_info = facet.DescriptorImageInfo{ .image_view = gpu.picture_view };
        const write = facet.WriteDescriptorSet{ .dst_set = gpu.picture_set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

        const bytes = planet.width * planet.height * 4;
        var staging: ?*facet.Buffer = null;
        var staging_memory: ?*facet.DeviceMemory = null;
        defer {
            fb.DestroyBuffer(device, staging);
            fb.FreeMemory(device, staging_memory);
        }
        try expect(fb.CreateBuffer(device, &.{ .size = bytes, .usage = facet.BUFFER_USAGE_TRANSFER_SRC }, &staging), error.Refused);
        fb.GetBufferMemoryRequirements(device, staging.?, &needs);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = try gpu.typeFor(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE) }, &staging_memory), error.NoMemory);
        try expect(fb.BindBufferMemory(device, staging.?, staging_memory.?, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(device, staging_memory.?, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        const pixels: [*]u32 = @ptrCast(@alignCast(data.?));
        planet.fill(pixels[0 .. planet.width * planet.height]);

        const commands = gpu.commands.?;
        try expect(fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        const region = facet.BufferImageCopy{ .image_extent = extent };
        fb.CmdCopyBufferToImage(commands, staging.?, gpu.picture.?, .transfer_dst_optimal, 1, @ptrCast(&region));
        try expect(fb.EndCommandBuffer(commands), error.Refused);
        try gpu.play(null, null);
    }

    /// What hangs on the swapchain's images, given back.
    fn unchain(gpu: *Gpu) void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        for (&gpu.framebuffers) |*each| {
            fb.DestroyFramebuffer(device, each.*);
            each.* = null;
        }
        for (&gpu.views) |*each| {
            fb.DestroyImageView(device, each.*);
            each.* = null;
        }
        fb.DestroyImageView(device, gpu.depth_view);
        fb.DestroyImage(device, gpu.depth);
        fb.FreeMemory(device, gpu.depth_memory);
        gpu.depth_view = null;
        gpu.depth = null;
        gpu.depth_memory = null;
    }

    /// A swapchain at the surface's size, a framebuffer over each image with
    /// one depth buffer, in the place of one there was.
    fn chain(gpu: *Gpu) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const old = gpu.swapchain;
        if (old != null) {
            _ = fb.DeviceWaitIdle(device);
            gpu.unchain();
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

        // Depth lives in the tiles alone: memory with nothing behind it.
        try expect(fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = .{ .width = gpu.width, .height = gpu.height }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &gpu.depth), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, gpu.depth.?, &needs);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = try gpu.typeFor(needs, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED) }, &gpu.depth_memory), error.NoMemory);
        try expect(fb.BindImageMemory(device, gpu.depth.?, gpu.depth_memory.?, 0), error.Refused);
        try expect(fb.CreateImageView(device, &.{ .image = gpu.depth.?, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .level_count = 1, .layer_count = 1 } }, &gpu.depth_view), error.Refused);

        gpu.image_count = most_images;
        _ = fb.GetSwapchainImages(device, gpu.swapchain.?, &gpu.image_count, &gpu.images);
        for (gpu.images[0..gpu.image_count], 0..) |each, k| {
            try expect(fb.CreateImageView(device, &.{ .image = each, .format = gpu.format, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR, .level_count = 1, .layer_count = 1 } }, &gpu.views[k]), error.Refused);
            const views = [2]*facet.ImageView{ gpu.views[k].?, gpu.depth_view.? };
            try expect(fb.CreateFramebuffer(device, &.{ .render_pass = gpu.pass.?, .attachment_count = 2, .attachments = &views, .width = gpu.width, .height = gpu.height, .layers = 1 }, &gpu.framebuffers[k]), error.Refused);
        }
    }

    fn draw(gpu: *Gpu, commands: *facet.CommandBuffer, which: ?*facet.Pipeline, part: Part, constants: anytype) void {
        const fb = gpu.fb;
        fb.CmdBindPipeline(commands, .graphics, which.?);
        fb.CmdPushConstants(commands, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(@TypeOf(constants.*)), constants);
        fb.CmdDrawIndexed(commands, part.count, 1, part.first, 0, 0);
    }

    /// One frame recorded: the sky, the ship, the dust past it.
    fn record(gpu: *Gpu, framebuffer: *facet.Framebuffer, t: f32, gone: f32, wire: bool) Failure!void {
        const fb = gpu.fb;
        const commands = gpu.commands.?;
        const mesh = gpu.mesh;
        const width: f32 = @floatFromInt(gpu.width);
        const height: f32 = @floatFromInt(gpu.height);
        try expect(fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        const area = facet.Rect2D{ .extent = .{ .width = gpu.width, .height = gpu.height } };
        const clear = [2]facet.ClearValue{
            .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
            .{ .depth_stencil = .{ .depth = 1 } },
        };
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = gpu.pass.?, .framebuffer = framebuffer, .render_area = area, .clear_value_count = 2, .clear_values = &clear }, .@"inline");
        const viewport = facet.Viewport{ .width = width, .height = height, .max_depth = 1 };
        fb.CmdSetViewport(commands, 0, 1, @ptrCast(&viewport));
        fb.CmdSetScissor(commands, 0, 1, @ptrCast(&area));
        const offset: u64 = 0;
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&gpu.buffer), @ptrCast(&offset));
        fb.CmdBindIndexBuffer(commands, gpu.buffer.?, @sizeOf(@TypeOf(mesh.vertices)), .uint16);

        const moment = flight.momentAt(t);
        const projection = flight.projection(width / height);
        const sky = flight.multiply(projection, moment.sky);
        // The whole of the picture at about a line's thickness on a high one.
        const line_scale = @max(1, height / 1080);
        const pixel = [2]f32{ 2 / width, 2 / height };

        const star_size = SkyConstants{ .place = sky, .scale = .{ pixel[0] * 0.75 * line_scale, pixel[1] * 0.75 * line_scale } };
        gpu.draw(commands, gpu.stars, mesh.stars, &star_size);
        if (!wire) {
            const glow_size = SkyConstants{ .place = sky, .scale = .{ height / width, 1 } };
            gpu.draw(commands, gpu.glow, mesh.sun, &glow_size);
            const ahead = [3]f32{ moment.sky[2], moment.sky[6], moment.sky[10] };
            if (dot3(ahead, planet_towards) > planet_seen_from) {
                const turn = flight.planetTurn(t);
                const stands = [3]f32{ planet_towards[0] * planet_far, planet_towards[1] * planet_far, planet_towards[2] * planet_far };
                const sun_there = flight.back(turn, sun_towards);
                const eye_there = flight.back(turn, .{ -planet_towards[0], -planet_towards[1], -planet_towards[2] });
                const globe = PlanetConstants{ .place = flight.multiply(sky, sized(turn, planet_radius, stands)), .sun = sun_there, .eye = eye_there };
                fb.CmdBindDescriptorSets(commands, .graphics, gpu.layout.?, 0, 1, @ptrCast(&gpu.picture_set), 0, null);
                gpu.draw(commands, gpu.globe, mesh.planet, &globe);
                const air = PlanetConstants{ .place = flight.multiply(sky, sized(turn, planet_radius * air_above, stands)), .sun = sun_there, .eye = eye_there };
                gpu.draw(commands, gpu.air, mesh.planet, &air);
            }
        }

        const ship_place = flight.multiply(projection, flight.multiply(moment.view, moment.ship));
        const hull = HullConstants{
            .place = ship_place,
            .sun = flight.back(moment.ship, sun_towards),
            .glow = flight.flicker(t),
            .eye = flight.back(moment.ship, .{ moment.eye[0] - moment.ship[12], moment.eye[1] - moment.ship[13], moment.eye[2] - moment.ship[14] }),
            .planet = flight.back(moment.ship, planet_towards),
        };
        gpu.draw(commands, if (wire) gpu.black else gpu.hull, mesh.hull, &hull);
        // ELITE's lines: all there is of it with WIRE, faint on the faces if not.
        const lines = if (wire)
            LineConstants{ .place = ship_place, .pixel = pixel, .width = 1.5 * line_scale }
        else
            LineConstants{ .place = ship_place, .pixel = pixel, .width = line_scale, .bright = 0.42 };
        gpu.draw(commands, gpu.wire, mesh.wire, &lines);
        if (!wire) {
            const burn = flight.flicker(t);
            const flames = FlameConstants{ .place = ship_place, .length = 62 * burn, .strength = burn };
            gpu.draw(commands, gpu.flame, mesh.flames, &flames);
        }
        const specks = LineConstants{ .place = sky, .eye = moment.eye, .gone = gone, .pixel = pixel, .width = 1.25 * line_scale };
        gpu.draw(commands, gpu.dust, mesh.dust, &specks);

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
    fn frame(gpu: *Gpu, t: f32, gone: f32, wire: bool) Failure!bool {
        const fb = gpu.fb;
        var index: u32 = 0;
        switch (fb.AcquireNextImage(gpu.device.?, gpu.swapchain.?, facet.WAIT_FOREVER_NS, gpu.acquired, null, &index)) {
            .success, .suboptimal => {},
            .error_out_of_date => return false,
            .error_device_lost => return error.DeviceLost,
            else => return error.NoSurface,
        }
        try gpu.record(gpu.framebuffers[index].?, t, gone, wire);
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
};

fn explain(err: Failure) [*:0]const u8 {
    return switch (err) {
        error.NoDevice => "No device of facet.library's draws on this screen",
        error.NoSurface => "No surface over the screen",
        error.NoMemory => "Not enough memory",
        error.Refused => "facet.library refused something",
        error.DeviceLost => "The device is lost: it stopped drawing",
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

/// A window on the desktop, until it is sized.
fn desktopWindow(ib: *IntuitionBase) ?*intuition.Window {
    const as_large_as_the_screen: usize = @bitCast(@as(isize, -1));
    return ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_InnerWidth, .data = 960 },
        .{ .tag = wn.WA_InnerHeight, .data = 540 },
        .{ .tag = wn.WA_Position, .data = wn.WPOS_CENTERSCREEN },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_MinWidth, .data = 240 },
        .{ .tag = wn.WA_MinHeight, .data = 135 },
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
    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const frames: u32 = @intCast(@max(rdargs.number(argv[0]) orelse 0, 0));
    const on_cores = argv[1] != 0;
    const in_window = argv[2] != 0;
    const wire = argv[3] != 0;

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
    mesh.make();

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

    var gpu = Gpu{ .fb = @ptrCast(facet_lib) };
    defer gpu.down();
    const target: Target = if (in_window) .{ .window = window } else .{ .screen = screen.? };
    gpu.up(target, on_cores) catch |err| return say(dl, explain(err));
    gpu.prepare(mesh) catch |err| return say(dl, explain(err));
    gpu.loadPicture() catch |err| return say(dl, explain(err));
    gpu.chain() catch |err| return say(dl, explain(err));

    const began = now(tb);
    var last = began;
    var t: f32 = 0;
    var gone: f32 = 0;
    var drawn: u32 = 0;
    while (frames == 0 or drawn < frames) : (drawn += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0 or ending(ib, window)) break;
        const shown = gpu.frame(t, gone, wire) catch |err| return say(dl, explain(err));
        // The window was sized: drawn from now on at its new size.
        if (!shown) {
            gpu.chain() catch |err| return say(dl, explain(err));
            continue;
        }
        const at = now(tb);
        // However long the display made it wait, and no more than a tenth of a
        // second at a time, or the flight would jump.
        const seconds = @min(@as(f32, @floatFromInt(at - last)) / 1_000_000, 0.1);
        last = at;
        t = @mod(t + seconds, flight.cycle);
        gone = @mod(gone + seconds * flight.speed, flight.dust_box);
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
