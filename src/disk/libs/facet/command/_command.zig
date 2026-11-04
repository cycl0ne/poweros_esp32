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
const QueryPool = @import("../query/_query.zig").Pool;

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
    /// Played from a primary one (CmdExecuteCommands), not from a queue.
    secondary: bool = false,
    /// Recorded with ONE_TIME_SUBMIT: spent once played.
    one_time: bool = false,
    /// Its submissions the queue has not finished playing.
    pending: u32 = 0,
    /// The render pass being recorded, for CmdNextSubpass.
    pass: ?*_render.RenderPass = null,
    framebuffer: ?*_render.Framebuffer = null,
    area: facet.Rect2D = .{ .extent = .{} },
    subpass: u32 = 0,
    clears: [_render.most_attachments]facet.ClearValue = undefined,
    clear_count: u32 = 0,
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

/// CmdFillBuffer: a run of a buffer set to one value, four bytes at a time.
pub const FillBuffer = extern struct {
    pub const op: _stream.Op = .fill_buffer;
    head: Head = .{ .op = op },
    destination: *Buffer,
    offset: u64,
    /// `facet.WHOLE_SIZE` for the rest of the buffer.
    size: u64,
    data: u32,
    pad: u32 = 0,
};

/// CmdUpdateBuffer, followed by the bytes it writes: they are the command's
/// own, so that the program's may go as soon as it is recorded.
pub const UpdateBuffer = extern struct {
    pub const op: _stream.Op = .update_buffer;
    head: Head = .{ .op = op },
    destination: *Buffer,
    offset: u64,
    size: u64,
};

/// CmdClearColorImage, followed by its ranges.
pub const ClearColorImage = extern struct {
    pub const op: _stream.Op = .clear_color_image;
    head: Head = .{ .op = op },
    count: u32,
    /// 0xAARRGGBB.
    color: u32,
    /// The channels as they were given, red first, for a float image whose
    /// texels hold what they were told rather than a byte a channel
    /// (since 1.61).
    parts: [4]f32,
    image: *Image,
};

/// CmdClearDepthStencilImage, followed by its ranges.
pub const ClearDepthStencilImage = extern struct {
    pub const op: _stream.Op = .clear_depth_stencil_image;
    head: Head = .{ .op = op },
    count: u32,
    /// The depth as the tiles hold one: 0 nearest, 65535 furthest.
    depth: u16,
    stencil: u8,
    pad: u8 = 0,
    image: *Image,
};

/// CmdBeginQuery: what the work after it is counted into.
pub const BeginQuery = extern struct {
    pub const op: _stream.Op = .begin_query;
    head: Head = .{ .op = op },
    pool: *QueryPool,
    query: u32,
    /// QUERY_CONTROL_PRECISE, which this library counts either way.
    flags: u32,
};

/// CmdEndQuery: the query made available.
pub const EndQuery = extern struct {
    pub const op: _stream.Op = .end_query;
    head: Head = .{ .op = op },
    pool: *QueryPool,
    query: u32,
    pad: u32 = 0,
};

/// CmdResetQueryPool: queries set back to nothing counted.
pub const ResetQueryPool = extern struct {
    pub const op: _stream.Op = .reset_query_pool;
    head: Head = .{ .op = op },
    pool: *QueryPool,
    first: u32,
    count: u32,
};

/// CmdWriteTimestamp: the clock as the command is played.
pub const WriteTimestamp = extern struct {
    pub const op: _stream.Op = .write_timestamp;
    head: Head = .{ .op = op },
    pool: *QueryPool,
    query: u32,
    /// The stage it was asked for at: the commands are played one after
    /// another and each is finished before the next starts, so every stage
    /// is the same moment here.
    stage: u32,
};

/// CmdCopyQueryPoolResults: the values written into a buffer.
pub const CopyQueryResults = extern struct {
    pub const op: _stream.Op = .copy_query_results;
    head: Head = .{ .op = op },
    pool: *QueryPool,
    destination: *Buffer,
    offset: u64,
    stride: u64,
    first: u32,
    count: u32,
    flags: u32,
    pad: u32 = 0,
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
    /// What each colour attachment of the subpass is, and draws into. Played
    /// once for each: the commands up to the next EndRenderPass over again.
    parts: [*]const _render.Part,
    targets: [*]const _render.Target,
    part_count: u32,
    area: facet.Rect2D,
    /// 0xAARRGGBB for each colour attachment of the subpass, in the
    /// order the parts draw them, and the depth buffer's 0 to 65535.
    clear_colors: [_render.most_colors]u32,
    clear_depth: u32,
    clear_stencil: u32,
};

/// A subpass of `made`'s pass begun, with the clear values it was begun with.
pub fn beginSubpass(made: *CommandBuffer, number: u32) void {
    const pass = made.pass.?;
    const subpass = pass.subpasses[number];
    const first = pass.parts[subpass.first_part];
    const clears = made.clears[0..made.clear_count];
    var command = BeginRenderPass{
        .parts = pass.parts[subpass.first_part..].ptr,
        .targets = made.framebuffer.?.targets[subpass.first_part..].ptr,
        .part_count = subpass.part_count,
        .area = made.area,
        .clear_colors = @splat(0xFF00_0000),
        .clear_depth = if (first.depth) |depth| (if (depth < clears.len) _render.depthOf(clears[depth].depth_stencil) else 0xFFFF) else 0xFFFF,
        .clear_stencil = if (first.depth) |depth| (if (depth < clears.len) clears[depth].depth_stencil.stencil & 0xFF else 0) else 0,
    };
    // The subpass's colour attachments in the order its parts draw
    // them: one a part where it is played again for each, and all of a
    // part where they go together (since 1.51).
    var at: u32 = 0;
    for (pass.parts[subpass.first_part..][0..subpass.part_count]) |part| {
        for (part.colors[0..part.color_count]) |index| {
            if (at == _render.most_colors) break;
            if (index < clears.len) command.clear_colors[at] = _render.colorOf(clears[index].color);
            at += 1;
        }
    }
    record(made, command, u8, &.{});
}

