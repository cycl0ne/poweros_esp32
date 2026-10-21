// SPDX-License-Identifier: MIT
//! Scenes the rasterizer's tests draw: on the board by C:test/Raster and
//! C:test/Cube, and on the host against pictures kept as they should be
//! (reference.zig). A texture and its levels made from a pattern, a cube
//! that turns, a corridor that runs into the distance, and the matrices
//! that look at them.
//!
//! The vertices are made for any pipeline whose vertex has the fields they
//! fill: a position always, `uv` and `color` where the vertex has them.

const raster = @import("raster");
const Matrix = raster.Matrix;
const Texture = raster.Texture;

// --- matrices ----------------------------------------------------------------

/// `a * b`: what `b` does, then what `a` does.
pub fn multiply(a: Matrix, b: Matrix) Matrix {
    var made: Matrix = undefined;
    for (0..4) |column| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[column * 4 + k];
        made[column * 4 + row] = sum;
    };
    return made;
}

/// Seen from the origin looking down z, y up on the screen: `fov` the
/// angle the view's height takes, in radians, `aspect` its width over its
/// height, and what lies between `near` and `far` inside the depth.
pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Matrix {
    const f = 1 / @tan(fov / 2);
    var m: Matrix = @splat(0);
    m[0] = f / aspect;
    m[5] = -f;
    m[10] = far / (far - near);
    m[11] = 1;
    m[14] = -near * far / (far - near);
    return m;
}

pub fn translation(x: f32, y: f32, z: f32) Matrix {
    var m = raster.identity;
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

/// Turned round the y axis by `angle`, then round the x axis by `tilt`,
/// in radians.
pub fn turned(angle: f32, tilt: f32) Matrix {
    var round_y = raster.identity;
    round_y[0] = @cos(angle);
    round_y[2] = -@sin(angle);
    round_y[8] = @sin(angle);
    round_y[10] = @cos(angle);
    var round_x = raster.identity;
    round_x[5] = @cos(tilt);
    round_x[6] = @sin(tilt);
    round_x[9] = -@sin(tilt);
    round_x[10] = @cos(tilt);
    return multiply(round_x, round_y);
}

// --- the texture -------------------------------------------------------------

/// The pattern: squares of 32 texels, light and dark in turn, shading
/// across and down, each framed by a dark texel on every side - plain to
/// see how it lies on a face, and where it is bent. The lines lie on the
/// squares' bounds, so where two faces meet their lines meet too,
/// whichever way each runs the texture.
pub fn patternAt(x: u32, y: u32) u32 {
    if (x % 32 == 0 or x % 32 == 31 or y % 32 == 0 or y % 32 == 31) return 0xFF20_2020;
    const light = ((x / 32) ^ (y / 32)) & 1 != 0;
    const red = 0x40 + x % 256 / 2;
    const green = 0x40 + y % 256 / 2;
    const blue: u32 = if (light) 0xE0 else 0x50;
    return 0xFF00_0000 | red << 16 | green << 8 | blue;
}

/// The pattern's texture: 256 x 256, and its levels down to 1 x 1.
pub const texture_side = 256;
pub const texture_levels = 9;

/// The bytes the pattern's texture takes in `format`.
pub fn textureBytes(format: raster.TextureFormat) usize {
    return Texture.bytes(format, texture_side, texture_side, texture_levels) catch unreachable;
}

/// The pattern's texture in `format` over `memory`, `textureBytes` long:
/// each texel of each level the mean of the pattern's it covers.
pub fn patternTexture(format: raster.TextureFormat, memory: [*]u8) Texture {
    var texture = Texture.init(format, texture_side, texture_side, texture_levels, memory) catch unreachable;
    for (0..texture_levels) |lod| {
        const level: u32 = @intCast(lod);
        const block = @as(u32, 1) << @intCast(level);
        for (0..texture.height(level)) |y| for (0..texture.width(level)) |x| {
            var sums: [4]u32 = @splat(0);
            for (0..block) |dy| for (0..block) |dx| {
                const texel = patternAt(@intCast(x * block + dx), @intCast(y * block + dy));
                for (&sums, 0..) |*sum, k| sum.* += texel >> @intCast(k * 8) & 0xFF;
            };
            const count = block * block;
            var mean: u32 = 0;
            for (sums, 0..) |sum, k| mean |= (sum + count / 2) / count << @intCast(k * 8);
            texture.put(level, @intCast(x), @intCast(y), if (format == .rgb565) to565(mean) else mean);
        };
    }
    return texture;
}

fn to565(color: u32) u32 {
    return (color >> 19 & 0x1F) << 11 | (color >> 10 & 0x3F) << 5 | (color >> 3 & 0x1F);
}

/// A vertex of any pipeline: `color` and `uv` set where it has them.
pub fn vertexOf(comptime Vertex: type, position: [3]f32, color: u32, uv: [2]f32) Vertex {
    var vertex = Vertex{ .position = position };
    if (@FieldType(Vertex, "color") == u32) vertex.color = color;
    if (@FieldType(Vertex, "uv") == [2]f32) vertex.uv = uv;
    return vertex;
}

/// Two triangles of a quad, its corners in turn round it.
pub const quad_indices = [6]u16{ 0, 1, 2, 0, 2, 3 };

// --- the cube ----------------------------------------------------------------

/// Each face of a cube of side 2 round the origin: which way it faces,
/// and the two ways across it, the first turned into the second round
/// that one the way the faces' corners run.
const faces = [6][3][3]f32{
    .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
    .{ .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } },
    .{ .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 } },
    .{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } },
    .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } },
    .{ .{ 0, 0, -1 }, .{ 0, 1, 0 }, .{ 1, 0, 0 } },
};

