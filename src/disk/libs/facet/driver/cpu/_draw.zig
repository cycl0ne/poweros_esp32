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
const _tessellate = @import("../_tessellate.zig");
const _query = @import("../../query/_query.zig");
const _command = @import("../../command/_command.zig");
const _render = @import("../../render/_render.zig");
const _play = @import("_play.zig");
const Player = _play.Player;

/// The most vertices a draw works, the V3D driver's limit too: past it the
/// draw is left out and said to be, and a CmdDraw over it never gets this far.
const most_vertices = @import("../../instance/_instance.zig").max_draw_vertices;

/// A pipeline's state in the rasterizer's terms, as this driver keeps it
/// (Pipeline.driver).
pub const RasterState = struct {
    cull: raster.Cull,
    front: raster.Winding,
    depth_test: ?raster.batched.Compare,
    /// One for each colour attachment of the subpass, the draw taking the
    /// one for the attachment being drawn (`shader.Resources.output`).
    blend: [_render.most_colors]raster.Blend,
    mixing: [_render.most_colors]raster.Mixing,
};

/// The quickest way the rasterizer has of doing as a pipeline says.
pub fn blendOf(mixing: *const _pipeline.Mixing) raster.Blend {
    const whole = mixing.mask == facet.COLOR_COMPONENT_ALL;
    if (!mixing.enabled) return if (whole) .off else .general;
    if (!whole or mixing.color_op != .add or mixing.alpha_op != .add or mixing.src_color != .src_alpha) return .general;
    const keeps = mixing.src_alpha == .zero and mixing.dst_alpha == .one;
    const same = mixing.src_alpha == .src_alpha and mixing.dst_alpha == mixing.dst_color;
    return switch (mixing.dst_color) {
        .one_minus_src_alpha => if (same) .alpha else if (keeps) .alpha_keep else .general,
        .one => if (same) .add else if (keeps) .add_keep else .general,
        else => .general,
    };
}

/// A pipeline's mixing in the rasterizer's terms: its constants and what a
/// target without alpha changes are the draw's. Off, the colour replaces what
/// is there, in the channels of the mask.
pub fn mixingOf(mixing: *const _pipeline.Mixing) raster.Mixing {
    return .{
        .src_color = if (mixing.enabled) factorOf(mixing.src_color) else .one,
        .dst_color = if (mixing.enabled) factorOf(mixing.dst_color) else .zero,
        .color_op = if (mixing.enabled) operationOf(mixing.color_op) else .add,
        .src_alpha = if (mixing.enabled) factorOf(mixing.src_alpha) else .one,
        .dst_alpha = if (mixing.enabled) factorOf(mixing.dst_alpha) else .zero,
        .alpha_op = if (mixing.enabled) operationOf(mixing.alpha_op) else .add,
        .mask = maskOf(mixing.mask),
    };
}

fn factorOf(factor: facet.BlendFactor) @TypeOf(@as(raster.Mixing, undefined).src_color) {
    return @enumFromInt(@intFromEnum(factor));
}

fn operationOf(operation: facet.BlendOp) @TypeOf(@as(raster.Mixing, undefined).color_op) {
    return @enumFromInt(@intFromEnum(operation));
}

/// The bits of 0xAARRGGBB the channels of a write mask are.
fn maskOf(channels: u32) u32 {
    var mask: u32 = 0;
    if (channels & facet.COLOR_COMPONENT_R != 0) mask |= 0x00FF_0000;
    if (channels & facet.COLOR_COMPONENT_G != 0) mask |= 0x0000_FF00;
    if (channels & facet.COLOR_COMPONENT_B != 0) mask |= 0x0000_00FF;
    if (channels & facet.COLOR_COMPONENT_A != 0) mask |= 0xFF00_0000;
    return mask;
}

/// A pipeline's depth bias in the rasterizer's terms: the same three
/// numbers, read there in the depth's own units.
pub fn biasOf(bias: _pipeline.Bias) raster.batched.Bias {
    return .{ .constant = bias.constant, .clamp = bias.clamp, .slope = bias.slope };
}

/// A pipeline's stencil test in the rasterizer's terms: numbered as it is.
fn stencilFaceOf(face: _pipeline.StencilFace) raster.batched.StencilFace {
    return .{
        .fail = @enumFromInt(@intFromEnum(face.fail)),
        .pass = @enumFromInt(@intFromEnum(face.pass)),
        .depth_fail = @enumFromInt(@intFromEnum(face.depth_fail)),
        .compare = @enumFromInt(@intFromEnum(face.compare)),
        .compare_mask = face.compare_mask,
        .write_mask = face.write_mask,
        .reference = face.reference,
    };
}