/// CmdCopyImage, followed by its regions.
pub const CopyImage = extern struct {
    pub const op: _stream.Op = .copy_image;
    head: Head = .{ .op = op },
    count: u32,
    pad: u32 = 0,
    source: *Image,
    destination: *Image,
};

/// CmdBlitImage, followed by its regions.
pub const BlitImage = extern struct {
    pub const op: _stream.Op = .blit_image;
    head: Head = .{ .op = op },
    count: u32,
    filter: facet.Filter,
    source: *Image,
    destination: *Image,
};

/// CmdCopyImageToBuffer, followed by its regions.
pub const CopyImageToBuffer = extern struct {
    pub const op: _stream.Op = .copy_image_to_buffer;
    head: Head = .{ .op = op },
    count: u32,
    pad: u32 = 0,
    image: *Image,
    destination: *Buffer,
};

/// One attachment of CmdClearAttachments over one of its rectangles.
pub const ClearAttachment = extern struct {
    pub const op: _stream.Op = .clear_attachment;
    head: Head = .{ .op = op },
    aspect_mask: u32,
    rect: facet.Rect2D,
    /// 0xAARRGGBB, the depth 0 to 1, and the stencil.
    color: u32,
    depth: f32,
    stencil: u32,
    /// Which of the subpass's colour attachments the colour is for.
    output: u32,
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

/// CmdBindDescriptorSets, followed by the offsets its dynamic buffer
/// descriptors are shifted by.
pub const BindDescriptorSets = extern struct {
    pub const op: _stream.Op = .bind_descriptor_sets;
    head: Head = .{ .op = op },
    first: u32,
    count: u32,
    /// For compute functions, not for drawing: 1 or 0.
    compute: u32,
    /// The offsets after it: one for each dynamic buffer descriptor of
    /// the sets, in the order the sets, their bindings and the elements
    /// of each run (`dynamic_offsets`).
    offset_count: u32,
    /// The sets bound, `count` of them from `first`.
    sets: [facet.shader.MAX_SETS]?*DescriptorSet,
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

pub const SetBlendConstants = extern struct {
    pub const op: _stream.Op = .set_blend_constants;
    head: Head = .{ .op = op },
    constants: [4]f32,
};

/// CmdSetBlendConstantsAt: one colour attachment's own blend constants,
/// facet.library's own where Vulkan has the one set (since 1.51).
pub const SetBlendConstantsAt = extern struct {
    pub const op: _stream.Op = .set_blend_constants_at;
    head: Head = .{ .op = op },
    attachment: u32,
    pad: u32 = 0,
    constants: [4]f32,
};

/// CmdSetDepthBias, for a pipeline whose bias is dynamic.
pub const SetDepthBias = extern struct {
    pub const op: _stream.Op = .set_depth_bias;
    head: Head = .{ .op = op },
    constant: f32,
    clamp: f32,
    slope: f32,
};

/// CmdSetDepthBounds, for a pipeline whose bounds are dynamic.
pub const SetDepthBounds = extern struct {
    pub const op: _stream.Op = .set_depth_bounds;
    head: Head = .{ .op = op },
    min: f32,
    max: f32,
};

pub const SetLineWidth = extern struct {
    pub const op: _stream.Op = .set_line_width;
    head: Head = .{ .op = op },
    width: f32,
};

pub const SetStencil = extern struct {
    pub const op: _stream.Op = .set_stencil;
    head: Head = .{ .op = op },
    which: Which,
    face_mask: u32,
    value: u32,

    pub const Which = enum(u32) { compare, write, reference };
};

pub const Draw = extern struct {
    pub const op: _stream.Op = .draw;
    head: Head = .{ .op = op },
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

/// CmdDrawIndirect and CmdDrawIndexedIndirect: their numbers are in the
/// buffer as the command is played.
pub const DrawIndirect = extern struct {
    pub const op: _stream.Op = .draw_indirect;
    head: Head = .{ .op = op },
    buffer: *Buffer,
    offset: u64,
    count: u32,
    stride: u32,
    indexed: bool,
};

/// CmdBindPipeline with a compute pipeline.
pub const BindComputePipeline = extern struct {
    pub const op: _stream.Op = .bind_compute_pipeline;
    head: Head = .{ .op = op },
    pipeline: *_pipeline.Pipeline,
};

pub const Dispatch = extern struct {
    pub const op: _stream.Op = .dispatch;
    head: Head = .{ .op = op },
    count: [3]u32,
    pad: u32 = 0,
};

/// Its numbers are in the buffer as the command is played.
pub const DispatchIndirect = extern struct {
    pub const op: _stream.Op = .dispatch_indirect;
    head: Head = .{ .op = op },
    buffer: *Buffer,
    offset: u64,
};

/// CmdExecuteCommands, followed by the command buffers.
pub const ExecuteCommands = extern struct {
    pub const op: _stream.Op = .execute_commands;
    head: Head = .{ .op = op },
    count: u32,
    pad: u32 = 0,
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
