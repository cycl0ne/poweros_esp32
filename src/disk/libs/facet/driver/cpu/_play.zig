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
const Pipeline = @import("../../pipeline/_pipeline.zig").Pipeline;
const max_vertex_input_bindings = @import("../../instance/_instance.zig").max_vertex_input_bindings;
const _vertices = @import("../_vertices.zig");
const _draw = @import("_draw.zig");

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
    /// The sets and the push constants as bound, and the copy of them in
    /// the frame's memory the draws since they last changed read; null
    /// until a draw makes one.
    resources: shader.Resources = .{},
    drawn: ?*const shader.Resources = null,
    /// Memory a draw's vertices are worked in, kept for the next.
    scratch: ?[*]u8 = null,
    scratch_bytes: usize = 0,
};

/// The player a queue keeps while its device lasts: false when there is no
/// memory for it.
pub fn open(queue: *Queue) bool {
    const player = _objects.create(queue.device.sys, Player) orelse return false;
    player.* = .{};
    queue.driver = player;
    return true;
}

/// What the queue's player kept given back, and the player, as its device
/// goes.
pub fn close(queue: *Queue) void {
    const player = playerOf(queue);
    if (player.target) |*target| target.deinit();
    if (player.scratch) |scratch| queue.device.sys.FreeVec(scratch);
    _objects.destroy(queue.device.sys, player);
    queue.driver = null;
}

pub fn playerOf(queue: *const Queue) *Player {
    return @ptrCast(@alignCast(queue.driver.?));
}

/// The commands of `buffer`, in order.
pub fn play(queue: *Queue, buffer: *CommandBuffer) void {
    const player = playerOf(queue);
    restart(player);
    var commands = buffer.stream.commands();
    while (commands.next()) |head| switch (head.op) {
        .barrier => {},
        .copy_buffer_to_image => copyBufferToImage(_stream.as(_command.CopyBufferToImage, head)),
        .copy_buffer => _vertices.copyBuffer(_stream.as(_command.CopyBuffer, head)),
        .begin_render_pass => beginRenderPass(queue, _stream.as(_command.BeginRenderPass, head)),
        .end_render_pass => endRenderPass(player),
        .bind_pipeline => player.pipeline = _stream.as(_command.BindPipeline, head).pipeline,
        .bind_vertex_buffers => _vertices.bindVertexBuffers(player, _stream.as(_command.BindVertexBuffers, head)),
        .bind_index_buffer => {
            const command = _stream.as(_command.BindIndexBuffer, head);
            player.index_buffer = command.buffer;
            player.index_offset = command.offset;
            player.index_type = command.index_type;
        },
        .bind_descriptor_sets => {
            _vertices.bindDescriptorSets(&player.resources, _stream.as(_command.BindDescriptorSets, head));
            player.drawn = null;
        },
        .push_constants => {
            _vertices.pushConstants(&player.resources, _stream.as(_command.PushConstants, head));
            player.drawn = null;
        },
        .set_viewport => player.viewport = _stream.as(_command.SetViewport, head).viewport,
        .set_scissor => player.scissor = _stream.as(_command.SetScissor, head).scissor,
        .draw => if (player.drawing) {
            const command = _stream.as(_command.Draw, head);
            _draw.draw(queue, command.first_vertex, command.vertex_count, null, command.first_instance, command.instance_count);
        },
        .draw_indexed => if (player.drawing) {
            const command = _stream.as(_command.DrawIndexed, head);
            _draw.draw(queue, command.first_index, command.index_count, command.vertex_offset, command.first_instance, command.instance_count);
        },
        _ => {},
    };
    // A command buffer that ends inside its render pass ends the pass.
    endRenderPass(player);
}

/// Nothing bound, as each command buffer starts.
fn restart(player: *Player) void {
    player.drawing = false;
    player.pipeline = null;
    player.vertex_buffers = @splat(.{});
    player.index_buffer = null;
    player.resources = .{};
    player.drawn = null;
}

/// The surface a framebuffer's colour attachment is: its image's memory,
/// row after row. Null for an image not bound.
fn surfaceOf(framebuffer: *const _render.Framebuffer) ?raster.Surface {
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

fn beginRenderPass(queue: *Queue, command: *const _command.BeginRenderPass) void {
    const player = playerOf(queue);
    endRenderPass(player);
    const framebuffer = command.framebuffer;
    const surface = surfaceOf(framebuffer) orelse return;
    const render_pass = command.render_pass;
    // The render area, cut to the framebuffer.
    const offset = command.area.offset;
    const left: u32 = @intCast(std.math.clamp(offset.x, 0, @as(i64, framebuffer.width)));
    const top: u32 = @intCast(std.math.clamp(offset.y, 0, @as(i64, framebuffer.height)));
    const right: u32 = @intCast(std.math.clamp(@as(i64, offset.x) + command.area.extent.width, left, framebuffer.width));
    const bottom: u32 = @intCast(std.math.clamp(@as(i64, offset.y) + command.area.extent.height, top, framebuffer.height));
    const area = raster.Rect{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    const attachments = raster.Attachments{
        .color = .{ .load = if (render_pass.color_load == .clear) .clear else .keep, .clear = command.clear_color },
        .depth = .{ .used = render_pass.depth != null, .clear = @intCast(command.clear_depth) },
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
