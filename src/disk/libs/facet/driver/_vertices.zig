// SPDX-License-Identifier: MIT
//! What every driver does the same for a draw, as vertex functions run on
//! the cores whichever device draws: the vertices it names read from the
//! vertex buffers, each attribute into its location, and its triangles put
//! together from its indices as the topology says. Lines and points, and
//! the edges or corners of triangles drawn so, are made into little
//! rectangles of two triangles each, once their vertices are worked: a
//! driver only ever draws triangles.
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
const max_vertex_input_bindings = @import("../instance/_instance.zig").max_vertex_input_bindings;
const DescriptorSet = @import("../descriptor/_descriptor.zig").Set;

/// A vertex buffer bound.
/// What commands have bound of a player, kept where a subpass begins for its
/// further colour attachments.
pub const Bound = struct {
    pipeline: ?*Pipeline,
    vertex_buffers: [max_vertex_input_bindings]VertexBuffer,
    index_buffer: ?*Buffer,
    index_offset: u64,
    index_type: facet.IndexType,
    viewport: facet.Viewport,
    scissor: facet.Rect2D,
    blend_constants: [4]f32,
    line_width: f32,
    stencil: StencilSet,
    resources: shader.Resources,

    pub fn of(player: anytype) Bound {
        var made: Bound = undefined;
        inline for (@typeInfo(Bound).@"struct".fields) |field| @field(made, field.name) = @field(player, field.name);
        return made;
    }

    pub fn restore(bound: *const Bound, player: anytype) void {
        inline for (@typeInfo(Bound).@"struct".fields) |field| @field(player, field.name) = @field(bound, field.name);
    }
};

/// A subpass played for its further colour attachments: from its begin, for
/// the next `output`.
pub const Repeat = struct {
    begin: *const _command.BeginRenderPass,
    from: _stream.Reader,
    output: u32,
};

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
        .point_list, .patch_list => {
            for (0..indices.count) |k| {
                into[made] = if (indices.vertex(@intCast(k))) |number| number - lowest else no_corner;
                made += 1;
            }
        },
        .line_list => {
            var k: u32 = 0;
            while (k + 2 <= indices.count) : (k += 2) {
                for (0..2) |corner| into[made + corner] = if (indices.vertex(k + @as(u32, @intCast(corner)))) |number| number - lowest else no_corner;
                made += 2;
            }
        },
        .line_strip => {
            var last: ?u32 = null;
            for (0..indices.count) |k| {
                const number = indices.vertex(@intCast(k)) orelse {
                    last = null;
                    continue;
                };
                const here = number - lowest;
                if (last) |from| {
                    into[made] = from;
                    into[made + 1] = here;
                    made += 2;
                }
                last = here;
            }
        },
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

/// One draw of an indirect command, as a draw takes it.
pub const IndirectDraw = struct {
    first: u32,
    count: u32,
    vertex_offset: ?i32,
    first_instance: u32,
    instances: u32,
};

