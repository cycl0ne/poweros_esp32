// SPDX-License-Identifier: MIT
//! A draw played: the vertices it names read from the vertex buffers,
//! each attribute into its location, and given to the pipeline's vertex
//! function; its triangles put together from its indices as the topology
//! says; and both handed to the rasterizer (raster.batched), which sets
//! the triangles up for the tiles.
//!
//! The vertices worked are those from the lowest the draw names to the
//! highest, once for each instance, in memory of the player's kept for
//! the next draw. The resources the fragment function reads go into the
//! frame's memory, which lasts until the tiles are drawn - once for all
//! the draws until something bound changes.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const raster = @import("raster");
const Queue = @import("../../queue/_queue.zig").Queue;
const _buffer = @import("../../buffer/_buffer.zig");
const _image = @import("../../image/_image.zig");
const _pipeline = @import("../../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const _vertices = @import("../_vertices.zig");
const _play = @import("_play.zig");
const Player = _play.Player;

/// The most vertices a draw works: past it, the draw draws nothing.
const most_vertices = 1 << 20;

/// A pipeline's state in the rasterizer's terms, as this driver keeps it
/// (Pipeline.driver).
pub const RasterState = struct {
    cull: raster.Cull,
    front: raster.Winding,
    depth_test: ?raster.batched.Compare,
    blend: raster.Blend,
};

/// A draw of `count` vertices, or of `count` indices with `vertex_offset`
/// added to each: the vertices or indices from `first` on, each instance
/// from `first_instance` to `instances` past it.
pub fn draw(queue: *Queue, first: u32, count: u32, vertex_offset: ?i32, first_instance: u32, instances: u32) void {
    const player = _play.playerOf(queue);
    const pipeline = player.pipeline orelse return;
    if (pipeline.draws_nothing or count == 0 or instances == 0) return;
    const indices = _vertices.indicesOf(player, pipeline, first, count, vertex_offset) orelse return;
    const lowest, const highest = _vertices.range(indices) orelse return;
    if (highest - lowest >= most_vertices) return;
    const vertices = highest - lowest + 1;

    const locations = pipeline.locations;
    const stride = 4 + pipeline.varyings;
    const most_corners = (if (pipeline.topology == .triangle_list) count / 3 else count -| 2) * 3;
    const inputs_bytes = @as(usize, vertices) * locations * @sizeOf([4]f32);
    const outputs_bytes = @as(usize, vertices) * stride * @sizeOf(f32);
    const scratch = scratchOf(queue, inputs_bytes + outputs_bytes + most_corners * @sizeOf(u32)) orelse return;
    const inputs: [*][4]f32 = @ptrCast(@alignCast(scratch));
    const outputs: [*]f32 = @ptrCast(@alignCast(scratch + inputs_bytes));
    const corners: [*]u32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes));
    const corner_count = _vertices.assemble(pipeline.topology, indices, lowest, corners[0..most_corners]);

    const target = &player.target.?;
    const resources = player.drawn orelse resources: {
        const copy = target.arena.create(shader.Resources) orelse return;
        copy.* = player.resources;
        player.drawn = copy;
        break :resources copy;
    };
    const viewport = pipeline.viewport orelse player.viewport;
    const scissor = pipeline.scissor orelse player.scissor;
    const translated: *const RasterState = @ptrCast(@alignCast(pipeline.driver.?));
    const state = raster.batched.State{
        .viewport = .{ .x = viewport.x, .y = viewport.y, .width = viewport.width, .height = viewport.height },
        .min_depth = viewport.min_depth,
        .max_depth = viewport.max_depth,
        .scissor = .{
            .x = @intCast(@max(scissor.offset.x, 0)),
            .y = @intCast(@max(scissor.offset.y, 0)),
            .width = scissor.extent.width,
            .height = scissor.extent.height,
        },
        .cull = translated.cull,
        .front = translated.front,
        .depth_test = translated.depth_test,
        .depth_write = pipeline.depth_write,
        .blend = translated.blend,
        .prepass = pipeline.prepass,
        .varyings = pipeline.varyings,
        .fragment = pipeline.fragment,
        .resources = resources,
    };

    for (0..instances) |k| {
        const instance = first_instance +% @as(u32, @intCast(k));
        _vertices.readInputs(player, pipeline, lowest, vertices, instance, inputs[0 .. @as(usize, vertices) * locations]);
        const batch = shader.Vertices{
            .inputs = inputs,
            .input_stride = locations,
            .count = vertices,
            .outputs = outputs,
            .output_stride = stride,
            .first_vertex = lowest,
            .instance = instance,
            .resources = resources,
        };
        pipeline.vertex(&batch);
        // Out of the frame's memory: what was set up is drawn, the rest
        // not, as Vulkan leaves a device that runs out mid-frame.
        raster.batched.draw(target, &state, outputs[0 .. @as(usize, vertices) * stride], stride, corners[0..corner_count]) catch return;
    }
}

/// `bytes` of the player's memory for a draw's vertices, aligned for a
/// float; null when there is none to be had.
fn scratchOf(queue: *Queue, bytes: usize) ?[*]u8 {
    const player = _play.playerOf(queue);
    if (bytes <= player.scratch_bytes) return player.scratch;
    const sys = queue.device.sys;
    const memory = sys.AllocVec(bytes, sdk.exec.MEMF_ANY) orelse return null;
    if (player.scratch) |old| sys.FreeVec(old);
    player.scratch = @ptrCast(memory);
    player.scratch_bytes = bytes;
    return player.scratch;
}