/// 0 to 1 as 0 to 255, in 0xAARRGGBB.
pub fn constantOf(constants: [4]f32) u32 {
    var packed_constant: u32 = 0;
    for (constants, [4]u5{ 16, 8, 0, 24 }) |value, shift| {
        const scaled = std.math.clamp(value, 0, 1) * 255 + 0.5;
        packed_constant |= @as(u32, @intFromFloat(scaled)) << shift;
    }
    return packed_constant;
}

/// A draw of `count` vertices, or of `count` indices with `vertex_offset`
/// added to each: the vertices or indices from `first` on, each instance
/// from `first_instance` to `instances` past it.
pub fn draw(queue: *Queue, first: u32, count: u32, vertex_offset: ?i32, first_instance: u32, instances: u32) void {
    const player = _play.playerOf(queue);
    const pipeline = player.pipeline orelse return;
    if (count == 0 or instances == 0) return;
    const indices = _vertices.indicesOf(player, pipeline, first, count, vertex_offset) orelse return;
    const lowest, const highest = _vertices.range(indices) orelse return;
    if (highest - lowest >= most_vertices) return _play.noRoom(queue, "a draw of more vertices than one works");
    const vertices = highest - lowest + 1;

    const locations = pipeline.locations;
    const stride = 4 + pipeline.varyings;
    // A patch's vertices may carry other than what comes to be drawn.
    const point_stride = if (pipeline.tessellated) |tessellated| 4 + tessellated.vertex_varyings else stride;
    const most_corners = _vertices.mostCorners(pipeline.topology, count);
    const wide = _vertices.widens(pipeline);
    const most_wide: _vertices.Wide = if (wide and pipeline.tessellated == null) _vertices.mostWide(pipeline, most_corners) else .{};
    const wide_vertices_bytes = @as(usize, most_wide.vertices) * stride * @sizeOf(f32);
    const wide_indices_bytes = @as(usize, most_wide.indices) * @sizeOf(u32);
    const inputs_bytes = @as(usize, vertices) * locations * @sizeOf([4]f32);
    const outputs_bytes = @as(usize, vertices) * point_stride * @sizeOf(f32);
    const corners_bytes = most_corners * @sizeOf(u32);
    // A float a vertex for the point it makes, where the draw makes
    // points at all (`shader.Vertices.setPointSize`, since 1.70).
    const points = _vertices.makesPoints(pipeline);
    const sizes_bytes = if (points) @as(usize, vertices) * @sizeOf(f32) else 0;
    const scratch = scratchOf(queue, inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes + wide_indices_bytes + sizes_bytes) orelse return;
    const inputs: [*][4]f32 = @ptrCast(@alignCast(scratch));
    const outputs: [*]f32 = @ptrCast(@alignCast(scratch + inputs_bytes));
    const corners: [*]u32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes));
    const wide_vertices: [*]f32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes));
    const wide_indices: [*]u32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes));
    const sizes: ?[*]f32 = if (points) @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes + wide_indices_bytes)) else null;
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
    // The colour attachment being drawn has a mixing of its own; a
    // fragment function that writes several at once has them all, each
    // blended its own way into its own plane (since 1.51).
    const colors = @min(@max(pipeline.outputs, 1), target.colorCount());
    const first_output = @min(resources.output, _render.most_colors - 1);
    const blend, const mixing = player.mixingFor(pipeline, translated, first_output);
    var more_blends: [_render.most_colors - 1]raster.pipeline.Blend = @splat(.off);
    var more_mixings: [_render.most_colors - 1]raster.pipeline.Mixing = @splat(.{});
    for (1..colors) |k| {
        more_blends[k - 1], more_mixings[k - 1] = player.mixingFor(pipeline, translated, @intCast(k));
    }
    const stencil: ?[2]raster.batched.StencilFace = if (player.stencil.of(pipeline)) |faces| .{ stencilFaceOf(faces[0]), stencilFaceOf(faces[1]) } else null;
    // What a query counts of this draw, or nothing where none is being
    // counted into: the addresses were worked out when it began.
    const counters: *const _query.Counters = if (player.query) |*counting| &counting.counters else &_query.none;
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
        // Lines and points are not culled, and a triangle's edges were as
        // they were made.
        .cull = if (wide) .none else translated.cull,
        .sample_mask = pipeline.sample_mask,
        .rectangles = wide,
        .front = translated.front,
        .depth_test = translated.depth_test,
        .depth_write = pipeline.depth_write,
        // Only triangles are moved: a draw of points or lines, or of
        // triangles drawn as their edges or corners, takes no bias.
        .depth_bias = if (pipeline.biased and !wide) biasOf(pipeline.bias orelse player.depth_bias) else null,
        // What lies past the near plane drawn all the same, its depth held
        // inside the viewport's range; and the stored depth a pixel has to
        // lie between to be drawn at all.
        .depth_clamp = pipeline.clamped,
        .depth_bounds = if (pipeline.bounded) pipeline.bounds orelse player.depth_bounds else null,
        .blend = blend,
        .mixing = mixing,
        .more_blends = more_blends,
        .more_mixings = more_mixings,
        .color_count = colors,
        .stencil = stencil,
        .prepass = pipeline.prepass and stencil == null,
        .varyings = pipeline.varyings,
        .discards = pipeline.fixed.discards(),
        .fragment = pipeline.fragment,
        .resources = resources,
        // The pixels already in the tile, for a subpass that reads the
        // attachment it draws into (since 1.64).
        .reads_target = player.reads_target,
        .samples = counters.samples,
        .fragments = counters.fragment_invocations,
    };

    // What the stages are given, for a statistics query. What came out of
    // clipping is the rasterizer's own count, taken either side of the
    // draw (`stats.clipped`, since 1.92).
    const counted_before = target.stats;
    _query.add(counters.input_vertices, @as(u64, count) * instances);
    _query.add(counters.vertex_invocations, @as(u64, vertices) * instances);
    // Primitives, not triangles: `assemble` writes one corner a point and
    // two a line, so three was the count of a triangle topology and a
    // third of a point list. Item 83 of docs/facet-vulkan10.md.
    const per_primitive = _vertices.cornersPerPrimitive(pipeline.topology, if (pipeline.tessellated) |patches| patches.points else 0);
    _query.add(counters.input_primitives, @as(u64, corner_count / per_primitive) * instances);
    defer _query.add(counters.clipping_primitives, target.stats.clipped - counted_before.clipped);

    // What went *in* to clipping is counted from the primitives - one a
    // point, a line or a triangle - and not from the triangles the
    // rasterizer is given, which are two for each line or point it widens
    // and were the count until 1.92. That is llvmpipe's: gallium's draw
    // module counts `c_invocations` as the primitives its clip stage is
    // handed, before anything is culled, and lp_setup_vbuf.c adds them in
    // unless the rasterizer is discarded. With no tessellation they are
    // what input assembly made; tessellated, what the evaluation made,
    // counted below. Item 83 of docs/facet-vulkan10.md.
    //
    // A pipeline that draws nothing - `rasterizer_discard_enable`, or
    // every face culled - still owes the counts above, and this returned
    // before them until 1.88. Vulkan's one licence to leave a counter
    // alone here covers the clipping pair under the discard and nothing
    // else: "if rasterizerDiscardEnable is enabled, the clipping input and
    // output primitives counters may not be incremented". A cull of every
    // face is no discard: its primitives reach clipping and stop at setup,
    // as llvmpipe's `triangle_noop` stops them, so they are counted going
    // in and none coming out (since 1.92; both were left at zero before).
    //
    // The vertex function itself is not run where there is no
    // tessellation to feed, and that is honest only because
    // `vertex_pipeline_stores_and_atomics` is false on both devices: a
    // vertex function writes its outputs and nothing else, and the outputs
    // of a draw that rasterises nothing cannot be read. The day a device
    // claims that feature this has to run the stage for real. Tessellated,
    // it runs, and the tessellation with it, for what those stages count.
    const discarded = pipeline.draws_nothing and !pipeline.culls_everything;
    if (pipeline.tessellated == null) {
        if (!discarded) _query.add(counters.clipping_invocations, @as(u64, corner_count / per_primitive) * instances);
        if (pipeline.draws_nothing) return;
    }
    const per_drawn = _vertices.cornersPerPrimitive(pipeline.drawn_topology, 0);

    for (0..instances) |k| {
        const instance = first_instance +% @as(u32, @intCast(k));
        _vertices.readInputs(player, pipeline, lowest, vertices, instance, inputs[0 .. @as(usize, vertices) * locations]);
        // One pixel unless the function says otherwise, which is the
        // point every draw made before 1.70.
        if (sizes) |each| @memset(each[0..vertices], 1);
        const batch = shader.Vertices{
            .inputs = inputs,
            .input_stride = locations,
            .count = vertices,
            .outputs = outputs,
            .output_stride = point_stride,
            .first_vertex = lowest,
            .instance = instance,
            .resources = resources,
            .sizes = sizes,
        };
        pipeline.vertex(&batch);
        if (pipeline.tessellated != null) {
            const made = _tessellate.run(queue.device.sys, pipeline, resources, outputs, corners[0..corner_count], instance, most_vertices, counters) orelse continue;
            defer made.free(queue.device.sys);
            if (!discarded) _query.add(counters.clipping_invocations, made.corners().len / per_drawn);
            if (pipeline.draws_nothing) continue;
            if (wide) {
                const widened = _vertices.widen(pipeline, &viewport, pipeline.line_width orelse player.line_width, made.vertices, stride, made.corners(), made.wide_vertices, made.wide_indices, null);
                raster.batched.draw(target, &state, made.wide_vertices[0 .. @as(usize, widened.vertices) * stride], stride, made.wide_indices[0..widened.indices]) catch return;
            } else {
                raster.batched.draw(target, &state, made.vertices[0 .. @as(usize, made.vertex_count) * stride], stride, made.corners()) catch return;
            }
            continue;
        }
        // Out of the frame's memory: what was set up is drawn, the rest
        // not, as Vulkan leaves a device that runs out mid-frame.
        if (wide) {
            const made = _vertices.widen(pipeline, &viewport, pipeline.line_width orelse player.line_width, outputs, stride, corners[0..corner_count], wide_vertices, wide_indices, sizes);
            raster.batched.draw(target, &state, wide_vertices[0 .. @as(usize, made.vertices) * stride], stride, wide_indices[0..made.indices]) catch return;
            continue;
        }
        raster.batched.draw(target, &state, outputs[0 .. @as(usize, vertices) * stride], stride, corners[0..corner_count]) catch return;
    }
}

