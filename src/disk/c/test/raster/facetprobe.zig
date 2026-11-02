// SPDX-License-Identifier: MIT
//! FacetProbe: what facet.library's newer corners do on the real machine,
//! checked on each of its devices in turn - which is what the host tests
//! cannot do, there being no V3D on the host.
//!
//!   FacetProbe CORES/S,V3D/S,QUIET/S
//!
//! It draws into images of its own and reads them back, so it opens no
//! screen and shows nothing. Every check prints a line - `ok` or `FAILED`
//! and why - unless QUIET, which prints the failures and the count alone.
//! With neither switch it runs on every device the instance lists, the
//! cores first; CORES or V3D picks one. It returns WARN where a check
//! failed and OK where none did, so a script can ask.
//!
//! A check says what it expects of the device it is on: where a feature is
//! one device's and not another's (`GetPhysicalDeviceFeatures`), what is
//! checked is that the calls agree with the feature, not that the feature
//! is true. So the same run passes on the cores and on the V3D, and fails
//! where a driver says one thing and does another.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FacetBase = sdk.interface.facet.FacetBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FacetProbe";
const VERSION_STRING = "\x00$VER: FacetProbe 1.0 (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CORES/S,V3D/S,QUIET/S";

/// The side of the pictures drawn into: two tiles across, so that what is
/// written back tile by tile is seen as well.
const side = 64;

