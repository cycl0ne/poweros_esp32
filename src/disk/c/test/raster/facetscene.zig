// SPDX-License-Identifier: MIT
//! The cube's scene as facet.library draws it: the vertex both pipelines
//! read, the shaders - the backdrop's colours mixed over it, the box
//! textured, its transform the push constants - and the pattern's levels
//! staged for a copy into an image. What C:test/FacetCube draws, and the
//! host tests check against the rasterizer's own picture of the cube.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const texture = facet.texture;
const scenes = @import("scenes.zig");

pub const Vertex = extern struct {
    position: [3]f32,
    /// 0xAARRGGBB: read as b8g8r8a8_unorm.
    color: u32 = 0xFFFF_FFFF,
    uv: [2]f32 = .{ 0, 0 },
};

/// Where a vertex's fields are, for both pipelines.
pub const attributes = [_]facet.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "position") },
    .{ .location = 1, .binding = 0, .format = .b8g8r8a8_unorm, .offset = @offsetOf(Vertex, "color") },
    .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
};

fn backdropVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const c = vertices.input(@intCast(k), 1);
        vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], 1, shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

fn boxVertex(vertices: *const shader.Vertices) callconv(.c) void {
    const transform = vertices.resources.constants([16]f32);
    for (0..vertices.count) |k| {
        const p = vertices.input(@intCast(k), 0);
        const uv = vertices.input(@intCast(k), 2);
        const clip = shader.transform(transform, .{ p[0], p[1], p[2] });
        vertices.output(@intCast(k))[0..6].* = .{ clip[0], clip[1], clip[2], clip[3], uv[0], uv[1] };
    }
}

const entries = [_]shader.Entry{
    shader.vertex("backdrop", &backdropVertex, 4),
    shader.fixedFragment("backdrop", .{ .kind = .color }),
    shader.vertex("box", &boxVertex, 2),
    shader.fixedFragment("box", .{ .kind = .texture, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("box nearest", .{ .kind = .texture, .sampling = .{ .filter = .nearest } }),
};

/// The functions, for a shader module: "backdrop" and "box" each a vertex
/// and a fragment function, and "box nearest" a fragment function taking
/// the nearest texel.
pub const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

/// The bytes the pattern's levels take staged, 8888 texels row by row.
pub const staged_bytes = staged: {
    var bytes: usize = 0;
    for (0..scenes.texture_levels) |level| bytes += (scenes.texture_side >> level) * (scenes.texture_side >> level) * 4;
    break :staged bytes;
};

/// The pattern's texture, as scenes.patternTexture makes it, staged into
/// `into` - `staged_bytes` of it - as b8g8r8a8 texels, a level after the
/// other: the regions that copy each into its level of an image.
pub fn stage(pattern: *const texture.Texture, into: [*]u8) [scenes.texture_levels]facet.BufferImageCopy {
    var regions: [scenes.texture_levels]facet.BufferImageCopy = undefined;
    var at: usize = 0;
    const spread: [*]const u64 = @ptrCast(@alignCast(pattern.memory));
    for (&regions, 0..) |*region, lod| {
        const level: u32 = @intCast(lod);
        region.* = .{ .buffer_offset = at, .image_subresource = .{ .mip_level = level }, .image_extent = .{ .width = pattern.width(level), .height = pattern.height(level) } };
        for (0..pattern.height(level)) |y| for (0..pattern.width(level)) |x| {
            const texel = texture.gather(spread[pattern.index(level, @intCast(x), @intCast(y))]);
            std.mem.writeInt(u32, into[at..][0..4], texel, .little);
            at += 4;
        };
    }
    return regions;
}
