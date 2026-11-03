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
//! on its own; into any other image it is handed on to nothing.

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
    /// colour attachment is, or null.
    display: ?_image.Display = null,
    /// What the draws are drawn with: bound, and set by commands.
    pipeline: ?*Pipeline = null,
    vertex_buffers: [max_vertex_input_bindings]VertexBuffer = @splat(.{}),
    index_buffer: ?*Buffer = null,
    index_offset: u64 = 0,
    index_type: facet.IndexType = .uint16,
    viewport: facet.Viewport = .{ .width = 0, .height = 0 },
    scissor: facet.Rect2D = .{ .extent = .{} },
    blend_constants: [4]f32 = @splat(0),
    /// What CmdSetDepthBias set, for a pipeline whose bias is dynamic.
    depth_bias: _pipeline.Bias = .{},
    /// What CmdSetDepthBounds last set, for a pipeline whose bounds are
    /// dynamic.
    depth_bounds: [2]f32 = .{ 0, 1 },
    line_width: f32 = 1,
    stencil: _vertices.StencilSet = .{},
    /// The colour attachment has no alpha.
    target_opaque: bool = false,
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
    /// The query the work is counted into, between CmdBeginQuery and
    /// CmdEndQuery; null while nothing counts.
    query: ?_queries.Counting = null,
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
        .copy_buffer_to_image => copyBufferToImage(_stream.as(_command.CopyBufferToImage, head)),
        .copy_buffer => _vertices.copyBuffer(_stream.as(_command.CopyBuffer, head)),
        .fill_buffer => if (!_vertices.fillBuffer(_stream.as(_command.FillBuffer, head))) noRoom(queue, "a fill of bytes that are not the buffer's"),
        .update_buffer => if (!_vertices.updateBuffer(_stream.as(_command.UpdateBuffer, head))) noRoom(queue, "an update of bytes that are not the buffer's"),
        .clear_color_image => if (!_transfer.clearColorImage(_stream.as(_command.ClearColorImage, head))) noRoom(queue, "a clear of an image whose format it cannot write"),
        .clear_depth_stencil_image => if (!_transfer.clearDepthImage(_stream.as(_command.ClearDepthStencilImage, head))) noRoom(queue, "a clear of a depth image whose pixels it cannot write"),
        .copy_image => _transfer.copyImage(_stream.as(_command.CopyImage, head)),
        .blit_image => _transfer.blitImage(_stream.as(_command.BlitImage, head)),
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
        .set_blend_constants => player.blend_constants = _stream.as(_command.SetBlendConstants, head).constants,
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
            player.query = _queries.begun(command);
            if (player.query == null and command.query >= command.pool.count) noRoom(queue, "a query begun past the pool's last");
        },
        .end_query => {
            const command = _stream.as(_command.EndQuery, head);
            _queries.ended(command);
            if (player.query) |counting| if (counting.pool == command.pool and counting.index == command.query) {
                player.query = null;
            };
        },
        .reset_query_pool => {
            const command = _stream.as(_command.ResetQueryPool, head);
            _query.reset(command.pool, command.first, command.count);
            if (player.query) |counting| if (counting.pool == command.pool) {
                player.query = null;
            };
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
    player.query = null;
}

/// What the work of a command is counted into: the query begun, or nothing.
fn countersOf(player: *const Player) *const _query.Counters {
    return if (player.query) |*counting| &counting.counters else &_query.none;
}

/// The surface a framebuffer's colour attachment is: its image's memory,
/// row after row. Null for an image not bound.
fn surfaceOf(framebuffer: *const _render.Target) ?raster.Surface {
    const image = framebuffer.color.image;
    return .{
        .pixels = image.data orelse return null,
        .pitch = image.pitch,
        .width = image.width,
        .height = image.height,
        .format = switch (image.format) {
            .b8g8r8a8_unorm => .bgra32,
            .r8g8b8a8_unorm => .rgba32,
            .r5g6b5_unorm_pack16 => .rgb565,
            else => unreachable,
        },
    };
}

/// A depth attachment's rows as one of the plane's: the depth of each
/// pixel, or its stencil, wherever that lies in the pixel's bytes
/// (`_image.stencilOffset`). Null where there is nothing in memory to read
/// or write.
fn planeOf(view: ?*const _image.ImageView, which: enum { depth, stencil }) ?raster.Attachments.Plane {
    const image = (view orelse return null).image;
    const format = image.format;
    const stride = _image.bytesOf(format);
    const at = switch (which) {
        .depth => if (_image.hasDepth(format)) _image.depthOffset(format) else return null,
        .stencil => if (_image.hasStencil(format)) _image.stencilOffset(format) else return null,
    };
    if (stride == 0 or at >= stride) return null;
    const data = image.data orelse return null;
    return .{ .pixels = data + at, .pitch = image.pitch, .stride = stride };
}

fn beginRenderPass(queue: *Queue, command: *const _command.BeginRenderPass, output: u32) void {
    const player = playerOf(queue);
    endRenderPass(player);
    player.resources.output = output;
    const framebuffer = &command.targets[output];
    const surface = surfaceOf(framebuffer) orelse return;
    player.target_opaque = surface.format == .rgb565;
    const render_pass = &command.parts[output];
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
    const attachments = raster.Attachments{
        .color = .{ .load = if (render_pass.color_load == .clear) .clear else .keep, .clear = command.clear_colors[output] },
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
    player.display = framebuffer.color.image.display;
    if (player.target) |*target| {
        target.moveTo(surface, area, attachments) catch return;
    } else {
        player.target = raster.Target.init(hostOf(queue), surface, area, attachments) catch return;
    }
    player.target.?.begin();
    player.drawn = null;
    player.drawing = true;
}

fn endRenderPass(player: *Player) void {
    if (!player.drawing) return;
    player.drawing = false;
    player.drawn = null;
    _ = player.target.?.finish();
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
