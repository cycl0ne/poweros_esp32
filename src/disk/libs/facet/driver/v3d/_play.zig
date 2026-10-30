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
//! A pass over part of the image loads the tiles it touches, as a tile is
//! stored whole, and a clear of that part is a rectangle drawn first.

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
const Pipeline = @import("../../pipeline/_pipeline.zig").Pipeline;
const max_vertex_input_bindings = @import("../../instance/_instance.zig").max_vertex_input_bindings;
const _vertices = @import("../_vertices.zig");
const driver = @import("driver.zig");
const Hardware = driver.Hardware;
const regs = v3d.regs;
const cl = v3d.cl;
const qpu = v3d.qpu;
const tiling = v3d.tiling;
const frames = v3d.frame;
const Frame = frames.Frame;
const Area = frames.Area;
const Block = v3d.Block;

/// The bytes of a chunk, and how many a frame can have.
const chunk_bytes: u32 = 1024 * 1024;
const most_chunks = 32;
/// Of the binner's list at a time; a list in several parts branches on.
const list_part_bytes: u32 = 64 * 1024;
/// What is kept free in a part: a draw's packets, then the branch out.
const packets_bytes: u32 = 160;
/// The memory for the binner's lists: its first block of each tile, and what
/// it goes on into before it asks for more.
const tile_list_bytes: u32 = 128;
const tile_lists_extra: u32 = 1024 * 1024;
const tile_state_bytes: u32 = 256;
/// The most vertices a draw works: past it, the draw draws nothing.
const most_vertices = 1 << 20;
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
    resources: shader.Resources = .{},
    /// The frame being made.
    frame: Frame = undefined,
    area: Area = undefined,
    image: *Image = undefined,
    bin: cl.List = undefined,
    /// A draw is on the binner's list.
    binned: bool = false,
    /// Memory a draw's vertices are worked in, kept for the next.
    scratch: ?[*]u8 = null,
    scratch_bytes: usize = 0,
    chunks: [most_chunks]Chunk = undefined,
    chunk_count: u32 = 0,
    chunk_at: u32 = 0,
    tile_lists: ?Block = null,
    tile_state: ?Block = null,
};

