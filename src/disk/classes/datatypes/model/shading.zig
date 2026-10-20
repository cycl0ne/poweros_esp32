// SPDX-License-Identifier: MIT
//! How model.datatype's triangles are drawn: the vertex they are read
//! from, and the shader functions facet.library runs over them.
//!
//! The light is worked out at each vertex - how squarely its normal faces
//! the light, either side alike, and `camera.ambient` where it does not
//! - times the material's colour, and carried over the triangle: a model
//! drawn by the cores of a microcontroller has its lighting done once a
//! vertex, not once a pixel. A part without a picture is that colour,
//! mixed over the triangle (`shader.smooth`); one with a picture is the
//! picture, filtered, times the colour at the middle of each square of
//! four pixels.

const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const ModelVertex = sdk.datatypes.modelclass.ModelVertex;

/// What a part is drawn with, in the push constants.
pub const Constants = extern struct {
    /// Into clip space (`camera.View.transform`).
    transform: [16]f32,
    /// Towards the light in the model's space, then how much falls where
    /// it does not reach.
    light: [4]f32,
    /// The material's colour, 0 to 1.
    color: [4]f32,
};

/// Where a vertex's fields are.
pub const attributes = [_]facet.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(ModelVertex, "position") },
    .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(ModelVertex, "normal") },
    .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(ModelVertex, "uv") },
};

/// How much light a vertex facing `normal` takes.
inline fn lightOn(constants: *const Constants, normal: [4]f32) f32 {
    const facing = @abs(normal[0] * constants.light[0] + normal[1] * constants.light[1] + normal[2] * constants.light[2]);
    return constants.light[3] + (1 - constants.light[3]) * @min(facing, 1);
}

fn colouredVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const constants = vertices.resources.constants(Constants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const lit = lightOn(constants, vertices.input(@intCast(k), 1));
        const clip = shader.transform(&constants.transform, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..8].* = .{
            clip[0],                                  clip[1],                                  clip[2],                                  clip[3],
            shader.channel(constants.color[0] * lit), shader.channel(constants.color[1] * lit), shader.channel(constants.color[2] * lit), shader.channel(1),
        };
    }
}

fn colouredFragment(fragments: *const shader.Fragments) callconv(.c) void {
    shader.smooth(fragments);
}

fn texturedVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const constants = vertices.resources.constants(Constants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const uv = vertices.input(@intCast(k), 2);
        const lit = lightOn(constants, vertices.input(@intCast(k), 1));
        const clip = shader.transform(&constants.transform, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..9].* = .{
            clip[0],                  clip[1],                  clip[2],                  clip[3], uv[0], uv[1],
            constants.color[0] * lit, constants.color[1] * lit, constants.color[2] * lit,
        };
    }
}

/// The picture at each pixel, then each square of four times the light
/// and colour at its middle.
fn texturedFragment(fragments: *const shader.Fragments) callconv(.c) void {
    @setRuntimeSafety(false);
    shader.textured(.{ .filter = .bilinear }, fragments, fragments.resources.sampled(0, 0, 0));
    var rows = shader.Rows(6).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.centre(quad);
        const w = 1 / at[0];
        // In 256ths, held inside 0 to 256.
        var tint: [3]u32 = undefined;
        inline for (&tint, 3..) |*each, plane| each.* = @intFromFloat(@min(@max(at[plane] * w * 256, 0), 256));
        for (out) |*pixel| {
            const c = pixel.*;
            const red = (c >> 16 & 0xFF) * tint[0] >> 8;
            const green = (c >> 8 & 0xFF) * tint[1] >> 8;
            const blue = (c & 0xFF) * tint[2] >> 8;
            pixel.* = (c & 0xFF00_0000) | red << 16 | green << 8 | blue;
        }
    }
}

const entries = [_]shader.Entry{
    shader.vertex("coloured", &colouredVertex, 4),
    shader.fragment("coloured", &colouredFragment, 4),
    shader.vertex("textured", &texturedVertex, 5),
    shader.fragment("textured", &texturedFragment, 5),
};

/// The functions, for a shader module: "coloured" and "textured", each a
/// vertex and a fragment function.
pub const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
