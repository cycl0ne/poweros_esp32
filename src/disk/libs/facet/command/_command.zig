// SPDX-License-Identifier: MIT
//! A command pool, its command buffers, and the commands they record.
//!
//! A command buffer is initial when it is made or reset, recording from
//! BeginCommandBuffer to EndCommandBuffer, then executable: submitted, it
//! is played by the queue's task, as often as it is submitted. One
//! recorded with ONE_TIME_SUBMIT is spent by its one submission, and has
//! to be recorded again. A command recorded outside a recording is not
//! recorded at all.

const sdk = @import("sdk");
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;
const _stream = @import("_stream.zig");
const Stream = _stream.Stream;
const Head = _stream.Head;
const Buffer = @import("../buffer/_buffer.zig").Buffer;
const Image = @import("../image/_image.zig").Image;
const _render = @import("../render/_render.zig");
const _pipeline = @import("../pipeline/_pipeline.zig");
const DescriptorSet = @import("../descriptor/_descriptor.zig").Set;

pub const CommandPool = struct {
    device: *Device,
    flags: u32,
    /// Its command buffers, the last allocated first.
    first: ?*CommandBuffer = null,
};

pub const State = enum(u8) { initial, recording, executable, spent };

pub const CommandBuffer = struct {
    device: *Device,
    pool: *CommandPool,
    stream: Stream = .{},
    state: State = .initial,
    /// Recorded with ONE_TIME_SUBMIT: spent once played.
    one_time: bool = false,
    /// Its submissions the queue has not finished playing.
    pending: u32 = 0,
    /// On its pool's list.
    next: ?*CommandBuffer = null,
    previous: ?*CommandBuffer = null,
};

/// The command buffer, if it is recording.
pub fn recording(buffer: *facet.CommandBuffer) ?*CommandBuffer {
    const made: *CommandBuffer = @ptrCast(@alignCast(buffer));
    return if (made.state == .recording) made else null;
}

/// Command `command`, and `items` after it, recorded into `buffer`.
pub fn record(buffer: *CommandBuffer, command: anytype, comptime Item: type, items: []const Item) void {
    buffer.stream.put(buffer.device.sys, command, Item, items);
}

/// The buffer's recording given up and its chunks kept or given back.
pub fn clear(buffer: *CommandBuffer, release: bool) void {
    buffer.stream.reset(buffer.device.sys, release);
    buffer.state = .initial;
    buffer.one_time = false;
}

// --- the commands ------------------------------------------------------------

/// CmdPipelineBarrier: the work before it ends before the work after it
/// starts, which a queue's order gives already.
pub const Barrier = extern struct {
    pub const op: _stream.Op = .barrier;
    head: Head = .{ .op = op },
    src_stage_mask: u32,
    dst_stage_mask: u32,
};

/// CmdCopyBufferToImage, followed by its regions.
pub const CopyBufferToImage = extern struct {
    pub const op: _stream.Op = .copy_buffer_to_image;
    head: Head = .{ .op = op },
    count: u32,
    pad: u32 = 0,
    source: *Buffer,
    image: *Image,
};

/// CmdCopyBuffer, followed by its regions.
pub const CopyBuffer = extern struct {
    pub const op: _stream.Op = .copy_buffer;
    head: Head = .{ .op = op },
    count: u32,
    pad: u32 = 0,
    source: *Buffer,
    destination: *Buffer,
};

/// CmdBeginRenderPass, its clear values made the tiles' own.
pub const BeginRenderPass = extern struct {
    pub const op: _stream.Op = .begin_render_pass;
    head: Head = .{ .op = op },
    render_pass: *_render.RenderPass,
    framebuffer: *_render.Framebuffer,
    area: facet.Rect2D,
    /// 0xAARRGGBB, and the depth buffer's 0 to 65535.
    clear_color: u32,
    clear_depth: u32,
};

pub const EndRenderPass = extern struct {
    pub const op: _stream.Op = .end_render_pass;
    head: Head = .{ .op = op },
};

pub const BindPipeline = extern struct {
    pub const op: _stream.Op = .bind_pipeline;
    head: Head = .{ .op = op },
    pipeline: *_pipeline.Pipeline,
};

/// A vertex buffer as CmdBindVertexBuffers carries it.
pub const VertexBuffer = extern struct {
    buffer: *Buffer,
    offset: u64 align(4),
};

/// CmdBindVertexBuffers, followed by its buffers.
pub const BindVertexBuffers = extern struct {
    pub const op: _stream.Op = .bind_vertex_buffers;
    head: Head = .{ .op = op },
    first: u32,
    count: u32,
};

pub const BindIndexBuffer = extern struct {
    pub const op: _stream.Op = .bind_index_buffer;
    head: Head = .{ .op = op },
    buffer: *Buffer,
    offset: u64 align(4),
    index_type: facet.IndexType,
    pad: u32 = 0,
};

/// CmdBindDescriptorSets, followed by its sets.
pub const BindDescriptorSets = extern struct {
    pub const op: _stream.Op = .bind_descriptor_sets;
    head: Head = .{ .op = op },
    first: u32,
    count: u32,
};

/// CmdPushConstants, followed by its bytes.
pub const PushConstants = extern struct {
    pub const op: _stream.Op = .push_constants;
    head: Head = .{ .op = op },
    offset: u32,
    size: u32,
};

pub const SetViewport = extern struct {
    pub const op: _stream.Op = .set_viewport;
    head: Head = .{ .op = op },
    viewport: facet.Viewport,
};

pub const SetScissor = extern struct {
    pub const op: _stream.Op = .set_scissor;
    head: Head = .{ .op = op },
    scissor: facet.Rect2D,
};

pub const Draw = extern struct {
    pub const op: _stream.Op = .draw;
    head: Head = .{ .op = op },
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

pub const DrawIndexed = extern struct {
    pub const op: _stream.Op = .draw_indexed;
    head: Head = .{ .op = op },
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
    pad: u32 = 0,
};

/// The buffer taken off its pool's list.
pub fn unlink(pool: *CommandPool, buffer: *CommandBuffer) void {
    if (buffer.previous) |previous| previous.next = buffer.next else pool.first = buffer.next;
    if (buffer.next) |next| next.previous = buffer.previous;
    buffer.next = null;
    buffer.previous = null;
}