/// Everything made through facet.library on one device, given back by
/// `down` in the order it goes.
const Probe = struct {
    fb: *FacetBase,
    dl: *DosBase,
    quiet: bool,
    instance: *facet.Instance,
    physical: *facet.PhysicalDevice,
    features: facet.PhysicalDeviceFeatures = undefined,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    pool: ?*facet.CommandPool = null,
    commands: *facet.CommandBuffer = undefined,
    fence: ?*facet.Fence = null,
    /// What a check made and `give` gives back, newest first.
    memories: [12]?*facet.DeviceMemory = @splat(null),
    images: [8]?*facet.Image = @splat(null),
    views: [8]?*facet.ImageView = @splat(null),
    buffers: [8]?*facet.Buffer = @splat(null),
    passes: [8]?*facet.RenderPass = @splat(null),
    frames: [8]?*facet.Framebuffer = @splat(null),
    modules: [2]?*facet.ShaderModule = @splat(null),
    layouts: [2]?*facet.PipelineLayout = @splat(null),
    pipelines: [4]?*facet.Pipeline = @splat(null),
    passed: u32 = 0,
    failed: u32 = 0,

    fn up(fb: *FacetBase, dl: *DosBase, instance: *facet.Instance, physical: *facet.PhysicalDevice, quiet: bool) ?Probe {
        var probe = Probe{ .fb = fb, .dl = dl, .quiet = quiet, .instance = instance, .physical = physical };
        fb.GetPhysicalDeviceFeatures(physical, &probe.features);
        fb.GetPhysicalDeviceMemoryProperties(physical, &probe.memory);
        const queue_info = facet.DeviceQueueCreateInfo{};
        if (fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &probe.device) != .success) return null;
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(probe.device.?, 0, 0, &queue);
        probe.queue = queue orelse return null;
        if (fb.CreateCommandPool(probe.device.?, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &probe.pool) != .success) return null;
        var commands: [1]?*facet.CommandBuffer = undefined;
        if (fb.AllocateCommandBuffers(probe.device.?, &.{ .command_pool = probe.pool.?, .command_buffer_count = 1 }, &commands) != .success) return null;
        probe.commands = commands[0] orelse return null;
        if (fb.CreateFence(probe.device.?, &.{}, &probe.fence) != .success) return null;
        return probe;
    }

    fn down(probe: *Probe) void {
        const fb = probe.fb;
        const device = probe.device orelse return;
        _ = fb.DeviceWaitIdle(device);
        probe.give();
        fb.DestroyFence(device, probe.fence);
        fb.DestroyCommandPool(device, probe.pool);
        fb.DestroyDevice(device);
    }

    /// What the checks made given back, in the reverse order of its making.
    fn give(probe: *Probe) void {
        const fb = probe.fb;
        const device = probe.device.?;
        _ = fb.DeviceWaitIdle(device);
        for (&probe.pipelines) |*each| take(each, fb, device, FacetBase.DestroyPipeline);
        for (&probe.layouts) |*each| take(each, fb, device, FacetBase.DestroyPipelineLayout);
        for (&probe.modules) |*each| take(each, fb, device, FacetBase.DestroyShaderModule);
        for (&probe.frames) |*each| take(each, fb, device, FacetBase.DestroyFramebuffer);
        for (&probe.passes) |*each| take(each, fb, device, FacetBase.DestroyRenderPass);
        for (&probe.views) |*each| take(each, fb, device, FacetBase.DestroyImageView);
        for (&probe.images) |*each| take(each, fb, device, FacetBase.DestroyImage);
        for (&probe.buffers) |*each| take(each, fb, device, FacetBase.DestroyBuffer);
        for (&probe.memories) |*each| take(each, fb, device, FacetBase.FreeMemory);
    }

    fn take(slot: anytype, fb: *FacetBase, device: *facet.Device, destroy: anytype) void {
        if (slot.*) |each| destroy(fb, device, each);
        slot.* = null;
    }

    /// `made` kept in `slots` so that `give` gives it back; null when there
    /// is no room, which a check then fails on.
    fn keep(slots: anytype, made: anytype) @TypeOf(made) {
        for (slots) |*slot| {
            if (slot.* == null) {
                slot.* = made;
                return made;
            }
        }
        return null;
    }

    /// A block of memory as `needs` says, of the first type with `wanted`.
    fn block(probe: *Probe, needs: facet.MemoryRequirements, wanted: u32) ?*facet.DeviceMemory {
        const types = probe.memory.memory_types[0..probe.memory.memory_type_count];
        for (types, 0..) |each, index| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(index) == 0) continue;
            if (each.property_flags & wanted != wanted) continue;
            var made: ?*facet.DeviceMemory = null;
            if (probe.fb.AllocateMemory(probe.device.?, &.{ .allocation_size = needs.size, .memory_type_index = @intCast(index) }, &made) != .success) return null;
            return keep(&probe.memories, made);
        }
        return null;
    }

    /// A buffer of `bytes` the program can read, and its bytes.
    fn buffer(probe: *Probe, bytes: u64, usage: u32) ?struct { *facet.Buffer, [*]u8 } {
        const fb = probe.fb;
        const device = probe.device.?;
        var made: ?*facet.Buffer = null;
        if (fb.CreateBuffer(device, &.{ .size = bytes, .usage = usage }, &made) != .success) return null;
        const held = keep(&probe.buffers, made) orelse return null;
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(device, held, &needs);
        const memory = probe.block(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse return null;
        if (fb.BindBufferMemory(device, held, memory, 0) != .success) return null;
        var data: ?*anyopaque = null;
        if (fb.MapMemory(device, memory, 0, facet.WHOLE_SIZE, 0, &data) != .success) return null;
        return .{ held, @ptrCast(data.?) };
    }

    /// An image as `info` says, bound into memory with `wanted`, and a view
    /// of it; `null` for either where the call refused.
    fn image(probe: *Probe, info: facet.ImageCreateInfo, wanted: u32) ?struct { *facet.Image, *facet.ImageView } {
        const fb = probe.fb;
        const device = probe.device.?;
        var made: ?*facet.Image = null;
        if (fb.CreateImage(device, &info, &made) != .success) return null;
        const held = keep(&probe.images, made) orelse return null;
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, held, &needs);
        const memory = probe.block(needs, wanted) orelse return null;
        if (fb.BindImageMemory(device, held, memory, 0) != .success) return null;
        const aspect: u32 = if (info.format == .d16_unorm) facet.IMAGE_ASPECT_DEPTH else facet.IMAGE_ASPECT_COLOR;
        var view: ?*facet.ImageView = null;
        if (fb.CreateImageView(device, &.{ .image = held, .format = info.format, .subresource_range = .{ .aspect_mask = aspect } }, &view) != .success) return null;
        return .{ held, keep(&probe.views, view) orelse return null };
    }

    /// The bytes of an image the program reads directly, and its pitch.
    fn mapped(probe: *Probe, made: *facet.Image, memory: *facet.DeviceMemory) ?struct { [*]const u8, u32 } {
        var data: ?*anyopaque = null;
        if (probe.fb.MapMemory(probe.device.?, memory, 0, facet.WHOLE_SIZE, 0, &data) != .success) return null;
        var layout: facet.SubresourceLayout = undefined;
        probe.fb.GetImageSubresourceLayout(probe.device.?, made, &.{}, &layout);
        return .{ @as([*]const u8, @ptrCast(data.?)) + @as(usize, @intCast(layout.offset)), @intCast(layout.row_pitch) };
    }

    fn renderPass(probe: *Probe, info: facet.RenderPassCreateInfo) ?*facet.RenderPass {
        var made: ?*facet.RenderPass = null;
        if (probe.fb.CreateRenderPass(probe.device.?, &info, &made) != .success) return null;
        return keep(&probe.passes, made);
    }

    fn framebuffer(probe: *Probe, pass: *facet.RenderPass, views: []const *facet.ImageView) ?*facet.Framebuffer {
        var made: ?*facet.Framebuffer = null;
        if (probe.fb.CreateFramebuffer(probe.device.?, &.{ .render_pass = pass, .attachment_count = @intCast(views.len), .attachments = views.ptr, .width = side, .height = side }, &made) != .success) return null;
        return keep(&probe.frames, made);
    }

    /// The command buffer, begun.
    fn record(probe: *Probe) ?*facet.CommandBuffer {
        if (probe.fb.BeginCommandBuffer(probe.commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }) != .success) return null;
        return probe.commands;
    }

    /// The command buffer ended, submitted and waited for.
    fn submit(probe: *Probe) bool {
        const fb = probe.fb;
        if (fb.EndCommandBuffer(probe.commands) != .success) return false;
        if (fb.ResetFences(probe.device.?, 1, @ptrCast(&probe.fence)) != .success) return false;
        const info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&probe.commands) };
        if (fb.QueueSubmit(probe.queue, 1, @ptrCast(&info), probe.fence) != .success) return false;
        return fb.WaitForFences(probe.device.?, 1, @ptrCast(&probe.fence), true, facet.WAIT_FOREVER_NS) == .success;
    }

    /// One check: `ok`, said with its name, and counted.
    fn check(probe: *Probe, ok: bool, name: [*:0]const u8) void {
        if (ok) {
            probe.passed += 1;
            if (!probe.quiet) _ = Printf(probe.dl, "  ok      %s\n", .{name});
        } else {
            probe.failed += 1;
            _ = Printf(probe.dl, "  FAILED  %s\n", .{name});
        }
    }

    /// One check with two numbers said where it failed.
    fn checkEqual(probe: *Probe, wanted: u64, found: u64, name: [*:0]const u8) void {
        if (wanted == found) return probe.check(true, name);
        probe.failed += 1;
        _ = Printf(probe.dl, "  FAILED  %s: wanted %lu, found %lu\n", .{ name, wanted, found });
    }
};