pub const cube_vertices = 24;
pub const cube_triangles = 12;

/// The cube's corners, each face's own four with the whole texture over
/// it, and a colour of the face's own. Seen from outside, a face's
/// corners run clockwise on the screen.
pub fn cube(comptime Vertex: type) [cube_vertices]Vertex {
    var made: [cube_vertices]Vertex = undefined;
    const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    for (faces, 0..) |face, f| {
        const color = 0xFF00_0000 | @as(u32, @intCast(f + 1)) * 0x0024_4A6E & 0x00FF_FFFF;
        for (corners, uvs, 0..) |corner, uv, k| {
            var position: [3]f32 = undefined;
            for (&position, 0..) |*p, axis| p.* = face[0][axis] + corner[0] * face[1][axis] + corner[1] * face[2][axis];
            made[f * 4 + k] = vertexOf(Vertex, position, color, uv);
        }
    }
    return made;
}

pub const cube_indices = indices: {
    var made: [cube_triangles * 3]u16 = undefined;
    for (0..6) |f| {
        for (quad_indices, 0..) |corner, k| made[f * 6 + k] = @intCast(f * 4 + corner);
    }
    break :indices made;
};

/// The cube `distance` in front of the eye, turned by `angle` and its top
/// tipped towards it, over a view `aspect` wide.
pub fn cubeTransform(angle: f32, distance: f32, aspect: f32) Matrix {
    const eye = perspective(1.0, aspect, 0.5, 20);
    return multiply(eye, multiply(translation(0, 0, distance), turned(angle, -0.45 - 0.25 * @sin(angle * 0.7))));
}

/// What lies behind it: the whole view, darker at the top, as far as the
/// depth goes. For a pipeline with the identity transform.
pub fn backdrop(comptime Vertex: type) [4]Vertex {
    const far = 0.9999;
    return .{
        vertexOf(Vertex, .{ -1, -1, far }, 0xFF10_1838, .{ 0, 0 }),
        vertexOf(Vertex, .{ 1, -1, far }, 0xFF18_1040, .{ 1, 0 }),
        vertexOf(Vertex, .{ 1, 1, far }, 0xFF50_3060, .{ 1, 1 }),
        vertexOf(Vertex, .{ -1, 1, far }, 0xFF30_4870, .{ 0, 1 }),
    };
}

// --- the corridor ------------------------------------------------------------

/// How far the corridor runs, and how often the texture goes along a wall
/// in that.
const corridor_near = 0.2;
const corridor_far = 24;
const corridor_repeats = 24;

pub const corridor_vertices = 20;
pub const corridor_triangles = 10;

/// A corridor running away from the eye: its floor, its ceiling, its two
/// walls and its end, the texture `corridor_repeats` times along each
/// side. Every pixel of a 4:3 view is on one of them; the sides go from
/// right beside the eye - where a texel takes many pixels - to where a
/// pixel takes many texels.
pub fn corridor(comptime Vertex: type) [corridor_vertices]Vertex {
    const x = 1.0;
    const y = 0.75;
    const near = corridor_near;
    const far = corridor_far;
    const r = corridor_repeats;
    const sides = [5][4][3]f32{
        .{ .{ -x, -y, near }, .{ x, -y, near }, .{ x, -y, far }, .{ -x, -y, far } },
        .{ .{ -x, y, near }, .{ x, y, near }, .{ x, y, far }, .{ -x, y, far } },
        .{ .{ -x, -y, near }, .{ -x, y, near }, .{ -x, y, far }, .{ -x, -y, far } },
        .{ .{ x, -y, near }, .{ x, y, near }, .{ x, y, far }, .{ x, -y, far } },
        .{ .{ -x, -y, far }, .{ x, -y, far }, .{ x, y, far }, .{ -x, y, far } },
    };
    const along = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, r }, .{ 0, r } };
    const across = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    var made: [corridor_vertices]Vertex = undefined;
    for (sides, 0..) |side, s| {
        for (side, 0..) |position, k| {
            const uv = if (s == 4) across[k] else along[k];
            made[s * 4 + k] = vertexOf(Vertex, position, 0xFF00_0000 | @as(u32, @intCast(s + 1)) * 0x0030_2010, uv);
        }
    }
    return made;
}

pub const corridor_indices = indices: {
    var made: [corridor_triangles * 3]u16 = undefined;
    for (0..5) |s| {
        for (quad_indices, 0..) |corner, k| made[s * 6 + k] = @intCast(s * 4 + corner);
    }
    break :indices made;
};

/// The corridor seen from its middle, over a view `aspect` wide.
pub fn corridorTransform(aspect: f32) Matrix {
    return perspective(1.2, aspect, 0.1, 30);
}
