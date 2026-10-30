// SPDX-License-Identifier: MIT
//! FacetBoth: the same frames through facet.library on the cores and on the
//! device after them, a CM5's V3D, and each pair compared pixel by pixel:
//! the cores are the reference. A case is a command buffer's worth - a kind
//! of draw, a piece of a pipeline's state, a render area, a format - in
//! pictures the program reads back.
//!
//!   FacetBoth SIZE/K,ONLY/K
//!
//! Pictures are SIZE big, WIDTHxHEIGHT: 640x360 if not given. ONLY runs the
//! cases with that in their name. A job that never ends stops the V3D until
//! the program goes, and with it the cases after it. It prints for
//! each case how many pixels are further apart than two steps of a channel,
//! and returns WARN if any case has more than one in a thousand, with a map
//! of where they are. Textures
//! are drawn no smaller than the level their pixels are on either way: the
//! two choose a level by different sums, and pictures of a texture turned
//! in depth are C:test/FacetCube's to look at.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FacetBase = sdk.interface.facet.FacetBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FacetBoth";
const VERSION_STRING = "\x00$VER: FacetBoth 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SIZE/K,ONLY/K";

const Failure = error{ NoMemory, NoDevice, Refused, DeviceLost };

const Vertex = extern struct {
    p: [4]f32,
    c: [4]f32,
    uv: [2]f32,
};

fn at(x: f32, y: f32, z: f32, c: [4]f32, u: f32, v: f32) Vertex {
    return .{ .p = .{ x, y, z, 1 }, .c = c, .uv = .{ u, v } };
}

const red = [4]f32{ 0.9, 0.1, 0.15, 1 };
const green = [4]f32{ 0.1, 0.8, 0.2, 1 };
const blue = [4]f32{ 0.15, 0.2, 0.9, 1 };
const yellow = [4]f32{ 0.9, 0.85, 0.1, 1 };
const see_through = [4]f32{ 0.9, 0.3, 0.1, 0.4 };

// What the cases draw: where each part of `geometry` starts, and it.
const clockwise_at = 0;
const counter_at = 3;
const strip_at = 6;
const fan_at = 11;
const far_at = 16;
const near_at = 19;
const glass_at = 22;
const quad_at = 25;
const wide_at = 31;
const behind_at = 37;

const geometry = [_]Vertex{
    // Clockwise on the picture, y down.
    at(-0.71, -0.63, 0.5, red, 0, 0),
    at(0.27, -0.52, 0.5, green, 1, 0),
    at(-0.33, 0.47, 0.5, blue, 0, 1),
    // The other way round.
    at(0.83, 0.71, 0.5, yellow, 0, 0),
    at(0.17, -0.11, 0.5, blue, 1, 0),
    at(0.09, 0.67, 0.5, green, 0, 1),
    // A strip.
    at(-0.81, 0.53, 0.5, red, 0, 0),
    at(-0.77, -0.47, 0.5, green, 0, 0),
    at(-0.23, 0.61, 0.5, blue, 0, 0),
    at(0.11, -0.59, 0.5, yellow, 0, 0),
    at(0.73, 0.43, 0.5, red, 0, 0),
    // A fan.
    at(0.03, 0.07, 0.5, yellow, 0, 0),
    at(-0.57, -0.73, 0.5, red, 0, 0),
    at(0.47, -0.67, 0.5, green, 0, 0),
    at(0.79, 0.21, 0.5, blue, 0, 0),
    at(-0.13, 0.77, 0.5, red, 0, 0),
    // Far, near and laid over.
    at(-0.73, -0.71, 0.75, blue, 0, 0),
    at(0.41, -0.57, 0.75, blue, 0, 0),
    at(-0.27, 0.59, 0.75, blue, 0, 0),
    at(-0.37, -0.31, 0.25, red, 0, 0),
    at(0.69, -0.17, 0.25, red, 0, 0),
    at(0.07, 0.83, 0.25, red, 0, 0),
    at(-0.51, -0.41, 0.5, see_through, 0, 0),
    at(0.57, -0.23, 0.5, see_through, 0, 0),
    at(-0.03, 0.69, 0.5, see_through, 0, 0),
    // A rectangle over most of the picture, its texture once.
    at(-0.71, -0.73, 0.5, red, 0, 0),
    at(0.73, -0.73, 0.5, green, 1, 0),
    at(-0.71, 0.77, 0.5, blue, 0, 1),
    at(0.73, -0.73, 0.5, green, 1, 0),
    at(0.73, 0.77, 0.5, yellow, 1, 1),
    at(-0.71, 0.77, 0.5, blue, 0, 1),
    // The same past the texture's edges.
    at(-0.71, -0.73, 0.5, red, -1.25, -1.25),
    at(0.73, -0.73, 0.5, green, 2.25, -1.25),
    at(-0.71, 0.77, 0.5, blue, -1.25, 2.25),
    at(0.73, -0.73, 0.5, green, 2.25, -1.25),
    at(0.73, 0.77, 0.5, yellow, 2.25, 2.25),
    at(-0.71, 0.77, 0.5, blue, -1.25, 2.25),
    // A corner behind the eye.
    .{ .p = .{ -0.61, -0.57, 0.3, 1 }, .c = red, .uv = .{ 0, 0 } },
    .{ .p = .{ 0.67, -0.49, 0.3, 1 }, .c = green, .uv = .{ 0, 0 } },
    .{ .p = .{ 0.1, 0.8, -0.5, -0.5 }, .c = blue, .uv = .{ 0, 0 } },
};