// --- the shaders the probe draws with ----------------------------------------

/// One colour, the push constants', over triangles whose vertices are
/// three floats at location 0, already in clip space.
const Flat = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn fragment(fragments: *const facet.shader.Fragments) callconv(.c) void {
        facet.shader.fill(fragments, fragments.resources.constants(u32).*);
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 0),
        facet.shader.fragment("main", &fragment, 0),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// A pipeline of `Flat` over `pass`, depth tested and written.
fn flatPipeline(probe: *Probe, pass: *facet.RenderPass, module: *facet.ShaderModule, layout: *facet.PipelineLayout) ?*facet.Pipeline {
    const stages = [2]facet.PipelineShaderStageCreateInfo{
        .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module, .name = "main" },
        .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module, .name = "main" },
    };
    const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = 12 };
    const attribute = facet.VertexInputAttributeDescription{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat };
    const input = facet.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = 1,
        .vertex_attribute_descriptions = @ptrCast(&attribute),
    };
    const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list };
    const viewport = facet.Viewport{ .width = side, .height = side };
    const scissor = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
    const raster = facet.PipelineRasterizationStateCreateInfo{};
    const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    const blends: [1]facet.PipelineColorBlendAttachmentState = @splat(.{});
    const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = &blends };
    const dynamic = facet.PipelineDynamicStateCreateInfo{};
    const info = facet.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .stages = &stages,
        .vertex_input_state = &input,
        .input_assembly_state = &assembly,
        .viewport_state = &view,
        .rasterization_state = &raster,
        .depth_stencil_state = &depth,
        .color_blend_state = &blend,
        .dynamic_state = &dynamic,
        .layout = layout,
        .render_pass = pass,
    };
    var made: [1]?*facet.Pipeline = undefined;
    if (probe.fb.CreateGraphicsPipelines(probe.device.?, null, 1, @ptrCast(&info), &made) != .success) return null;
    return Probe.keep(&probe.pipelines, made[0]);
}

