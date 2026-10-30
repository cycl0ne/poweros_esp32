// SPDX-License-Identifier: MIT
//! What every driver does the same for a draw, as vertex functions run on
//! the cores whichever device draws: the vertices it names read from the
//! vertex buffers, each attribute into its location, and its triangles put
//! together from its indices as the topology says.
//!
//! A `player` here is a driver's own state of what is bound: it has
//! `vertex_buffers`, `index_buffer`, `index_offset` and `index_type`.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const _command = @import("../command/_command.zig");
const _stream = @import("../command/_stream.zig");
const _buffer = @import("../buffer/_buffer.zig");
const Buffer = _buffer.Buffer;
const _image = @import("../image/_image.zig");
const _pipeline = @import("../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const DescriptorSet = @import("../descriptor/_descriptor.zig").Set;

/// A vertex buffer bound.
pub const VertexBuffer = struct {
    buffer: ?*Buffer = null,
    offset: u64 = 0,
};

/// What a draw's indices are: the index buffer's, from its first, or the
/// vertices in order from the first.
pub const Indices = struct {
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
    pub fn vertex(indices: Indices, k: u32) ?u32 {
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

/// The draw's indices: the index buffer's from `first`, or the vertices
/// from `first`. Null for an indexed draw with no index buffer bound.
pub fn indicesOf(player: anytype, pipeline: *const Pipeline, first: u32, count: u32, vertex_offset: ?i32) ?Indices {
    const offset = vertex_offset orelse return .{ .bytes = null, .wide = false, .base = first, .count = count, .restart = false };
    const buffer = player.index_buffer orelse return null;
    const wide = player.index_type == .uint32;
    const start = player.index_offset + @as(u64, first) * @as(u64, if (wide) 4 else 2);
    const bytes = _buffer.bytes(buffer, start, facet.WHOLE_SIZE) orelse return null;
    return .{ .bytes = bytes, .wide = wide, .base = offset, .count = count, .restart = pipeline.restart };
}

/// The lowest vertex the draw names and the highest, or null for none.
pub fn range(indices: Indices) ?struct { u32, u32 } {
    var lowest: u32 = std.math.maxInt(u32);
    var highest: u32 = 0;
    for (0..indices.count) |k| {
        const number = indices.vertex(@intCast(k)) orelse continue;
        lowest = @min(lowest, number);
        highest = @max(highest, number);
    }
    if (lowest > highest) return null;
    return .{ lowest, highest };
}

/// A corner naming a vertex there is none of: its triangle is left out.
pub const no_corner = std.math.maxInt(u32);

/// The draw's triangles as three of the worked vertices each, from
/// `lowest`, into `into`: how many corners. A triangle with an index past
/// the buffer names a vertex there is none of, and is left out.
pub fn assemble(topology: facet.PrimitiveTopology, indices: Indices, lowest: u32, into: []u32) usize {
    var made: usize = 0;
    switch (topology) {
        .triangle_list => {
            var k: u32 = 0;
            while (k + 3 <= indices.count) : (k += 3) {
                for (0..3) |corner| into[made + corner] = if (indices.vertex(k + @as(u32, @intCast(corner)))) |number| number - lowest else no_corner;
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
pub fn readInputs(player: anytype, pipeline: *const Pipeline, lowest: u32, vertices: u32, instance: u32, into: [][4]f32) void {
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

pub fn bindVertexBuffers(player: anytype, command: *const _command.BindVertexBuffers) void {
    for (_stream.items(_command.BindVertexBuffers, _command.VertexBuffer, command, command.count), command.first..) |bound, binding| {
        if (binding >= player.vertex_buffers.len) break;
        player.vertex_buffers[binding] = .{ .buffer = bound.buffer, .offset = bound.offset };
    }
}

pub fn bindDescriptorSets(resources: *shader.Resources, command: *const _command.BindDescriptorSets) void {
    for (_stream.items(_command.BindDescriptorSets, *DescriptorSet, command, command.count), command.first..) |set, at| {
        if (at >= shader.MAX_SETS) break;
        resources.sets[at] = &set.view;
    }
}

pub fn pushConstants(resources: *shader.Resources, command: *const _command.PushConstants) void {
    const bytes = _stream.items(_command.PushConstants, u8, command, command.size);
    @memcpy(resources.push[command.offset..][0..command.size], bytes);
}

pub fn copyBuffer(command: *const _command.CopyBuffer) void {
    for (_stream.items(_command.CopyBuffer, facet.BufferCopy, command, command.count)) |region| {
        const from = _buffer.bytes(command.source, region.src_offset, region.size) orelse continue;
        const into = _buffer.bytes(command.destination, region.dst_offset, region.size) orelse continue;
        // Overlapping regions are the program's mistake; copied forwards.
        std.mem.copyForwards(u8, into, from);
    }
}