/// Index 0 to 4 of the strip, broken after the third.
const restart_indices = [_]u16{ 0, 1, 2, 0xFFFF, 2, 3, 4 };
const indices_16 = [_]u16{ 2, 1, 0 };
const indices_32 = [_]u32{ 0, 1, 2, 3, 4, 1 };
/// Added to each vertex's place, one for each instance.
const instance_places = [_][2]f32{ .{ 0, 0 }, .{ 0.31, 0.23 }, .{ -0.27, 0.19 } };

fn place(vertices: *const shader.Vertices, k: usize) [4]f32 {
    const p = vertices.input(@intCast(k), 0);
    const moved = vertices.input(@intCast(k), 3);
    return .{ p[0] + moved[0] * p[3], p[1] + moved[1] * p[3], p[2], p[3] };
}

fn colorVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], p[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

fn textureVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1] };
    }
}

fn modulateVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..10].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

const entries = [_]shader.Entry{
    shader.vertex("color", &colorVertex, 4),
    shader.vertex("texture", &textureVertex, 2),
    shader.vertex("modulate", &modulateVertex, 6),
    shader.fixedFragment("color", .{ .kind = .color }),
    shader.fixedFragment("texture", .{ .kind = .texture, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("nearest", .{ .kind = .texture, .sampling = .{ .filter = .nearest } }),
    shader.fixedFragment("nearest 565", .{ .kind = .texture, .sampling = .{ .format = .rgb565, .filter = .nearest } }),
    shader.fixedFragment("clamp", .{ .kind = .texture, .sampling = .{ .filter = .bilinear, .address = .clamp } }),
    shader.fixedFragment("modulate", .{ .kind = .texture_color, .sampling = .{ .filter = .nearest } }),
};
const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

const texture_side: u32 = 64;
const texture_levels = 7;
const formats = [_]facet.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm, .r5g6b5_unorm_pack16 };
const Target = enum(u32) { bgra, rgba, rgb565 };

/// What a pipeline of a case is.
const Options = struct {
    vertex: [*:0]const u8 = "color",
    fragment: [*:0]const u8 = "color",
    topology: facet.PrimitiveTopology = .triangle_list,
    restart: bool = false,
    cull: u32 = facet.CULL_MODE_NONE,
    front: facet.FrontFace = .clockwise,
    test_depth: bool = false,
    write_depth: bool = false,
    compare: facet.CompareOp = .less,
    blend: bool = false,
    target: Target = .bgra,
    depth: bool = true,
    load: bool = false,
};

/// What a pass of a case is.
const Pass = struct {
    target: Target = .bgra,
    depth: bool = true,
    load: bool = false,
    /// Parts of 1 of the picture; all of it if null.
    area: ?[4]f32 = null,
    clear: [4]f32 = .{ 0.06, 0.09, 0.2, 1 },
};

/// One device and everything drawn with it.
const Side = struct {
    fb: *FacetBase,
    width: u32,
    height: u32,
    physical: *facet.PhysicalDevice,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    blocks: [24]?*facet.DeviceMemory = @splat(null),
    block_count: u32 = 0,
    vertices: ?*facet.Buffer = null,
    places: ?*facet.Buffer = null,
    indices: ?*facet.Buffer = null,
    staging: ?*facet.Buffer = null,
    pictures: [formats.len]?*facet.Image = @splat(null),
    picture_views: [formats.len]?*facet.ImageView = @splat(null),
    picture_bytes: [formats.len][*]const u8 = undefined,
    picture_pitch: [formats.len]usize = undefined,
    depth: ?*facet.Image = null,
    depth_view: ?*facet.ImageView = null,
    textures: [formats.len]?*facet.Image = @splat(null),
    texture_views: [formats.len]?*facet.ImageView = @splat(null),
    /// Render passes by format, depth and load.
    passes: [formats.len][2][2]?*facet.RenderPass = @splat(@splat(@splat(null))),
    framebuffers: [formats.len][2]?*facet.Framebuffer = @splat(@splat(null)),
    set_layout: ?*facet.DescriptorSetLayout = null,
    descriptor_pool: ?*facet.DescriptorPool = null,
    sets: [formats.len]?*facet.DescriptorSet = @splat(null),
    layout: ?*facet.PipelineLayout = null,
    module: ?*facet.ShaderModule = null,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    /// The pipelines of the case being drawn.
    made: [8]?*facet.Pipeline = @splat(null),
    made_count: u32 = 0,

    fn expect(result: facet.Result, failure: Failure) Failure!void {
        if (result == .error_device_lost) return error.DeviceLost;
        if (result != .success) return failure;
    }

    fn up(side: *Side) Failure!void {
        const fb = side.fb;
        fb.GetPhysicalDeviceMemoryProperties(side.physical, &side.memory);
        const queue_info = facet.DeviceQueueCreateInfo{};
        try expect(fb.CreateDevice(side.physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &side.device), error.NoDevice);
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(side.device.?, 0, 0, &queue);
        side.queue = queue.?;
        const device = side.device.?;

        var bytes = try side.buffer(@sizeOf(@TypeOf(geometry)), facet.BUFFER_USAGE_VERTEX_BUFFER, &side.vertices);
        @memcpy(bytes[0..@sizeOf(@TypeOf(geometry))], std.mem.asBytes(&geometry));
        bytes = try side.buffer(@sizeOf(@TypeOf(instance_places)), facet.BUFFER_USAGE_VERTEX_BUFFER, &side.places);
        @memcpy(bytes[0..@sizeOf(@TypeOf(instance_places))], std.mem.asBytes(&instance_places));
        const index_bytes = @sizeOf(@TypeOf(restart_indices)) + @sizeOf(@TypeOf(indices_16)) + @sizeOf(@TypeOf(indices_32)) + 8;
        bytes = try side.buffer(index_bytes, facet.BUFFER_USAGE_INDEX_BUFFER, &side.indices);
        @memcpy(bytes[0..@sizeOf(@TypeOf(restart_indices))], std.mem.asBytes(&restart_indices));
        @memcpy(bytes[offset_16..][0..@sizeOf(@TypeOf(indices_16))], std.mem.asBytes(&indices_16));
        @memcpy(bytes[offset_32..][0..@sizeOf(@TypeOf(indices_32))], std.mem.asBytes(&indices_32));

        // The depth, in the tiles alone.
        const extent = facet.Extent3D{ .width = side.width, .height = side.height };
        try side.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, &side.depth);
        side.depth_view = try side.view(side.depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);

        for (formats, 0..) |format, f| {
            for (0..2) |with_depth| for (0..2) |load| {
                const attachments = [2]facet.AttachmentDescription{
                    .{ .format = format, .load_op = if (load != 0) .load else .clear, .store_op = .store, .final_layout = .general },
                    .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
                };
                const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
                const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
                const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = if (with_depth != 0) &depth else null };
                try expect(fb.CreateRenderPass(device, &.{ .attachment_count = @intCast(1 + with_depth), .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.passes[f][with_depth][load]), error.Refused);
            };
            const block = try side.imageGiving(.{ .format = format, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE, &side.pictures[f]);
            side.picture_views[f] = try side.view(side.pictures[f].?, format, facet.IMAGE_ASPECT_COLOR, 1);
            var data: ?*anyopaque = null;
            try expect(fb.MapMemory(device, block, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
            var layout: facet.SubresourceLayout = undefined;
            fb.GetImageSubresourceLayout(device, side.pictures[f].?, &.{}, &layout);
            side.picture_bytes[f] = @as([*]const u8, @ptrCast(data.?)) + @as(usize, @intCast(layout.offset));
            side.picture_pitch[f] = @intCast(layout.row_pitch);
            for (0..2) |with_depth| {
                const views = [2]*facet.ImageView{ side.picture_views[f].?, side.depth_view.? };
                try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.passes[f][with_depth][0].?, .attachment_count = @intCast(1 + with_depth), .attachments = &views, .width = side.width, .height = side.height }, &side.framebuffers[f][with_depth]), error.Refused);
            }
            try side.image(.{ .format = format, .extent = .{ .width = texture_side, .height = texture_side }, .mip_levels = texture_levels, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, 0, &side.textures[f]);
            side.texture_views[f] = try side.view(side.textures[f].?, format, facet.IMAGE_ASPECT_COLOR, texture_levels);
        }

        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &side.set_layout), error.Refused);
        try expect(fb.CreateDescriptorPool(device, &.{ .max_sets = formats.len }, &side.descriptor_pool), error.Refused);
        const layouts: [formats.len]?*facet.DescriptorSetLayout = @splat(side.set_layout);
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = formats.len, .set_layouts = @ptrCast(&layouts) }, &side.sets), error.Refused);
        for (side.sets, side.texture_views) |set, texture_view| {
            const image_info = facet.DescriptorImageInfo{ .image_view = texture_view };
            const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        }
        try expect(fb.CreateShaderModule(device, &.{ .code = &code }, &side.module), error.Refused);
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&side.set_layout) }, &side.layout), error.Refused);
        try expect(fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &side.command_pool), error.Refused);
        var commands: [1]?*facet.CommandBuffer = undefined;
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = side.command_pool.?, .command_buffer_count = 1 }, &commands), error.Refused);
        side.commands = commands[0];
        try expect(fb.CreateFence(device, &.{}, &side.fence), error.Refused);
        try side.stageTextures();
    }

    /// Each texture's levels, a level's checks of a colour of its own, so
    /// that a level read for another shows.
    fn stageTextures(side: *Side) Failure!void {
        const fb = side.fb;
        var total: u64 = 0;
        for (formats) |format| {
            const texel_bytes: u64 = if (format == .r5g6b5_unorm_pack16) 2 else 4;
            for (0..texture_levels) |level| total += @as(u64, texture_side >> @intCast(level)) * (texture_side >> @intCast(level)) * texel_bytes;
        }
        const staged = try side.buffer(total, facet.BUFFER_USAGE_TRANSFER_SRC, &side.staging);
        try expect(fb.BeginCommandBuffer(side.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        var used: usize = 0;
        for (formats, side.textures) |format, target_image| {
            var regions: [texture_levels]facet.BufferImageCopy = undefined;
            for (&regions, 0..) |*region, l| {
                const level: u32 = @intCast(l);
                const across: u32 = texture_side >> @intCast(level);
                region.* = .{ .buffer_offset = used, .image_subresource = .{ .mip_level = level }, .image_extent = .{ .width = across, .height = across } };
                for (0..across) |y| for (0..across) |x| {
                    const texel = texelAt(level, @intCast(x), @intCast(y));
                    switch (format) {
                        .b8g8r8a8_unorm => std.mem.writeInt(u32, staged[used..][0..4], texel, .little),
                        .r8g8b8a8_unorm => std.mem.writeInt(u32, staged[used..][0..4], texel & 0xFF00_FF00 | (texel >> 16 & 0xFF) | (texel & 0xFF) << 16, .little),
                        else => {
                            const packed565: u16 = @intCast((texel >> 8 & 0xF800) | (texel >> 5 & 0x07E0) | (texel >> 3 & 0x1F));
                            std.mem.writeInt(u16, staged[used..][0..2], packed565, .little);
                        },
                    }
                    used += if (format == .r5g6b5_unorm_pack16) 2 else 4;
                };
            }
            fb.CmdCopyBufferToImage(side.commands.?, side.staging.?, target_image.?, .transfer_dst_optimal, texture_levels, &regions);
        }
        try side.submit();
    }

    fn texelAt(level: u32, x: u32, y: u32) u32 {
        const check = ((x >> 2) ^ (y >> 2)) & 1;
        const tint = 0x20 + level * 0x20;
        const r = if (check != 0) 0xF0 else tint;
        const g = if (check != 0) tint else 0x40 + x;
        const b = 0x20 + y;
        return 0xFF00_0000 | r << 16 | (g & 0xFF) << 8 | (b & 0xFF);
    }

    fn buffer(side: *Side, bytes: u64, usage: u32, into: *?*facet.Buffer) Failure![*]u8 {
        const fb = side.fb;
        try expect(fb.CreateBuffer(side.device.?, &.{ .size = bytes, .usage = usage }, into), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(side.device.?, into.*.?, &needs);
        const block = try side.allocate(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE);
        try expect(fb.BindBufferMemory(side.device.?, into.*.?, block, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(side.device.?, block, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        return @ptrCast(data.?);
    }

    fn image(side: *Side, info: facet.ImageCreateInfo, wanted: u32, into: *?*facet.Image) Failure!void {
        _ = try side.imageGiving(info, wanted, into);
    }

    fn imageGiving(side: *Side, info: facet.ImageCreateInfo, wanted: u32, into: *?*facet.Image) Failure!*facet.DeviceMemory {
        const fb = side.fb;
        try expect(fb.CreateImage(side.device.?, &info, into), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(side.device.?, into.*.?, &needs);
        const block = try side.allocate(needs, wanted);
        try expect(fb.BindImageMemory(side.device.?, into.*.?, block, 0), error.Refused);
        return block;
    }

    fn view(side: *Side, of: *facet.Image, format: facet.Format, aspect: u32, levels: u32) Failure!*facet.ImageView {
        var made: ?*facet.ImageView = null;
        try expect(side.fb.CreateImageView(side.device.?, &.{ .image = of, .format = format, .subresource_range = .{ .aspect_mask = aspect, .level_count = levels } }, &made), error.Refused);
        return made.?;
    }

    fn allocate(side: *Side, needs: facet.MemoryRequirements, wanted: u32) Failure!*facet.DeviceMemory {
        if (side.block_count == side.blocks.len) return error.NoMemory;
        for (side.memory.memory_types[0..side.memory.memory_type_count], 0..) |kind, k| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(k) != 0 and kind.property_flags & wanted == wanted) {
                const slot = &side.blocks[side.block_count];
                try expect(side.fb.AllocateMemory(side.device.?, &.{ .allocation_size = needs.size, .memory_type_index = @intCast(k) }, slot), error.NoMemory);
                side.block_count += 1;
                return slot.*.?;
            }
        }
        return error.NoMemory;
    }

    fn down(side: *Side) void {
        const fb = side.fb;
        const device = side.device orelse return;
        _ = fb.DeviceWaitIdle(device);
        fb.DestroyFence(device, side.fence);
        fb.DestroyCommandPool(device, side.command_pool);
        fb.DestroyPipelineLayout(device, side.layout);
        fb.DestroyShaderModule(device, side.module);
        fb.DestroyDescriptorPool(device, side.descriptor_pool);
        fb.DestroyDescriptorSetLayout(device, side.set_layout);
        for (&side.framebuffers) |*pair| for (pair) |each| fb.DestroyFramebuffer(device, each);
        for (side.picture_views) |each| fb.DestroyImageView(device, each);
        for (side.pictures) |each| fb.DestroyImage(device, each);
        for (side.texture_views) |each| fb.DestroyImageView(device, each);
        for (side.textures) |each| fb.DestroyImage(device, each);
        fb.DestroyImageView(device, side.depth_view);
        fb.DestroyImage(device, side.depth);
        for (&side.passes) |*by_depth| for (by_depth) |*by_load| for (by_load) |each| fb.DestroyRenderPass(device, each);
        fb.DestroyBuffer(device, side.vertices);
        fb.DestroyBuffer(device, side.places);
        fb.DestroyBuffer(device, side.indices);
        fb.DestroyBuffer(device, side.staging);
        for (side.blocks[0..side.block_count]) |block| fb.FreeMemory(device, block);
        fb.DestroyDevice(device);
        side.device = null;
    }

    fn submit(side: *Side) Failure!void {
        const fb = side.fb;
        try expect(fb.EndCommandBuffer(side.commands.?), error.Refused);
        const info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&side.commands) };
        try expect(fb.QueueSubmit(side.queue, 1, @ptrCast(&info), side.fence), error.Refused);
        try expect(fb.WaitForFences(side.device.?, 1, @ptrCast(&side.fence), true, facet.WAIT_FOREVER_NS), error.Refused);
        try expect(fb.ResetFences(side.device.?, 1, @ptrCast(&side.fence)), error.Refused);
    }

    /// A pass begun over the picture, the whole viewport and scissor set and
    /// the vertex buffers bound.
    fn begin(side: *Side, pass: Pass) void {
        const fb = side.fb;
        const commands = side.commands.?;
        const t = @intFromEnum(pass.target);
        const d = @intFromBool(pass.depth);
        const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = pass.clear } }, .{ .depth_stencil = .{ .depth = 1 } } };
        const area: facet.Rect2D = if (pass.area) |part| .{
            .offset = .{ .x = side.partOf(side.width, part[0]), .y = side.partOf(side.height, part[1]) },
            .extent = .{
                .width = @intCast(side.partOf(side.width, part[2]) - side.partOf(side.width, part[0])),
                .height = @intCast(side.partOf(side.height, part[3]) - side.partOf(side.height, part[1])),
            },
        } else .{ .extent = .{ .width = side.width, .height = side.height } };
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = side.passes[t][d][@intFromBool(pass.load)].?, .framebuffer = side.framebuffers[t][d].?, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        side.setViewport(0, 0, @floatFromInt(side.width), @floatFromInt(side.height), 0, 1);
        const whole = facet.Rect2D{ .extent = .{ .width = side.width, .height = side.height } };
        fb.CmdSetScissor(commands, 0, 1, @ptrCast(&whole));
        const buffers = [2]*facet.Buffer{ side.vertices.?, side.places.? };
        const offsets = [2]u64{ 0, 0 };
        fb.CmdBindVertexBuffers(commands, 0, 2, &buffers, &offsets);
    }

    fn partOf(_: *const Side, whole: u32, part: f32) i32 {
        return @intFromFloat(@as(f32, @floatFromInt(whole)) * part);
    }

    fn setViewport(side: *Side, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        const viewport = facet.Viewport{ .x = x, .y = y, .width = width, .height = height, .min_depth = min_depth, .max_depth = max_depth };
        side.fb.CmdSetViewport(side.commands.?, 0, 1, @ptrCast(&viewport));
    }

    fn end(side: *Side) void {
        side.fb.CmdEndRenderPass(side.commands.?);
    }

    /// A pipeline as `options` say, made for this case and bound.
    fn use(side: *Side, options: Options) Failure!void {
        const fb = side.fb;
        const stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = side.module.?, .name = options.vertex },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = side.module.?, .name = options.fragment },
        };
        const bindings = [2]facet.VertexInputBindingDescription{
            .{ .binding = 0, .stride = @sizeOf(Vertex) },
            .{ .binding = 1, .stride = @sizeOf([2]f32), .input_rate = .instance },
        };
        const attributes = [4]facet.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "p") },
            .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "c") },
            .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 3, .binding = 1, .format = .r32g32_sfloat },
        };
        const input = facet.PipelineVertexInputStateCreateInfo{ .vertex_binding_description_count = 2, .vertex_binding_descriptions = &bindings, .vertex_attribute_description_count = 4, .vertex_attribute_descriptions = &attributes };
        const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = options.topology, .primitive_restart_enable = options.restart };
        const viewports = facet.PipelineViewportStateCreateInfo{};
        const dynamic_states = [2]facet.DynamicState{ .viewport, .scissor };
        const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = 2, .dynamic_states = &dynamic_states };
        const rasterization = facet.PipelineRasterizationStateCreateInfo{ .cull_mode = options.cull, .front_face = options.front };
        const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = options.test_depth, .depth_write_enable = options.write_depth, .depth_compare_op = options.compare };
        const blend_attachment = facet.PipelineColorBlendAttachmentState{
            .blend_enable = options.blend,
            .src_color_blend_factor = if (options.blend) .src_alpha else .one,
            .dst_color_blend_factor = if (options.blend) .one_minus_src_alpha else .zero,
            .src_alpha_blend_factor = if (options.blend) .src_alpha else .one,
            .dst_alpha_blend_factor = if (options.blend) .one_minus_src_alpha else .zero,
        };
        const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&blend_attachment) };
        const info = facet.GraphicsPipelineCreateInfo{
            .stage_count = 2,
            .stages = &stages,
            .vertex_input_state = &input,
            .input_assembly_state = &assembly,
            .viewport_state = &viewports,
            .rasterization_state = &rasterization,
            .depth_stencil_state = &depth,
            .color_blend_state = &blend,
            .dynamic_state = &dynamic,
            .layout = side.layout.?,
            .render_pass = side.passes[@intFromEnum(options.target)][@intFromBool(options.depth)][@intFromBool(options.load)].?,
        };
        const slot = &side.made[side.made_count];
        var made: [1]?*facet.Pipeline = undefined;
        try expect(fb.CreateGraphicsPipelines(side.device.?, null, 1, @ptrCast(&info), &made), error.Refused);
        slot.* = made[0];
        side.made_count += 1;
        fb.CmdBindPipeline(side.commands.?, .graphics, made[0].?);
    }

    fn forgetPipelines(side: *Side) void {
        for (side.made[0..side.made_count]) |each| side.fb.DestroyPipeline(side.device.?, each);
        side.made_count = 0;
    }

    fn draw(side: *Side, first: u32, count: u32) void {
        side.fb.CmdDraw(side.commands.?, count, 1, first, 0);
    }

    fn texture(side: *Side, format: usize) void {
        side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.layout.?, 0, 1, @ptrCast(&side.sets[format]), 0, null);
    }
};