/// A pass of a colour attachment and a depth one, the depth kept as the ops
/// say.
fn passKeeping(probe: *Probe, color_load: facet.AttachmentLoadOp, load: facet.AttachmentLoadOp, store: facet.AttachmentStoreOp) ?*facet.RenderPass {
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = color_load, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .d16_unorm, .load_op = load, .store_op = store, .final_layout = .depth_stencil_attachment_optimal },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    return probe.renderPass(.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) });
}

// --- 1.30: a depth attachment that outlives its pass -------------------------

/// A depth read back into a buffer, `side` pixels a row, 16 bits each.
fn depthAt(bytes: [*]const u8, x: u32, y: u32) u16 {
    return std.mem.readInt(u16, bytes[(y * side + x) * 2 ..][0..2], .little);
}

fn depthChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    if (!probe.features.stored_depth) {
        // The device keeps no depth: the pass that asks for one is refused,
        // and one that keeps none is made.
        probe.check(passKeeping(probe, .clear, .clear, .store) == null, "a stored depth refused where the device keeps none");
        probe.check(passKeeping(probe, .clear, .load, .dont_care) == null, "a loaded depth refused the same way");
        probe.check(passKeeping(probe, .clear, .clear, .dont_care) != null, "a depth that stays in the tiles is still taken");
        return;
    }

    const storing = passKeeping(probe, .clear, .clear, .store) orelse return probe.check(false, "a pass that stores its depth");
    probe.check(true, "a pass that stores its depth");
    const loading = passKeeping(probe, .load, .load, .store) orelse return probe.check(false, "a pass that loads its depth");
    probe.check(true, "a pass that loads its depth");

    const extent = facet.Extent3D{ .width = side, .height = side };
    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC }, 0) orelse
        return probe.check(false, "a depth image with memory behind it");
    probe.check(true, "a depth image with memory behind it");
    const frame = probe.framebuffer(storing, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");
    const after = probe.framebuffer(loading, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer for the second pass");

    // A transient depth image has no memory, so a pass that stores into it
    // is refused its framebuffer.
    const transient = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED);
    if (transient) |one| {
        probe.check(probe.framebuffer(storing, &.{ color[1], one[1] }) == null, "a transient depth refused the framebuffer that stores");
    }

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Flat.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const range = facet.PushConstantRange{ .size = 4 };
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const first = flatPipeline(probe, storing, module.?, layout.?) orelse return probe.check(false, "a pipeline over the storing pass");
    const second = flatPipeline(probe, loading, module.?, layout.?) orelse return probe.check(false, "a pipeline over the loading pass");

    // A near corner at 0.25 and a far one at 0.75, with a band between
    // them that neither covers and the clear's depth stays in: the near
    // one reaches to x + y = 48 of the 64, the far one starts past 64.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.25 }, .{ 0.5, -1, 0.25 }, .{ -1, 0.5, 0.25 },
        .{ 1, 1, 0.75 },   .{ -1, 1, 0.75 },   .{ 1, -1, 0.75 },
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const read_back, const back_bytes = probe.buffer(side * side * 2, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer to read the depth into");
    @memset(back_bytes[0 .. side * side * 2], 0xAA);

    const offset: u64 = 0;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const whole = facet.BufferImageCopy{ .image_extent = extent, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } };

    var commands = probe.record() orelse return probe.check(false, "a command buffer recording");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, first);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the frame submitted");

    const near: u16 = @intFromFloat(@round(0.25 * 65535));
    const far: u16 = @intFromFloat(@round(0.75 * 65535));
    probe.checkEqual(near, depthAt(back_bytes, 4, 4), "the near triangle's depth stored");
    probe.checkEqual(far, depthAt(back_bytes, 40, 40), "the far triangle's depth stored");
    // Past the first tile across, and down a row: the tiles are written
    // back one at a time, so a pixel in another one is worth asking about.
    probe.checkEqual(near, depthAt(back_bytes, 34, 2), "the depth of a pixel in another tile");
    probe.checkEqual(0xFFFF, depthAt(back_bytes, 56, 2), "the clear's depth where neither triangle is");

    // The same depth loaded: a triangle at 0.5 wins only over the far half.
    const across = [_][3]f32{ .{ -1, -1, 0.5 }, .{ 3, -1, 0.5 }, .{ -1, 3, 0.5 } };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(across))], std.mem.asBytes(&across));
    commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = loading, .framebuffer = after, .render_area = area }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, second);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the second frame submitted");

    const pixels, const pitch = probe.mapped(color[0], probe.memories[0].?) orelse .{ @as([*]const u8, @ptrCast(back_bytes)), 0 };
    if (pitch != 0) {
        probe.checkEqual(green, pixelAt(pixels, pitch, 4, 4), "the nearer stored depth kept its pixel");
        probe.checkEqual(red, pixelAt(pixels, pitch, 40, 40), "the further stored depth gave way");
    }
    const half: u16 = @intFromFloat(@round(0.5 * 65535));
    probe.checkEqual(near, depthAt(back_bytes, 4, 4), "the loaded depth kept where it was nearer");
    probe.checkEqual(half, depthAt(back_bytes, 40, 40), "the loaded depth written where it was further");
    probe.checkEqual(half, depthAt(back_bytes, 56, 2), "the loaded clear gave way to the new triangle");

    // Cleared without a pass over it.
    const value = facet.ClearDepthStencilValue{ .depth = 1 };
    const subresource = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
    commands = probe.record() orelse return probe.check(false, "a third recording");
    fb.CmdClearDepthStencilImage(commands, depth[0], 0, &value, 1, @ptrCast(&subresource));
    fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the clear submitted");
    probe.checkEqual(0xFFFF, depthAt(back_bytes, 4, 4), "CmdClearDepthStencilImage set the whole image");
    probe.checkEqual(0xFFFF, depthAt(back_bytes, 40, 40), "and its other corner");
}

