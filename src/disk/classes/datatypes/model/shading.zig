// SPDX-License-Identifier: MIT
//! How model.datatype's triangles are drawn: the vertex they are read
//! from, and the shader functions facet.library runs over them.
//!
//! The light is worked out at each vertex - how squarely its normal faces
//! the light, either side alike, and `camera.ambient` where it does not
//! - times the material's colour, and carried over the triangle: a model
//! drawn by the cores of a microcontroller has its lighting done once a
//! vertex, not once a pixel. A part without a picture is that colour,
//! mixed over the triangle; one with a picture is the picture, filtered,
//! times that colour. Both are fixed forms of fragment function, so that
//! a GPU can draw them as well as the cores.

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

fn texturedVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const constants = vertices.resources.constants(Constants);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const uv = vertices.input(@intCast(k), 2);
        const lit = lightOn(constants, vertices.input(@intCast(k), 1));
        const clip = shader.transform(&constants.transform, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..10].* = .{
            clip[0],                                  clip[1],                                  clip[2],                                  clip[3],
            uv[0],                                    uv[1],
            shader.channel(constants.color[0] * lit), shader.channel(constants.color[1] * lit), shader.channel(constants.color[2] * lit), shader.channel(1),
        };
    }
}

const entries = [_]shader.Entry{
    shader.vertex("coloured", &colouredVertex, 4),
    shader.fixedFragment("coloured", .{ .kind = .color }),
    shader.vertex("textured", &texturedVertex, 6),
    shader.fixedFragment("textured", .{ .kind = .texture_color, .sampling = .{ .filter = .bilinear } }),
};

/// The functions, for a shader module: "coloured" and "textured", each a
/// vertex and a fragment function.
pub const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