const offset_16 = @sizeOf(@TypeOf(restart_indices)) + 2;
const offset_32 = (offset_16 + @sizeOf(@TypeOf(indices_16)) + 3) / 4 * 4;

const Case = struct {
    name: [*:0]const u8,
    target: Target = .bgra,
    run: *const fn (side: *Side) Failure!void,
};

const Cases = struct {
    fn clear(side: *Side) Failure!void {
        side.begin(.{});
        side.end();
    }
    fn triangles(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn strip(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_strip });
        side.draw(strip_at, 5);
        side.end();
    }
    fn fan(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_fan });
        side.draw(fan_at, 5);
        side.end();
    }
    fn restart(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_strip, .restart = true });
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, 0, .uint16);
        side.fb.CmdDrawIndexed(side.commands.?, restart_indices.len, 1, 0, strip_at, 0);
        side.end();
    }
    fn indexed16(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, offset_16, .uint16);
        side.fb.CmdDrawIndexed(side.commands.?, indices_16.len, 1, 0, counter_at, 0);
        side.end();
    }
    fn indexed32(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, offset_32, .uint32);
        side.fb.CmdDrawIndexed(side.commands.?, indices_32.len, 1, 0, 0, 0);
        side.end();
    }
    fn instances(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .blend = true });
        side.fb.CmdDraw(side.commands.?, 3, instance_places.len, glass_at, 0);
        side.end();
    }
    fn cullBack(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_BACK, .front = .clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn cullFront(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_FRONT, .front = .clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn cullBackCounter(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_BACK, .front = .counter_clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn depthLess(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.draw(near_at, 3);
        side.end();
    }
    fn depthNearFirst(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn depthGreater(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true, .compare = .always });
        side.draw(near_at, 3);
        try side.use(.{ .test_depth = true, .write_depth = true, .compare = .greater });
        side.draw(far_at, 3);
        side.end();
    }
    fn depthNoWrite(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = false });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn noDepthAttachment(side: *Side) Failure!void {
        side.begin(.{ .depth = false });
        try side.use(.{ .depth = false });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn blend(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        try side.use(.{ .blend = true });
        side.draw(glass_at, 3);
        side.end();
    }
    fn scissor(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        const part = facet.Rect2D{
            .offset = .{ .x = @intCast(side.width / 5), .y = @intCast(side.height / 4) },
            .extent = .{ .width = side.width / 2, .height = side.height / 3 },
        };
        side.fb.CmdSetScissor(side.commands.?, 0, 1, @ptrCast(&part));
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn viewport(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        const w: f32 = @floatFromInt(side.width);
        const h: f32 = @floatFromInt(side.height);
        side.setViewport(w * 0.3, h * 0.2, w * 0.6, h * 0.7, 0, 1);
        side.draw(clockwise_at, 6);
        side.setViewport(-w * 0.2, -h * 0.25, w * 0.6, h * 0.7, 0, 1);
        side.draw(strip_at, 3);
        side.end();
    }
    fn depthRange(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        const w: f32 = @floatFromInt(side.width);
        const h: f32 = @floatFromInt(side.height);
        side.setViewport(0, 0, w, h, 0.5, 1);
        side.draw(near_at, 3);
        side.setViewport(0, 0, w, h, 0, 0.5);
        side.draw(far_at, 3);
        side.end();
    }
    fn behind(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(behind_at, 3);
        side.end();
    }
    fn areaClear(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.end();
    }
    fn areaClearDraw(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.draw(near_at, 3);
        side.end();
    }
    fn areaKeep(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true, .area = .{ 0.25, 0.25, 0.75, 0.75 } });
        try side.use(.{ .load = true, .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.end();
    }
    fn wholeKeep(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true });
        try side.use(.{ .load = true, .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.end();
    }
    fn areaTexture(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.texture(0);
        try side.use(.{ .vertex = "texture", .fragment = "nearest", .test_depth = true, .write_depth = true });
        side.draw(quad_at, 6);
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.end();
    }
    fn areaTextureOnly(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.texture(0);
        try side.use(.{ .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn keptTexture(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true });
        side.texture(0);
        try side.use(.{ .load = true, .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn partKeptTexture(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true, .area = .{ 0.25, 0.25, 0.75, 0.75 } });
        side.texture(0);
        try side.use(.{ .load = true, .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn areaColorOnly(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
    }
    fn areaColorDepth(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.end();
    }
    fn underTexture(comptime load: bool, comptime part: bool, comptime tested: bool) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.end();
                side.begin(.{ .load = load, .area = if (part) .{ 0.125, 0.125, 0.875, 0.875 } else null });
                side.texture(0);
                try side.use(.{ .load = load, .test_depth = tested, .write_depth = tested });
                side.draw(far_at, 3);
                try side.use(.{ .load = load, .vertex = "texture", .fragment = "nearest", .test_depth = tested, .write_depth = tested });
                side.draw(quad_at, 6);
                side.end();
            }
        }.run;
    }
    fn textured(comptime fragment: [*:0]const u8, comptime format: usize, comptime first: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.texture(format);
                try side.use(.{ .vertex = "texture", .fragment = fragment });
                side.draw(first, 6);
                side.end();
            }
        }.run;
    }
    fn modulate(side: *Side) Failure!void {
        side.begin(.{});
        side.texture(0);
        try side.use(.{ .vertex = "modulate", .fragment = "modulate" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn missing(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn onTarget(comptime target: Target) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{ .target = target });
                try side.use(.{ .target = target });
                side.draw(clockwise_at, 6);
                try side.use(.{ .target = target, .blend = true });
                side.draw(glass_at, 3);
                side.end();
            }
        }.run;
    }
};

const cases = [_]Case{
    .{ .name = "clear", .run = &Cases.clear },
    .{ .name = "triangles", .run = &Cases.triangles },
    .{ .name = "strip", .run = &Cases.strip },
    .{ .name = "fan", .run = &Cases.fan },
    .{ .name = "restart", .run = &Cases.restart },
    .{ .name = "indices of 16 bits", .run = &Cases.indexed16 },
    .{ .name = "indices of 32 bits", .run = &Cases.indexed32 },
    .{ .name = "instances", .run = &Cases.instances },
    .{ .name = "cull back", .run = &Cases.cullBack },
    .{ .name = "cull front", .run = &Cases.cullFront },
    .{ .name = "cull back, front the other way", .run = &Cases.cullBackCounter },
    .{ .name = "depth, far first", .run = &Cases.depthLess },
    .{ .name = "depth, near first", .run = &Cases.depthNearFirst },
    .{ .name = "depth, greater", .run = &Cases.depthGreater },
    .{ .name = "depth, not written", .run = &Cases.depthNoWrite },
    .{ .name = "no depth attachment", .run = &Cases.noDepthAttachment },
    .{ .name = "blend", .run = &Cases.blend },
    .{ .name = "scissor", .run = &Cases.scissor },
    .{ .name = "viewport", .run = &Cases.viewport },
    .{ .name = "depth range", .run = &Cases.depthRange },
    .{ .name = "a corner behind the eye", .run = &Cases.behind },
    .{ .name = "part cleared", .run = &Cases.areaClear },
    .{ .name = "part cleared, drawn with depth", .run = &Cases.areaClearDraw },
    .{ .name = "part kept, drawn with depth", .run = &Cases.areaKeep },
    .{ .name = "all kept, drawn with depth", .run = &Cases.wholeKeep },
    .{ .name = "part cleared, texture and colour with depth", .run = &Cases.areaTexture },
    .{ .name = "part cleared, one colour", .run = &Cases.areaColorOnly },
    .{ .name = "part cleared, one with depth", .run = &Cases.areaColorDepth },
    .{ .name = "part cleared, texture alone", .run = &Cases.areaTextureOnly },
    .{ .name = "all kept, texture", .run = &Cases.keptTexture },
    .{ .name = "part kept, texture", .run = &Cases.partKeptTexture },
    .{ .name = "under: cleared, all", .run = Cases.underTexture(false, false, false) },
    .{ .name = "under: cleared, all, depth", .run = Cases.underTexture(false, false, true) },
    .{ .name = "under: kept, all", .run = Cases.underTexture(true, false, false) },
    .{ .name = "under: kept, all, depth", .run = Cases.underTexture(true, false, true) },
    .{ .name = "under: kept, part", .run = Cases.underTexture(true, true, false) },
    .{ .name = "under: kept, part, depth", .run = Cases.underTexture(true, true, true) },
    .{ .name = "texture bilinear", .run = Cases.textured("texture", 0, quad_at) },
    .{ .name = "texture nearest", .run = Cases.textured("nearest", 0, quad_at) },
    .{ .name = "texture repeated", .run = Cases.textured("nearest", 0, wide_at) },
    .{ .name = "texture clamped", .run = Cases.textured("clamp", 0, wide_at) },
    .{ .name = "texture in rgba", .run = Cases.textured("nearest", 1, quad_at) },
    .{ .name = "texture in 565", .run = Cases.textured("nearest 565", 2, quad_at) },
    .{ .name = "texture times colour", .run = &Cases.modulate },
    .{ .name = "no texture", .run = &Cases.missing },
    .{ .name = "drawn in rgba", .target = .rgba, .run = Cases.onTarget(.rgba) },
    .{ .name = "drawn in 565", .target = .rgb565, .run = Cases.onTarget(.rgb565) },
};

/// How far apart two pixels are, in the channel furthest apart: in steps of
/// a channel of 8 bits, or of 565.
fn apart(target: Target, one: [*]const u8, other: [*]const u8) u32 {
    var most: u32 = 0;
    if (target == .rgb565) {
        const a: u32 = std.mem.readInt(u16, one[0..2], .little);
        const b: u32 = std.mem.readInt(u16, other[0..2], .little);
        for ([_]u5{ 0, 5, 11 }, [_]u32{ 0x1F, 0x3F, 0x1F }) |shift, mask| {
            const x: i32 = @intCast(a >> shift & mask);
            const y: i32 = @intCast(b >> shift & mask);
            most = @max(most, @abs(x - y));
        }
        return most;
    }
    for (0..4) |k| {
        const x: i32 = one[k];
        const y: i32 = other[k];
        most = @max(most, @abs(x - y));
    }
    return most;
}

fn compare(dl: *DosBase, case: *const Case, cores: *const Side, gpu: *const Side) bool {
    const t = @intFromEnum(case.target);
    const bytes: usize = if (case.target == .rgb565) 2 else 4;
    // 565 is dithered on the cores: a step either way is no difference.
    const slack: u32 = if (case.target == .rgb565) 1 else 2;
    var wrong: u64 = 0;
    var worst: u32 = 0;
    var first_x: usize = 0;
    var first_y: usize = 0;
    var first_cores: u32 = 0;
    var first_gpu: u32 = 0;
    for (0..cores.height) |y| {
        const on_cores = cores.picture_bytes[t] + y * cores.picture_pitch[t];
        const on_gpu = gpu.picture_bytes[t] + y * gpu.picture_pitch[t];
        for (0..cores.width) |x| {
            const distance = apart(case.target, on_cores + x * bytes, on_gpu + x * bytes);
            worst = @max(worst, distance);
            if (distance <= slack) continue;
            if (wrong == 0) {
                first_x = x;
                first_y = y;
                first_cores = pixelAt(on_cores + x * bytes, bytes);
                first_gpu = pixelAt(on_gpu + x * bytes, bytes);
            }
            wrong += 1;
        }
    }
    const pixels = @as(u64, cores.width) * cores.height;
    _ = Printf(dl, "%s: %lu of %lu apart, %lu at worst\n", .{ case.name, wrong, pixels, @as(u64, worst) });
    if (wrong != 0) _ = Printf(dl, "  the first at %lu,%lu: %08lx on the cores, %08lx on the other\n", .{ @as(u64, first_x), @as(u64, first_y), @as(u64, first_cores), @as(u64, first_gpu) });
    const like = wrong <= pixels / 1000;
    if (!like) printMap(dl, case.target, cores, gpu, slack);
    return like;
}

/// Where the pixels apart are, a letter for each part of the picture: `.`
/// none, then more of them.
fn printMap(dl: *DosBase, target: Target, cores: *const Side, gpu: *const Side, slack: u32) void {
    const across = 64;
    const down = 24;
    const t = @intFromEnum(target);
    const bytes: usize = if (target == .rgb565) 2 else 4;
    for (0..down) |row| {
        var line: [across + 1:0]u8 = undefined;
        for (0..across) |column| {
            const left = column * cores.width / across;
            const right = (column + 1) * cores.width / across;
            const top = row * cores.height / down;
            const bottom = (row + 1) * cores.height / down;
            var seen: usize = 0;
            for (top..bottom) |y| for (left..right) |x| {
                const on_cores = cores.picture_bytes[t] + y * cores.picture_pitch[t] + x * bytes;
                const on_gpu = gpu.picture_bytes[t] + y * gpu.picture_pitch[t] + x * bytes;
                if (apart(target, on_cores, on_gpu) > slack) seen += 1;
            };
            line[column] = if (seen == 0) '.' else if (seen * 4 < (right - left) * (bottom - top)) '-' else '#';
        }
        line[across] = '\n';
        line[across + 1] = 0;
        _ = Printf(dl, "%s", .{@as([*:0]const u8, &line)});
    }
}

fn pixelAt(at_pixel: [*]const u8, bytes: usize) u32 {
    return if (bytes == 2) std.mem.readInt(u16, at_pixel[0..2], .little) else std.mem.readInt(u32, at_pixel[0..4], .little);
}

fn parseSize(text: [*:0]const u8) ?[2]u32 {
    var sides = [2]u32{ 0, 0 };
    var side: usize = 0;
    var k: usize = 0;
    while (text[k] != 0) : (k += 1) {
        if (text[k] == 'x' and side == 0) {
            side = 1;
        } else if (text[k] >= '0' and text[k] <= '9') {
            sides[side] = sides[side] * 10 + (text[k] - '0');
        } else return null;
    }
    if (side != 1 or sides[0] == 0 or sides[1] == 0) return null;
    return sides;
}

fn named(case: *const Case, only: ?[*:0]const u8) bool {
    const wanted = std.mem.span(only orelse return true);
    return std.mem.indexOf(u8, std.mem.span(case.name), wanted) != null;
}

fn runAll(dl: *DosBase, cores: *Side, gpu: *Side, only: ?[*:0]const u8) Failure!i32 {
    try cores.up();
    try gpu.up();
    var result: i32 = dos.RETURN_OK;
    for (&cases) |*case| {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        if (!named(case, only)) continue;
        for ([2]*Side{ cores, gpu }) |side| {
            try Side.expect(side.fb.BeginCommandBuffer(side.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
            try case.run(side);
            try side.submit();
            side.forgetPipelines();
        }
        if (!compare(dl, case, cores, gpu)) result = dos.RETURN_WARN;
    }
    return result;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const size: [2]u32 = if (argv[0] != 0) parseSize(@ptrFromInt(argv[0])) orelse {
        _ = Printf(dl, "SIZE is WIDTHxHEIGHT\n", .{});
        return dos.RETURN_FAIL;
    } else .{ 640, 360 };

    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{facet.FACETNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(facet_lib);
    const fb: *FacetBase = @ptrCast(facet_lib);
    var instance: ?*facet.Instance = null;
    if (fb.CreateInstance(&.{ .application_name = COMMAND_NAME }, &instance) != .success) return dos.RETURN_FAIL;
    defer fb.DestroyInstance(instance.?);
    var count: u32 = 2;
    var physical: [2]*facet.PhysicalDevice = undefined;
    if (fb.EnumeratePhysicalDevices(instance.?, &count, &physical) != .success or count < 2) {
        _ = Printf(dl, "There is no device after the cores to compare\n", .{});
        return dos.RETURN_WARN;
    }
    var cores = Side{ .fb = fb, .width = size[0], .height = size[1], .physical = physical[0] };
    var gpu = Side{ .fb = fb, .width = size[0], .height = size[1], .physical = physical[1] };
    defer cores.down();
    defer gpu.down();
    const only: ?[*:0]const u8 = if (argv[1] != 0) @ptrFromInt(argv[1]) else null;
    return runAll(dl, &cores, &gpu, only) catch |err| {
        _ = Printf(dl, "It stopped: %s\n", .{@as([*:0]const u8, switch (err) {
            error.NoMemory => "not enough memory",
            error.NoDevice => "no device",
            error.Refused => "facet.library refused something",
            error.DeviceLost => "the device is lost",
        })});
        return dos.RETURN_FAIL;
    };
}