/// A pixel of the picture read where it was drawn, 0xAARRGGBB.
fn pixelAt(pixels: [*]const u8, pitch: u32, x: u32, y: u32) u32 {
    return std.mem.readInt(u32, pixels[y * pitch + x * 4 ..][0..4], .little);
}

// --- the run -----------------------------------------------------------------

/// Every check on one device.
fn probeDevice(fb: *FacetBase, dl: *DosBase, instance: *facet.Instance, physical: *facet.PhysicalDevice, quiet: bool) struct { u32, u32 } {
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(physical, &properties);
    _ = Printf(dl, "%s:\n", .{@as([*:0]const u8, @ptrCast(&properties.device_name))});
    var probe = Probe.up(fb, dl, instance, physical, quiet) orelse {
        _ = Printf(dl, "  FAILED  a device and its queue\n", .{});
        return .{ 0, 1 };
    };
    defer probe.down();
    depthChecks(&probe);
    return .{ probe.passed, probe.failed };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const only_cores = argv[0] != 0;
    const only_gpu = argv[1] != 0;
    const quiet = argv[2] != 0;

    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{facet.FACETNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(facet_lib);
    const fb: *FacetBase = @ptrCast(facet_lib);

    var instance: ?*facet.Instance = null;
    if (fb.CreateInstance(&.{ .application_name = COMMAND_NAME }, &instance) != .success) {
        _ = Printf(dl, "No instance\n", .{});
        return dos.RETURN_FAIL;
    }
    defer fb.DestroyInstance(instance);
    var count: u32 = 2;
    var physical: [2]*facet.PhysicalDevice = undefined;
    if (fb.EnumeratePhysicalDevices(instance.?, &count, &physical) != .success or count == 0) {
        _ = Printf(dl, "No device\n", .{});
        return dos.RETURN_FAIL;
    }
    if (only_gpu and count < 2) {
        _ = Printf(dl, "No device after the cores\n", .{});
        return dos.RETURN_FAIL;
    }
    const first: u32 = if (only_gpu) 1 else 0;
    const last: u32 = if (only_cores) 1 else count;

    var passed: u32 = 0;
    var failed: u32 = 0;
    for (first..last) |index| {
        const one, const other = probeDevice(fb, dl, instance.?, physical[index], quiet);
        passed += one;
        failed += other;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
    }
    _ = Printf(dl, "%u checks passed, %u failed\n", .{ passed, failed });
    return if (failed == 0) dos.RETURN_OK else dos.RETURN_WARN;
}
