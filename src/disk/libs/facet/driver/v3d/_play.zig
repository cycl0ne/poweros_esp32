// SPDX-License-Identifier: MIT
//! A command buffer played for the V3D, on its queue's task: copies done as
//! they come, and each render pass made into a frame's two control lists
//! and sent.
//!
//! The binner's list grows draw by draw (`draw`). What a draw needs in the
//! V3D's reach - its vertices worked by the program's vertex function, its
//! indices, its shader state - is carved from chunks the player keeps from
//! frame to frame. CmdEndRenderPass adds the renderer's list, writes it all
//! out to memory, runs the binner and then the renderer, waiting on what
//! their interrupts signal, and hands on to the display what was drawn. The
//! cores' other work on the frame is only the vertex functions.
//!
//! A pass over part of the image loads the tiles at that part's edge, as a
//! tile is stored whole and those tiles must keep the pixels outside it, and
//! a clear of the part is a rectangle drawn first. The tiles the part covers
//! whole are not loaded: they are cleared by the renderer like any other, and
//! loading them cost 2.5 ms of a 5.8 ms frame of 1920x1080 inside 2560x1440.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const v3d = @import("v3d");
const ExecBase = sdk.interface.exec.ExecBase;
const _objects = @import("../../_objects.zig");
const Queue = @import("../../queue/_queue.zig").Queue;
const _command = @import("../../command/_command.zig");
const CommandBuffer = _command.CommandBuffer;
const _stream = @import("../../command/_stream.zig");
const _buffer = @import("../../buffer/_buffer.zig");
const Buffer = _buffer.Buffer;
const _image = @import("../../image/_image.zig");
const Image = _image.Image;
const _pipeline = @import("../../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const _instance = @import("../../instance/_instance.zig");
const max_vertex_input_bindings = _instance.max_vertex_input_bindings;
const _vertices = @import("../_vertices.zig");
const _compute = @import("../_compute.zig");
const _tessellate = @import("../_tessellate.zig");
const _transfer = @import("../_transfer.zig");
const driver = @import("driver.zig");
const _queries = @import("../_queries.zig");
const _query = @import("../../query/_query.zig");
const _render = @import("../../render/_render.zig");
const _sync = @import("../../sync/_sync.zig");
const Hardware = driver.Hardware;
const regs = v3d.regs;
const cl = v3d.cl;
const qpu = v3d.qpu;
const compile = v3d.compile;
const tiling = v3d.tiling;
const frames = v3d.frame;
const Frame = frames.Frame;
const Area = frames.Area;
const Block = v3d.Block;

/// The bytes of a chunk, and how many a frame can have.
const chunk_bytes: u32 = 1024 * 1024;
const most_chunks = 64;
/// Of the binner's list at a time; a list in several parts branches on.
const list_part_bytes: u32 = 64 * 1024;
const packets_bytes = frames.packets_bytes;
/// The memory for the binner's lists: its first block of each tile, and what
/// it goes on into before it asks for more.
const tile_list_bytes: u32 = 128;
const tile_lists_extra: u32 = 1024 * 1024;
/// And for each triangle sent, most of which fall in one tile.
const tile_list_triangle_bytes: u32 = 16;
const most_tile_lists_bytes: u32 = 128 * 1024 * 1024;
const tile_state_bytes: u32 = 256;
/// The most vertices a draw works, the cores' driver's limit too: past it the
/// draw is left out and said to be, and a CmdDraw over it never gets this far.
const most_vertices = _instance.max_draw_vertices;
/// A vertex's place on screen, in 1/64 of a pixel, held inside this.
const most_screen: f32 = 1 << 30;
/// What a sampled texture that is not there reads, as `shader.missing`.
const missing_color = [4]f32{ 1, 0, 1, 1 };

const Chunk = struct {
    block: Block,
    used: u32 = 0,
};

/// Somewhere both can reach.
const Place = struct {
    cpu: [*]u8,
    address: u32,
};

/// What playing keeps from one command to the next, and its memory from
/// frame to frame.
pub const Player = struct {
    hardware: *Hardware,
    drawing: bool = false,
    pipeline: ?*Pipeline = null,
    vertex_buffers: [max_vertex_input_bindings]_vertices.VertexBuffer = @splat(.{}),
    index_buffer: ?*Buffer = null,
    index_offset: u64 = 0,
    index_type: facet.IndexType = .uint16,
    viewport: facet.Viewport = .{ .width = 0, .height = 0 },
    scissor: facet.Rect2D = .{ .extent = .{} },
    /// What CmdSetBlendConstants set over every colour attachment, and
    /// what CmdSetBlendConstantsAt set for one of its own (facet's own,
    /// since 1.51).
    blend_constants: [4]f32 = @splat(0),
    attachment_constants: [_render.most_colors]?[4]f32 = @splat(null),
    /// What CmdSetDepthBias set, for a pipeline whose bias is dynamic.
    depth_bias: _pipeline.Bias = .{},
    /// What CmdSetDepthBounds last set, for a pipeline whose bounds are
    /// dynamic.
    depth_bounds: [2]f32 = .{ 0, 1 },
    line_width: f32 = 1,
    stencil: _vertices.StencilSet = .{},
    resources: shader.Resources = .{},
    /// Which of its subpass's parts is being drawn: a query counts the
    /// first alone (since 1.116).
    part: u32 = 0,
    /// What was bound where a subpass of several attachments began.
    saved: _vertices.Bound = undefined,
    /// What compute functions have bound, apart from what draws have.
    compute_pipeline: ?*Pipeline = null,
    compute_resources: shader.Resources = .{},
    /// The frame being made.
    frame: Frame = undefined,
    area: Area = undefined,
    /// The colour's image, or null in a frame of no colour (since 1.150).
    image: ?*Image = null,
    /// Where in that image's memory the frame's rows begin: the layer its
    /// view begins at, which the GPU is given and the CPU's caches are kept
    /// in step over (since 1.91). Mesa's v3dv adds the same to every load
    /// and store it emits (`v3dv_layer_offset`, v3dv_image.c).
    image_first: usize = 0,
    /// And the bytes from there the frame stores into: the rows of its
    /// height, or a level of four samples (since 1.147).
    image_bytes: usize = 0,
    /// The image whose rows hold the depth or the stencil the frame keeps,
    /// for the caches either side of the job: null where the pass keeps
    /// neither (since 1.47).
    kept_image: ?*Image = null,
    /// The same for the kept plane: the level and the layer its view
    /// names (since 1.91).
    kept_first: usize = 0,
    /// And how many bytes of it the frame reaches.
    kept_bytes: usize = 0,
    /// The layer of its colour's image the frame draws into, the one its
    /// view begins at (since 1.148).
    color_layer: u32 = 0,
    /// The colour's resolve attachment in a frame of four, or null for
    /// none: averaged into by the tiles as they end where the frame has a
    /// `Frame.resolve`, and by the CPU after the frame where it has not
    /// (since 1.148).
    resolve_view: ?*const _image.ImageView = null,
    /// The first byte of its rows the tiles store into, and how many, for
    /// the caches either side of the job.
    resolve_first: usize = 0,
    resolve_bytes: usize = 0,
    /// The occlusion query being counted into, or null for none: what
    /// CmdBeginQuery begins and CmdEndQuery ends (since 1.47).
    counting: ?_queries.Counting = null,
    /// The words this frame's queries have the hardware count into, and
    /// the address the last packet gave - the packet is written again only
    /// where it changes.
    tallies: [most_tallies]Tally = undefined,
    tally_count: u32 = 0,
    tally_address: u32 = 0,
    /// The frame's group of counters, carved when the first query counts.
    tally_group: ?Place = null,
    bin: cl.List = undefined,
    /// The address of the binner's list's first part, where the binner
    /// starts (`startBinning`, since 1.150).
    bin_start: u32 = 0,
    /// A draw is on the binner's list.
    binned: bool = false,
    /// A program a draw runs writes through the TMU: the job's
    /// tmu_dirty_rcl, which v3dv gathers from them
    /// (v3dvx_cmd_buffer.c:2559-2564) and the caches are cleaned after
    /// for (since 1.168).
    tmu_dirty_rcl: bool = false,
    /// The storage buffers the job's draws bind, as far as their
    /// descriptors' ranges go: what the CPU's caches hold of them is
    /// dropped after a job whose programs write through the TMU, for the
    /// memory is HOST_COHERENT, where Linux maps v3dv's buffers
    /// write-combined instead (since 1.168). Past `most_storage` the job's
    /// others are said and not dropped.
    storage: [most_storage]Range = undefined,
    storage_count: u32 = 0,
    storage_over: bool = false,
    /// Memory a draw's vertices are worked in, kept for the next.
    scratch: ?[*]u8 = null,
    scratch_bytes: usize = 0,
    chunks: [most_chunks]Chunk = undefined,
    chunk_count: u32 = 0,
    chunk_at: u32 = 0,
    tile_lists: ?Block = null,
    /// The triangles sent to the binner this render pass.
    triangles: u64 = 0,
    /// A draw left out for want of room has been reported.
    told_no_room: bool = false,
    tile_state: ?Block = null,
};

pub fn open(queue: *Queue) callconv(.c) bool {
    const device = queue.device;
    const hardware = driver.hold(device.base) orelse return false;
    const player = _objects.create(device.sys, Player) orelse {
        driver.letGo(device.base, hardware);
        return false;
    };
    player.* = .{ .hardware = hardware };
    queue.driver = player;
    return true;
}

pub fn close(queue: *Queue) callconv(.c) void {
    const device = queue.device;
    const player = playerOf(queue);
    const hardware = player.hardware;
    const sys = device.sys;
    sys.ObtainSemaphore(&device.base.v3d_lock);
    for (player.chunks[0..player.chunk_count]) |*chunk| hardware.space.free(&chunk.block);
    if (player.tile_lists) |*block| hardware.space.free(block);
    if (player.tile_state) |*block| hardware.space.free(block);
    hardware.stale = true;
    sys.ReleaseSemaphore(&device.base.v3d_lock);
    if (player.scratch) |scratch| sys.FreeVec(scratch);
    _objects.destroy(sys, player);
    queue.driver = null;
    driver.letGo(device.base, hardware);
}

fn playerOf(queue: *const Queue) *Player {
    return @ptrCast(@alignCast(queue.driver.?));
}

/// Whether the V3D has stopped doing what it is sent: `lost` has said why.
pub fn broken(queue: *const Queue) bool {
    return playerOf(queue).hardware.broken;
}

/// A sampled image's layout in memory.
pub fn layoutOf(format: facet.Format, width: u32, height: u32, depth: u32, levels: u32, four: bool) tiling.Layout {
    return tiling.layoutOf(_image.bytesOf(format), width, height, depth, @min(levels, tiling.most_levels), four);
}

/// The store's and the load's name for a level's tiling.
fn memoryOf(kind: tiling.Kind) u64 {
    return switch (kind) {
        .lineartile => cl.MEMORY_LINEARTILE,
        .ublinear_1 => cl.MEMORY_UBLINEAR_1,
        .ublinear_2 => cl.MEMORY_UBLINEAR_2,
        .uif => cl.MEMORY_UIF,
        .uif_xor => cl.MEMORY_UIF_XOR,
    };
}

/// A texture image's layout: of a 3D image, its slices in each level
/// (since 1.141).
pub fn imageLayout(image: *const _image.Image) tiling.Layout {
    return layoutOf(image.format, image.width, image.height, if (image.volume) image.layers else 1, image.levels, image.quads);
}

/// Where layer `layer` of a texture image begins, or slice `layer` of
/// level `level` of a 3D one, from where the image's level does: a layer
/// is a texture of its own, `layer_bytes` from the one before, and a 3D
/// image's slices lie in each level (`tiling.sliceAt`, since 1.141).
pub fn layerAt(image: *const _image.Image, layout: *const tiling.Layout, level: u32, layer: u32) usize {
    if (image.volume) return tiling.sliceAt(layout, level, layer);
    return layer * @as(usize, @intCast(image.layer_bytes));
}

/// The commands of `buffer`, in order.
pub fn play(queue: *Queue, buffer: *CommandBuffer) void {
    const player = playerOf(queue);
    player.drawing = false;
    player.pipeline = null;
    player.vertex_buffers = @splat(.{});
    player.index_buffer = null;
    player.resources = .{};
    player.compute_pipeline = null;
    player.compute_resources = .{};
    playStream(queue, &buffer.stream);
    // A command buffer that ends inside its render pass ends the pass.
    endRenderPass(queue);
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
        .copy_buffer_to_image => copyBufferToImage(queue, _stream.as(_command.CopyBufferToImage, head)),
        .copy_buffer => _vertices.copyBuffer(_stream.as(_command.CopyBuffer, head)),
        .fill_buffer => if (!_vertices.fillBuffer(_stream.as(_command.FillBuffer, head))) noRoom(queue, "a fill of bytes that are not the buffer's"),
        .update_buffer => if (!_vertices.updateBuffer(_stream.as(_command.UpdateBuffer, head))) noRoom(queue, "an update of bytes that are not the buffer's"),
        // The CPU clears, so what it wrote goes out before the TMU reads
        // it, as after a copy (since 1.142; until then a cleared texture
        // could be sampled from what the caches had not yet written).
        .clear_color_image => {
            const command = _stream.as(_command.ClearColorImage, head);
            if (!_transfer.clearColorImage(command)) noRoom(queue, "a clear of an image whose format it cannot write");
            texturesToGpu(queue, command.image);
        },
        .clear_depth_stencil_image => {
            const command = _stream.as(_command.ClearDepthStencilImage, head);
            if (!_transfer.clearDepthImage(command)) noRoom(queue, "a clear of a depth image whose pixels it cannot write");
            texturesToGpu(queue, command.image);
        },
        .copy_image => {
            const command = _stream.as(_command.CopyImage, head);
            _transfer.copyImage(command);
            texturesToGpu(queue, command.destination);
        },
        .blit_image => {
            const command = _stream.as(_command.BlitImage, head);
            _transfer.blitImage(command);
            texturesToGpu(queue, command.destination);
        },
        // On the cores' body, which reads each sample where this device
        // keeps it (`_image.sampleOf`, since 1.146). A pass's resolve is in
        // the tiles since 1.148; v3dv does this command in them too, with a
        // job of its own (`resolve_image_tlb`, v3dv_meta_copy.c:5109),
        // which is yet to be ported.
        .resolve_image => {
            const command = _stream.as(_command.ResolveImage, head);
            _transfer.resolveImage(command);
            texturesToGpu(queue, command.destination);
        },
        .copy_image_to_buffer => _transfer.copyImageToBuffer(_stream.as(_command.CopyImageToBuffer, head)),
        .clear_attachment => if (player.drawing) clearAttachment(queue, _stream.as(_command.ClearAttachment, head)),
        .begin_render_pass => {
            const command = _stream.as(_command.BeginRenderPass, head);
            beginRenderPass(queue, command, 0);
            if (command.part_count > 1) {
                player.saved = .of(player);
                repeat = .{ .begin = command, .from = commands, .output = 1 };
            }
        },
        .end_render_pass => {
            endRenderPass(queue);
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
        },
        .push_constants => {
            const command = _stream.as(_command.PushConstants, head);
            _vertices.pushConstants(&player.resources, command);
            _vertices.pushConstants(&player.compute_resources, command);
        },
        .set_viewport => player.viewport = _stream.as(_command.SetViewport, head).viewport,
        .set_scissor => player.scissor = _stream.as(_command.SetScissor, head).scissor,
        .set_blend_constants => {
            player.blend_constants = _stream.as(_command.SetBlendConstants, head).constants;
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
            draw(queue, command.first_vertex, command.vertex_count, null, command.first_instance, command.instance_count);
        },
        .draw_indexed => if (player.drawing) {
            const command = _stream.as(_command.DrawIndexed, head);
            draw(queue, command.first_index, command.index_count, command.vertex_offset, command.first_instance, command.instance_count);
        },
        .draw_indirect => if (player.drawing) {
            const command = _stream.as(_command.DrawIndirect, head);
            for (0..command.count) |k| {
                const made = _vertices.indirectDraw(command, @intCast(k)) orelse break;
                draw(queue, made.first, made.count, made.vertex_offset, made.first_instance, made.instances);
            }
        },
        .bind_compute_pipeline => player.compute_pipeline = _stream.as(_command.BindComputePipeline, head).pipeline,
        .dispatch => if (!player.drawing) _compute.dispatch(queue.device.sys, player.compute_pipeline, &player.compute_resources, _stream.as(_command.Dispatch, head).count, &_query.none),
        .dispatch_indirect => if (!player.drawing) _compute.dispatchIndirect(queue.device.sys, player.compute_pipeline, &player.compute_resources, _stream.as(_command.DispatchIndirect, head), &_query.none),
        // The V3D counts nothing of its work: it has neither the occlusion
        // query nor the statistics (its features say so, and CreateQueryPool
        // refuses both on it), so only a timestamp pool is ever here. A
        // query ended is still made available, so that a program waiting
        // for one does not wait for ever.
        .begin_query => {
            const command = _stream.as(_command.BeginQuery, head);
            // The hardware counts an occlusion query's samples into a word
            // of its own, which a draw points it at (since 1.47); what the
            // QPUs were given is still counted by nothing, so a statistics
            // pool is refused on this device and begins nothing here.
            player.counting = _queries.begun(command);
            if (player.counting == null and command.query >= command.pool.count) noRoom(queue, "a query begun past the pool's last");
        },
        .end_query => {
            const command = _stream.as(_command.EndQuery, head);
            _queries.ended(command);
            if (player.counting) |counting| if (counting.pool == command.pool and counting.index == command.query) {
                player.counting = null;
            };
        },
        .reset_query_pool => {
            const command = _stream.as(_command.ResetQueryPool, head);
            _query.reset(command.pool, command.first, command.count);
            if (player.counting) |counting| if (counting.pool == command.pool) {
                player.counting = null;
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

// --- memory -----------------------------------------------------------------

/// `bytes` from the frame's chunks: null when there is no more to be had.
/// Where the hardware counts one query's samples while a frame is drawn,
/// and the counter those samples are added to as the frame ends (since
/// 1.47).
const Tally = struct {
    /// The query's counter, whose first lane the frame's count goes into,
    /// the task's own (query/_query.zig `lanes`).
    samples: _query.Counter,
    at: *u32,
    address: u32,
};

/// How many queries one frame counts into: a group of them, as the
/// hardware takes them - sixteen words one after another. A program that
/// begins more than this many in one pass has the rest counted as 0.
const most_tallies = 16;

/// Bytes of memory from `at`.
const Range = struct {
    at: [*]const u8,
    bytes: usize,
};

/// The storage buffers a job keeps to drop from the CPU's caches.
const most_storage = 32;

/// What the group takes and where it must lie: the hardware wants a group
/// of sixteen counters on a boundary of 1024 bytes, with the words
/// themselves in the 64 at the start of it (Mesa's v3dv_query.c).
const tally_group_bytes = 1024;
const tally_line_bytes = most_tallies * @sizeOf(u32);

fn carve(queue: *Queue, bytes: u32, alignment: u32) ?Place {
    const player = playerOf(queue);
    while (player.chunk_at < player.chunk_count) : (player.chunk_at += 1) {
        const chunk = &player.chunks[player.chunk_at];
        const start = std.mem.alignForward(u32, chunk.used, alignment);
        if (start + bytes <= chunk.block.bytes) {
            chunk.used = start + bytes;
            return .{ .cpu = chunk.block.cpu + start, .address = chunk.block.address + start };
        }
    }
    if (player.chunk_count == most_chunks) return null;
    const device = queue.device;
    device.sys.ObtainSemaphore(&device.base.v3d_lock);
    const block = player.hardware.space.alloc(@max(bytes, chunk_bytes));
    if (block != null) player.hardware.stale = true;
    device.sys.ReleaseSemaphore(&device.base.v3d_lock);
    player.chunks[player.chunk_count] = .{ .block = block orelse return null, .used = bytes };
    player.chunk_at = player.chunk_count;
    player.chunk_count += 1;
    const made = &player.chunks[player.chunk_at].block;
    return .{ .cpu = made.cpu, .address = made.address };
}

/// Room for a draw's packets on the binner's list: it goes on in a new part
/// if this one has none. False when there is no memory for one.
fn roomOnList(queue: *Queue) bool {
    const player = playerOf(queue);
    if (player.bin.used + packets_bytes <= list_part_bytes) return true;
    const place = carve(queue, list_part_bytes, 8) orelse return false;
    cl.branch(&player.bin, place.address);
    player.bin = .{ .at = place.cpu, .address = place.address };
    return true;
}

/// A block as big as `bytes`, the one kept if it is.
fn sized(queue: *Queue, kept: *?Block, bytes: u32) bool {
    const player = playerOf(queue);
    const device = queue.device;
    if (kept.*) |block| if (block.bytes >= bytes) return true;
    device.sys.ObtainSemaphore(&device.base.v3d_lock);
    defer device.sys.ReleaseSemaphore(&device.base.v3d_lock);
    const space = &player.hardware.space;
    if (kept.*) |*block| space.free(block);
    kept.* = space.alloc(bytes);
    player.hardware.stale = true;
    return kept.* != null;
}

/// What the binner's lists are given for a frame of `tiles` and `triangles`.
fn tileListsBytes(tiles: u32, triangles: u64) u32 {
    const wanted = tiles * tile_list_bytes + tile_lists_extra + triangles * tile_list_triangle_bytes;
    return @intCast(@min(wanted, most_tile_lists_bytes));
}

/// Something left out of a frame for want of room, said once a queue with
/// what it was. The program is not told: nothing of a frame being played
/// reaches it, and a frame half drawn is still shown. What can be caught
/// while it is recorded is refused there instead (`CmdDraw`).
fn noRoom(queue: *Queue, what: [*:0]const u8) void {
    const player = playerOf(queue);
    if (player.told_no_room) return;
    player.told_no_room = true;
    exec.kprintf(queue.device.sys, "v3d: %s left out of the frame for want of room; what follows may be too\n", .{what});
}

/// Where the V3D has an image, mapped the first time it is asked: 0 where it
/// cannot reach it. What stays mapped after the image goes is reached by no
/// list, as lists are made only from images there are.
fn addressOf(queue: *Queue, image: *Image) u32 {
    if (image.driver_address != 0) return image.driver_address;
    const player = playerOf(queue);
    const device = queue.device;
    const data = image.data orelse return 0;
    device.sys.ObtainSemaphore(&device.base.v3d_lock);
    defer device.sys.ReleaseSemaphore(&device.base.v3d_lock);
    image.driver_address = player.hardware.space.map(@intFromPtr(data), image.bytes) orelse 0;
    player.hardware.stale = true;
    return image.driver_address;
}

// --- the render pass --------------------------------------------------------

fn beginRenderPass(queue: *Queue, command: *const _command.BeginRenderPass, part: u32) void {
    endRenderPass(queue);
    const player = playerOf(queue);
    if (player.hardware.broken) return;
    player.part = part;
    // The location its colour is written at: its part's number, unless a
    // colour before it is unused and has none (since 1.118).
    player.resources.output = command.parts[part].output;
    const framebuffer = &command.targets[part];
    // A part of no colour - a subpass of no colour attachment, or of
    // unused ones alone - has no image of colour, and `colors[0]` is not
    // set: its frame configures the unused render target and moves no
    // colour (`Frame.color`, since 1.150).
    const has_color = command.parts[part].color_count != 0;
    const image: ?*Image = if (has_color) framebuffer.colors[0].image else null;
    const output: struct { u64, bool } = if (image) |each| switch (each.format) {
        .b8g8r8a8_unorm => .{ cl.OUTPUT_RGBA8, true },
        .r8g8b8a8_unorm => .{ cl.OUTPUT_RGBA8, false },
        .r5g6b5_unorm_pack16 => .{ cl.OUTPUT_BGR565, false },
        else => return,
    } else .{ cl.OUTPUT_RGBA8, false };
    const address = if (image) |each| addressOf(queue, each) else 0;
    if (image) |each| if (address == 0) {
        exec.kprintf(queue.device.sys, "v3d: an image at %lx is out of its reach\n", .{@intFromPtr(each.data)});
        return;
    };
    // The render area, cut to the framebuffer.
    const offset = command.area.offset;
    const left: u32 = @intCast(std.math.clamp(offset.x, 0, @as(i64, framebuffer.width)));
    const top: u32 = @intCast(std.math.clamp(offset.y, 0, @as(i64, framebuffer.height)));
    const right: u32 = @intCast(std.math.clamp(@as(i64, offset.x) + command.area.extent.width, left, framebuffer.width));
    const bottom: u32 = @intCast(std.math.clamp(@as(i64, offset.y) + command.area.extent.height, top, framebuffer.height));
    if (left == right or top == bottom) return;
    const whole = left == 0 and top == 0 and right == framebuffer.width and bottom == framebuffer.height;
    const clears = has_color and command.parts[part].color_loads[0] == .clear;
    // The tile its samples and its one render target fit, at 32 bits of
    // internal colour whatever the format, or none. Four samples where the
    // colour has four, which its depth has too, Vulkan having a subpass's
    // attachments of one count (since 1.147, docs/facet-vulkan10.md item
    // 61, step V4); in a part of no colour, where its depth has, and in
    // one of no attachment where its first draw's pipeline has
    // (`restartAtFour`, V8).
    const four = if (image) |each| each.samples > 1 else command.parts[part].samples > 1;
    const tile = frames.chooseTile(if (has_color) 4 else 0, four);
    const color = command.clear_colors[part];
    player.image = image;
    // The layer the view begins at, an image kept in rows having layers
    // since 1.91: until then the frame began at the image's first byte
    // whatever its view said.
    const place = if (image) |each| colorPlace(each, framebuffer.colors[0].base_layer, framebuffer.height) else ColorPlace{ .first = 0, .bytes = 0, .stride = 0, .memory = cl.MEMORY_RASTER };
    player.image_first = place.first;
    player.image_bytes = place.bytes;
    player.kept_image = null;
    // `beginBin` stops the hardware's counter, so the frame starts with no
    // word and writes the packet again at the first draw that counts.
    player.tally_address = 0;
    player.tally_count = 0;
    player.tally_group = null;
    player.area = .{ .left = left, .top = top, .right = right, .bottom = bottom };
    // A job's flag starts clear, as v3dv's job is made, and binds no
    // storage buffer yet (since 1.168).
    player.tmu_dirty_rcl = false;
    player.storage_count = 0;
    player.storage_over = false;
    player.frame = .{
        .width = framebuffer.width,
        .height = framebuffer.height,
        .image = address + @as(u32, @intCast(player.image_first)),
        .stride = place.stride,
        .memory = place.memory,
        .format = output[0],
        .swap_rb = output[1],
        // Red in the low byte.
        .clear = color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16,
        // `startBinning`'s, once it has made them.
        .tile_lists = 0,
        .binned = false,
        .load = has_color and (!clears or !whole),
        .clear_inside = clears and !whole,
        .depth = command.parts[part].tests_depth,
        .clear_depth = @as(f32, @floatFromInt(command.clear_depth)) / 65535,
        .stencil = command.parts[part].tests_stencil,
        .clear_stencil = command.clear_stencil,
        .kept = kept: {
            const made = keptOf(queue, &command.parts[part], framebuffer);
            if (made != null) player.kept_image = framebuffer.depth.?.image;
            break :kept made;
        },
        .area = if (whole) null else player.area,
        .four = four,
        .tile = tile,
        .color = has_color,
    };
    player.color_layer = if (has_color) framebuffer.colors[0].base_layer else 0;
    // The colour's resolve attachment, in a frame of four. The tiles
    // average its samples into it as each ends where every tile they
    // render lies inside the area, and the CPU does after the frame where
    // one does not, as v3dv resolves in the TLB only over a render area
    // aligned to its tiles and with a job of its own after the frame
    // otherwise (`use_tlb_resolve`, v3dv_cmd_buffer.c:1184-1203). A
    // resolve attachment is of the colour's format and of one sample
    // (VUID-VkSubpassDescription-pResolveAttachments-00849, -00850), and
    // here in rows, an image drawn into being kept in rows on this device
    // (`_image.create`); one of any other shape is not resolved into.
    player.resolve_view = null;
    if (four) if (image) |each| if (framebuffer.resolves[0]) |view| resolve: {
        const into = view.image;
        if (into.samples != 1 or into.format != each.format or into.kind != .rows or !_image.readable(into)) break :resolve;
        player.resolve_view = view;
        if (!frames.tilesInArea(&player.frame)) break :resolve;
        const at = addressOf(queue, into);
        if (at == 0) break :resolve;
        const rows = _image.rowsAt(into, view.base_level, view.base_layer);
        player.resolve_first = rows.at;
        player.resolve_bytes = @as(usize, rows.pitch) * framebuffer.height;
        player.frame.resolve = .{ .image = at + @as(u32, @intCast(rows.at)), .stride = rows.pitch };
    };
    // A depth or a stencil kept in memory and stored, over a render area
    // a tile the renderer renders sticks out of, is loaded first whatever
    // its load op, so that the tile's store writes back what lay outside
    // the area, as v3dv loads an attachment it stores wherever the area is
    // not tile aligned (`v3dv_cmd_buffer_check_needs_load`,
    // v3dv_cmd_buffer.c:1557-1564). What the pass begins with inside the
    // area is then a rectangle drawn over it, as v3dv clears there with
    // CmdClearAttachments (`cmd_buffer_emit_subpass_clears`,
    // v3dv_cmd_buffer.c:1430-1488) - here whatever the op, the part not
    // saying it was CLEAR, which for DONT_CARE leaves contents Vulkan
    // leaves undefined (since 1.151). Before, such a tile stored the
    // tile's clear over the pixels outside the area.
    var kept_inside: ?frames.Kept = null;
    if (player.frame.kept) |*kept| if (kept.store and !kept.load and !frames.tilesInArea(&player.frame)) {
        kept.load = true;
        kept_inside = kept.*;
    };
    if (!startBinning(queue)) return;
    player.drawing = true;
    const colors_inside = clears and !whole;
    if (colors_inside or kept_inside != null) {
        const depth_inside = if (kept_inside) |kept| kept.buffer == cl.STORE_Z else false;
        const stencil_inside = if (kept_inside) |kept| kept.buffer == cl.STORE_STENCIL else false;
        clearRectangle(
            queue,
            player.area,
            color,
            if (colors_inside) 0xF else 0,
            if (depth_inside) player.frame.clear_depth else null,
            if (stencil_inside) @truncate(player.frame.clear_stencil) else null,
        );
    }
}

/// The frame's tile lists, tile state and binner's list made for its
/// tiles, its chunks given back, and the binner's list begun: what a frame
/// starts with, and what one started again at four starts with
/// (`restartAtFour`).
fn startBinning(queue: *Queue) bool {
    const player = playerOf(queue);
    const frame = &player.frame;
    const tiles = frame.tilesX() * frame.tilesY();
    if (!sized(queue, &player.tile_lists, tileListsBytes(tiles, 0))) return false;
    frame.tile_lists = player.tile_lists.?.address;
    player.triangles = 0;
    if (!sized(queue, &player.tile_state, tiles * tile_state_bytes)) return false;
    for (player.chunks[0..player.chunk_count]) |*chunk| chunk.used = 0;
    player.chunk_at = 0;
    const list = carve(queue, list_part_bytes, 8) orelse return false;
    player.bin = .{ .at = list.cpu, .address = list.address };
    // Where the binner starts: this first part, however many the list
    // goes on into (`roomOnList`), as v3dv starts its job's at the first
    // of its chained blocks (v3dv_queue.c:733-737). Since 1.150: before,
    // a list grown past its first part was started at its last, without
    // the binning mode it begins with.
    player.bin_start = list.address;
    player.binned = false;
    frames.beginBin(&player.bin, frame);
    return true;
}

/// v3dv's cmd_buffer_restart_job_for_msaa_if_needed
/// (v3dv_cmd_buffer.c:2655-2735, called at :2906): a subpass of no
/// attachment draws at its pipelines' sample count, which its frame cannot
/// know as it starts, so where the first draw's pipeline has four and the
/// frame has one, the frame starts again at four, of the size it has and
/// in the tile four samples of no colour take (item 61's V8, since 1.150).
/// Nothing has been binned yet - all a subpass's pipelines are of one
/// count, Vulkan having no variableMultisampleRate - so nothing is lost.
/// False where there is no memory to start again.
fn restartAtFour(queue: *Queue, pipeline: *const Pipeline) bool {
    const player = playerOf(queue);
    if (player.binned or pipeline.samples <= 1 or player.frame.four) return true;
    // Any attachment gives the frame its count, which its pipelines have
    // (VUID-VkGraphicsPipelineCreateInfo-multisampledRenderToSingleSampled-06853,
    // held to in CreateGraphicsPipelines).
    if (player.frame.color or player.frame.depth or player.frame.stencil) return true;
    player.frame.four = true;
    player.frame.tile = frames.chooseTile(0, true);
    // The counter is started again in the new list by the first draw
    // that counts, and nothing has been counted to keep.
    player.tally_address = 0;
    player.tally_count = 0;
    player.tally_group = null;
    return startBinning(queue);
}

/// Where a frame stores its colour: the rows of the layer its view begins
/// at, or for an image of four samples that layer's level, where the
/// device keeps each pixel's four together and the tiles store them all
/// at once, in the level's own tiling (`_image.Image.quads`, since 1.147;
/// v3dvx_cmd_buffer.c:396-406, 408-409).
const ColorPlace = struct { first: usize, bytes: usize, stride: u32, memory: u64 };

fn colorPlace(image: *const _image.Image, layer: u32, height: u32) ColorPlace {
    if (image.quads) {
        const layout = imageLayout(image);
        const level = &layout.levels[0];
        return .{
            .first = layerAt(image, &layout, 0, layer) + level.offset,
            .bytes = level.slice_bytes,
            .stride = tiling.blocksDown(&layout, 0),
            .memory = memoryOf(level.kind),
        };
    }
    return .{ .first = _image.rowsAt(image, 0, layer).at, .bytes = @as(usize, image.pitch) * height, .stride = image.pitch, .memory = cl.MEMORY_RASTER };
}

/// The depth or the stencil a part keeps in its image's rows, or null where
/// both live in the tiles alone. One plane at most: a format that holds
/// them both is refused on this device, the hardware storing a plane as its
/// own pixels one after another (`Capabilities.stored_both`).
fn keptOf(queue: *Queue, part: *const _render.Part, framebuffer: *const _render.Target) ?frames.Kept {
    const keeps_depth = part.loads_depth or part.stores_depth;
    const keeps_stencil = part.loads_stencil or part.stores_stencil;
    if (keeps_depth == keeps_stencil) return null; // neither, or the two together
    const view = framebuffer.depth orelse return null;
    const image = view.image;
    const address = addressOf(queue, image);
    if (address == 0) {
        exec.kprintf(queue.device.sys, "v3d: a depth image at %lx is out of its reach\n", .{@intFromPtr(image.data)});
        return null;
    }
    // A depth image sampled as well lies as a texture (since 1.142,
    // `_image.deviceLaid`): the level and the layer the view names, stored
    // in that level's own tiling, as v3dv stores into a slice of its image
    // (v3dvx_cmd_buffer.c:396-406), so the TMU reads it where it lies. And
    // one of four samples, kept together in its level, which the frame of
    // four stores all of (since 1.147).
    if (_image.deviceLaid(image)) {
        const layout = imageLayout(image);
        const level = &layout.levels[view.base_level];
        const at = layerAt(image, &layout, view.base_level, view.base_layer) + level.offset;
        playerOf(queue).kept_first = at;
        playerOf(queue).kept_bytes = level.slice_bytes;
        return .{
            .buffer = if (keeps_depth) cl.STORE_Z else cl.STORE_STENCIL,
            .format = if (keeps_depth) cl.OUTPUT_D16 else cl.OUTPUT_S8,
            .image = address + @as(u32, @intCast(at)),
            .stride = tiling.blocksDown(&layout, view.base_level),
            .memory = memoryOf(level.kind),
            .load = if (keeps_depth) part.loads_depth else part.loads_stencil,
            .store = if (keeps_depth) part.stores_depth else part.stores_stencil,
        };
    }
    // The level and the layer the view names, in that level's own rows, as
    // the cores' `planeOf` has drawn into since 1.58 and 1.63: until 1.91
    // this device stored a kept plane at the image's first byte, with the
    // first level's pitch, whatever the view said.
    const rows = _image.rowsAt(image, view.base_level, view.base_layer);
    playerOf(queue).kept_first = rows.at;
    playerOf(queue).kept_bytes = @as(usize, rows.pitch) * framebuffer.height;
    return .{
        .buffer = if (keeps_depth) cl.STORE_Z else cl.STORE_STENCIL,
        .format = if (keeps_depth) cl.OUTPUT_D16 else cl.OUTPUT_S8,
        .image = address + @as(u32, @intCast(rows.at)),
        .stride = rows.pitch,
        .load = if (keeps_depth) part.loads_depth else part.loads_stencil,
        .store = if (keeps_depth) part.stores_depth else part.stores_stencil,
    };
}

/// A part of the attachments cleared in the middle of a pass.
fn clearAttachment(queue: *Queue, command: *const _command.ClearAttachment) void {
    const player = playerOf(queue);
    // A framebuffer here has the one layer (`max_framebuffer_layers`), so
    // a rectangle of any other names nothing of it (since 1.91).
    if (command.base_layer != 0 or command.layer_count == 0) return;
    const aspect = command.aspect_mask;
    const rect = command.rect;
    const x = @as(i64, rect.offset.x);
    const y = @as(i64, rect.offset.y);
    const area = player.area;
    const left: u32 = @intCast(std.math.clamp(x, area.left, area.right));
    const top: u32 = @intCast(std.math.clamp(y, area.top, area.bottom));
    const right: u32 = @intCast(std.math.clamp(x + rect.extent.width, left, area.right));
    const bottom: u32 = @intCast(std.math.clamp(y + rect.extent.height, top, area.bottom));
    if (left == right or top == bottom) return;
    clearRectangle(
        queue,
        .{ .left = left, .top = top, .right = right, .bottom = bottom },
        command.color,
        // No colour in a frame of none, where a colour attachment the
        // clear names is an unused one, whose clear has no effect (since
        // 1.150).
        if (aspect & facet.IMAGE_ASPECT_COLOR != 0 and command.output == player.resources.output and player.frame.color) 0xF else 0,
        if (aspect & facet.IMAGE_ASPECT_DEPTH != 0 and player.frame.depth) command.depth else null,
        if (aspect & facet.IMAGE_ASPECT_STENCIL != 0 and player.frame.stencil) @truncate(command.stencil) else null,
    );
}

/// A rectangle over the whole image, cut to `clip`, writing the `channels` of
/// the colour and the depth and the stencil given.
fn clearRectangle(queue: *Queue, clip: frames.Area, color: u32, channels: u32, depth: ?f32, stencil: ?u8) void {
    const player = playerOf(queue);
    // Nothing to write: a colour the frame does not draw, and neither
    // plane (since 1.150, where it drew a rectangle that wrote nothing).
    if (channels == 0 and depth == null and stencil == null) return;
    // In a frame of no colour, the program of no colour, which reads no
    // varying and writes the depth the rasterizer made, the rectangle's
    // own (since 1.150).
    const no_color = !player.frame.color;
    const varyings: u32 = if (no_color) 0 else 4;
    const channel = struct {
        fn of(value: u32, shift: u5) f32 {
            return @as(f32, @floatFromInt(value >> shift & 0xFF)) / 255;
        }
    }.of;
    const rgba = [4]f32{ channel(color, 16), channel(color, 8), channel(color, 0), channel(color, 24) };
    const corners = [_]u32{ 0, 1, 2, 2, 1, 3 };
    const indices = carve(queue, @sizeOf(@TypeOf(corners)), 4) orelse return;
    @memcpy(indices.cpu[0..@sizeOf(@TypeOf(corners))], std.mem.asBytes(&corners));
    const stride = recordStride(varyings);
    const vertices = carve(queue, 4 * stride, 4) orelse return;
    const half_width = @as(f32, @floatFromInt(player.frame.width)) / 2;
    const half_height = @as(f32, @floatFromInt(player.frame.height)) / 2;
    const viewport = ViewportScale{ .half_width = half_width, .half_height = half_height, .scale = 1, .offset = 0 };
    for ([4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }, 0..) |corner, k| {
        writeRecord(vertices.cpu + k * stride, &[4]f32{ corner[0], corner[1], depth orelse 0, 1 }, &viewport, varyings, .{ .constant = rgba });
    }
    const stencil_face = cl.StencilFace{ .fail = 1, .pass = 2, .depth_fail = 1, .compare = cl.COMPARE_ALWAYS, .compare_mask = 0, .write_mask = 0xFF, .reference = stencil orelse 0 };
    const state = frames.DrawState{
        .clip = clip,
        .cfg = .{ .compare = cl.COMPARE_ALWAYS, .depth_write = depth != null, .stencil = stencil != null },
        .mixing = .{ .channels = channels },
        .stencil = .{ stencil_face, stencil_face },
        .x = 0,
        .y = 0,
        .width = half_width * 2,
        .height = half_height * 2,
    };
    const hardware = player.hardware;
    const uniforms = if (no_color)
        streamOf(queue, hardware.no_color.stream(), &.{}, null, 0, .{}) orelse return noRoom(queue, "a clear with no memory for its uniforms")
    else
        (carve(queue, 4, 4) orelse return noRoom(queue, "a clear with no memory for its uniforms")).address;
    if (!roomOnList(queue)) return noRoom(queue, "a clear with no memory for the binner's list");
    frames.writeDrawState(&player.bin, &player.frame, &state);
    const fragment = if (no_color) hardware.no_color.address else hardware.programs.color;
    if (!sendVertices(queue, vertices.address, varyings, fragment, uniforms, if (no_color) &hardware.no_color else null)) return;
    cl.indexBufferSetup(&player.bin, indices.address, @sizeOf(@TypeOf(corners)));
    cl.indexedPrimList(&player.bin, cl.PRIM_TRIANGLES, corners.len);
    player.binned = true;
}

/// What was written into a texture on the cores seen by the V3D, or into a
/// depth image laid out as one (since 1.142).
fn texturesToGpu(queue: *Queue, image: *Image) void {
    if (_image.deviceLaid(image)) if (image.data) |data| {
        playerOf(queue).hardware.space.rangeToGpu(data, @intCast(image.bytes));
    };
}

fn endRenderPass(queue: *Queue) void {
    const player = playerOf(queue);
    if (!player.drawing) return;
    player.drawing = false;
    const hardware = player.hardware;
    const device = queue.device;
    const sys = device.sys;
    frames.endBin(&player.bin);
    player.frame.binned = player.binned;
    // Only now is it known how many triangles the binner's lists must hold.
    if (!sized(queue, &player.tile_lists, tileListsBytes(player.frame.tilesX() * player.frame.tilesY(), player.triangles))) {
        exec.kprintf(sys, "v3d: no memory for the binner's lists of %lu triangles\n", .{player.triangles});
        hardware.broken = true;
        return;
    }
    player.frame.tile_lists = player.tile_lists.?.address;

    const lists = carve(queue, 4096, 16) orelse return;
    var tile_list = cl.List{ .at = lists.cpu, .address = lists.address };
    frames.writeTileList(&tile_list, &player.frame, player.frame.load);
    const tiles = frames.TileList{ .start = tile_list.address, .end = tile_list.here() };
    // A second list, without the load, for the supertiles the cleared area
    // covers whole: nothing of the image is wanted under a clear.
    var inside: ?frames.TileList = null;
    if (player.frame.clear_inside) {
        var plain = cl.List{ .at = lists.cpu + 256, .address = lists.address + 256 };
        frames.writeTileList(&plain, &player.frame, false);
        inside = .{ .start = plain.address, .end = plain.here() };
    }
    var render = cl.List{ .at = lists.cpu + 512, .address = lists.address + 512 };
    frames.writeRender(&render, &player.frame, tiles, inside);

    const space = &hardware.space;
    const image = player.image;
    const image_bytes = player.image_bytes;
    for (player.chunks[0..player.chunk_count]) |*chunk| {
        if (chunk.used != 0) space.rangeToGpu(chunk.block.cpu, chunk.used);
    }
    if (image) |each| space.rangeToGpu(each.data.? + player.image_first, image_bytes);
    // The depth or the stencil the frame keeps lies in another image: what
    // the CPU wrote there goes out to memory before the frame, and what a
    // store writes is dropped from the CPU's caches after. Out before a
    // store as well as a load (since 1.136): a line is dropped with a
    // write-back first (exec's CachePostDMA, `dc civac`), so one the CPU
    // left dirty - a CmdClearDepthStencilImage, which the CPU writes -
    // landed over what the V3D stored, where only a load sent it out.
    const kept_bytes: usize = if (player.frame.kept != null) player.kept_bytes else 0;
    if (player.frame.kept != null) space.rangeToGpu(player.kept_image.?.data.? + player.kept_first, kept_bytes);
    // And the rows the tiles resolve into, for the same reason.
    if (player.frame.resolve != null) space.rangeToGpu(player.resolve_view.?.image.data.? + player.resolve_first, player.resolve_bytes);

    sys.ObtainSemaphore(&device.base.v3d_lock);
    defer sys.ReleaseSemaphore(&device.base.v3d_lock);
    if (hardware.stale) {
        if (!space.flush()) {
            exec.kprintf(sys, "v3d: its MMU's caches did not empty\n", .{});
            hardware.broken = true;
            return;
        }
        hardware.stale = false;
    }
    const engine = &hardware.engine;
    if (player.binned) {
        const binned = engine.bin(player.bin_start, player.bin.here(), &player.tile_lists.?, &player.tile_state.?);
        if (binned != .done) return lost(player, sys, binned, "binning");
    }
    const rendered = engine.render(render.address, render.here());
    // What the programs wrote through the TMU, out to memory before
    // anything reads it: the CACHE_CLEAN job Linux runs after a job
    // submitted with DRM_V3D_SUBMIT_CL_FLUSH_CACHE, which v3dv asks for
    // where the job's tmu_dirty_rcl is (v3dv_queue.c:746-747,
    // v3d_submit.c:1214-1221; since 1.168). A clean that does not finish
    // is said, as Linux's drm_err says it, and the job is not lost.
    if (rendered == .done and player.tmu_dirty_rcl) {
        if (!engine.cleanCaches()) exec.kprintf(sys, "v3d: the TMU's writes did not go out\n", .{});
        for (player.storage[0..player.storage_count]) |each| space.rangeFromGpu(each.at, each.bytes);
        if (player.storage_over) exec.kprintf(sys, "v3d: a job bound more than %lu storage buffers, and the CPU may read the rest stale\n", .{@as(u64, most_storage)});
    }
    if (image) |each| space.rangeFromGpu(each.data.? + player.image_first, image_bytes);
    if (player.frame.kept) |kept| if (kept.store) space.rangeFromGpu(player.kept_image.?.data.? + player.kept_first, kept_bytes);
    if (player.frame.resolve != null) space.rangeFromGpu(player.resolve_view.?.image.data.? + player.resolve_first, player.resolve_bytes);
    addTallies(player, space);
    if (rendered != .done) return lost(player, sys, rendered, "rendering");
    // A resolve the tiles could not do, over the render area, from the
    // samples the frame stored, as v3dv finishes the job and then resolves
    // what its tiles did not by CmdResolveImage's own path
    // (`cmd_buffer_subpass_handle_pending_resolves`,
    // v3dv_cmd_buffer.c:957-1005): here that path's body on the CPU
    // (`_transfer.resolveRectangle`).
    const area = player.area;
    // A frame of no colour has no resolve and nothing shown.
    const color_image = image orelse return;
    if (player.resolve_view) |view| if (player.frame.resolve == null) {
        _transfer.resolveRectangle(color_image, player.color_layer, .{ area.left, area.top }, view.image, view.base_level, view.base_layer, .{ area.left, area.top }, area.right - area.left, area.bottom - area.top);
    };
    // What is shown is the resolve where there is one, as the cores show
    // it (`cpu/_play.zig`), a swapchain's image being of one sample.
    const shown = if (player.resolve_view) |view| view.image else color_image;
    if (shown.display) |display| {
        display.handOn(area.left, area.top, area.right - area.left, area.bottom - area.top);
    }
}

/// What became of a job said, with where its list had got to. Nothing more
/// is sent after it.
fn lost(player: *const Player, sys: *ExecBase, finished: v3d.Engine.Finished, what: [*:0]const u8) void {
    const hardware = player.hardware;
    const engine = &hardware.engine;
    const gpu = &hardware.gpu;
    if (engine.overflow_short) {
        exec.kprintf(sys, "v3d: %s: the binner ran out of memory, all %ld blocks given\n", .{ what, @as(u64, engine.overflow_used) });
    } else switch (finished) {
        .fault => exec.kprintf(sys, "v3d: %s: MMU fault %lx from client %lx at %lx\n", .{ what, @as(u64, engine.last_fault.status), @as(u64, engine.last_fault.client), engine.last_fault.address }),
        else => exec.kprintf(sys, "v3d: %s: it did not finish, %ld core interrupt(s), %ld hub, the binner short of memory: %ld\n", .{ what, @as(u64, engine.core_interrupts), @as(u64, engine.hub_interrupts), @as(u64, @intFromBool(engine.overflow_short)) }),
    }
    const area = player.area;
    exec.kprintf(sys, "v3d: its binner at %lx of %lx, status %lx; its renderer at %lx of %lx, status %lx; a frame of %ldx%ld, binned %ld, loaded %ld, depth %ld, area %ld,%ld to %ld,%ld\n", .{
        @as(u64, gpu.coreRead(regs.CLE_CT0CA)),
        @as(u64, gpu.coreRead(regs.CLE_CT0EA)),
        @as(u64, gpu.coreRead(regs.CLE_CT0CS)),
        @as(u64, gpu.coreRead(regs.CLE_CT1CA)),
        @as(u64, gpu.coreRead(regs.CLE_CT1EA)),
        @as(u64, gpu.coreRead(regs.CLE_CT1CS)),
        @as(u64, player.frame.width),
        @as(u64, player.frame.height),
        @as(u64, @intFromBool(player.binned)),
        @as(u64, @intFromBool(player.frame.load)),
        @as(u64, @intFromBool(player.frame.depth)),
        @as(u64, area.left),
        @as(u64, area.top),
        @as(u64, area.right),
        @as(u64, area.bottom),
    });
    hardware.broken = true;
}

// --- a draw -----------------------------------------------------------------

/// What takes a vertex function's outputs to the record the programs read.
const ViewportScale = struct {
    half_width: f32,
    half_height: f32,
    scale: f32,
    offset: f32,
};

/// The bytes of a vertex's record, with `varyings`: its clip position; its
/// place on screen, depth and 1/w; what it carries.
fn recordStride(varyings: u32) u32 {
    return 32 + varyings * 4;
}

/// What a record's varyings are: a vertex function's as they are, or with a
/// colour through `shader.channel` from a place on, which the V3D wants 0 to
/// 1; or for all its vertices a colour already 0 to 1.
const Carried = union(enum) {
    as_they_are,
    colors_from: u32,
    constant: [4]f32,
};

fn screenPlace(value: f32) i32 {
    // A NaN as well.
    const held = if (value > -most_screen) @min(value, most_screen) else -most_screen;
    return @intFromFloat(held);
}

fn writeRecord(into: [*]u8, output: [*]const f32, viewport: *const ViewportScale, varyings: u32, carried: Carried) void {
    const words: [*]align(1) u32 = @ptrCast(into);
    const w = output[3];
    const inverse_w = 1 / w;
    for (0..4) |k| words[k] = @bitCast(output[k]);
    const x: i32 = screenPlace(output[0] * inverse_w * viewport.half_width * 64);
    const y: i32 = screenPlace(output[1] * inverse_w * viewport.half_height * 64);
    words[4] = @bitCast(x);
    words[5] = @bitCast(y);
    const z: f32 = output[2] * inverse_w * viewport.scale + viewport.offset;
    words[6] = @bitCast(z);
    words[7] = @bitCast(inverse_w);
    for (0..varyings) |k| {
        const value: f32 = switch (carried) {
            .as_they_are => output[4 + k],
            .colors_from => |first| if (k >= first and k < first + 4) (output[4 + k] - 0.5) / 255 else output[4 + k],
            .constant => |color| color[k],
        };
        words[8 + k] = @bitCast(value);
    }
}

/// A compiled program's uniform stream, written where the V3D reads it:
/// its floats, the TMU's two words of each unit from `tmus`, a unit's
/// configuration at its place (since 1.173), and the push constants as
/// the command buffer last set them before this draw (`CmdPushConstants`),
/// read as v3dv reads QUNIFORM_UNIFORM (v3dv_uniforms.c:513). A vertex
/// program's has the viewport's words in it too, from `scale` (since
/// 1.163), and a program that spills the pipeline's spill buffer's
/// (`driver.Spill`, since 1.177). Its address, or null with no memory
/// for it.
fn streamOf(queue: *Queue, stream: []const compile.Word, tmus: []const Configuration, scale: ?*const ViewportScale, first_vertex: u32, spill: driver.Spill) ?u32 {
    const bytes: u32 = @max(4, @as(u32, @intCast(stream.len * 4)));
    const place = carve(queue, bytes, 4) orelse return null;
    const words: [*]u32 = @ptrCast(@alignCast(place.cpu));
    const pushed = &playerOf(queue).resources.push;
    for (stream, 0..) |word, k| words[k] = switch (word) {
        .float => |each| @bitCast(each),
        // `Code.sampled` names every unit these do, and the draw found
        // each before it came here.
        .texture => |unit| if (unit < tmus.len) tmus[unit].texture else 0,
        // The sampler's address, with the bits the program sets of it
        // (since 1.167).
        .sampler => |each| if (each.unit < tmus.len) tmus[each.unit].sampler | each.bits else 0,
        // `compile` holds every word inside the push constants, so `at`
        // is one of theirs.
        .push => |at| std.mem.readInt(u32, pushed[at * 4 ..][0..4], .little),
        // `buffersBound` has found each.
        .ubo => |each| bufferAddress(queue, each, true) orelse 0,
        .ssbo => |each| storageAddress(queue, each, true) orelse 0,
        // A vertex program's alone, which the draw gives `scale` to.
        .viewport => |which| @bitCast(if (scale) |each| viewportWord(each, which) else 0),
        // A vertex program's: the vertex its draw numbers its vertices
        // from, which the VPM's vertex id counts from (since 1.192).
        .first_vertex => first_vertex,
        // The pipeline made the buffer where one of its programs needs it
        // (`driver.checkSpillSize`).
        .spill_offset => spill.address,
        .spill_size_per_thread => spill.size_per_thread,
        // The unit's view, as `tmuConfiguration` measured it (since 1.181).
        .texture_size => |each| if (each.unit < tmus.len) tmus[each.unit].sizes[@intFromEnum(each.field)] else 0,
    };
    return place.address;
}

/// A word of the viewport as v3dv writes QUNIFORM_VIEWPORT_* (v3dv_uniforms.c:
/// 526-552): x and y scaled to the clipper's 1/64ths of a pixel
/// (clipper_xy_granularity, v3d_device_info.c:91), the depth's offset and
/// its scale. `writeRecord` works the same on the CPU (since 1.163).
fn viewportWord(scale: *const ViewportScale, which: compile.Viewport) f32 {
    return switch (which) {
        .x_scale => scale.half_width * 64,
        .y_scale => scale.half_height * 64,
        .z_offset => scale.offset,
        .z_scale => scale.scale,
    };
}

/// Where the V3D reads a uniform buffer's floats: the buffer's address,
/// its descriptor's offset and a dynamic one's, and the offset the
/// program reads at (write_ubo_ssbo_uniforms, v3dv_uniforms.c:235-350;
/// since 1.160). Its bytes from there go out of the CPU's caches first,
/// as v3dv's memory is coherent and what the CPU wrote is in memory
/// before the V3D reads it, where `out` says so. Null where nothing is
/// bound there, where the program reads past the descriptor's range, or
/// where the bind shifted that range past its buffer
/// (`shader.SHIFTED_OUT`): the range moves with a dynamic offset, as in
/// v3dv, and stays as long as the write gave it.
fn bufferAddress(queue: *Queue, at: compile.UboAddress, out: bool) ?u32 {
    const resources = &playerOf(queue).resources;
    const found = resources.slot(at.set, at.binding, 0) orelse return null;
    const bytes: [*]const u8 = @ptrCast(found.pointer orelse return null);
    const shift = resources.shiftOf(at.set, found);
    if (shift == shader.SHIFTED_OUT or at.offset >= found.range) return null;
    const address = std.math.cast(u32, @intFromPtr(bytes) + shift + at.offset) orelse return null;
    if (out) playerOf(queue).hardware.space.rangeToGpu(bytes + shift + at.offset, found.range - at.offset);
    return address;
}

/// Where the V3D reads a storage buffer: the buffer's address and its
/// descriptor's offsets, as v3dv writes QUNIFORM_SSBO_OFFSET
/// (write_ubo_ssbo_uniforms, v3dv_uniforms.c:235-350), the program adding
/// the offset of each load; its bytes out of the CPU's caches first where
/// `out` says so, as `bufferAddress` sends a uniform buffer's. Null where
/// nothing is bound there, where the program reads past the descriptor's
/// range, or where the bind shifted that range past its buffer (since
/// 1.164).
fn storageAddress(queue: *Queue, at: compile.StorageAddress, out: bool) ?u32 {
    const resources = &playerOf(queue).resources;
    const found = resources.slot(at.set, at.binding, 0) orelse return null;
    const bytes: [*]const u8 = @ptrCast(found.pointer orelse return null);
    const shift = resources.shiftOf(at.set, found);
    if (shift == shader.SHIFTED_OUT or at.reach > found.range) return null;
    const address = std.math.cast(u32, @intFromPtr(bytes) + shift) orelse return null;
    if (out) {
        const player = playerOf(queue);
        player.hardware.space.rangeToGpu(bytes + shift, found.range);
        keepStorage(player, .{ .at = bytes + shift, .bytes = found.range });
    }
    return address;
}

/// A storage buffer a draw binds, kept for after the job, once.
fn keepStorage(player: *Player, range: Range) void {
    for (player.storage[0..player.storage_count]) |each| {
        if (each.at == range.at and each.bytes == range.bytes) return;
    }
    if (player.storage_count == most_storage) {
        player.storage_over = true;
        return;
    }
    player.storage[player.storage_count] = range;
    player.storage_count += 1;
}

/// Whether every uniform buffer and storage buffer a program's `stream`
/// reads is bound, and where the V3D reaches it.
fn buffersBound(queue: *Queue, stream: []const compile.Word) bool {
    for (stream) |word| switch (word) {
        .ubo => |each| if (bufferAddress(queue, each, false) == null) return false,
        .ssbo => |each| if (storageAddress(queue, each, false) == null) return false,
        else => {},
    };
    return true;
}

/// A vertex's record's attributes, its programs and its shader state, and
/// the packet that says so.
///
/// `own` is the pipeline's own compiled program where `fragment` is it,
/// which says its threads, its W and its scoreboard; null for one written
/// by hand, whose are `cl.Programs`' defaults.
fn sendVertices(queue: *Queue, vertices: u32, varyings: u32, fragment: u32, uniforms: u32, own: ?*const driver.Shader) bool {
    const player = playerOf(queue);
    const programs = &player.hardware.programs;
    const attributes: u32 = 2 + @as(u32, @intFromBool(varyings > 0)) + @as(u32, @intFromBool(varyings > 4));
    const record = carve(queue, cl.shader_record_bytes + 16 * attributes, 32) orelse return false;
    var list = cl.List{ .at = record.cpu, .address = record.address };
    cl.shaderRecord(&list, .{
        .fragment = fragment,
        .fragment_uniforms = uniforms,
        // One pregenerated program for each varying count this device
        // takes, and `varyings` is held to that by CreateGraphicsPipelines
        // against the limit this driver reports (`compile.most_varyings`,
        // which is what `programs.vertex` is sized by). The bound is
        // repeated here because the cores report `shader.MAX_VARYINGS`
        // since 1.90 and this table is eight long: an index past it would
        // be a read of whatever follows the array, and a draw that draws
        // nothing is the right answer for a pipeline that should never
        // have reached here.
        .vertex = if (varyings < programs.vertex.len) programs.vertex[varyings] else return false,
        .vertex_uniforms = uniforms,
        .coordinate = programs.coordinate,
        .coordinate_uniforms = uniforms,
        .varyings = varyings,
        .fragment_threads = if (own) |made| made.threads else 4,
        .center_w = if (own) |made| made.center_w else false,
        .lock_scoreboard_on_first_thrsw = if (own) |made| made.lock_scoreboard_on_first_thrsw else false,
        .writes_z = if (own) |made| made.writes_z else false,
        .disable_ez = if (own) |made| made.disable_ez else false,
    });
    const stride = recordStride(varyings);
    cl.attribute(&list, vertices, 4, 4, 0, stride);
    cl.attribute(&list, vertices + 16, 4, 2, 4, stride);
    if (varyings > 0) cl.attribute(&list, vertices + 32, @min(varyings, 4), 0, @min(varyings, 4), stride);
    if (varyings > 4) cl.attribute(&list, vertices + 48, varyings - 4, 0, varyings - 4, stride);
    cl.glShaderState(&player.bin, record.address, attributes);
    return true;
}

/// The shader record of a draw whose vertex shader the QPU runs, and its
/// attribute records, and the packet that says so, as
/// v3dX(cmd_buffer_emit_gl_shader_state) emits them (v3dvx_cmd_buffer.c:
/// 2560-2790; since 1.163). `inputs` is where the draw's attributes are,
/// four floats a location and `locations` of them a vertex, as
/// `_vertices.readInputs` makes them of what the buffers hold: a record
/// for each driver location the vertex program reads, four floats wide,
/// of which each program reads what it reads of it.
fn sendCompiledVertices(queue: *Queue, inputs: u32, locations: u32, stage: *const driver.VertexStage, vertex_uniforms: u32, coordinate_uniforms: u32, fragment: u32, uniforms: u32, own: *const driver.Shader) bool {
    const player = playerOf(queue);
    const vs = &stage.vertex.program;
    const cs = &stage.coordinate.program;
    // va_count: the attributes the vertex program still has after
    // nir_remove_dead_variables (driver_location_map,
    // v3dvx_pipeline.c:694-721), and the first driver location where the
    // coordinate program takes GFXH-1602's row of it, which v3dv's always
    // has, the vertex program reading it (`compile.VertexProgram.first_row`;
    // since 1.192).
    var va_count: u32 = 0;
    for (vs.vattr_sizes[0..vs.attribute_count], 0..) |size, driver_location| va_count += @intFromBool(size != 0 or (driver_location == 0 and cs.first_row));
    const attributes = @max(va_count, 1);
    const record = carve(queue, cl.shader_record_bytes + 16 * attributes, 32) orelse return false;
    var list = cl.List{ .at = record.cpu, .address = record.address };
    cl.shaderRecord(&list, .{
        .fragment = fragment,
        .fragment_uniforms = uniforms,
        .vertex = stage.vertex.address,
        .vertex_uniforms = vertex_uniforms,
        .coordinate = stage.coordinate.address,
        .coordinate_uniforms = coordinate_uniforms,
        .varyings = own.varyings,
        .fragment_threads = own.threads,
        .center_w = own.center_w,
        .lock_scoreboard_on_first_thrsw = own.lock_scoreboard_on_first_thrsw,
        .writes_z = own.writes_z,
        .disable_ez = own.disable_ez,
        .compiled_vertex = .{
            .vertex_sectors = vs.vpm_output_sectors,
            .coordinate_sectors = cs.vpm_output_sectors,
            .vertex_threads = stage.vertex.threads,
            .coordinate_threads = stage.coordinate.threads,
            .vertex_single_seg = vs.single_seg,
            .coordinate_single_seg = cs.single_seg,
            .vertex_ids = idsOf(vs.system_values),
            .coordinate_ids = idsOf(cs.system_values),
            .point_size = vs.point_size,
        },
    });
    const stride = locations * @sizeOf([4]f32);
    var cs_loaded_any = false;
    for (0..vs.attribute_count) |driver_location| {
        const gfxh1602 = driver_location == 0 and cs.first_row;
        if (vs.vattr_sizes[driver_location] == 0 and !gfxh1602) continue;
        var by_coordinate: u32 = cs.vattr_sizes[driver_location];
        if (by_coordinate != 0) cs_loaded_any = true;
        // GFXH-1602: where the coordinate program reads the VPM's values,
        // its first attribute is loaded, a float of it where it reads
        // none (v3dvx_cmd_buffer.c:2730-2737). GFXH-930: the coordinate
        // program reads at least one attribute, the last where it reads
        // none, tested as v3dv tests it, against the driver location.
        if (gfxh1602) {
            by_coordinate = 1;
            cs_loaded_any = true;
        } else if (driver_location == va_count - 1 and !cs_loaded_any) {
            by_coordinate = 1;
            cs_loaded_any = true;
        }
        cl.floatAttribute(&list, inputs + 16 * @as(u32, vs.attribute_location[driver_location]), 4, by_coordinate, vs.vattr_sizes[driver_location], stride);
    }
    // GFXH-930 again: with no attribute, one of a float that is never
    // used, at an address the V3D reaches.
    if (va_count == 0) cl.floatAttribute(&list, record.address, 1, 1, 1, 0);
    cl.glShaderState(&player.bin, record.address, attributes);
    return true;
}

/// What the shader record says a program reads of the VPM's values.
fn idsOf(values: compile.SystemValues) cl.Ids {
    return .{ .vertex_id = values.vertex_id, .instance_id = values.instance_id, .base_instance = values.base_instance };
}

/// The two words a program that samples reads as the TMU's
/// configuration. A fixed form has them in a place of their own; a
/// generated program has them among the floats it holds, where its own
/// `wrtmuc` fall - so this answers the words and the caller places them.
const Configuration = struct {
    texture: u32,
    sampler: u32,
    /// The view's width, height and depth at its first level, its layers
    /// and its levels, in `compile.TextureSize.Field`'s order: what
    /// get_texture_size_from_image_view answers (v3dv_uniforms.c:378-414),
    /// a 3D image's slices its depth (since 1.181).
    sizes: [5]u32 = @splat(0),
};

/// Where a channel of a view's swizzle comes from, as the TMU's state names
/// it (since 1.120).
fn pickOf(source: facet.texture.Swizzle.Source) tiling.Pick {
    return switch (source) {
        inline else => |one| @field(tiling.Pick, @tagName(one)),
    };
}

/// The TMU's two words for the texture bound at `set`, `binding`, read
/// as `how` says, `compared` with the reference the program writes.
/// Null without a texture bound, with one of a format the TMU does not
/// read, a comparison of anything but a depth, or with no memory.
fn tmuConfiguration(queue: *Queue, set: u32, binding: u32, how: tiling.Sampled, compared: bool) ?Configuration {
    const player = playerOf(queue);
    const sampled = player.resources.sampled(set, binding, 0) orelse return null;
    const view: *const _image.ImageView = @fieldParentPtr("texels", sampled);
    const image = view.image;
    // A texture, or since 1.142 a depth image laid out as one, which the
    // pass stored where the TMU reads it (`_image.deviceLaid`).
    if (image.data == null or !_image.deviceLaid(image)) return null;
    const texels: tiling.Texels = switch (image.format) {
        .b8g8r8a8_unorm => .bgra,
        .r8g8b8a8_unorm => .rgba,
        .r5g6b5_unorm_pack16 => .rgb565,
        // One byte of red a texel, the TMU's own R8 (since 1.48).
        .r8_unorm => .r8,
        // As v3dv samples D16_UNORM (v3dvx_formats.c:204; since 1.142).
        .d16_unorm => .d16,
        else => return null,
    };
    if (compared and texels != .d16) return null;
    const layout = imageLayout(image);
    const state = carve(queue, tiling.texture_state_bytes, tiling.texture_state_alignment) orelse return null;
    // The view's swizzle, which the TMU applies over the format's own
    // (since 1.120).
    const picks = [4]tiling.Pick{ pickOf(view.swizzle.r), pickOf(view.swizzle.g), pickOf(view.swizzle.b), pickOf(view.swizzle.a) };
    // A 3D image's slices are told by the step between level 0's, which
    // is its `layer_bytes`, as v3dv tells them (v3dvx_image.c:107,
    // v3dv_image.c:135): the TMU finds a smaller level's from there.
    const first_layer = if (image.volume) 0 else view.base_layer * image.layer_bytes;
    tiling.writeTextureState(state.cpu[0..tiling.texture_state_bytes], &layout, texels, picks, @intCast(@intFromPtr(image.data) + first_layer), view.base_level, view.base_level + view.level_count - 1, view.layer_count, @intCast(image.layer_bytes));
    const sampler = carve(queue, tiling.sampler_state_bytes, tiling.sampler_state_alignment) orelse return null;
    tiling.writeSamplerState(sampler.cpu[0..tiling.sampler_state_bytes], how.state);
    // vk_image_view's extent is its first level's (vk_image.c), which v3dv
    // does not minify again (v3dv_uniforms.c:388-393).
    const level = @min(view.base_level, 31);
    const sizes = [5]u32{
        @max(image.width >> @intCast(level), 1),
        @max(image.height >> @intCast(level), 1),
        if (image.volume) @max(image.layers >> @intCast(level), 1) else 1,
        view.layer_count,
        view.level_count,
    };
    return .{ .texture = tiling.parameter0(state.address), .sampler = tiling.parameter1(sampler.address, how.unnormalized), .sizes = sizes };
}

/// The two uniforms of a fixed form that samples, in a place of their
/// own: the form says how it is sampled, and the texture is the one
/// bound at set 0, binding 0, which is where a fixed form's is.
///
/// A form that samples through the sampler bound beside the texture
/// (`Fixed.needsSampler`) takes that sampler, at set 0, binding 0 as the
/// cores read it (`shader.zig`'s `texturedBy` and `layeredBy`), whole
/// (`tiling.samplerOf`, since 1.141); null where none is bound there.
///
/// The shadow form's program writes the reference (`qpu.shadow_code`), so
/// its sampler's comparison is carried and its depth read as compared
/// (since 1.142).
fn textureUniforms(queue: *Queue, fixed: shader.Fixed) ?u32 {
    const dref = fixed.kind == .texture_shadow;
    const how: tiling.Sampled = if (fixed.needsSampler()) bound: {
        const sampler = playerOf(queue).resources.samplerOf(0, 0, 0) orelse return null;
        break :bound tiling.samplerOf(sampler, dref) orelse return null;
    } else own: {
        const filter: tiling.Filter = switch (fixed.sampling.filter) {
            .nearest => .nearest,
            .bilinear => .bilinear,
        };
        const wrap: tiling.Wrap = if (fixed.kind == .texture_cube) .clamp else switch (fixed.sampling.address) {
            .wrap => .repeat,
            .clamp => .clamp,
        };
        break :own .{ .state = .{ .mag = filter, .min = filter, .wrap = @splat(wrap) } };
    };
    const made = tmuConfiguration(queue, 0, 0, how, dref) orelse return null;
    const place = carve(queue, 8, 4) orelse return null;
    const words: [*]u32 = @ptrCast(@alignCast(place.cpu));
    words[0] = made.texture;
    words[1] = made.sampler;
    return place.address;
}

/// The TMU's two words for a generated program's sampler: the texture
/// and the sampler the draw bound where the module named them. The
/// module carries the set and the binding; the sampler carries how,
/// which is the difference from a fixed form, whose `Fixed.sampling`
/// says it instead.
///
/// The sampler is the whole of it since 1.140 - its levels mixed, held
/// and shifted, its five wraps an axis apiece, its border, its anisotropy
/// and its texels - as v3dv packs it (`tiling.samplerOf`). Null where
/// nothing is bound, or for a sampler that compares beside a program that
/// does not, which is the one `tiling.samplerOf` turns down: the draw
/// paints `shader.missing` for it. A program that compares has its
/// sampler's comparison, and a depth to compare with (since 1.143).
/// Until 1.140 this went through `texture.samplingOf`, which is the
/// cores' fast path, and so painted that colour for every sampler but one
/// filter, one wrap of two and every level as it is.
fn sampledBy(queue: *Queue, which: compile.Sampler) ?Configuration {
    const player = playerOf(queue);
    const sampler = player.resources.samplerOf(which.set, which.binding, 0) orelse return null;
    // A program that compares writes the reference to TMUDREF, and the
    // sampler's comparison goes to the TMU with it (since 1.143).
    const how = tiling.samplerOf(sampler, which.compared) orelse return null;
    return tmuConfiguration(queue, which.set, which.binding, how, which.compared);
}

/// A stencil operation as the hardware numbers them: keep and zero the other
/// way round.
fn stencilOpOf(op: facet.StencilOp) u32 {
    return switch (op) {
        .keep => 1,
        .zero => 0,
        else => @intFromEnum(op),
    };
}

fn stencilFaceOf(face: _pipeline.StencilFace) cl.StencilFace {
    return .{
        .fail = stencilOpOf(face.fail),
        .pass = stencilOpOf(face.pass),
        .depth_fail = stencilOpOf(face.depth_fail),
        .compare = @intFromEnum(face.compare),
        .compare_mask = face.compare_mask,
        .write_mask = face.write_mask,
        .reference = face.reference,
    };
}

/// A pipeline's mixing in the hardware's terms: the one for the colour
/// attachment this part draws.
fn mixingOf(player: *const Player, pipeline: *const Pipeline) cl.Mixing {
    const asked = _pipeline.mixingAt(pipeline, player.resources.output);
    // What is there has no alpha: it reads as wholly opaque.
    const mixing = if (player.frame.format == cl.OUTPUT_BGR565) asked.overOpaque() else asked.*;
    return .{
        .src_color = @intFromEnum(mixing.src_color),
        .dst_color = @intFromEnum(mixing.dst_color),
        .color_mode = @intFromEnum(mixing.color_op),
        .src_alpha = @intFromEnum(mixing.src_alpha),
        .dst_alpha = @intFromEnum(mixing.dst_alpha),
        .alpha_mode = @intFromEnum(mixing.alpha_op),
        .constants = mixing.constants orelse
            player.attachment_constants[@min(player.resources.output, _render.most_colors - 1)] orelse
            player.blend_constants,
        .channels = mixing.mask,
    };
}

/// The samples a draw writes. In a frame of four, the pipeline's mask
/// where it has four, and all four where it has one, as v3dv's
/// `pipeline_set_sample_mask` (v3dv_pipeline.c:2903-2913): a pipeline of
/// one in a frame of four is against Vulkan. In a frame of one the
/// hardware wants all four bits or none (:2908-2909), and none is a draw
/// facet leaves out (`draw`).
fn sampleMaskOf(player: *const Player, pipeline: *const Pipeline) u4 {
    if (!player.frame.four) return if (pipeline.sample_mask & 1 != 0) 0xF else 0;
    return if (pipeline.samples > 1) @truncate(pipeline.sample_mask) else 0xF;
}

/// What a draw is drawn with, or null where nothing of it can be seen.
fn drawStateOf(player: *const Player, pipeline: *const Pipeline, viewport: *const facet.Viewport) ?frames.DrawState {
    const scissor = pipeline.scissor orelse player.scissor;
    const area = player.area;
    const x = @as(i64, scissor.offset.x);
    const y = @as(i64, scissor.offset.y);
    const left: u32 = @intCast(std.math.clamp(x, area.left, area.right));
    const top: u32 = @intCast(std.math.clamp(y, area.top, area.bottom));
    const right: u32 = @intCast(std.math.clamp(x + scissor.extent.width, left, area.right));
    const bottom: u32 = @intCast(std.math.clamp(y + scissor.extent.height, top, area.bottom));
    if (left == right or top == bottom or viewport.width == 0 or viewport.height == 0) return null;
    const has_depth = player.frame.depth;
    const stencil = if (player.frame.stencil) player.stencil.of(pipeline) else null;
    // What a triangle moves its depth by, and the bounds a pixel's own is
    // tested against: the pipeline's, or what a command set where it left
    // them dynamic. Neither means anything without a depth buffer (since
    // 1.47).
    const bias = if (has_depth and pipeline.biased) (pipeline.bias orelse player.depth_bias) else null;
    const bounds = if (has_depth and pipeline.bounded) (pipeline.bounds orelse player.depth_bounds) else null;
    return .{
        .clip = .{ .left = left, .top = top, .right = right, .bottom = bottom },
        .cfg = .{
            // Lines and points are not culled, and a triangle's edges were
            // as they were made.
            .forward = pipeline.cull != .front or _vertices.widens(pipeline),
            .reverse = pipeline.cull != .back or _vertices.widens(pipeline),
            // As Mesa has it: the hardware calls the other way round so.
            .clockwise = pipeline.front == .counter_clockwise,
            .compare = if (has_depth) (if (pipeline.depth_test) |compare| @intFromEnum(compare) else cl.COMPARE_ALWAYS) else cl.COMPARE_ALWAYS,
            .depth_write = has_depth and pipeline.depth_test != null and pipeline.depth_write,
            .stencil = stencil != null,
            .blend = _pipeline.mixingAt(pipeline, player.resources.output).enabled,
            .biased = bias != null,
            .bounded = bounds != null,
            .clamped = pipeline.clamped,
        },
        .mixing = mixingOf(player, pipeline),
        .stencil = if (stencil) |faces| .{ stencilFaceOf(faces[0]), stencilFaceOf(faces[1]) } else undefined,
        .bias_constant = if (bias) |moved| moved.constant else 0,
        .bias_slope = if (bias) |moved| moved.slope else 0,
        .bias_clamp = if (bias) |moved| moved.clamp else 0,
        .bounds = bounds orelse .{ 0, 1 },
        .x = viewport.x,
        .y = viewport.y,
        .width = viewport.width,
        .height = viewport.height,
        .min_depth = viewport.min_depth,
        .max_depth = viewport.max_depth,
        .sample_mask = sampleMaskOf(player, pipeline),
    };
}

/// Where the hardware is to count this draw's samples, written into the
/// binner's list before the draw's state: the word of the query being
/// counted into, or 0 for none. The packet is written only where the
/// address changes, the binner holding it until it does (since 1.47).
fn countSamples(queue: *Queue) void {
    const player = playerOf(queue);
    const address = tallyFor(queue);
    if (address == player.tally_address) return;
    cl.occlusionQuery(&player.bin, address);
    player.tally_address = address;
}

/// The word this frame counts the query being counted into with: the one
/// it already has, or a new one zeroed; 0 where nothing is counted or
/// there is no room for another. A subpass played once for each of its
/// colour attachments is counted in the first of them alone, as on the
/// cores (since 1.116): the frames of the others leave the counter
/// stopped, as a frame with no query does.
fn tallyFor(queue: *Queue) u32 {
    const player = playerOf(queue);
    if (player.part != 0) return 0;
    const counting = player.counting orelse return 0;
    const samples = counting.counters.samples orelse return 0;
    for (player.tallies[0..player.tally_count]) |tally| {
        if (tally.samples == samples) return tally.address;
    }
    if (player.tally_count == most_tallies) return 0;
    if (player.tally_group == null) {
        const place = carve(queue, tally_group_bytes, tally_group_bytes) orelse return 0;
        @memset(place.cpu[0..tally_line_bytes], 0);
        player.tally_group = place;
    }
    const group = player.tally_group.?;
    const at: *u32 = @ptrCast(@alignCast(group.cpu + player.tally_count * @sizeOf(u32)));
    const address = group.address + player.tally_count * @sizeOf(u32);
    player.tallies[player.tally_count] = .{ .samples = samples, .at = at, .address = address };
    player.tally_count += 1;
    return address;
}

/// What the hardware counted added to the queries, the frame drawn: each
/// word read back out of the CPU's caches first, it being the V3D that
/// wrote it.
fn addTallies(player: *Player, space: *const v3d.Space) void {
    const group = player.tally_group orelse return;
    space.rangeFromGpu(group.cpu, tally_line_bytes);
    for (player.tallies[0..player.tally_count]) |tally| _query.add(tally.samples, tally.at.*);
    player.tally_count = 0;
    player.tally_group = null;
}

/// A draw of `count` vertices, or of `count` indices with `vertex_offset`
/// added to each: the vertices or indices from `first` on, each instance
/// from `first_instance` to `instances` past it.
fn draw(queue: *Queue, first: u32, count: u32, vertex_offset: ?i32, first_instance: u32, instances: u32) void {
    const player = playerOf(queue);
    const pipeline = player.pipeline orelse return;
    // The sample mask covering nothing is one more way to draw nothing,
    // and on this device that is the whole of it: it reports
    // `pipeline_statistics_queries = false` (driver.zig), so unlike the
    // cores there is no counter that a masked-off draw still owes, and
    // returning here is exact. (Since 1.89, item 61 of
    // docs/facet-vulkan10.md.)
    if (pipeline.draws_nothing or sampleMaskOf(player, pipeline) == 0 or count == 0 or instances == 0) return;
    // A frame of no attachment, started again at four where its first
    // draw's pipeline draws four (item 61's V8, since 1.150). Before
    // anything of this draw's is carved: starting again gives the frame's
    // memory back. Where there is none to start again with, the frame is
    // dropped, as one that could not begin is.
    if (!restartAtFour(queue, pipeline)) {
        player.drawing = false;
        return noRoom(queue, "a frame of no attachment started again at four samples");
    }
    const viewport = pipeline.viewport orelse player.viewport;
    var state = drawStateOf(player, pipeline, &viewport) orelse return;
    const indices = _vertices.indicesOf(player, pipeline, first, count, vertex_offset) orelse return;
    const lowest, const highest = _vertices.range(indices) orelse return;
    if (highest - lowest >= most_vertices) return noRoom(queue, "a draw of more vertices than one works");
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
    // A float a vertex for the point it makes, where the draw makes points
    // at all (`shader.Vertices.setPointSize`, since 1.70).
    const points = _vertices.makesPoints(pipeline);
    const sizes_bytes = if (points) @as(usize, vertices) * @sizeOf(f32) else 0;
    const scratch = scratchOf(queue, inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes + wide_indices_bytes + sizes_bytes) orelse return noRoom(queue, "a draw with no memory to work its vertices in");
    const inputs: [*][4]f32 = @ptrCast(@alignCast(scratch));
    const outputs: [*]f32 = @ptrCast(@alignCast(scratch + inputs_bytes));
    const corners: [*]u32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes));
    const wide_vertices: [*]f32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes));
    const wide_indices: [*]u32 = @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes));
    const sizes: ?[*]f32 = if (points) @ptrCast(@alignCast(scratch + inputs_bytes + outputs_bytes + corners_bytes + wide_vertices_bytes + wide_indices_bytes)) else null;
    const corner_count = _vertices.assemble(pipeline.topology, indices, lowest, corners[0..most_corners]);
    if (corner_count == 0) return;

    // The triangles whose corners are all there: once for all instances,
    // where rectangles are made anew for each.
    var index_place: Place = undefined;
    var kept: u32 = 0;
    if (!wide and pipeline.tessellated == null) {
        index_place = carve(queue, @intCast(corner_count * 4), 4) orelse return noRoom(queue, "a draw with no memory for its indices");
        const kept_indices: [*]u32 = @ptrCast(@alignCast(index_place.cpu));
        var corner: usize = 0;
        while (corner < corner_count) : (corner += 3) {
            const three = corners[corner..][0..3];
            if (three[0] == _vertices.no_corner or three[1] == _vertices.no_corner or three[2] == _vertices.no_corner) continue;
            @memcpy(kept_indices[kept..][0..3], three);
            kept += 3;
        }
        if (kept == 0) return;
    }

    const programs = &player.hardware.programs;
    const fixed = pipeline.fixed;
    var varyings = pipeline.varyings;
    var carried: Carried = .as_they_are;
    var fragment: u32 = undefined;
    var uniforms: u32 = undefined;
    // The pipeline's own program, where it is what `fragment` is.
    var own: ?*const driver.Shader = null;
    // The program of no colour (`Hardware.no_color`, since 1.150) draws a
    // pipeline of no fragment stage, as v3dv's noop fragment shader does
    // (v3dv_pipeline.c:2616-2645), and in a frame of no colour every
    // fixed form, whose program writes a colour the frame has not and
    // drops no pixel: what it leaves is the depth and the stencil, which
    // the program of no colour leaves the same. A compiled program was
    // compiled for its subpass (`Pipeline.colorless`) and draws itself.
    var no_color = !player.frame.color and fixed.kind != .none;
    if (!no_color) switch (fixed.kind) {
        .color => {
            carried = .{ .colors_from = 0 };
            fragment = programs.color;
            const place = carve(queue, 4, 4) orelse return noRoom(queue, "a draw with no memory for its uniforms");
            uniforms = place.address;
        },
        // The forms that sample through the bound sampler run the
        // programs of the forms they are otherwise, the TMU told the
        // sampler (`textureUniforms`, since 1.141).
        // And the shadow one, whose program writes the reference (since
        // 1.142).
        .texture, .texture_color, .texture_array, .texture_cube, .texture_3d, .texture_sampled, .texture_array_sampled, .texture_cube_sampled, .texture_3d_sampled, .texture_shadow => {
            if (fixed.kind == .texture_color) carried = .{ .colors_from = 2 };
            fragment = switch (fixed.kind) {
                .texture, .texture_sampled => programs.texture,
                .texture_color => programs.texture_color,
                .texture_array, .texture_array_sampled => programs.array,
                .texture_cube, .texture_cube_sampled => programs.cube,
                .texture_shadow => programs.shadow,
                else => programs.volume,
            };
            uniforms = textureUniforms(queue, fixed) orelse missing: {
                // As `shader.missing`: the colour says what has gone wrong.
                // (A frame of no colour never reaches here: `no_color`.)
                varyings = 4;
                carried = .{ .constant = missing_color };
                fragment = programs.color;
                const place = carve(queue, 4, 4) orelse return noRoom(queue, "a draw with no memory for its uniforms");
                break :missing place.address;
            };
        },
        // No fixed form: the pipeline's own fragment shader, compiled as
        // the pipeline was made (since 1.76). Its varyings are 0 to 1, as
        // the graph wrote them and the tile buffer takes them, so they go
        // out as they are and not divided back out of `shader.channel`'s
        // scaling the way a fixed form's are.
        .none => none: {
            if (!pipeline.fragment_stage) {
                no_color = true;
                break :none;
            }
            const made: *const driver.Shader = @ptrCast(@alignCast(pipeline.driver orelse return));
            // Where the program samples, the TMU's two words of each unit
            // come from the texture and the sampler bound at the set and
            // binding the module named - which a draw knows and a
            // pipeline does not. Missing where there is no texture there,
            // or where the sampler compares and the program does not
            // (`sampledBy`).
            var tmus: [compile.most_samplers]Configuration = undefined;
            var found: usize = 0;
            for (made.sampled()) |each| {
                tmus[found] = sampledBy(queue, each) orelse break;
                found += 1;
            }
            // A uniform buffer the program reads and the draw has not
            // bound is what has gone wrong too (since 1.160).
            const lacking = found != made.sampled().len or !buffersBound(queue, made.stream());
            if (lacking and !player.frame.color) {
                // No colour to say what has gone wrong with: the depth
                // drawn as if nothing dropped a pixel.
                no_color = true;
            } else if (lacking) {
                // As `shader.missing`, and as a fixed form does: the
                // colour says what has gone wrong.
                varyings = 4;
                carried = .{ .constant = missing_color };
                fragment = programs.color;
                const place = carve(queue, 4, 4) orelse return noRoom(queue, "a draw with no memory for its uniforms");
                uniforms = place.address;
            } else {
                fragment = made.address;
                own = made;
                carried = .as_they_are;
                uniforms = streamOf(queue, made.stream(), tmus[0..found], null, 0, made.spillWords()) orelse return noRoom(queue, "a draw with no memory for its uniforms");
            }
        },
        // Refused when the pipeline was made (driver.zig): no fixed form's
        // program drops pixels or reads a cube of an array
        // (`samplesHere`), so none of these reaches a frame here.
        .texture_cutout, .texture_cube_array, .texture_cube_array_sampled => return,
    };
    if (no_color) {
        const made = &player.hardware.no_color;
        varyings = made.varyings;
        carried = .as_they_are;
        fragment = made.address;
        own = made;
        uniforms = streamOf(queue, made.stream(), &.{}, null, 0, .{}) orelse return noRoom(queue, "a draw with no memory for its uniforms");
    }

    // The pipeline's vertex shader on the QPU, where it was compiled for
    // it and the draw runs the pipeline's own fragment program: the
    // vertex function is not called then (since 1.163). Not where a
    // buffer either of its programs reads is not bound, which the vertex
    // function is left to make of (since 1.164).
    const compiled_vertex: ?*const driver.VertexStage = if (own) |made| (if (made.vertex) |*stage| (if (buffersBound(queue, stage.vertex.stream()) and buffersBound(queue, stage.coordinate.stream())) stage else null) else null) else null;
    if (own) |made| if (made.tmu_dirty_rcl) {
        player.tmu_dirty_rcl = true;
    };
    if (compiled_vertex) |stage| if (stage.vertex.tmu_dirty_rcl or stage.coordinate.tmu_dirty_rcl) {
        player.tmu_dirty_rcl = true;
    };
    const scale = ViewportScale{
        .half_width = viewport.width / 2,
        .half_height = viewport.height / 2,
        .scale = viewport.max_depth - viewport.min_depth,
        .offset = viewport.min_depth,
    };
    const record_bytes = recordStride(varyings);
    // How the program's varyings are interpolated, which a fixed form's
    // and the colour that says what has gone wrong are with perspective
    // (since 1.190).
    if (own) |made| {
        state.flat_shade_flags = made.flat_shade_flags;
        state.noperspective_flags = made.noperspective_flags;
    }
    if (!roomOnList(queue)) return noRoom(queue, "a draw with no memory for the binner's list");
    countSamples(queue);
    frames.writeDrawState(&player.bin, &player.frame, &state);
    for (0..instances) |k| {
        const instance = first_instance +% @as(u32, @intCast(k));
        if (compiled_vertex) |stage| {
            // The attributes made floats where the V3D reads them, and the
            // programs' own streams: the triangles are the ones kept
            // above, of vertices numbered from `lowest`.
            const place = carve(queue, @intCast(@max(inputs_bytes, 16)), 16) orelse return noRoom(queue, "a draw with no memory for its attributes");
            const into: [*][4]f32 = @ptrCast(@alignCast(place.cpu));
            _vertices.readInputs(player, pipeline, lowest, vertices, instance, into[0 .. @as(usize, vertices) * locations]);
            const vertex_uniforms = streamOf(queue, stage.vertex.stream(), &.{}, &scale, lowest, own.?.spillWords()) orelse return noRoom(queue, "a draw with no memory for its uniforms");
            const coordinate_uniforms = streamOf(queue, stage.coordinate.stream(), &.{}, &scale, lowest, own.?.spillWords()) orelse return noRoom(queue, "a draw with no memory for its uniforms");
            if (!roomOnList(queue)) return noRoom(queue, "a draw with no memory for the binner's list");
            if (!sendCompiledVertices(queue, place.address, locations, stage, vertex_uniforms, coordinate_uniforms, fragment, uniforms, own.?)) return noRoom(queue, "a draw with no memory for its shader record");
            // Each instance is a draw of its own here, of its attributes
            // made floats, so its instance id is 0: its base instance is
            // the instance, and InstanceIndex their sum, as v3dv's draw
            // of a first instance has the base be (v3dvx_cmd_buffer.c:
            // 2821-2829; since 1.192). Indices are kept from `lowest`, so
            // no base vertex: the first vertex is a uniform.
            if (stage.vertex.program.system_values.base_instance or stage.coordinate.program.system_values.base_instance) cl.baseVertexBaseInstance(&player.bin, 0, instance);
            cl.indexBufferSetup(&player.bin, index_place.address, kept * 4);
            cl.indexedPrimList(&player.bin, cl.PRIM_TRIANGLES, kept);
            player.binned = true;
            player.triangles += kept / 3;
            continue;
        }
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
            .resources = &player.resources,
            .sizes = sizes,
        };
        pipeline.vertex(&batch);
        var drawn: [*]const f32 = outputs;
        var drawn_vertices: usize = vertices;
        var drawn_corners: []const u32 = corners[0..corner_count];
        var into_vertices: [*]f32 = wide_vertices;
        var into_indices: [*]u32 = wide_indices;
        var tessellated: ?_tessellate.Made = null;
        defer if (tessellated) |made| made.free(queue.device.sys);
        if (pipeline.tessellated != null) {
            const made = _tessellate.run(queue.device.sys, pipeline, &player.resources, outputs, corners[0..corner_count], instance, most_vertices, &_query.none) orelse {
                noRoom(queue, "a draw with no memory to tessellate it, or more vertices out of it than one works");
                continue;
            };
            tessellated = made;
            drawn = made.vertices;
            drawn_vertices = made.vertex_count;
            drawn_corners = made.corners();
            into_vertices = made.wide_vertices;
            into_indices = made.wide_indices;
            if (!wide) {
                if (made.corner_count == 0) continue;
                index_place = carve(queue, made.corner_count * 4, 4) orelse return noRoom(queue, "a draw with no memory for the indices it tessellated to");
                @memcpy(@as([*]u32, @ptrCast(@alignCast(index_place.cpu)))[0..made.corner_count], drawn_corners);
                kept = made.corner_count;
            }
        }
        if (wide) {
            const made = _vertices.widen(pipeline, &viewport, pipeline.line_width orelse player.line_width, drawn, stride, drawn_corners, into_vertices, into_indices, if (tessellated == null) sizes else null);
            if (made.indices == 0) continue;
            index_place = carve(queue, made.indices * 4, 4) orelse return noRoom(queue, "a draw with no memory for the indices of its lines or points");
            @memcpy(@as([*]u32, @ptrCast(@alignCast(index_place.cpu)))[0..made.indices], into_indices[0..made.indices]);
            kept = made.indices;
            drawn = into_vertices;
            drawn_vertices = made.vertices;
        }
        const records_bytes = std.math.cast(u32, drawn_vertices * record_bytes) orelse return noRoom(queue, "a draw with more vertex records than a frame holds");
        const records = carve(queue, records_bytes, 4) orelse return noRoom(queue, "a draw with no memory for its vertex records");
        for (0..drawn_vertices) |vertex| {
            writeRecord(records.cpu + vertex * record_bytes, drawn + vertex * stride, &scale, varyings, carried);
        }
        if (!roomOnList(queue)) return noRoom(queue, "a draw with no memory for the binner's list");
        if (!sendVertices(queue, records.address, varyings, fragment, uniforms, own)) return noRoom(queue, "a draw with no memory for its shader record");
        cl.indexBufferSetup(&player.bin, index_place.address, kept * 4);
        cl.indexedPrimList(&player.bin, cl.PRIM_TRIANGLES, kept);
        player.binned = true;
        player.triangles += kept / 3;
    }
}

