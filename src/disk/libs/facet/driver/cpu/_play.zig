// SPDX-License-Identifier: MIT
//! A command buffer played by the cores, on its queue's task: its commands
//! done in the order they were recorded, each finished before the next
//! starts - so a barrier has nothing left to wait for, and a layout nothing
//! to change. What it plays shares a frame's tiles between the cores
//! (ShareWork), the task doing a part of them itself.
//!
//! A render pass is a frame of the rasterizer's: CmdBeginRenderPass moves
//! the queue's target onto the framebuffer's colour attachment and begins
//! it, each draw transforms its vertices and puts its triangles on the
//! tiles' lists (_draw.zig), and CmdEndRenderPass draws the tiles, shared
//! between the cores, and writes them into the attachment. What is bound
//! - the pipeline, the buffers, the sets, the push constants - is kept
//! from command to command, and starts again with each command buffer.
//!
//! A tile written into a swapchain's image is handed on to the display
//! by the part that wrote it (rtg's RefreshRect), as C:test/Cube hands
//! on its own; into any other image it is handed on to nothing. A colour
//! of four samples is handed on as its resolve attachment, which is the
//! swapchain's image where the program resolves into one (since 1.109).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const raster = @import("raster");
const _objects = @import("../../_objects.zig");
const Queue = @import("../../queue/_queue.zig").Queue;
const _command = @import("../../command/_command.zig");
const CommandBuffer = _command.CommandBuffer;
const _stream = @import("../../command/_stream.zig");
const _buffer = @import("../../buffer/_buffer.zig");
const Buffer = _buffer.Buffer;
const _image = @import("../../image/_image.zig");
const _render = @import("../../render/_render.zig");
const _pipeline = @import("../../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const max_vertex_input_bindings = @import("../../instance/_instance.zig").max_vertex_input_bindings;
const _vertices = @import("../_vertices.zig");
const _compute = @import("../_compute.zig");
const _transfer = @import("../_transfer.zig");
const _draw = @import("_draw.zig");
const _queries = @import("../_queries.zig");
const _query = @import("../../query/_query.zig");
const _sync = @import("../../sync/_sync.zig");

pub const VertexBuffer = _vertices.VertexBuffer;

/// What playing keeps from one command to the next, and from one command
/// buffer to the next on its queue.
pub const Player = struct {
    /// The rasterizer's target: made at the first render pass, moved onto
    /// each after it, and kept with its buffers and its frame's memory
    /// until the device goes.
    target: ?raster.Target = null,
    /// Inside a render pass that could begin.
    drawing: bool = false,
    /// Where the pass's tiles are handed on to: the display's buffer the
    /// first colour attachment is - or its resolve attachment, where it
    /// has one (since 1.109) - or null (`displayOf`).
    display: ?_image.Display = null,
    /// What the draws are drawn with: bound, and set by commands.
    pipeline: ?*Pipeline = null,
    vertex_buffers: [max_vertex_input_bindings]VertexBuffer = @splat(.{}),
    index_buffer: ?*Buffer = null,
    index_offset: u64 = 0,
    index_type: facet.IndexType = .uint16,
    viewport: facet.Viewport = .{ .width = 0, .height = 0 },
    scissor: facet.Rect2D = .{ .extent = .{} },
    /// What CmdSetBlendConstants set over every colour attachment, and
    /// what CmdSetBlendConstantsAt set for one of its own (facet's own,
    /// since 1.51): a pipeline whose constants are dynamic blends by its
    /// attachment's where that was set, and by the shared set otherwise.
    blend_constants: [4]f32 = @splat(0),
    attachment_constants: [_render.most_colors]?[4]f32 = @splat(null),
    /// What CmdSetDepthBias set, for a pipeline whose bias is dynamic.
    depth_bias: _pipeline.Bias = .{},
    /// What CmdSetDepthBounds last set, for a pipeline whose bounds are
    /// dynamic.
    depth_bounds: [2]f32 = .{ 0, 1 },
    line_width: f32 = 1,
    stencil: _vertices.StencilSet = .{},
    /// Whether each colour attachment the part draws has no alpha to
    /// read, which a blend of the destination's alpha takes as 1: one
    /// for each, the first's alone until a subpass draws several
    /// together (since 1.51), each at its location (since 1.118).
    target_opaques: [_render.most_colors]bool = @splat(false),
    /// Which of its subpass's parts is being drawn: a query counts the
    /// first alone (since 1.116).
    part: u32 = 0,
    /// Whether the part being drawn reads the colour attachment it draws
    /// into: its fragment functions are given the tile's own pixels for
    /// it (`shader.Fragments.keptAt`, since 1.64).
    reads_target: bool = false,
    /// Something left out for want of room has been reported.
    told_no_room: bool = false,
    /// The sets and the push constants as bound, and the copy of them in
    /// the frame's memory the draws since they last changed read; null
    /// until a draw makes one.
    resources: shader.Resources = .{},
    /// What compute functions have bound, apart from what draws have.
    compute_pipeline: ?*Pipeline = null,
    compute_resources: shader.Resources = .{},
    drawn: ?*const shader.Resources = null,
    /// What was bound where a subpass of several attachments began.
    saved: _vertices.Bound = undefined,
    /// Memory a draw's vertices are worked in, kept for the next.
    scratch: ?[*]u8 = null,
    scratch_bytes: usize = 0,
    /// The queries the work is counted into, each between its
    /// CmdBeginQuery and CmdEndQuery: one of each type that counts, both
    /// at once (since 1.117).
    queries: _queries.Active = .{},
    /// What the pass reaches past its framebuffer's first layer with.
    layered: Layered = .{},

    /// How colour attachment `output` is blended into by `pipeline`: its
    /// own of the pipeline's mixings, with the constants a command set
    /// where the pipeline leaves them to one, and taken over a target
    /// with no alpha to read. (`_draw.zig` draws by these.)
    pub fn mixingFor(player: *const Player, pipeline: *const Pipeline, translated: *const _draw.RasterState, output: u32) struct { raster.pipeline.Blend, raster.pipeline.Mixing } {
        const at = @min(output, _render.most_colors - 1);
        const asked = _pipeline.mixingAt(pipeline, at);
        const blend = translated.blend[at];
        var mixing = translated.mixing[at];
        if (blend == .general) {
            // What is there has no alpha: it reads as wholly opaque.
            if (player.target_opaques[at]) mixing = _draw.mixingOf(&asked.overOpaque());
            mixing.constant = _draw.constantOf(asked.constants orelse player.attachment_constants[at] orelse player.blend_constants);
        }
        return .{ blend, mixing };
    }
};

/// The player a queue keeps while its device lasts: false when there is no
/// memory for it.
pub fn open(queue: *Queue) callconv(.c) bool {
    const player = _objects.create(queue.device.sys, Player) orelse return false;
    player.* = .{};
    queue.driver = player;
    return true;
}

/// What the queue's player kept given back, and the player, as its device
/// goes.
pub fn close(queue: *Queue) callconv(.c) void {
    const player = playerOf(queue);
    if (player.target) |*target| target.deinit();
    if (player.scratch) |scratch| queue.device.sys.FreeVec(scratch);
    _objects.destroy(queue.device.sys, player);
    queue.driver = null;
}

/// Something left out of a frame for want of room, said once a queue with
/// what it was. The program is not told: nothing of a frame being played
/// reaches it. What can be caught while it is recorded is refused there
/// instead (`CmdDraw`).
pub fn noRoom(queue: *Queue, what: [*:0]const u8) void {
    const player = playerOf(queue);
    if (player.told_no_room) return;
    player.told_no_room = true;
    exec.kprintf(queue.device.sys, "facet.library: %s left out of the frame on the cores; what follows may be too\n", .{what});
}

pub fn playerOf(queue: *const Queue) *Player {
    return @ptrCast(@alignCast(queue.driver.?));
}

/// The commands of `buffer`, in order.
pub fn play(queue: *Queue, buffer: *CommandBuffer) void {
    const player = playerOf(queue);
    restart(player);
    playStream(queue, &buffer.stream);
    // A command buffer that ends inside its render pass ends the pass.
    endRenderPass(player);
}

/// The commands of a recording; a secondary command buffer's go on from what
/// the primary has bound and begun.
fn playStream(queue: *Queue, stream: *const _stream.Stream) void {
    const player = playerOf(queue);
    var commands = stream.commands();
    var repeat: ?_vertices.Repeat = null;
    while (commands.next()) |head| switch (head.op) {
        .barrier => {},
        .set_event, .reset_event, .wait_events => _sync.play(queue.device.sys, head),
        .copy_buffer_to_image => copyBufferToImage(_stream.as(_command.CopyBufferToImage, head)),
        .copy_buffer => _vertices.copyBuffer(_stream.as(_command.CopyBuffer, head)),
        .fill_buffer => if (!_vertices.fillBuffer(_stream.as(_command.FillBuffer, head))) noRoom(queue, "a fill of bytes that are not the buffer's"),
        .update_buffer => if (!_vertices.updateBuffer(_stream.as(_command.UpdateBuffer, head))) noRoom(queue, "an update of bytes that are not the buffer's"),
        .clear_color_image => if (!_transfer.clearColorImage(_stream.as(_command.ClearColorImage, head))) noRoom(queue, "a clear of an image whose format it cannot write"),
        .clear_depth_stencil_image => if (!_transfer.clearDepthImage(_stream.as(_command.ClearDepthStencilImage, head))) noRoom(queue, "a clear of a depth image whose pixels it cannot write"),
        .copy_image => _transfer.copyImage(_stream.as(_command.CopyImage, head)),
        .blit_image => _transfer.blitImage(_stream.as(_command.BlitImage, head)),
        .resolve_image => _transfer.resolveImage(_stream.as(_command.ResolveImage, head)),
        .copy_image_to_buffer => _transfer.copyImageToBuffer(_stream.as(_command.CopyImageToBuffer, head)),
        .clear_attachment => if (player.drawing) _draw.clearAttachment(queue, _stream.as(_command.ClearAttachment, head)),
        .begin_render_pass => {
            const command = _stream.as(_command.BeginRenderPass, head);
            beginRenderPass(queue, command, 0);
            if (command.part_count > 1) {
                player.saved = .of(player);
                repeat = .{ .begin = command, .from = commands, .output = 1 };
            }
        },
        .end_render_pass => {
            endRenderPass(player);
            if (repeat) |*again| {
                if (again.output == again.begin.part_count) {
                    repeat = null;
                } else {
                    player.saved.restore(player);
                    beginRenderPass(queue, again.begin, again.output);
                    commands = again.from;
                    again.output += 1;
                }
            }
        },
        .bind_pipeline => player.pipeline = _stream.as(_command.BindPipeline, head).pipeline,
        .bind_vertex_buffers => _vertices.bindVertexBuffers(player, _stream.as(_command.BindVertexBuffers, head)),
        .bind_index_buffer => {
            const command = _stream.as(_command.BindIndexBuffer, head);
            player.index_buffer = command.buffer;
            player.index_offset = command.offset;
            player.index_type = command.index_type;
        },
        .bind_descriptor_sets => {
            const command = _stream.as(_command.BindDescriptorSets, head);
            _vertices.bindDescriptorSets(if (command.compute != 0) &player.compute_resources else &player.resources, command);
            player.drawn = null;
        },
        .push_constants => {
            const command = _stream.as(_command.PushConstants, head);
            _vertices.pushConstants(&player.resources, command);
            _vertices.pushConstants(&player.compute_resources, command);
            player.drawn = null;
        },
        .set_viewport => player.viewport = _stream.as(_command.SetViewport, head).viewport,
        .set_scissor => player.scissor = _stream.as(_command.SetScissor, head).scissor,
        .set_blend_constants => {
            player.blend_constants = _stream.as(_command.SetBlendConstants, head).constants;
            // The one set over all of them: an attachment's own, set
            // before it, is forgotten.
            player.attachment_constants = @splat(null);
        },
        .set_blend_constants_at => {
            const command = _stream.as(_command.SetBlendConstantsAt, head);
            if (command.attachment < _render.most_colors) player.attachment_constants[command.attachment] = command.constants;
        },
        .set_depth_bias => {
            const command = _stream.as(_command.SetDepthBias, head);
            player.depth_bias = .{ .constant = command.constant, .clamp = command.clamp, .slope = command.slope };
        },
        .set_depth_bounds => {
            const command = _stream.as(_command.SetDepthBounds, head);
            player.depth_bounds = .{ command.min, command.max };
        },
        .set_line_width => player.line_width = _stream.as(_command.SetLineWidth, head).width,
        .set_stencil => player.stencil.apply(_stream.as(_command.SetStencil, head)),
        .draw => if (player.drawing) {
            const command = _stream.as(_command.Draw, head);
            _draw.draw(queue, command.first_vertex, command.vertex_count, null, command.first_instance, command.instance_count);
        },
        .draw_indexed => if (player.drawing) {
            const command = _stream.as(_command.DrawIndexed, head);
            _draw.draw(queue, command.first_index, command.index_count, command.vertex_offset, command.first_instance, command.instance_count);
        },
        .draw_indirect => if (player.drawing) {
            const command = _stream.as(_command.DrawIndirect, head);
            for (0..command.count) |k| {
                const made = _vertices.indirectDraw(command, @intCast(k)) orelse break;
                _draw.draw(queue, made.first, made.count, made.vertex_offset, made.first_instance, made.instances);
            }
        },
        .bind_compute_pipeline => player.compute_pipeline = _stream.as(_command.BindComputePipeline, head).pipeline,
        .dispatch => if (!player.drawing) _compute.dispatch(queue.device.sys, player.compute_pipeline, &player.compute_resources, _stream.as(_command.Dispatch, head).count, countersOf(player)),
        .dispatch_indirect => if (!player.drawing) _compute.dispatchIndirect(queue.device.sys, player.compute_pipeline, &player.compute_resources, _stream.as(_command.DispatchIndirect, head), countersOf(player)),
        .begin_query => {
            const command = _stream.as(_command.BeginQuery, head);
            // A pool of another kind, or a query past its last, counts
            // nothing: CmdBeginQuery refuses what it can see while it is
            // recorded, and the rest is said here.
            player.queries.begin(command);
            if (command.query >= command.pool.count) noRoom(queue, "a query begun past the pool's last");
        },
        .end_query => {
            const command = _stream.as(_command.EndQuery, head);
            _queries.ended(command);
            player.queries.end(command.pool, command.query);
        },
        .reset_query_pool => {
            const command = _stream.as(_command.ResetQueryPool, head);
            _query.reset(command.pool, command.first, command.count);
            player.queries.forget(command.pool);
        },
        .write_timestamp => {
            const command = _stream.as(_command.WriteTimestamp, head);
            if (!_queries.stamped(queue.device.base, command)) noRoom(queue, "a timestamp a pool of another kind cannot hold");
        },
        .copy_query_results => {
            const command = _stream.as(_command.CopyQueryResults, head);
            if (!_queries.copied(command)) noRoom(queue, "a copy of query values that are not the buffer's");
        },
        .execute_commands => {
            const command = _stream.as(_command.ExecuteCommands, head);
            for (_stream.items(_command.ExecuteCommands, *CommandBuffer, command, command.count)) |secondary| playStream(queue, &secondary.stream);
        },
        _ => {},
    };
}

/// Nothing bound, as each command buffer starts.
fn restart(player: *Player) void {
    player.drawing = false;
    player.pipeline = null;
    player.vertex_buffers = @splat(.{});
    player.index_buffer = null;
    player.resources = .{};
    player.compute_pipeline = null;
    player.compute_resources = .{};
    player.drawn = null;
    player.queries = .{};
}

/// What the work of a command is counted into: the queries begun, or
/// nothing.
fn countersOf(player: *const Player) *const _query.Counters {
    return &player.queries.counters;
}

/// What a pass reaches past its framebuffer's first layer with (since
/// 1.91): the part's framebuffer, its colour attachments, the render area
/// cut to the framebuffer, and which of the depth's planes the pass keeps in
/// the image. Nothing draws into those layers, so this is all a clear of
/// them needs.
pub const Layered = struct {
    framebuffer: ?*const _render.Target = null,
    colors: u32 = 0,
    area: raster.Rect = .{},
    depth: bool = false,
    stencil: bool = false,
};

/// The surface a framebuffer's colour attachment is: its image's memory,
/// row after row, from the layer its view begins at. Null for an image not
/// bound.
fn surfaceOf(framebuffer: *const _render.Target, output: u32) ?raster.Surface {
    return surfaceAt(framebuffer.colors[output], 0, 0);
}

/// The surface a part's colour attachment `output` is resolved into, at
/// the layer its view begins at: its resolve attachment's, or null where
/// it has none (since 1.109).
fn resolveOf(framebuffer: *const _render.Target, output: u32) ?raster.Surface {
    const view = framebuffer.resolves[output] orelse return null;
    return surfaceAt(view, 0, 0);
}

/// The display a part's tiles are handed on to, if any: its first colour
/// attachment's image's, or that attachment's resolve attachment's where
/// it has one, the tiles writing their averages into it as they are
/// written back (since 1.109). A swapchain's image is of one sample, so
/// it is a resolve attachment and never the colour of four. None for a
/// part of no colour attachment, which shows nothing (since 1.113).
pub fn displayOf(framebuffer: *const _render.Target) ?_image.Display {
    if (framebuffer.color_count == 0) return null;
    const shown = framebuffer.resolves[0] orelse framebuffer.colors[0];
    return shown.image.display;
}

/// The same `layer` layers past the one the view begins at. An image kept in
/// rows has layers since 1.91, and until then this was the image's first
/// layer whatever its view said: what drew into a view of the second layer
/// went into the first, the one place the depth's `planeOf` was already
/// right about. A multisampled image's samples follow sample 0's plane,
/// a plane each (since 1.103): this is sample `sample`'s, and the tiles
/// reach those past sample 0's by `sample_bytes` (since 1.104). Of the
/// level the view names, an image kept in rows having levels since 1.119:
/// a pass draws into that level's own rows, as llvmpipe maps the level a
/// surface names, with that level's stride (`init_scene_texture`,
/// src/gallium/drivers/llvmpipe/lp_scene.c:159-185).
fn surfaceAt(view: *const _image.ImageView, layer: u32, sample: u32) ?raster.Surface {
    const image = view.image;
    const data = image.data orelse return null;
    const plane = @as(usize, sample) * @as(usize, @intCast(image.sample_bytes));
    const rows = _image.rowsAt(image, view.base_level, view.base_layer + layer);
    const size = _image.levelSize(image, view.base_level);
    return .{
        .pixels = data + plane + rows.at,
        .pitch = rows.pitch,
        .width = size[0],
        .height = size[1],
        .format = switch (image.format) {
            .b8g8r8a8_unorm => .bgra32,
            .r8g8b8a8_unorm => .rgba32,
            .r5g6b5_unorm_pack16 => .rgb565,
            else => unreachable,
        },
        .sample_bytes = @intCast(image.sample_bytes),
    };
}

/// A depth attachment's rows as one of the plane's: the depth of each
/// pixel, or its stencil, wherever that lies in the pixel's bytes
/// (`_image.stencilOffset`). Null where there is nothing in memory to read
/// or write.
fn planeOf(view: ?*const _image.ImageView, which: Aspect) ?raster.Attachments.Plane {
    return planeAt(view orelse return null, which, 0, 0);
}

const Aspect = enum { depth, stencil };

/// The same `layer` layers past the one the view begins at (since 1.91),
/// in sample `sample`'s plane of a multisampled image, laid out as a
/// colour image's are (since 1.104); the tiles reach those past sample
/// 0's by `sample_bytes` (since 1.105).
fn planeAt(held: *const _image.ImageView, which: Aspect, layer: u32, sample: u32) ?raster.Attachments.Plane {
    const image = held.image;
    const format = image.format;
    const stride = _image.bytesOf(format);
    const at = switch (which) {
        .depth => if (_image.hasDepth(format)) _image.depthOffset(format) else return null,
        .stencil => if (_image.hasStencil(format)) _image.stencilOffset(format) else return null,
    };
    if (stride == 0 or at >= stride) return null;
    const data = image.data orelse return null;
    // The level and the layer the view names, a depth image having layers
    // since 1.58 and levels since 1.63: a pass draws into the ones its
    // framebuffer's view begins at, in that level's own rows.
    const rows = _image.rowsAt(image, held.base_level, held.base_layer + layer);
    const plane = @as(usize, sample) * @as(usize, @intCast(image.sample_bytes));
    return .{ .pixels = data + plane + rows.at + at, .pitch = rows.pitch, .stride = stride, .sample_bytes = @intCast(image.sample_bytes) };
}

/// The layers of a framebuffer past its first, cleared as a part begins where
/// an attachment's load op clears (since 1.91). Nothing draws into them -
/// Vulkan 1.0 has only a geometry shader's `Layer` to pick one, and no device
/// here has a geometry shader - so the clear is all the pass does to them,
/// and it goes straight into the image's rows rather than through the
/// tiles. This is Mesa's lavapipe: `render_clear` (lvp_execute.c) clears a
/// surface over every layer of the view the framebuffer has before anything
/// is drawn. What is written is what a tile cleared and stored leaves
/// (`raster.fillSurface`), so the first layer and the rest of a framebuffer
/// cleared alike are the same bytes, a 565 one dithered and all.
///
/// A depth or a stencil is written where the part keeps it in the image and
/// does not load it, which is the one case its other layers outlive the pass
/// with something defined in them.
///
/// A multisampled image's layers are cleared in every sample's plane (since
/// 1.104; until then in the first alone), as llvmpipe clears a surface of
/// more than one sample a sample at a time (`llvmpipe_clear_render_target`,
/// lp_surface.c:356-368; `llvmpipe_clear_depth_stencil`, :429-442).
fn clearLayers(layered: Layered, part: *const _render.Part, command: *const _command.BeginRenderPass, first_clear: u32) void {
    const framebuffer = layered.framebuffer orelse return;
    if (framebuffer.layers <= 1) return;
    for (0..layered.colors) |k| {
        if (part.color_loads[k] != .clear) continue;
        const color = command.clear_colors[@min(first_clear + k, _render.most_colors - 1)];
        const held = framebuffer.colors[k];
        for (1..framebuffer.layers) |layer| for (0..held.image.samples) |sample| {
            const surface = surfaceAt(held, @intCast(layer), @intCast(sample)) orelse break;
            raster.fillSurface(surface, layered.area, color);
        };
    }
    const view = framebuffer.depth orelse return;
    const clears_depth = layered.depth and part.stores_depth and !part.loads_depth;
    const clears_stencil = layered.stencil and part.stores_stencil and !part.loads_stencil;
    if (!clears_depth and !clears_stencil) return;
    for (1..framebuffer.layers) |layer| for (0..view.image.samples) |sample| {
        const at: u32 = @intCast(layer);
        const plane_of: u32 = @intCast(sample);
        if (clears_depth) if (planeAt(view, .depth, at, plane_of)) |plane| raster.fillDepth(plane, layered.area, @intCast(command.clear_depth));
        if (clears_stencil) if (planeAt(view, .stencil, at, plane_of)) |plane| raster.fillStencil(plane, layered.area, @intCast(command.clear_stencil));
    };
}

/// The layers of a framebuffer past its first resolved as a part ends
/// (since 1.109): each colour attachment that has a resolve attachment,
/// its samples averaged into it over the render area, as the tiles
/// resolve the first. No tile reaches those layers, so they are resolved
/// from what the image's rows hold by then - what the part's load ops and
/// clears left there (`clearLayers`, `clearRectangle`). lavapipe resolves
/// every layer of the framebuffer (`resolve_color`, lvp_execute.c:1809).
fn resolveLayers(layered: Layered) void {
    const framebuffer = layered.framebuffer orelse return;
    for (0..layered.colors) |k| {
        const into = framebuffer.resolves[k] orelse continue;
        for (1..framebuffer.layers) |layer| {
            const from = surfaceAt(framebuffer.colors[k], @intCast(layer), 0) orelse break;
            const resolve = surfaceAt(into, @intCast(layer), 0) orelse break;
            raster.resolveSurface(from, resolve, layered.area);
        }
    }
}

/// CmdClearAttachments' rectangle, over the layers it names past the
/// framebuffer's first (since 1.91): the first is in the tiles and cleared by
/// drawing (`_draw.clearAttachment`), and these are in the image's rows and
/// cleared in them, as `clearLayers` clears them for a load op. Layers past
/// the framebuffer's last are left alone, as is what lies outside the render
/// area, which the tiles never reach either. lavapipe's
/// `handle_clear_attachments` is the same over `clear_attachment_layers`.
/// A multisampled image's layers are cleared in every sample's plane, as
/// `clearLayers` clears them (since 1.104).
pub fn clearRectangle(player: *const Player, command: *const _command.ClearAttachment) void {
    const layered = player.layered;
    const framebuffer = layered.framebuffer orelse return;
    const first = @max(command.base_layer, 1);
    const end = @min(command.base_layer +| command.layer_count, framebuffer.layers);
    if (first >= end) return;
    const rect = command.rect;
    const area = layered.area;
    const left: u32 = @intCast(std.math.clamp(@as(i64, rect.offset.x), area.x, area.x + area.width));
    const top: u32 = @intCast(std.math.clamp(@as(i64, rect.offset.y), area.y, area.y + area.height));
    const right: u32 = @intCast(std.math.clamp(@as(i64, rect.offset.x) + rect.extent.width, left, area.x + area.width));
    const bottom: u32 = @intCast(std.math.clamp(@as(i64, rect.offset.y) + rect.extent.height, top, area.y + area.height));
    if (left == right or top == bottom) return;
    const cut = raster.Rect{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    const aspect = command.aspect_mask;
    // The colour of this part's own attachment, as the tiles' clear masks
    // every other one out.
    const color = aspect & facet.IMAGE_ASPECT_COLOR != 0 and command.output == player.resources.output and layered.colors != 0;
    const depth = aspect & facet.IMAGE_ASPECT_DEPTH != 0 and layered.depth;
    const stencil = aspect & facet.IMAGE_ASPECT_STENCIL != 0 and layered.stencil;
    for (first..end) |layer| {
        const at: u32 = @intCast(layer);
        if (color) {
            const held = framebuffer.colors[0];
            for (0..held.image.samples) |sample| {
                if (surfaceAt(held, at, @intCast(sample))) |surface| raster.fillSurface(surface, cut, command.color);
            }
        }
        const view = framebuffer.depth orelse continue;
        for (0..view.image.samples) |sample| {
            const plane_of: u32 = @intCast(sample);
            if (depth) if (planeAt(view, .depth, at, plane_of)) |plane| raster.fillDepth(plane, cut, _render.depthOf(.{ .depth = command.depth, .stencil = 0 }));
            if (stencil) if (planeAt(view, .stencil, at, plane_of)) |plane| raster.fillStencil(plane, cut, @truncate(command.stencil));
        }
    }
}

fn beginRenderPass(queue: *Queue, command: *const _command.BeginRenderPass, part: u32) void {
    const player = playerOf(queue);
    endRenderPass(player);
    player.part = part;
    const framebuffer = &command.targets[part];
    const render_pass = &command.parts[part];
    // The location its first colour is written at: its part's number,
    // unless a colour before it is unused and has none (since 1.118).
    player.resources.output = render_pass.output;
    // A surface for each colour attachment the part draws: the one it
    // usually has, and all of a subpass's where they go together
    // (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER, since 1.51).
    var surfaces: [_render.most_colors]raster.Surface = undefined;
    const colors = @min(render_pass.color_count, framebuffer.color_count);
    for (0..colors) |k| surfaces[k] = surfaceOf(framebuffer, @intCast(k)) orelse return;
    // The clears are the subpass's, in the order its parts draw them, so
    // this part's begin after the colours of the parts before it: that is
    // `part` where the subpass is played again for each of them, and 0
    // where its one part draws them all.
    var first_clear: u32 = 0;
    for (command.parts[0..part]) |before| first_clear += before.color_count;
    // Each attachment says for itself whether it has an alpha to read, at
    // the location a blend asks for it by.
    player.target_opaques = @splat(false);
    for (surfaces[0..colors], 0..) |each, k| player.target_opaques[@min(render_pass.output + k, _render.most_colors - 1)] = each.format == .rgb565;
    // What the subpass reads of what it draws (since 1.64).
    player.reads_target = render_pass.reads_target;
    // The render area, cut to the framebuffer.
    const offset = command.area.offset;
    const left: u32 = @intCast(std.math.clamp(offset.x, 0, @as(i64, framebuffer.width)));
    const top: u32 = @intCast(std.math.clamp(offset.y, 0, @as(i64, framebuffer.height)));
    const right: u32 = @intCast(std.math.clamp(@as(i64, offset.x) + command.area.extent.width, left, framebuffer.width));
    const bottom: u32 = @intCast(std.math.clamp(@as(i64, offset.y) + command.area.extent.height, top, framebuffer.height));
    const area = raster.Rect{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    // Where the pass keeps its depth or its stencil, the image's rows are
    // the plane the tiles read from and write back into; a transient image
    // has none, and CreateFramebuffer has already refused that pass. A
    // format that holds both keeps each pixel's depth and its stencil
    // beside each other, which is what the stride is for.
    const keeps_depth = render_pass.stores_depth or render_pass.loads_depth;
    const keeps_stencil = render_pass.stores_stencil or render_pass.loads_stencil;
    const plane: ?raster.Attachments.Plane = if (keeps_depth) planeOf(framebuffer.depth, .depth) else null;
    const stencil_plane: ?raster.Attachments.Plane = if (keeps_stencil) planeOf(framebuffer.depth, .stencil) else null;
    var attachments = raster.Attachments{
        .color = .{
            .load = if (render_pass.color_loads[0] == .clear) .clear else .keep,
            .clear = command.clear_colors[@min(first_clear, _render.most_colors - 1)],
            .resolve = resolveOf(framebuffer, 0),
        },
        .color_count = colors,
        .samples = render_pass.samples,
        .depth = .{
            .used = render_pass.tests_depth,
            .clear = @intCast(command.clear_depth),
            .plane = plane,
            .load = if (render_pass.loads_depth and plane != null) .keep else .clear,
            .store = render_pass.stores_depth and plane != null,
        },
        .stencil = .{
            .used = render_pass.tests_stencil,
            .clear = @intCast(command.clear_stencil),
            .plane = stencil_plane,
            .load = if (render_pass.loads_stencil and stencil_plane != null) .keep else .clear,
            .store = render_pass.stores_stencil and stencil_plane != null,
        },
    };
    // Those past the first: the subpass's own clears, in the order its
    // part draws them - none in a subpass of none (since 1.113).
    for (1..@max(colors, 1)) |k| attachments.more[k - 1] = .{
        .load = if (render_pass.color_loads[k] == .clear) .clear else .keep,
        .clear = command.clear_colors[@min(first_clear + k, _render.most_colors - 1)],
        .resolve = resolveOf(framebuffer, @intCast(k)),
    };
    player.display = displayOf(framebuffer);
    if (player.target) |*target| {
        target.moveToAll(surfaces[0..colors], area, attachments) catch return;
    } else {
        player.target = raster.Target.initAll(hostOf(queue), surfaces[0..colors], area, attachments) catch return;
    }
    player.target.?.begin();
    player.drawn = null;
    player.drawing = true;
    // The framebuffer's other layers, which no tile reaches (since 1.91).
    player.layered = .{
        .framebuffer = framebuffer,
        .colors = colors,
        .area = area,
        .depth = plane != null,
        .stencil = stencil_plane != null,
    };
    clearLayers(player.layered, render_pass, command, first_clear);
}

fn endRenderPass(player: *Player) void {
    if (!player.drawing) return;
    player.drawing = false;
    player.drawn = null;
    _ = player.target.?.finish();
    resolveLayers(player.layered);
    player.layered = .{};
}

/// What the queue's target is given of the system: exec's workers and
/// memory, and the display the pass draws into, if any.
fn hostOf(queue: *Queue) raster.Host {
    return .{ .context = queue, .share = &share, .hand_on = &handOn, .allocate = &allocate, .free = &free };
}

fn queueOf(context: ?*anyopaque) *Queue {
    return @ptrCast(@alignCast(context.?));
}

fn share(context: ?*anyopaque, work: raster.Work, data: ?*anyopaque, parts: u32) u32 {
    return queueOf(context).device.sys.ShareWork(work, data, parts);
}

fn handOn(context: ?*anyopaque, area: raster.Rect) void {
    const display = playerOf(queueOf(context)).display orelse return;
    display.handOn(area.x, area.y, area.width, area.height);
}

fn allocate(context: ?*anyopaque, bytes: usize) ?[*]u8 {
    return @ptrCast(queueOf(context).device.sys.AllocVec(bytes, exec.MEMF_ANY));
}

fn free(context: ?*anyopaque, memory: [*]u8, bytes: usize) void {
    _ = bytes;
    queueOf(context).device.sys.FreeVec(memory);
}

fn copyBufferToImage(command: *const _command.CopyBufferToImage) void {
    const from = _buffer.bytes(command.source, 0, facet.WHOLE_SIZE) orelse return;
    for (_stream.items(_command.CopyBufferToImage, facet.BufferImageCopy, command, command.count)) |*region| {
        _image.copyFromBuffer(command.image, from, region);
    }
}