/// Draw `k` of `command`, read from its buffer now; null where the buffer
/// ends before it.
pub fn indirectDraw(command: *const _command.DrawIndirect, k: u32) ?IndirectDraw {
    const at = command.offset + @as(u64, k) * command.stride;
    if (command.indexed) {
        const bytes = _buffer.bytes(command.buffer, at, @sizeOf(facet.DrawIndexedIndirectCommand)) orelse return null;
        const given = std.mem.bytesToValue(facet.DrawIndexedIndirectCommand, bytes);
        return .{ .first = given.first_index, .count = given.index_count, .vertex_offset = given.vertex_offset, .first_instance = given.first_instance, .instances = given.instance_count };
    }
    const bytes = _buffer.bytes(command.buffer, at, @sizeOf(facet.DrawIndirectCommand)) orelse return null;
    const given = std.mem.bytesToValue(facet.DrawIndirectCommand, bytes);
    return .{ .first = given.first_vertex, .count = given.vertex_count, .vertex_offset = null, .first_instance = given.first_instance, .instances = given.instance_count };
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

/// CmdFillBuffer: a run of a buffer set to one value, four bytes at a time.
/// False, and nothing written, where the run is not the buffer's.
pub fn fillBuffer(command: *const _command.FillBuffer) bool {
    const into = _buffer.bytes(command.destination, command.offset, command.size) orelse return false;
    // Four bytes at a time, as they lie in memory: the low byte first. The
    // tail of a run whose length is not a multiple of four cannot arise -
    // the command rounds both down as it is recorded.
    const words: [*]align(1) u32 = @ptrCast(into.ptr);
    @memset(words[0 .. into.len / 4], command.data);
    return true;
}

/// CmdUpdateBuffer: the bytes kept with the command written into a buffer.
/// False, and nothing written, where they are not the buffer's.
pub fn updateBuffer(command: *const _command.UpdateBuffer) bool {
    const from = _stream.items(_command.UpdateBuffer, u8, command, @intCast(command.size));
    const into = _buffer.bytes(command.destination, command.offset, command.size) orelse return false;
    @memcpy(into, from);
    return true;
}

/// The most corners `assemble` makes of `count` indices.
pub fn mostCorners(topology: facet.PrimitiveTopology, count: u32) usize {
    return switch (topology) {
        .point_list, .patch_list => count,
        .line_list => count / 2 * 2,
        .line_strip => @as(usize, count -| 1) * 2,
        .triangle_list => count / 3 * 3,
        else => @as(usize, count -| 2) * 3,
    };
}

/// Whether a pipeline's draws come to something other than filled triangles.
pub fn widens(pipeline: *const Pipeline) bool {
    return switch (pipeline.drawn_topology) {
        .point_list, .line_list, .line_strip => true,
        else => pipeline.polygon_mode != .fill,
    };
}

/// What `widen` makes.
pub const Wide = struct {
    vertices: u32 = 0,
    indices: u32 = 0,
};

/// The most `widen` makes of `corners` corners.
pub fn mostWide(pipeline: *const Pipeline, corners: usize) Wide {
    const rectangles = switch (pipeline.drawn_topology) {
        .point_list => corners,
        .line_list, .line_strip => corners / 2,
        // A triangle's three edges, or its three corners.
        else => corners,
    };
    return .{ .vertices = @intCast(rectangles * 4), .indices = @intCast(rectangles * 6) };
}

/// How near the eye a line is cut, in w: its direction on the picture needs
/// both ends in front.
const nearest_w: f32 = 1.0 / 65536.0;

/// The most floats a vertex carries `widen` can work with: a position and
/// `shader`'s varyings.
const most_stride = 64;

/// What `widen` writes to.
const Widening = struct {
    half_width: f32,
    half_height: f32,
    half_line: f32,
    stride: u32,
    outputs: [*]const f32,
    into: [*]f32,
    indices: [*]u32,
    made: Wide = .{},

    /// A rectangle whose corners are these two ends, each moved `by` pixels
    /// either way along x and y.
    fn rectangle(widening: *Widening, a: []const f32, b: []const f32, by: [2]f32) void {
        const stride = widening.stride;
        const first = widening.made.vertices;
        const dx = by[0] / widening.half_width;
        const dy = by[1] / widening.half_height;
        for ([4]struct { []const f32, f32 }{ .{ a, -1 }, .{ a, 1 }, .{ b, -1 }, .{ b, 1 } }, 0..) |corner, k| {
            const into = (widening.into + (first + k) * stride)[0..stride];
            @memcpy(into, corner[0]);
            into[0] += corner[1] * dx * corner[0][3];
            into[1] += corner[1] * dy * corner[0][3];
        }
        for ([6]u32{ 0, 1, 2, 2, 1, 3 }, widening.indices[widening.made.indices..][0..6]) |corner, *index| index.* = first + corner;
        widening.made.vertices += 4;
        widening.made.indices += 6;
    }

    fn vertex(widening: *const Widening, k: u32) []const f32 {
        return (widening.outputs + @as(usize, k) * widening.stride)[0..widening.stride];
    }

    fn point(widening: *Widening, k: u32) void {
        const at = widening.vertex(k);
        if (at[3] < nearest_w) return;
        // Two ends the same, moved apart along x, then the whole along y:
        // the rectangle's corners have it moved both ways.
        var low: [most_stride]f32 = undefined;
        var high: [most_stride]f32 = undefined;
        const stride = widening.stride;
        @memcpy(low[0..stride], at);
        @memcpy(high[0..stride], at);
        low[1] -= 0.5 / widening.half_height * at[3];
        high[1] += 0.5 / widening.half_height * at[3];
        widening.rectangle(low[0..stride], high[0..stride], .{ 0.5, 0 });
    }

    fn line(widening: *Widening, from: u32, to: u32) void {
        const stride = widening.stride;
        var a: [most_stride]f32 = undefined;
        var b: [most_stride]f32 = undefined;
        @memcpy(a[0..stride], widening.vertex(from));
        @memcpy(b[0..stride], widening.vertex(to));
        // Both ends in front of the eye.
        if (a[3] < nearest_w and b[3] < nearest_w) return;
        if (a[3] < nearest_w or b[3] < nearest_w) {
            const along = (nearest_w - a[3]) / (b[3] - a[3]);
            const moved: *[most_stride]f32 = if (a[3] < nearest_w) &a else &b;
            for (moved[0..stride], a[0..stride], b[0..stride]) |*value, at_a, at_b| value.* = at_a + (at_b - at_a) * along;
        }
        // Across the line on the picture, half its width each way.
        const across = (b[0] / b[3] - a[0] / a[3]) * widening.half_width;
        const down = (b[1] / b[3] - a[1] / a[3]) * widening.half_height;
        const length = @sqrt(across * across + down * down);
        if (length == 0 or length != length) return;
        widening.rectangle(a[0..stride], b[0..stride], .{ -down / length * widening.half_line, across / length * widening.half_line });
    }

    /// Whether the triangle's face is drawn, as the fill's would be: one with
    /// a corner behind the eye always is.
    fn faced(widening: *const Widening, pipeline: *const Pipeline, three: []const u32) bool {
        if (pipeline.cull == .none) return true;
        const a = widening.vertex(three[0]);
        const b = widening.vertex(three[1]);
        const c = widening.vertex(three[2]);
        if (a[3] <= 0 or b[3] <= 0 or c[3] <= 0) return true;
        const ax = a[0] / a[3] * widening.half_width;
        const ay = a[1] / a[3] * widening.half_height;
        const bx = b[0] / b[3] * widening.half_width;
        const by = b[1] / b[3] * widening.half_height;
        const cx = c[0] / c[3] * widening.half_width;
        const cy = c[1] / c[3] * widening.half_height;
        // Positive turns from x to y on the picture, y down: clockwise.
        const area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        const front = if (pipeline.front == .clockwise) area > 0 else area < 0;
        return if (pipeline.cull == .back) front else !front;
    }
};

/// A draw's primitives, `corners` of the vertices in `outputs`, made into
/// rectangles in `into` - `stride` floats a vertex - and `indices` of three
/// for each of their triangles. At `width` pixels, for lines.
pub fn widen(pipeline: *const Pipeline, viewport: *const facet.Viewport, width: f32, outputs: [*]const f32, stride: u32, corners: []const u32, into: [*]f32, indices: [*]u32) Wide {
    if (stride > most_stride or viewport.width == 0 or viewport.height == 0) return .{};
    var widening = Widening{
        .half_width = viewport.width / 2,
        .half_height = viewport.height / 2,
        .half_line = width / 2,
        .stride = stride,
        .outputs = outputs,
        .into = into,
        .indices = indices,
    };
    switch (pipeline.drawn_topology) {
        .point_list => for (corners) |corner| {
            if (corner != no_corner) widening.point(corner);
        },
        .line_list, .line_strip => {
            var k: usize = 0;
            while (k + 2 <= corners.len) : (k += 2) {
                if (corners[k] != no_corner and corners[k + 1] != no_corner) widening.line(corners[k], corners[k + 1]);
            }
        },
        else => {
            var k: usize = 0;
            while (k + 3 <= corners.len) : (k += 3) {
                const three = corners[k..][0..3];
                if (three[0] == no_corner or three[1] == no_corner or three[2] == no_corner) continue;
                if (!widening.faced(pipeline, three)) continue;
                for (0..3) |edge| {
                    if (pipeline.polygon_mode == .point) {
                        widening.point(three[edge]);
                    } else {
                        widening.line(three[edge], three[(edge + 1) % 3]);
                    }
                }
            }
        },
    }
    return widening.made;
}

/// What commands set of the stencil, as a player keeps it: front, back.
pub const StencilSet = struct {
    compare: [2]u8 = .{ 0, 0 },
    write: [2]u8 = .{ 0, 0 },
    reference: [2]u8 = .{ 0, 0 },

    /// A command played.
    pub fn apply(set: *StencilSet, command: *const _command.SetStencil) void {
        const values = switch (command.which) {
            .compare => &set.compare,
            .write => &set.write,
            .reference => &set.reference,
        };
        const value: u8 = @truncate(command.value);
        if (command.face_mask & facet.STENCIL_FACE_FRONT != 0) values[0] = value;
        if (command.face_mask & facet.STENCIL_FACE_BACK != 0) values[1] = value;
    }

    /// A pipeline's test for its draws now: null for none. Lines and points,
    /// which have no face, go by the front's.
    pub fn of(set: *const StencilSet, pipeline: *const Pipeline) ?[2]_pipeline.StencilFace {
        var faces = pipeline.stencil orelse return null;
        for (&faces, 0..) |*face, k| {
            if (pipeline.dynamic_stencil_compare) face.compare_mask = set.compare[k];
            if (pipeline.dynamic_stencil_write) face.write_mask = set.write[k];
            if (pipeline.dynamic_stencil_reference) face.reference = set.reference[k];
        }
        if (widens(pipeline)) faces[1] = faces[0];
        return faces;
    }
};