/// `bytes` of the player's memory for a draw's vertices, aligned for a
/// float; null when there is none to be had.
fn scratchOf(queue: *Queue, bytes: usize) ?[*]u8 {
    const player = playerOf(queue);
    if (bytes <= player.scratch_bytes) return player.scratch;
    const sys = queue.device.sys;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
    if (player.scratch) |old| sys.FreeVec(old);
    player.scratch = @ptrCast(memory);
    player.scratch_bytes = bytes;
    return player.scratch;
}

// --- copies -----------------------------------------------------------------

fn copyBufferToImage(queue: *Queue, command: *const _command.CopyBufferToImage) void {
    const from = _buffer.bytes(command.source, 0, facet.WHOLE_SIZE) orelse return;
    const image = command.image;
    for (_stream.items(_command.CopyBufferToImage, facet.BufferImageCopy, command, command.count)) |*region| {
        if (_image.unpacks(image)) {
            _image.copyUnpacking(image, from, region);
        } else if (image.kind == .texture) {
            copyToTexture(image, from, region);
        } else {
            _image.copyFromBuffer(image, from, region);
        }
    }
    texturesToGpu(queue, image);
}

/// A rectangle of texels into a level of a texture, as they are in the
/// buffer: the texture's state says which channel is which.
fn copyToTexture(image: *Image, from: []const u8, region: *const facet.BufferImageCopy) void {
    const data = image.data orelse return;
    const level = region.image_subresource.mip_level;
    if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) return;
    const level_width = @max(image.width >> @intCast(level), 1);
    const level_height = @max(image.height >> @intCast(level), 1);
    const left: u32 = @intCast(region.image_offset.x);
    const top: u32 = @intCast(region.image_offset.y);
    if (left >= level_width or top >= level_height) return;
    const width = @min(region.image_extent.width, level_width - left);
    const height = @min(region.image_extent.height, level_height - top);
    const pixel = _image.bytesOf(image.format);
    const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
    const source_pitch = @as(usize, row_length) * pixel;
    const start = std.math.cast(usize, region.buffer_offset) orelse return;
    const layout = imageLayout(image);
    const range = _image.layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse return;
    const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
    for (0..range.count) |slice| {
        const layer_data = data + layerAt(image, &layout, level, range.first + @as(u32, @intCast(slice)));
        for (0..height) |row| {
            const at = start + slice * slice_height * source_pitch + row * source_pitch;
            if (at + width * pixel > from.len) return;
            const y = top + @as(u32, @intCast(row));
            for (0..width) |column| {
                const x = left + @as(u32, @intCast(column));
                const into = layer_data + tiling.texelOffset(&layout, level, x, y);
                @memcpy(into[0..pixel], from[at + column * pixel ..][0..pixel]);
            }
        }
    }
}
