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
const Queue = @import("../queue/_queue.zig").Queue;
const _buffer = @import("../buffer/_buffer.zig");
const _image = @import("../image/_image.zig");
const _pipeline = @import("../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const Player = @import("_play.zig").Player;

/// The most vertices a draw works: past it, the draw draws nothing.
const most_vertices = 1 << 20;

/// What a draw's indices are: the index buffer's, from its first, or the
/// vertices in order from the first.
const Indices = struct {
    /// The index buffer's bytes from the first index, or null.
    bytes: ?[]const u8,
    wide: bool,
    /// What an index is added to for its vertex: the vertex offset, or the
    /// first vertex.
    base: i64,
    count: u32,
    /// An index of all ones restarts a strip or a fan.
    restart: bool,

    /// Index `k`'s vertex, or null where it is a restart, or past the
    /// buffer, or below the first vertex there is.
    fn vertex(indices: Indices, k: u32) ?u32 {
        const bytes = indices.bytes orelse {
            const number = indices.base + k;
            return if (number > std.math.maxInt(u32)) null else @intCast(number);
        };
        const index: u32 = if (indices.wide) index: {
            if (@as(usize, k) * 4 + 4 > bytes.len) return null;
            break :index std.mem.readInt(u32, bytes[k * 4 ..][0..4], .little);
        } else index: {
            if (@as(usize, k) * 2 + 2 > bytes.len) return null;
            const short = std.mem.readInt(u16, bytes[k * 2 ..][0..2], .little);
            if (indices.restart and short == 0xFFFF) return null;
            break :index short;
        };
        if (indices.restart and index == 0xFFFF_FFFF) return null;
        const number = indices.base + index;
        if (number < 0 or number > std.math.maxInt(u32)) return null;
        return @intCast(number);
    }
};

/// A draw of `count` vertices, or of `count` indices with `vertex_offset`
/// added to each: the vertices or indices from `first` on, each instance
/// from `first_instance` to `instances` past it.
pub fn draw(queue: *Queue, first: u32, count: u32, vertex_offset: ?i32, first_instance: u32, instances: u32) void {
    const player = &queue.player;
    const pipeline = player.pipeline orelse return;
    if (pipeline.draws_nothing or count == 0 or instances == 0) return;
    const indices = indicesOf(player, pipeline, first, count, vertex_offset) orelse return;

    // The vertices from the lowest to the highest the draw names.
    var lowest: u32 = std.math.maxInt(u32);
    var highest: u32 = 0;
    for (0..count) |k| {
        const number = indices.vertex(@intCast(k)) orelse continue;
        lowest = @min(lowest, number);
        highest = @max(highest, number);
    }
    if (lowest > highest or highest - lowest >= most_vertices) return;
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
    const corner_count = assemble(pipeline.topology, indices, lowest, corners[0..most_corners]);

    const target = &player.target.?;
    const resources = player.drawn orelse resources: {
        const copy = target.arena.create(shader.Resources) orelse return;
        copy.* = player.resources;
        player.drawn = copy;
        break :resources copy;
    };
    const viewport = pipeline.viewport orelse player.viewport;
    const scissor = pipeline.scissor orelse player.scissor;
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
        .cull = pipeline.cull,
        .front = pipeline.front,
        .depth_test = pipeline.depth_test,
        .depth_write = pipeline.depth_write,
        .blend = pipeline.blend,
        .varyings = pipeline.varyings,
        .fragment = pipeline.fragment,
        .resources = resources,
    };

    for (0..instances) |k| {
        const instance = first_instance +% @as(u32, @intCast(k));
        readInputs(player, pipeline, lowest, vertices, instance, inputs[0 .. @as(usize, vertices) * locations]);
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

/// The draw's indices: the index buffer's from `first`, or the vertices
/// from `first`. Null for an indexed draw with no index buffer bound.
fn indicesOf(player: *const Player, pipeline: *const Pipeline, first: u32, count: u32, vertex_offset: ?i32) ?Indices {
    const offset = vertex_offset orelse return .{ .bytes = null, .wide = false, .base = first, .count = count, .restart = false };
    const buffer = player.index_buffer orelse return null;
    const wide = player.index_type == .uint32;
    const start = player.index_offset + @as(u64, first) * @as(u64, if (wide) 4 else 2);
    const bytes = _buffer.bytes(buffer, start, facet.WHOLE_SIZE) orelse return null;
    return .{ .bytes = bytes, .wide = wide, .base = offset, .count = count, .restart = pipeline.restart };
}

/// The draw's triangles as three of the worked vertices each, from
/// `lowest`, into `into`: how many corners. A triangle with an index past
/// the buffer names a vertex there is none of, and is left out.
fn assemble(topology: facet.PrimitiveTopology, indices: Indices, lowest: u32, into: []u32) usize {
    const none = std.math.maxInt(u32);
    var made: usize = 0;
    switch (topology) {
        .triangle_list => {
            var k: u32 = 0;
            while (k + 3 <= indices.count) : (k += 3) {
                for (0..3) |corner| into[made + corner] = if (indices.vertex(k + @as(u32, @intCast(corner)))) |number| number - lowest else none;
                made += 3;
            }
        },
        .triangle_strip, .triangle_fan => {
            // The vertices since the last restart: the fan's first, and the
            // two before the next.
            var run: u32 = 0;
            var hub: u32 = 0;
            var previous: [2]u32 = undefined;
            for (0..indices.count) |k| {
                const number = indices.vertex(@intCast(k)) orelse {
                    run = 0;
                    continue;
                };
                const here = number - lowest;
                if (run >= 2) {
                    const three: [3]u32 = if (topology == .triangle_fan)
                        .{ previous[1], here, hub }
                    else if (run % 2 == 0)
                        .{ previous[0], previous[1], here }
                    else
                        // Every other triangle of a strip turned back, so
                        // that all face the same way.
                        .{ previous[1], previous[0], here };
                    @memcpy(into[made..][0..3], &three);
                    made += 3;
                }
                if (run == 0) hub = here;
                previous = .{ previous[1], here };
                run += 1;
            }
        },
        else => {},
    }
    return made;
}

/// Each worked vertex's inputs, for `instance`: what its attributes hold
/// at its locations, (0, 0, 0, 1) elsewhere and past a buffer's end.
fn readInputs(player: *const Player, pipeline: *const Pipeline, lowest: u32, vertices: u32, instance: u32, into: [][4]f32) void {
    @memset(into, .{ 0, 0, 0, 1 });
    const locations = pipeline.locations;
    for (pipeline.attributes[0..pipeline.attribute_count]) |attribute| {
        const binding = pipeline.bindings[attribute.binding];
        const bound = player.vertex_buffers[attribute.binding];
        const bytes = _buffer.bytes(bound.buffer orelse continue, bound.offset, facet.WHOLE_SIZE) orelse continue;
        const size = _image.bytesOf(attribute.format);
        for (0..vertices) |k| {
            const element: u64 = if (binding.per_instance) instance else lowest + @as(u64, k);
            const at = element * binding.stride + attribute.offset;
            if (at + size > bytes.len) continue;
            into[k * locations + attribute.location] = _pipeline.decode(attribute.format, bytes.ptr + @as(usize, @intCast(at)));
        }
    }
}

/// `bytes` of the player's memory for a draw's vertices, aligned for a
/// float; null when there is none to be had.
fn scratchOf(queue: *Queue, bytes: usize) ?[*]u8 {
    const player = &queue.player;
    if (bytes <= player.scratch_bytes) return player.scratch;
    const sys = queue.device.sys;
    const memory = sys.AllocVec(bytes, sdk.exec.MEMF_ANY) orelse return null;
    if (player.scratch) |old| sys.FreeVec(old);
    player.scratch = @ptrCast(memory);
    player.scratch_bytes = bytes;
    return player.scratch;
}