pub fn open(queue: *Queue) bool {
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

pub fn close(queue: *Queue) void {
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

/// A sampled image's layout in memory.
pub fn layoutOf(format: facet.Format, width: u32, height: u32, levels: u32) tiling.Layout {
    return tiling.layoutOf(_image.bytesOf(format), width, height, @min(levels, tiling.most_levels));
}

/// The commands of `buffer`, in order.
pub fn play(queue: *Queue, buffer: *CommandBuffer) void {
    const player = playerOf(queue);
    player.drawing = false;
    player.pipeline = null;
    player.vertex_buffers = @splat(.{});
    player.index_buffer = null;
    player.resources = .{};
    var commands = buffer.stream.commands();
    while (commands.next()) |head| switch (head.op) {
        .barrier => {},
        .copy_buffer_to_image => copyBufferToImage(queue, _stream.as(_command.CopyBufferToImage, head)),
        .copy_buffer => _vertices.copyBuffer(_stream.as(_command.CopyBuffer, head)),
        .begin_render_pass => beginRenderPass(queue, _stream.as(_command.BeginRenderPass, head)),
        .end_render_pass => endRenderPass(queue),
        .bind_pipeline => player.pipeline = _stream.as(_command.BindPipeline, head).pipeline,
        .bind_vertex_buffers => _vertices.bindVertexBuffers(player, _stream.as(_command.BindVertexBuffers, head)),
        .bind_index_buffer => {
            const command = _stream.as(_command.BindIndexBuffer, head);
            player.index_buffer = command.buffer;
            player.index_offset = command.offset;
            player.index_type = command.index_type;
        },
        .bind_descriptor_sets => _vertices.bindDescriptorSets(&player.resources, _stream.as(_command.BindDescriptorSets, head)),
        .push_constants => _vertices.pushConstants(&player.resources, _stream.as(_command.PushConstants, head)),
        .set_viewport => player.viewport = _stream.as(_command.SetViewport, head).viewport,
        .set_scissor => player.scissor = _stream.as(_command.SetScissor, head).scissor,
        .draw => if (player.drawing) {
            const command = _stream.as(_command.Draw, head);
            draw(queue, command.first_vertex, command.vertex_count, null, command.first_instance, command.instance_count);
        },
        .draw_indexed => if (player.drawing) {
            const command = _stream.as(_command.DrawIndexed, head);
            draw(queue, command.first_index, command.index_count, command.vertex_offset, command.first_instance, command.instance_count);
        },
        _ => {},
    };
    // A command buffer that ends inside its render pass ends the pass.
    endRenderPass(queue);
}

// --- memory -----------------------------------------------------------------

/// `bytes` from the frame's chunks: null when there is no more to be had.
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

fn beginRenderPass(queue: *Queue, command: *const _command.BeginRenderPass) void {
    endRenderPass(queue);
    const player = playerOf(queue);
    if (player.hardware.broken) return;
    const framebuffer = command.framebuffer;
    const image = framebuffer.color.image;
    const output: struct { u64, bool } = switch (image.format) {
        .b8g8r8a8_unorm => .{ cl.OUTPUT_RGBA8, true },
        .r8g8b8a8_unorm => .{ cl.OUTPUT_RGBA8, false },
        .r5g6b5_unorm_pack16 => .{ cl.OUTPUT_BGR565, false },
        else => return,
    };
    const address = addressOf(queue, image);
    if (address == 0) {
        exec.kprintf(queue.device.sys, "v3d: an image at %lx is out of its reach\n", .{@intFromPtr(image.data)});
        return;
    }
    // The render area, cut to the framebuffer.
    const offset = command.area.offset;
    const left: u32 = @intCast(std.math.clamp(offset.x, 0, @as(i64, framebuffer.width)));
    const top: u32 = @intCast(std.math.clamp(offset.y, 0, @as(i64, framebuffer.height)));
    const right: u32 = @intCast(std.math.clamp(@as(i64, offset.x) + command.area.extent.width, left, framebuffer.width));
    const bottom: u32 = @intCast(std.math.clamp(@as(i64, offset.y) + command.area.extent.height, top, framebuffer.height));
    if (left == right or top == bottom) return;
    const whole = left == 0 and top == 0 and right == framebuffer.width and bottom == framebuffer.height;
    const clears = command.render_pass.color_load == .clear;
    const tiles = ((framebuffer.width + 63) / 64) * ((framebuffer.height + 63) / 64);
    if (!sized(queue, &player.tile_lists, tiles * tile_list_bytes + tile_lists_extra)) return;
    if (!sized(queue, &player.tile_state, tiles * tile_state_bytes)) return;
    for (player.chunks[0..player.chunk_count]) |*chunk| chunk.used = 0;
    player.chunk_at = 0;
    const list = carve(queue, list_part_bytes, 8) orelse return;
    const color = command.clear_color;
    player.image = image;
    player.area = .{ .left = left, .top = top, .right = right, .bottom = bottom };
    player.frame = .{
        .width = framebuffer.width,
        .height = framebuffer.height,
        .image = address,
        .stride = image.pitch,
        .format = output[0],
        .swap_rb = output[1],
        // Red in the low byte.
        .clear = color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16,
        .tile_lists = player.tile_lists.?.address,
        .binned = false,
        .load = !clears or !whole,
        .depth = command.render_pass.depth != null,
        .clear_depth = @as(f32, @floatFromInt(command.clear_depth)) / 65535,
        .area = if (whole) null else player.area,
    };
    player.bin = .{ .at = list.cpu, .address = list.address };
    player.binned = false;
    frames.beginBin(&player.bin, &player.frame);
    player.drawing = true;
    if (clears and !whole) clearArea(queue, color);
}

/// A clear of part of the image: a rectangle of the colour, over all of it
/// and cut to the part.
fn clearArea(queue: *Queue, color: u32) void {
    const player = playerOf(queue);
    const channel = struct {
        fn of(value: u32, shift: u5) f32 {
            return @as(f32, @floatFromInt(value >> shift & 0xFF)) / 255;
        }
    }.of;
    const rgba = [4]f32{ channel(color, 16), channel(color, 8), channel(color, 0), channel(color, 24) };
    const corners = [_]u32{ 0, 1, 2, 2, 1, 3 };
    const indices = carve(queue, @sizeOf(@TypeOf(corners)), 4) orelse return;
    @memcpy(indices.cpu[0..@sizeOf(@TypeOf(corners))], std.mem.asBytes(&corners));
    const stride = recordStride(4);
    const vertices = carve(queue, 4 * stride, 4) orelse return;
    const half_width = @as(f32, @floatFromInt(player.frame.width)) / 2;
    const half_height = @as(f32, @floatFromInt(player.frame.height)) / 2;
    const viewport = ViewportScale{ .half_width = half_width, .half_height = half_height, .scale = 0, .offset = 0 };
    for ([4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }, 0..) |corner, k| {
        writeRecord(vertices.cpu + k * stride, &[4]f32{ corner[0], corner[1], 0, 1 }, &viewport, 4, .{ .constant = rgba });
    }
    const state = frames.DrawState{
        .clip = player.area,
        .x = 0,
        .y = 0,
        .width = half_width * 2,
        .height = half_height * 2,
    };
    const uniforms = carve(queue, 4, 4) orelse return;
    if (!roomOnList(queue)) return;
    frames.writeDrawState(&player.bin, &state);
    if (!sendVertices(queue, vertices.address, 4, player.hardware.programs.color, uniforms.address)) return;
    cl.indexBufferSetup(&player.bin, indices.address, @sizeOf(@TypeOf(corners)));
    cl.indexedPrimList(&player.bin, cl.PRIM_TRIANGLES, corners.len);
    player.binned = true;
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

    const lists = carve(queue, 4096, 16) orelse return;
    var tile_list = cl.List{ .at = lists.cpu, .address = lists.address };
    frames.writeTileList(&tile_list, &player.frame);
    var render = cl.List{ .at = lists.cpu + 512, .address = lists.address + 512 };
    frames.writeRender(&render, &player.frame, tile_list.address, tile_list.here());

    const space = &hardware.space;
    const image = player.image;
    const image_bytes: usize = @as(usize, image.pitch) * player.frame.height;
    for (player.chunks[0..player.chunk_count]) |*chunk| {
        if (chunk.used != 0) space.rangeToGpu(chunk.block.cpu, chunk.used);
    }
    space.rangeToGpu(image.data.?, image_bytes);

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
        const binned = engine.bin(player.bin.address, player.bin.here(), &player.tile_lists.?, &player.tile_state.?);
        if (binned != .done) return lost(player, sys, binned, "binning");
    }
    const rendered = engine.render(render.address, render.here());
    space.rangeFromGpu(image.data.?, image_bytes);
    if (rendered != .done) return lost(player, sys, rendered, "rendering");
    if (image.display) |display| {
        const area = player.area;
        display.handOn(area.left, area.top, area.right - area.left, area.bottom - area.top);
    }
}

/// What became of a job said, with where its list had got to. Nothing more
/// is sent after it.
fn lost(player: *const Player, sys: *ExecBase, finished: v3d.Engine.Finished, what: [*:0]const u8) void {
    const hardware = player.hardware;
    const engine = &hardware.engine;
    const gpu = &hardware.gpu;
    switch (finished) {
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

/// A vertex's record's attributes, its programs and its shader state, and
/// the packet that says so.
fn sendVertices(queue: *Queue, vertices: u32, varyings: u32, fragment: u32, uniforms: u32) bool {
    const player = playerOf(queue);
    const programs = &player.hardware.programs;
    const attributes: u32 = 2 + @as(u32, @intFromBool(varyings > 0)) + @as(u32, @intFromBool(varyings > 4));
    const record = carve(queue, cl.shader_record_bytes + 16 * attributes, 32) orelse return false;
    var list = cl.List{ .at = record.cpu, .address = record.address };
    cl.shaderRecord(&list, .{
        .fragment = fragment,
        .fragment_uniforms = uniforms,
        .vertex = programs.vertex[varyings],
        .vertex_uniforms = uniforms,
        .coordinate = programs.coordinate,
        .coordinate_uniforms = uniforms,
        .varyings = varyings,
    });
    const stride = recordStride(varyings);
    cl.attribute(&list, vertices, 4, 4, 0, stride);
    cl.attribute(&list, vertices + 16, 4, 2, 4, stride);
    if (varyings > 0) cl.attribute(&list, vertices + 32, @min(varyings, 4), 0, @min(varyings, 4), stride);
    if (varyings > 4) cl.attribute(&list, vertices + 48, varyings - 4, 0, varyings - 4, stride);
    cl.glShaderState(&player.bin, record.address, attributes);
    return true;
}

/// The two uniforms of a program that samples: the texture's state and the
/// sampler's, carved beside them. Null without a texture bound, or no memory.
fn textureUniforms(queue: *Queue, fixed: shader.Fixed) ?u32 {
    const player = playerOf(queue);
    const sampled = player.resources.sampled(0, 0, 0) orelse return null;
    const view: *const _image.ImageView = @fieldParentPtr("texels", sampled);
    const image = view.image;
    if (image.kind != .texture or image.data == null) return null;
    const texels: tiling.Texels = switch (image.format) {
        .b8g8r8a8_unorm => .bgra,
        .r8g8b8a8_unorm => .rgba,
        .r5g6b5_unorm_pack16 => .rgb565,
        else => return null,
    };
    const layout = layoutOf(image.format, image.width, image.height, image.levels);
    const state = carve(queue, tiling.texture_state_bytes, tiling.texture_state_alignment) orelse return null;
    tiling.writeTextureState(state.cpu[0..tiling.texture_state_bytes], &layout, texels, @intCast(@intFromPtr(image.data)), view.base_level, view.base_level + view.level_count - 1);
    const sampler = carve(queue, tiling.sampler_state_bytes, tiling.sampler_state_alignment) orelse return null;
    const filter: tiling.Filter = switch (fixed.sampling.filter) {
        .nearest => .nearest,
        .bilinear => .bilinear,
    };
    const wrap: tiling.Wrap = switch (fixed.sampling.address) {
        .wrap => .repeat,
        .clamp => .clamp,
    };
    tiling.writeSamplerState(sampler.cpu[0..tiling.sampler_state_bytes], filter, wrap);
    const place = carve(queue, 8, 4) orelse return null;
    const words: [*]u32 = @ptrCast(@alignCast(place.cpu));
    words[0] = tiling.parameter0(state.address);
    words[1] = tiling.parameter1(sampler.address);
    return place.address;
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
    return .{
        .clip = .{ .left = left, .top = top, .right = right, .bottom = bottom },
        .cfg = .{
            .forward = pipeline.cull != .front,
            .reverse = pipeline.cull != .back,
            // As Mesa has it: the hardware calls the other way round so.
            .clockwise = pipeline.front == .counter_clockwise,
            .compare = if (has_depth) (if (pipeline.depth_test) |compare| @intFromEnum(compare) else cl.COMPARE_ALWAYS) else cl.COMPARE_ALWAYS,
            .depth_write = has_depth and pipeline.depth_test != null and pipeline.depth_write,
            .blend = pipeline.blend == .alpha,
        },
        .x = viewport.x,
        .y = viewport.y,
        .width = viewport.width,
        .height = viewport.height,
        .min_depth = viewport.min_depth,
        .max_depth = viewport.max_depth,
    };
}

/// A draw of `count` vertices, or of `count` indices with `vertex_offset`
/// added to each: the vertices or indices from `first` on, each instance
/// from `first_instance` to `instances` past it.
fn draw(queue: *Queue, first: u32, count: u32, vertex_offset: ?i32, first_instance: u32, instances: u32) void {
    const player = playerOf(queue);
    const pipeline = player.pipeline orelse return;
    if (pipeline.draws_nothing or count == 0 or instances == 0) return;
    const viewport = pipeline.viewport orelse player.viewport;
    const state = drawStateOf(player, pipeline, &viewport) orelse return;
    const indices = _vertices.indicesOf(player, pipeline, first, count, vertex_offset) orelse return;
    const lowest, const highest = _vertices.range(indices) orelse return;
    if (highest - lowest >= most_vertices) return;
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
    const corner_count = _vertices.assemble(pipeline.topology, indices, lowest, corners[0..most_corners]);

    // The triangles whose corners are all there.
    const index_bytes: u32 = @intCast(corner_count * 4);
    if (index_bytes == 0) return;
    const index_place = carve(queue, index_bytes, 4) orelse return;
    const kept_indices: [*]u32 = @ptrCast(@alignCast(index_place.cpu));
    var kept: u32 = 0;
    var corner: usize = 0;
    while (corner < corner_count) : (corner += 3) {
        const three = corners[corner..][0..3];
        if (three[0] == _vertices.no_corner or three[1] == _vertices.no_corner or three[2] == _vertices.no_corner) continue;
        @memcpy(kept_indices[kept..][0..3], three);
        kept += 3;
    }
    if (kept == 0) return;

    const programs = &player.hardware.programs;
    const fixed = pipeline.fixed;
    var varyings = pipeline.varyings;
    var carried: Carried = .as_they_are;
    var fragment: u32 = undefined;
    var uniforms: u32 = undefined;
    switch (fixed.kind) {
        .color => {
            carried = .{ .colors_from = 0 };
            fragment = programs.color;
            const place = carve(queue, 4, 4) orelse return;
            uniforms = place.address;
        },
        .texture, .texture_color => {
            if (fixed.kind == .texture_color) carried = .{ .colors_from = 2 };
            fragment = if (fixed.kind == .texture) programs.texture else programs.texture_color;
            uniforms = textureUniforms(queue, fixed) orelse missing: {
                // As `shader.missing`: the colour says what has gone wrong.
                varyings = 4;
                carried = .{ .constant = missing_color };
                fragment = programs.color;
                const place = carve(queue, 4, 4) orelse return;
                break :missing place.address;
            };
        },
        .none => return,
    }

    const scale = ViewportScale{
        .half_width = viewport.width / 2,
        .half_height = viewport.height / 2,
        .scale = viewport.max_depth - viewport.min_depth,
        .offset = viewport.min_depth,
    };
    const record_bytes = recordStride(varyings);
    const records_bytes = std.math.cast(u32, @as(u64, vertices) * record_bytes) orelse return;
    if (!roomOnList(queue)) return;
    frames.writeDrawState(&player.bin, &state);
    for (0..instances) |k| {
        const instance = first_instance +% @as(u32, @intCast(k));
        _vertices.readInputs(player, pipeline, lowest, vertices, instance, inputs[0 .. @as(usize, vertices) * locations]);
        const batch = shader.Vertices{
            .inputs = inputs,
            .input_stride = locations,
            .count = vertices,
            .outputs = outputs,
            .output_stride = stride,
            .first_vertex = lowest,
            .instance = instance,
            .resources = &player.resources,
        };
        pipeline.vertex(&batch);
        const records = carve(queue, records_bytes, 4) orelse return;
        for (0..vertices) |vertex| {
            writeRecord(records.cpu + vertex * record_bytes, outputs + vertex * stride, &scale, varyings, carried);
        }
        if (!roomOnList(queue)) return;
        if (!sendVertices(queue, records.address, varyings, fragment, uniforms)) return;
        cl.indexBufferSetup(&player.bin, index_place.address, kept * 4);
        cl.indexedPrimList(&player.bin, cl.PRIM_TRIANGLES, kept);
        player.binned = true;
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
        if (image.kind == .texture) {
            copyToTexture(image, from, region);
        } else {
            _image.copyFromBuffer(image, from, region);
        }
    }
    if (image.kind == .texture) if (image.data) |data| {
        playerOf(queue).hardware.space.rangeToGpu(data, @intCast(image.bytes));
    };
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
    const layout = layoutOf(image.format, image.width, image.height, image.levels);
    for (0..height) |row| {
        const at = start + row * source_pitch;
        if (at + width * pixel > from.len) return;
        const y = top + @as(u32, @intCast(row));
        for (0..width) |column| {
            const x = left + @as(u32, @intCast(column));
            const into = data + tiling.texelOffset(&layout, level, x, y);
            @memcpy(into[0..pixel], from[at + column * pixel ..][0..pixel]);
        }
    }
}