/// The colour a clear draws with: its corners', all the same.
fn clearColor(fragments: *const shader.Fragments) callconv(.c) void {
    shader.smooth(fragments);
}

const no_resources = shader.Resources{};

/// A part of the attachments cleared in the middle of a pass: a rectangle
/// drawn over the part, writing what is cleared and no more.
pub fn clearAttachment(queue: *Queue, command: *const _command.ClearAttachment) void {
    const player = _play.playerOf(queue);
    // The layers past the framebuffer's first are in the image's rows alone
    // and are cleared there (since 1.91); the first is in the tiles, and
    // is cleared here only where the rectangle names it.
    _play.clearRectangle(player, command);
    if (command.base_layer != 0 or command.layer_count == 0) return;
    const target = &player.target.?;
    const aspect = command.aspect_mask;
    const clears_stencil = aspect & facet.IMAGE_ASPECT_STENCIL != 0;
    const clears_depth = aspect & facet.IMAGE_ASPECT_DEPTH != 0;
    const color = command.color;
    const rect = command.rect;
    const surface = target.surfaceAt(0);
    const surface_width: f32 = @floatFromInt(surface.width);
    const surface_height: f32 = @floatFromInt(surface.height);
    const stencil_face = raster.batched.StencilFace{ .pass = .replace, .compare = .always, .write_mask = 0xFF, .reference = @truncate(command.stencil) };
    const state = raster.batched.State{
        .viewport = .{ .x = 0, .y = 0, .width = surface_width, .height = surface_height },
        .scissor = .{
            .x = @intCast(@max(rect.offset.x, 0)),
            .y = @intCast(@max(rect.offset.y, 0)),
            .width = rect.extent.width,
            .height = rect.extent.height,
        },
        .depth_test = if (clears_depth) .always else null,
        .depth_write = clears_depth,
        .blend = .general,
        .mixing = .{ .mask = if (aspect & facet.IMAGE_ASPECT_COLOR != 0 and command.output == player.resources.output) 0xFFFF_FFFF else 0 },
        .stencil = if (clears_stencil) .{ stencil_face, stencil_face } else null,
        .varyings = 4,
        .fragment = &clearColor,
        .resources = &no_resources,
    };
    const channels = [4]f32{ shader.channelOfByte(color >> 16 & 0xFF), shader.channelOfByte(color >> 8 & 0xFF), shader.channelOfByte(color & 0xFF), shader.channelOfByte(color >> 24) };
    var vertices: [4 * 8]f32 = undefined;
    for ([4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }, 0..) |corner, k| {
        vertices[k * 8 ..][0..8].* = .{ corner[0], corner[1], command.depth, 1, channels[0], channels[1], channels[2], channels[3] };
    }
    raster.batched.draw(target, &state, &vertices, 8, &[6]u32{ 0, 1, 2, 2, 1, 3 }) catch return;
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
