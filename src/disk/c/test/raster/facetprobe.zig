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
const VERSION_STRING = "\x00$VER: FacetProbe 1.8 (03.11.2026)\r\n";
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
    pipelines: [8]?*facet.Pipeline = @splat(null),
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


/// The colour the vertices carry, which is one of the fixed forms every
/// device draws (`shader.FixedKind.color`): the vertices are three floats
/// at location 0 and the colour is white at every one of them, so what a
/// draw leaves behind is the mixing's doing alone.
const Smooth = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        // A channel of the colour is carried 0 to 255 (`shader.channel`),
        // not 0 to 1.
        const full = facet.shader.channel(1);
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], 1, full, full, full, full };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 4),
        facet.shader.fixedFragment("main", .{ .kind = .color }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// A pipeline of `Flat` over `pass`, depth tested and written, of one
/// colour attachment mixed the default way.
fn flatPipeline(probe: *Probe, pass: *facet.RenderPass, module: *facet.ShaderModule, layout: *facet.PipelineLayout) ?*facet.Pipeline {
    return pipelineOf(probe, pass, module, layout, .{ .depth_tested = true });
}

/// What a probe's pipelines differ in: one blend state for each colour
/// attachment of the subpass, whether the depth is tested and written, the
/// rasterization state, and what commands set.
const Shape = struct {
    blends: []const facet.PipelineColorBlendAttachmentState = &.{.{}},
    depth_tested: bool = false,
    raster: facet.PipelineRasterizationStateCreateInfo = .{},
    dynamic: []const facet.DynamicState = &.{},
    /// Which of the pass's subpasses it draws in, and which entry of the
    /// module it is: both stages take the same name.
    subpass: u32 = 0,
    name: [*:0]const u8 = "main",
    /// The stencil test, the front's and the back's; none where it is
    /// null.
    stencil: ?[2]facet.StencilOpState = null,
    /// What the vertices carry past their place, and how wide one is.
    attributes: []const facet.VertexInputAttributeDescription = &.{.{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat }},
    stride: u32 = 12,
    /// The whole depth state, where `depth_tested` is not enough.
    depth_state: ?facet.PipelineDepthStencilStateCreateInfo = null,
    /// Where z = 0 and z = 1 land in the depth.
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

/// A pipeline over `pass` of the module's "main", as `shape` says.
fn pipelineOf(probe: *Probe, pass: *facet.RenderPass, module: *facet.ShaderModule, layout: *facet.PipelineLayout, shape: Shape) ?*facet.Pipeline {
    const blends = shape.blends;
    const depth_tested = shape.depth_tested;
    const stages = [2]facet.PipelineShaderStageCreateInfo{
        .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module, .name = shape.name },
        .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module, .name = shape.name },
    };
    const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = shape.stride };
    const input = facet.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = @intCast(shape.attributes.len),
        .vertex_attribute_descriptions = shape.attributes.ptr,
    };
    const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list };
    const viewport = facet.Viewport{ .width = side, .height = side, .min_depth = shape.min_depth, .max_depth = shape.max_depth };
    const scissor = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
    const raster = shape.raster;
    const depth = shape.depth_state orelse facet.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = depth_tested,
        .depth_write_enable = depth_tested,
        .depth_compare_op = .less,
        .stencil_test_enable = shape.stencil != null,
        .front = if (shape.stencil) |faces| faces[0] else .{},
        .back = if (shape.stencil) |faces| faces[1] else .{},
    };
    const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = @intCast(blends.len), .attachments = blends.ptr };
    const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = @intCast(shape.dynamic.len), .dynamic_states = shape.dynamic.ptr };
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
        .subpass = shape.subpass,
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

// --- 1.31: an image a shader function writes through -------------------------

/// Each group writes one texel: its own numbers, so what is written says
/// which group wrote it.
const Paint = struct {
    fn run(groups: *const facet.shader.Groups) callconv(.c) void {
        const image = groups.resources.written(0, 0, 0) orelse return;
        const color = 0xFF00_0000 | groups.group[0] << 16 | groups.group[1] << 8 | groups.resources.constants(u32).*;
        image.setColor(0, 0, groups.group[0], groups.group[1], color);
    }

    /// What ran, and whether it found an image to write through: the test
    /// reads it out of a buffer.
    fn told(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 1) orelse return;
        out[0] = if (groups.resources.written(0, 0, 0) == null) 0xA11_600D else 0xBAD;
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.compute("main", &run),
        facet.shader.compute("told", &told),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn storageImageChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    const made = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout);
    if (!probe.features.storage_images) {
        probe.check(made == .error_feature_not_present, "a storage image refused where the device writes none");
        probe.check(set_layout == null, "and nothing given back for it");
        return;
    }
    if (made != .success) return probe.check(false, "a set layout with a storage image in it");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    probe.check(true, "a set layout with a storage image in it");

    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r8g8b8a8_unorm, &properties);
    probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0, "the format says it may be written through");

    const image = probe.image(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, 0) orelse return probe.check(false, "an image made to be written through");
    probe.check(true, "an image made to be written through");
    const sampled_only = probe.image(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_SAMPLED,
    }, 0);

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Paint.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const range = facet.PushConstantRange{ .size = 4 };
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &layout) != .success)
        return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success)
        return probe.check(false, "a descriptor set");
    const told_buffer, const told_bytes = probe.buffer(16, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    @memset(told_bytes[0..16], 0);

    const image_info = facet.DescriptorImageInfo{ .image_view = image[1] };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told_buffer, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);

    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "told" }, .layout = layout.? },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 2, &infos, &pipelines) != .success) return probe.check(false, "the compute pipelines");
    _ = Probe.keep(&probe.pipelines, pipelines[0]);
    _ = Probe.keep(&probe.pipelines, pipelines[1]);

    const four: u32 = 4;
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 4, &four);
    fb.CmdDispatch(commands, 8, 8, 1);
    if (!probe.submit()) return probe.check(false, "the dispatch submitted");

    const back, const back_bytes = probe.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_DST) orelse return probe.check(false, "a buffer to read the image into");
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 8, .height = 8 } };
    commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdCopyImageToBuffer(commands, image[0], .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the read-back submitted");

    // r8g8b8a8 in the buffer: the group's x, its y, the push constants,
    // and opaque.
    probe.checkEqual(0xFF04_0000, std.mem.readInt(u32, back_bytes[0..4], .little), "the first group's texel");
    probe.checkEqual(0xFF04_0003, std.mem.readInt(u32, back_bytes[3 * 4 ..][0..4], .little), "the fourth group's texel");
    probe.checkEqual(0xFF04_0507, std.mem.readInt(u32, back_bytes[(5 * 8 + 7) * 4 ..][0..4], .little), "a texel in the middle of the image");

    // An image that was not made to be written through: the write does not
    // take, and the function finds nothing.
    if (sampled_only) |one| {
        const refused = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = one[1] }) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&refused), 0, null);
        commands = probe.record() orelse return probe.check(false, "a third recording");
        fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDispatch(commands, 1, 1, 1);
        if (!probe.submit()) return probe.check(false, "the refused write submitted");
        probe.checkEqual(0xA11_600D, std.mem.readInt(u32, told_bytes[0..4], .little), "an image not made for it is not written through");
    }
}

// --- 1.32: a buffer read as texels of a format -------------------------------

/// Texel k of binding 0 read as a format and written into texel k of
/// binding 1, which is of another format: what reading by format is for.
const Swap = struct {
    fn run(groups: *const facet.shader.Groups) callconv(.c) void {
        const from = groups.resources.texels(0, 0, 0) orelse return;
        var into = groups.resources.texels(0, 1, 0) orelse return;
        const k = groups.group[0];
        const parts = from.at(k);
        into.set(k, .{ parts[1], parts[0], parts[2] * 0.5, 1 });
    }

    /// What the function sees of the two: the counts, and whether each may
    /// be written.
    fn told(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 2) orelse return;
        const from = groups.resources.texels(0, 0, 0);
        const into = groups.resources.texels(0, 1, 0);
        out[0] = if (from) |one| one.count else 0xFFFF_FFFF;
        out[1] = if (from) |one| @intFromBool(one.writable) else 0xFFFF_FFFF;
        out[2] = if (into) |one| one.count else 0xFFFF_FFFF;
        out[3] = if (into) |one| @intFromBool(one.writable) else 0xFFFF_FFFF;
        out[4] = if (from) |one| one.colorAt(0) else 0;
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.compute("main", &run),
        facet.shader.compute("told", &told),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn texelBufferChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const floats, const float_bytes = probe.buffer(4 * 16, facet.BUFFER_USAGE_UNIFORM_TEXEL_BUFFER) orelse return probe.check(false, "a buffer of floats");
    const colors, const color_bytes = probe.buffer(4 * 4, facet.BUFFER_USAGE_STORAGE_TEXEL_BUFFER) orelse return probe.check(false, "a buffer of colours");
    const given = [4][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 } };
    @memcpy(float_bytes[0..64], std.mem.asBytes(&given));
    @memset(color_bytes[0..16], 0);

    var reading: ?*facet.BufferView = null;
    const made = fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat }, &reading);
    if (!probe.features.texel_buffers) {
        probe.check(made == .error_feature_not_present, "a buffer view refused where the device has none");
        return;
    }
    if (made != .success) return probe.check(false, "a view of a buffer of floats");
    defer fb.DestroyBufferView(device, reading);
    probe.check(true, "a view of a buffer of floats");
    var writing: ?*facet.BufferView = null;
    if (fb.CreateBufferView(device, &.{ .buffer = colors, .format = .r8g8b8a8_unorm }, &writing) != .success) return probe.check(false, "a view written through");
    defer fb.DestroyBufferView(device, writing);

    // Refused: a format no view takes, and an offset that is not a texel's.
    var none: ?*facet.BufferView = null;
    probe.check(fb.CreateBufferView(device, &.{ .buffer = floats, .format = .d16_unorm }, &none) == .error_format_not_supported, "a format no view takes refused");
    probe.check(fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat, .offset = 4 }, &none) == .error_initialization_failed, "an offset that is not a texel's refused");
    probe.check(none == null, "and nothing given back for either");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Swap.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const bindings = [3]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 3, .bindings = &bindings }, &set_layout) != .success) return probe.check(false, "a set layout of the two kinds");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    probe.check(true, "a set layout of the two kinds");
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const told_buffer, const told_bytes = probe.buffer(32, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    @memset(told_bytes[0..32], 0);
    const told_info = facet.DescriptorBufferInfo{ .buffer = told_buffer, .range = facet.WHOLE_SIZE };
    const writes = [3]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&reading) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&writing) },
        .{ .dst_set = sets[0].?, .dst_binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&told_info) },
    };
    fb.UpdateDescriptorSets(device, 3, &writes, 0, null);

    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "told" }, .layout = layout.? },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 2, &infos, &pipelines) != .success) return probe.check(false, "the compute pipelines");
    _ = Probe.keep(&probe.pipelines, pipelines[0]);
    _ = Probe.keep(&probe.pipelines, pipelines[1]);

    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 4, 1, 1);
    if (!probe.submit()) return probe.check(false, "the dispatch submitted");

    // Read as floats and written as 8888, red and green swapped and blue
    // halved: r, g, b, a in the buffer's bytes.
    probe.checkEqual(0xFF00_FF00, std.mem.readInt(u32, color_bytes[0..4], .little), "a float texel read and a colour texel written");
    probe.checkEqual(0xFF00_00FF, std.mem.readInt(u32, color_bytes[4..8], .little), "the second of them");
    probe.checkEqual(0xFF80_0000, std.mem.readInt(u32, color_bytes[8..12], .little), "a part halved on the way");
    probe.checkEqual(0xFF80_FFFF, std.mem.readInt(u32, color_bytes[12..16], .little), "the last of them");

    commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the second dispatch submitted");
    const out: [*]const u32 = @ptrCast(@alignCast(told_bytes));
    probe.checkEqual(4, out[0], "the texels a uniform view holds");
    probe.checkEqual(0, out[1], "a uniform view is not written through");
    probe.checkEqual(4, out[2], "the texels a storage view holds");
    probe.checkEqual(1, out[3], "a storage view is");
    probe.checkEqual(0xFFFF_0000, out[4], "a float texel read as a colour");
}

// --- the run -----------------------------------------------------------------

/// Every check on one device.

// --- 1.33: a colour attachment blended its own way ---------------------------

fn blendChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
    };
    const colors = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .color_attachment_optimal }, .{ .attachment = 1, .layout = .color_attachment_optimal } };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &colors };
    const pass = probe.renderPass(.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }) orelse
        return probe.check(false, "a pass of two colour attachments");
    probe.check(true, "a pass of two colour attachments");

    // The form draws what the vertices carry, which every device draws:
    // the V3D takes this pipeline as the cores do.
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Smooth.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    // The first attachment keeps what is there, the second takes the
    // colour: the same draw, mixed each its own way.
    const keeps = facet.PipelineColorBlendAttachmentState{ .blend_enable = true, .src_color_blend_factor = .zero, .dst_color_blend_factor = .one, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one };
    const takes = facet.PipelineColorBlendAttachmentState{};
    const differing = [2]facet.PipelineColorBlendAttachmentState{ keeps, takes };
    const each_own = pipelineOf(probe, pass, module.?, layout.?, .{ .blends = &differing });
    if (!probe.features.independent_blend) {
        probe.check(each_own == null, "attachments that differ refused where a device blends them alike");
        const alike = [2]facet.PipelineColorBlendAttachmentState{ keeps, keeps };
        probe.check(pipelineOf(probe, pass, module.?, layout.?, .{ .blends = &alike }) != null, "the same state for both still taken");
        return;
    }
    const pipeline = each_own orelse return probe.check(false, "a pipeline whose attachments differ");
    probe.check(true, "a pipeline whose attachments differ");

    const extent = facet.Extent3D{ .width = side, .height = side };
    const wanted = facet.MEMORY_PROPERTY_HOST_VISIBLE;
    const info = facet.ImageCreateInfo{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    const first = probe.image(info, wanted) orelse return probe.check(false, "the first picture");
    const first_memory = probe.memories[0].?;
    const second = probe.image(info, wanted) orelse return probe.check(false, "the second picture");
    const second_memory = probe.memories[1].?;
    const frame = probe.framebuffer(pass, &.{ first[1], second[1] }) orelse return probe.check(false, "a framebuffer over the two");

    const vertices = [_][3]f32{
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));

    const offset: u64 = 0;
    // What the vertices carry, and what the clear left.
    const white: u32 = 0xFFFF_FFFF;
    const blue: u32 = 0xFF00_00FF;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const commands = probe.record() orelse return probe.check(false, "a command buffer recording");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, pipeline);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the frame submitted");

    const first_pixels, const first_pitch = probe.mapped(first[0], first_memory) orelse return probe.check(false, "the first picture read back");
    const second_pixels, const second_pitch = probe.mapped(second[0], second_memory) orelse return probe.check(false, "the second picture read back");
    probe.checkEqual(blue, pixelAt(first_pixels, first_pitch, 8, 8), "the attachment that keeps what is there kept the clear");
    probe.checkEqual(blue, pixelAt(first_pixels, first_pitch, 40, 52), "and in another tile");
    probe.checkEqual(white, pixelAt(second_pixels, second_pitch, 8, 8), "the attachment that takes the colour took it");
    probe.checkEqual(white, pixelAt(second_pixels, second_pitch, 40, 52), "and in another tile");
}

// --- 1.33: the depth bias ----------------------------------------------------

/// A quad over the whole picture at `z`, two triangles of it.
fn quadAt(z: f32) [6][3]f32 {
    return .{ .{ -1, -1, z }, .{ 1, -1, z }, .{ -1, 1, z }, .{ -1, 1, z }, .{ 1, -1, z }, .{ 1, 1, z } };
}

fn biasChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    const pass = passKeeping(probe, .clear, .clear, .dont_care) orelse return probe.check(false, "a pass of a colour and a depth");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Smooth.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    // The first draw writes its depth and no colour at all; the second is
    // the same quad, lifted towards the eye by three of the smallest
    // differences the depth holds.
    const depth_only = [1]facet.PipelineColorBlendAttachmentState{.{ .color_write_mask = 0 }};
    const nearer = facet.PipelineRasterizationStateCreateInfo{ .depth_bias_enable = true, .depth_bias_constant_factor = -3 };
    const biased = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true, .raster = nearer });
    if (!probe.features.depth_bias) {
        probe.check(biased == null, "a depth bias refused where the device moves none");
        probe.check(pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true }) != null, "a pipeline without one is still taken");
        return;
    }
    const lifts = biased orelse return probe.check(false, "a pipeline that lifts its triangles");
    probe.check(true, "a pipeline that lifts its triangles");
    const writes_depth = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true, .blends = &depth_only }) orelse
        return probe.check(false, "a pipeline that writes the depth alone");
    // A tenth of the range the other way, and the same held inside a
    // twentieth of it.
    const pushes = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true, .raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 0.11 * 65535 } }) orelse
        return probe.check(false, "a pipeline that pushes them away");
    const held = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true, .raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 0.11 * 65535, .depth_bias_clamp = 0.05 } }) orelse
        return probe.check(false, "a pipeline whose bias is held inside a clamp");

    const extent = facet.Extent3D{ .width = side, .height = side };
    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const memory = probe.memories[0].?;
    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT }, 0) orelse
        return probe.check(false, "a depth attachment");
    const frame = probe.framebuffer(pass, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");
    // Mapped the once: memory is mapped once at a time, and what the
    // frames draw lands in these bytes.
    const pixels, const pitch = probe.mapped(color[0], memory) orelse return probe.check(false, "the picture read back");

    const level = quadAt(0.5);
    const closer = quadAt(0.4);
    const quad_bytes = @sizeOf([6][3]f32);
    const vertex_buffer, const vertex_bytes = probe.buffer(2 * quad_bytes, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");

    const offset: u64 = 0;
    const white: u32 = 0xFFFF_FFFF;
    const blue: u32 = 0xFF00_00FF;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };

    // Each frame: the depth laid down by the first quad, then `second`
    // drawn white over it by `pipeline`, and the pixel it left.
    const frames = [4]struct { *facet.Pipeline, *const [6][3]f32, u32, [*:0]const u8 }{
        .{ lifts, &level, white, "the lifted draw won at the same depth" },
        .{ pushes, &closer, blue, "the pushed draw lost though it was nearer" },
        .{ held, &closer, white, "the clamp left it in front" },
        .{ writes_depth, &level, blue, "a draw of no colour at all leaves the clear" },
    };
    for (frames) |one| {
        const pipeline, const second, const wanted, const name = one;
        @memcpy(vertex_bytes[0..quad_bytes], std.mem.asBytes(&level));
        @memcpy(vertex_bytes[quad_bytes..][0..quad_bytes], std.mem.asBytes(second));
        const commands = probe.record() orelse return probe.check(false, "a command buffer recording");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, writes_depth);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdDraw(commands, 6, 1, 6, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        probe.checkEqual(wanted, pixelAt(pixels, pitch, 16, 16), name);
    }

    // What a command sets is what a dynamic pipeline uses.
    const dynamic_states = [1]facet.DynamicState{.depth_bias};
    const dynamic = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_tested = true, .raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 100 }, .dynamic = &dynamic_states }) orelse
        return probe.check(false, "a pipeline whose bias a command sets");
    for ([2]struct { f32, u32, [*:0]const u8 }{
        .{ -3, white, "the command's bias lifted the draw" },
        .{ 3, blue, "and pushed it away the other way" },
    }) |one| {
        const constant, const wanted, const name = one;
        @memcpy(vertex_bytes[0..quad_bytes], std.mem.asBytes(&level));
        @memcpy(vertex_bytes[quad_bytes..][0..quad_bytes], std.mem.asBytes(&level));
        const commands = probe.record() orelse return probe.check(false, "a recording for the command's bias");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, writes_depth);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdBindPipeline(commands, .graphics, dynamic);
        fb.CmdSetDepthBias(commands, constant, 0, 0);
        fb.CmdDraw(commands, 6, 1, 6, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        probe.checkEqual(wanted, pixelAt(pixels, pitch, 16, 16), name);
    }
}

// --- 1.35: dynamic buffer descriptors ----------------------------------------

/// What it was given of a dynamic uniform's range copied into a dynamic
/// storage buffer's: both are read from where the bind said, so what
/// lands where says the offsets were taken.
const Shift = struct {
    fn run(groups: *const facet.shader.Groups) callconv(.c) void {
        const from = groups.resources.buffer([4]u32, 0, 0) orelse return;
        const into = groups.resources.storage(u32, 0, 1) orelse return;
        if (into.len < 4) return;
        into[0..4].* = from.*;
        if (into.len > 4) into[4] = @intCast(into.len);
    }

    const entries = [_]facet.shader.Entry{facet.shader.compute("main", &run)};
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn dynamicChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer_dynamic, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    const made = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout);
    if (!probe.features.dynamic_descriptors) {
        probe.check(made == .error_feature_not_present, "a dynamic buffer descriptor refused where the device has none");
        probe.check(set_layout == null, "and nothing given back for it");
        return;
    }
    if (made != .success) return probe.check(false, "a set layout of the two dynamic kinds");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    probe.check(true, "a set layout of the two dynamic kinds");

    // A set holds only so many of them, as the limit says.
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    const most = properties.limits.max_descriptor_set_dynamic_buffers;
    probe.check(most != 0, "the limit says how many a set holds");
    var none: ?*facet.DescriptorSetLayout = null;
    const too_many = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = most + 1 };
    probe.check(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&too_many) }, &none) == .error_feature_not_present, "a set of more than the limit refused");
    probe.check(none == null, "and nothing given back for that either");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Shift.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const uniform, const uniform_bytes = probe.buffer(256, facet.BUFFER_USAGE_UNIFORM_BUFFER) orelse return probe.check(false, "a uniform buffer");
    const storage, const storage_bytes = probe.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    const in: [*]u32 = @ptrCast(@alignCast(uniform_bytes));
    const out: [*]u32 = @ptrCast(@alignCast(storage_bytes));
    for (0..64) |k| in[k] = @intCast(100 + k);
    const infos = [2]facet.DescriptorBufferInfo{
        .{ .buffer = uniform, .range = 128 },
        .{ .buffer = storage, .range = 128 },
    };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = 1, .buffer_info = @ptrCast(&infos[0]) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer_dynamic, .descriptor_count = 1, .buffer_info = @ptrCast(&infos[1]) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);

    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? };
    var pipelines: [1]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipelines) != .success) return probe.check(false, "the compute pipeline");
    _ = Probe.keep(&probe.pipelines, pipelines[0]);

    // The same set, bound again with offsets of its own each time.
    for ([3]struct { [2]u32, [*:0]const u8 }{
        .{ .{ 0, 0 }, "the set read and written where it was written" },
        .{ .{ 16, 32 }, "the same set shifted both ways by the bind" },
        .{ .{ 64, 4 }, "and shifted again, by other offsets" },
    }) |one| {
        const offsets, const name = one;
        @memset(storage_bytes[0..256], 0);
        const commands = probe.record() orelse return probe.check(false, "a recording");
        fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 2, &offsets);
        fb.CmdDispatch(commands, 1, 1, 1);
        if (!probe.submit()) return probe.check(false, "the dispatch submitted");
        const from = offsets[0] / 4;
        const into = offsets[1] / 4;
        var right = true;
        for (0..4) |k| right = right and out[into + k] == in[from + k];
        if (into > 0) right = right and out[into - 1] == 0;
        probe.check(right, name);
        // What is left of the range from the offset is what the function
        // reaches: 128 bytes less the offset, in numbers of four.
        probe.checkEqual((128 - offsets[1]) / 4, out[into + 4], "what was left of the range from there");
    }

    // Offsets left out are 0: read and written where the writes left them.
    @memset(storage_bytes[0..256], 0);
    const commands = probe.record() orelse return probe.check(false, "a last recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the dispatch submitted");
    probe.checkEqual(in[0], out[0], "a bind without offsets shifts nothing");
}

// --- 1.36: the three device queries ------------------------------------------

fn queryChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    const limits = &properties.limits;

    // A sampled image: the largest, its levels and its layers, as the
    // device's own limits say.
    var shape: facet.ImageFormatProperties = undefined;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled, 0, &shape) != .success) {
        return probe.check(false, "the largest sampled image");
    }
    probe.check(true, "the largest sampled image");
    probe.checkEqual(limits.max_image_dimension_2d, shape.max_extent.width, "as wide as the device's limit says");
    probe.checkEqual(1, shape.max_extent.depth, "and one deep");
    probe.checkEqual(limits.max_image_array_layers, shape.max_array_layers, "the layers of an array");
    probe.checkEqual(1, shape.sample_counts, "one sample a pixel");
    probe.check(shape.max_mip_levels > 1, "the levels of the largest");
    probe.check(shape.max_resource_size != 0, "the bytes an image may take");

    // An attachment is one level and one layer; a 3D image is as deep as
    // it is wide.
    if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"2d", .linear, facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &shape) != .success) {
        return probe.check(false, "the largest colour attachment");
    }
    probe.checkEqual(1, shape.max_mip_levels, "an attachment has one level");
    probe.checkEqual(1, shape.max_array_layers, "and one layer");
    const widest = shape.max_extent.width;
    if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"3d", .optimal, sampled, 0, &shape) != .success) {
        return probe.check(false, "the largest 3D image");
    }
    probe.checkEqual(limits.max_image_dimension_3d, shape.max_extent.depth, "a 3D image is as deep as the limit says");

    // Shapes there is no image of at all.
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .d16_unorm, .@"2d", .linear, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0, &shape) == .error_format_not_supported, "a depth image in rows refused");
    probe.checkEqual(0, shape.max_mip_levels, "and nothing written for it");
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"1d", .optimal, sampled, 0, &shape) == .error_format_not_supported, "a 1D image refused");
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled | facet.IMAGE_USAGE_COLOR_ATTACHMENT, 0, &shape) == .error_format_not_supported, "an attachment that is sampled too refused");

    // What the query says is what CreateImage does.
    var image: ?*facet.Image = null;
    const made = fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = widest, .height = 1 }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image);
    probe.check(made == .success, "an image of the widest extent made");
    fb.DestroyImage(device, image);
    image = null;
    const over = fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = widest + 1, .height = 1 }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, &image);
    probe.check(over == .error_format_not_supported and image == null, "one texel wider refused");

    // The render area's granularity is the device's tile.
    const pass = passKeeping(probe, .clear, .clear, .dont_care) orelse return probe.check(false, "a pass to ask about");
    var granularity: facet.Extent2D = undefined;
    fb.GetRenderAreaGranularity(device, pass, &granularity);
    probe.checkEqual(limits.tile_size, granularity.width, "the render area's granularity is the tile");
    probe.checkEqual(limits.tile_size, granularity.height, "square");

    // What a block has behind it: all of a plain one, none of a lazily
    // allocated one.
    var needs = facet.MemoryRequirements{ .size = 4096, .alignment = 64, .memory_type_bits = 0xFFFF_FFFF };
    const block = probe.block(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse return probe.check(false, "a block of memory");
    var bytes: u64 = 0xFFFF;
    fb.GetDeviceMemoryCommitment(device, block, &bytes);
    probe.checkEqual(4096, bytes, "a plain block is there whole");
    needs.size = 4 << 20;
    if (probe.block(needs, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED)) |lazy| {
        fb.GetDeviceMemoryCommitment(device, lazy, &bytes);
        probe.checkEqual(0, bytes, "a lazily allocated block has nothing behind it");
    }
}

// --- 1.37: input attachments -------------------------------------------------

/// Two entries: "main" draws one colour, and "read" draws what the
/// attachment it reads holds at the fragment's own pixel, its green and
/// blue the other way round - or `missing` where it finds no attachment
/// to read, so an empty descriptor is seen as well.
const Deferred = struct {
    const written: u32 = 0xFF11_2233;
    const swapped: u32 = 0xFF11_3322;
    const missing: u32 = 0xFF00_0000;

    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn write(fragments: *const facet.shader.Fragments) callconv(.c) void {
        facet.shader.fill(fragments, written);
    }

    fn read(fragments: *const facet.shader.Fragments) callconv(.c) void {
        const from = fragments.resources.input(0, 0, 0) orelse return facet.shader.fill(fragments, missing);
        for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |spot, *out| {
            inline for (0..4) |i| {
                const x = fragments.x + @as(u32, spot.x) + @as(u32, i & 1);
                const y = fragments.y + @as(u32, spot.y) + @as(u32, i >> 1);
                const color = from.colorAt(x, y);
                const green = (color >> 8) & 0xFF;
                const blue = color & 0xFF;
                out[i] = (color & 0xFFFF_0000) | (blue << 8) | green;
            }
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 0),
        facet.shader.fragment("main", &write, 0),
        facet.shader.vertex("read", &vertex, 0),
        facet.shader.fragment("read", &read, 0),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn inputChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    const layout_made = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout);

    // The pass: the first subpass draws attachment 0, the second reads it
    // and draws attachment 1.
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const to_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const to_second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const subpasses = [2]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &to_first },
        .{ .input_attachment_count = 1, .input_attachments = &to_first, .color_attachment_count = 1, .color_attachments = &to_second },
    };
    const pass_info = facet.RenderPassCreateInfo{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 2, .subpasses = &subpasses };

    if (!probe.features.input_attachments) {
        probe.check(layout_made == .error_feature_not_present, "an input attachment layout refused where the device reads none");
        probe.check(set_layout == null, "and nothing given back for it");
        probe.check(probe.renderPass(pass_info) == null, "a subpass that reads one refused there too");
        if (set_layout) |each| fb.DestroyDescriptorSetLayout(device, each);
        return;
    }
    if (layout_made != .success) return probe.check(false, "a set layout of an input attachment");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    probe.check(true, "a set layout of an input attachment");

    const pass = probe.renderPass(pass_info) orelse return probe.check(false, "a pass whose second subpass reads the first's");
    probe.check(true, "a pass whose second subpass reads the first's");

    // A subpass that reads what it draws is a loop, and a depth
    // attachment has no rows to read.
    const loop = facet.SubpassDescription{ .input_attachment_count = 1, .input_attachments = &to_first, .color_attachment_count = 1, .color_attachments = &to_first };
    probe.check(probe.renderPass(.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&loop) }) == null, "a subpass that reads what it draws refused");
    const with_depth = [2]facet.AttachmentDescription{
        .{ .format = .d16_unorm, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const reads_depth = facet.SubpassDescription{ .input_attachment_count = 1, .input_attachments = &to_first, .color_attachment_count = 1, .color_attachments = &to_second };
    probe.check(probe.renderPass(.{ .attachment_count = 2, .attachments = &with_depth, .subpass_count = 1, .subpasses = @ptrCast(&reads_depth) }) == null, "a depth attachment read as an input attachment refused");

    // The pictures: the one read is made to be read, and one that is not.
    const extent = facet.Extent3D{ .width = side, .height = side };
    const wanted = facet.MEMORY_PROPERTY_HOST_VISIBLE;
    const read_info = facet.ImageCreateInfo{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT };
    const first = probe.image(read_info, wanted) orelse return probe.check(false, "a picture made to be read");
    const first_memory = probe.memories[0].?;
    const plain_info = facet.ImageCreateInfo{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    const second = probe.image(plain_info, wanted) orelse return probe.check(false, "a picture drawn into");
    const second_memory = probe.memories[1].?;
    const plain = probe.image(plain_info, wanted) orelse return probe.check(false, "a picture not made to be read");

    // An input attachment is kept in rows, so it is not also a texture.
    var none: ?*facet.Image = null;
    const both = facet.ImageCreateInfo{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_INPUT_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED };
    probe.check(fb.CreateImage(device, &both, &none) != .success, "an image both read and sampled refused");
    probe.check(none == null, "and nothing given back for that either");

    const frame = probe.framebuffer(pass, &.{ first[1], second[1] }) orelse return probe.check(false, "a framebuffer over the two");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Deferred.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const writer = pipelineOf(probe, pass, module.?, layout.?, .{}) orelse return probe.check(false, "the pipeline that draws");
    const reader = pipelineOf(probe, pass, module.?, layout.?, .{ .subpass = 1, .name = "read" }) orelse return probe.check(false, "the pipeline that reads");

    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    const layouts = [2]*facet.DescriptorSetLayout{ set_layout.?, set_layout.? };
    var sets: [2]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 2, .set_layouts = &layouts }, &sets) != .success) return probe.check(false, "two descriptor sets");
    const infos = [2]facet.DescriptorImageInfo{ .{ .image_view = first[1], .image_layout = .general }, .{ .image_view = plain[1], .image_layout = .general } };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .input_attachment, .descriptor_count = 1, .image_info = @ptrCast(&infos[0]) },
        .{ .dst_set = sets[1].?, .dst_binding = 0, .descriptor_type = .input_attachment, .descriptor_count = 1, .image_info = @ptrCast(&infos[1]) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);

    const vertices = quadAt(0.5);
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    // Mapped once: a block is mapped one at a time.
    const first_pixels, const first_pitch = probe.mapped(first[0], first_memory) orelse return probe.check(false, "the attachment read back");
    const second_pixels, const second_pitch = probe.mapped(second[0], second_memory) orelse return probe.check(false, "the picture read back");

    // Each set in turn: the one that is read, then the one whose image was
    // not made to be read.
    for ([2]struct { u32, u32, [*:0]const u8, [*:0]const u8 }{
        .{ 0, Deferred.swapped, "what the first subpass drew, read back pixel by pixel", "and in another tile" },
        .{ 1, Deferred.missing, "a view of an image not made to be read leaves the descriptor empty", "in every tile" },
    }) |one| {
        const which, const expected, const name, const other = one;
        const commands = probe.record() orelse return probe.check(false, "a recording");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, writer);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdNextSubpass(commands, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, reader);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets[which]), 0, null);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        if (which == 0) probe.checkEqual(Deferred.written, pixelAt(first_pixels, first_pitch, 8, 8), "the first subpass drew its colour");
        probe.checkEqual(expected, pixelAt(second_pixels, second_pitch, 8, 8), name);
        probe.checkEqual(expected, pixelAt(second_pixels, second_pitch, 40, 52), other);
    }
}

// --- 1.38: a stencil that outlives its pass ----------------------------------

/// A pass of a colour attachment and a depth one of `format`, the four ops
/// as given: 'l' or 'c' for each load, 's' or 'd' for each store, the
/// depth's two first and the stencil's after.
fn passStenciling(probe: *Probe, format: facet.Format, ops: *const [4:0]u8) ?*facet.RenderPass {
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{
            .format = format,
            .load_op = if (ops[0] == 'l') .load else .clear,
            .store_op = if (ops[1] == 's') .store else .dont_care,
            .stencil_load_op = if (ops[2] == 'l') .load else .clear,
            .stencil_store_op = if (ops[3] == 's') .store else .dont_care,
            .final_layout = .depth_stencil_attachment_optimal,
        },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    return probe.renderPass(.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) });
}

fn stencilChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    if (!probe.features.stored_stencil) {
        probe.check(passStenciling(probe, .s8_uint, "cdcs") == null, "a stored stencil refused where the device keeps none");
        probe.check(passStenciling(probe, .d16_unorm_s8_uint, "cdld") == null, "a loaded stencil refused the same way");
        probe.check(passStenciling(probe, .s8_uint, "cdcd") != null, "a stencil that stays in the tiles is still taken");
        return;
    }
    // An op for a plane the format has not.
    probe.check(passStenciling(probe, .d16_unorm, "cdcs") == null, "a stencil op refused for a format with no stencil");

    const extent = facet.Extent3D{ .width = side, .height = side };
    const marked: u8 = 5;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const blue: u32 = 0xFF00_00FF;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const marks = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = marked };
    const equal = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = marked };

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Flat.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const range = facet.PushConstantRange{ .size = 4 };
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    // All of the picture, then its left half.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
        .{ -1, -1, 0.5 }, .{ 0, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 0, -1, 0.5 }, .{ 0, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;

    // One format of stencil alone, and one that holds a depth beside it.
    for ([2]facet.Format{ .s8_uint, .d16_unorm_s8_uint }) |format| {
        const stride: u32 = if (format == .s8_uint) 1 else 4;
        const inside: u32 = if (stride == 1) 0 else 2;
        const storing = passStenciling(probe, format, "cdcs") orelse return probe.check(false, "a pass that stores its stencil");
        probe.check(true, "a pass that stores its stencil");
        const loading = passStenciling(probe, format, "cdld") orelse return probe.check(false, "a pass that loads its stencil");
        probe.check(true, "a pass that loads its stencil");

        // Which block the picture's memory will be: the vertex buffer took
        // one before the loop, and the first format's images before this.
        var slot: usize = 0;
        while (slot < probe.memories.len and probe.memories[slot] != null) slot += 1;
        const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
            return probe.check(false, "a picture to draw into");
        const color_memory = probe.memories[slot].?;
        const stencil = probe.image(.{ .format = format, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC }, 0) orelse
            return probe.check(false, "a stencil image with memory behind it");
        probe.check(true, "a stencil image with memory behind it");
        const frame = probe.framebuffer(storing, &.{ color[1], stencil[1] }) orelse return probe.check(false, "a framebuffer over the two");
        const after = probe.framebuffer(loading, &.{ color[1], stencil[1] }) orelse return probe.check(false, "a framebuffer for the second pass");

        const mark = pipelineOf(probe, storing, module.?, layout.?, .{ .stencil = .{ marks, marks } }) orelse return probe.check(false, "a pipeline that marks");
        const draw = pipelineOf(probe, loading, module.?, layout.?, .{ .stencil = .{ equal, equal } }) orelse return probe.check(false, "a pipeline that draws where marked");

        const bytes = side * side * stride;
        const read_back, const back_bytes = probe.buffer(bytes, facet.BUFFER_USAGE_TRANSFER_DST) orelse
            return probe.check(false, "a buffer to read the stencil into");
        @memset(back_bytes[0..bytes], 0xAA);
        const whole = facet.BufferImageCopy{ .image_extent = extent, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL } };

        // The left half marked, the stencil stored, and read back.
        var commands = probe.record() orelse return probe.check(false, "a command buffer recording");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, mark);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
        fb.CmdDraw(commands, 6, 1, 6, 0);
        fb.CmdEndRenderPass(commands);
        fb.CmdCopyImageToBuffer(commands, stencil[0], .general, read_back, 1, @ptrCast(&whole));
        if (!probe.submit()) return probe.check(false, "the frame submitted");

        probe.checkEqual(marked, back_bytes[(8 * side + 16) * stride + inside], "the marked half's stencil stored");
        probe.checkEqual(0, back_bytes[(8 * side + 48) * stride + inside], "and the clear's where nothing marked");
        // Another tile down: the tiles are written back one at a time.
        probe.checkEqual(marked, back_bytes[(40 * side + 16) * stride + inside], "the same in another tile");
        probe.checkEqual(0, back_bytes[(40 * side + 48) * stride + inside], "and the clear's there too");

        // The second pass loads it and draws over all of the picture: only
        // the marked half takes the colour.
        commands = probe.record() orelse return probe.check(false, "a second recording");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = loading, .framebuffer = after, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, draw);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the second frame submitted");
        const pixels, const pitch = probe.mapped(color[0], color_memory) orelse return probe.check(false, "the picture read back");
        probe.checkEqual(green, pixelAt(pixels, pitch, 16, 8), "drawn where the stored stencil says");
        probe.checkEqual(blue, pixelAt(pixels, pitch, 48, 8), "and left where it does not");
        probe.checkEqual(green, pixelAt(pixels, pitch, 16, 40), "the same in another tile");
        probe.checkEqual(blue, pixelAt(pixels, pitch, 48, 40), "and left there too");

        // Cleared without a pass over it, the stencil aspect alone.
        const value = facet.ClearDepthStencilValue{ .depth = 1, .stencil = 9 };
        const only_stencil = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL };
        @memset(back_bytes[0..bytes], 0xAA);
        commands = probe.record() orelse return probe.check(false, "a third recording");
        fb.CmdClearDepthStencilImage(commands, stencil[0], 0, &value, 1, @ptrCast(&only_stencil));
        fb.CmdCopyImageToBuffer(commands, stencil[0], .general, read_back, 1, @ptrCast(&whole));
        if (!probe.submit()) return probe.check(false, "the clear submitted");
        probe.checkEqual(9, back_bytes[(8 * side + 16) * stride + inside], "cleared without a pass over it");
        probe.checkEqual(9, back_bytes[(40 * side + 48) * stride + inside], "in every tile of it");
    }
}

// --- 1.39: a depth image sampled where it lies ------------------------------

/// A shadow sample of a depth texture: s, t and the reference are the
/// vertices' second three floats, and what it draws is how much of the
/// sample passed - white for all of it, black for none.
const Shadowed = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1], uv[2] };
        }
    }

    fn fragment(fragments: *const facet.shader.Fragments) callconv(.c) void {
        facet.shader.texturedBy(
            true,
            .{ .format = .d16, .filter = .nearest, .address = .clamp },
            fragments,
            fragments.resources.sampled(0, 0, 0),
            fragments.resources.samplerOf(0, 0, 0),
        );
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 3),
        facet.shader.fragment("main", &fragment, 3),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn sampledDepthChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const extent = facet.Extent3D{ .width = side, .height = side };
    const usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED;
    var made: ?*facet.Image = null;
    const asked = fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = extent, .usage = usage }, &made);
    if (!probe.features.sampled_depth) {
        probe.check(asked != .success and made == null, "a sampled depth image refused where the device samples none");
        return;
    }
    if (asked != .success or made == null) return probe.check(false, "a depth image that is sampled as well");
    fb.DestroyImage(device, made);
    probe.check(true, "a depth image that is sampled as well");
    // One with a stencil in it has no texel to sample.
    var none: ?*facet.Image = null;
    probe.check(fb.CreateImage(device, &.{ .format = .d16_unorm_s8_uint, .extent = extent, .usage = usage }, &none) != .success, "one with a stencil in it refused");
    probe.check(none == null, "and nothing given back for it");

    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = usage }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a sampled depth image bound to memory");
    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture for the first pass");
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture for the second");
    const shown_memory = probe.memories[2].?;

    // The first pass draws the left half at 0.25 and stores the depth.
    const storing = passKeeping(probe, .clear, .clear, .store) orelse return probe.check(false, "a pass that stores its depth");
    const frame = probe.framebuffer(storing, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");
    var flat: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Flat.code }, &flat) != .success) return probe.check(false, "the first shader module");
    _ = Probe.keep(&probe.modules, flat);
    const range = facet.PushConstantRange{ .size = 4 };
    var flat_layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &flat_layout) != .success) return probe.check(false, "the first pipeline layout");
    _ = Probe.keep(&probe.layouts, flat_layout);
    const list = flatPipeline(probe, storing, flat.?, flat_layout.?) orelse return probe.check(false, "a pipeline that draws the depth");

    const left_half = [6][3]f32{
        .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 },
        .{ -1, 1, 0.25 },  .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 },
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(1024, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(left_half))], std.mem.asBytes(&left_half));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, flat_layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the first frame submitted");

    // The second samples it through a sampler that compares.
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Shadowed.code }, &module) != .success) return probe.check(false, "the shadow module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a combined image sampler");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the shadow pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var sampler: ?*facet.Sampler = null;
    if (fb.CreateSampler(device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .compare_enable = true,
        .compare_op = .less,
    }, &sampler) != .success) return probe.check(false, "a sampler that compares");
    defer fb.DestroySampler(device, sampler);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const info = facet.DescriptorImageInfo{ .sampler = sampler, .image_view = depth[1] };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const reading = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass for the shadow sample");
    const onto = probe.framebuffer(reading, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const shade = pipelineOf(probe, reading, module.?, layout.?, .{ .attributes = &attributes, .stride = 24 }) orelse
        return probe.check(false, "a pipeline that samples the depth");

    const white: u32 = 0xFFFF_FFFF;
    const black: u32 = 0xFF00_0000;
    const near: f32 = @round(0.25 * 65535);
    // Mapped once: a block is mapped one at a time.
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    const one_clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    for ([3]struct { f32, u32, u32, [*:0]const u8 }{
        .{ 0.5, black, white, "a depth sampled where it lies, nearer than the reference" },
        .{ (near - 4) / 65535, white, white, "a reference four 65535ths nearer passes" },
        .{ (near + 4) / 65535, black, white, "and four further does not: all 16 bits are compared" },
    }) |one| {
        const reference, const wanted_left, const wanted_right, const name = one;
        const quad = [6][6]f32{
            .{ -1, -1, 0.5, 0, 0, reference },
            .{ 1, -1, 0.5, 1, 0, reference },
            .{ -1, 1, 0.5, 0, 1, reference },
            .{ -1, 1, 0.5, 0, 1, reference },
            .{ 1, -1, 0.5, 1, 0, reference },
            .{ 1, 1, 0.5, 1, 1, reference },
        };
        @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
        commands = probe.record() orelse return probe.check(false, "a recording for the sample");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = reading, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &one_clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, shade);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the sampling frame submitted");
        probe.checkEqual(wanted_left, pixelAt(pixels, pitch, 16, 8), name);
        probe.checkEqual(wanted_right, pixelAt(pixels, pitch, 48, 40), "and where the clear left its depth");
    }
}

// --- 1.40: the depth clamp and the depth bounds test -------------------------

fn boundsChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    const extent = facet.Extent3D{ .width = side, .height = side };
    const bounded = facet.PipelineDepthStencilStateCreateInfo{ .depth_bounds_test_enable = true, .min_depth_bounds = 0, .max_depth_bounds = 0.5 };
    const clamping = facet.PipelineRasterizationStateCreateInfo{ .depth_clamp_enable = true };

    // The depth stored where the device keeps one, so that what the clamp
    // left can be read back; in the tiles alone otherwise, which is all
    // the bounds test needs.
    const stores = probe.features.stored_depth;
    const pass = passKeeping(probe, .clear, .clear, if (stores) .store else .dont_care) orelse
        return probe.check(false, "a pass of a colour and a depth");
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Flat.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const range = facet.PushConstantRange{ .size = 4 };
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    if (!probe.features.depth_bounds) {
        probe.check(pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = bounded }) == null, "a depth bounds test refused where the device has none");
    }
    if (!probe.features.depth_clamp) {
        probe.check(pipelineOf(probe, pass, module.?, layout.?, .{ .raster = clamping }) == null, "a depth clamp refused where the device has none");
    }
    if (!probe.features.depth_bounds and !probe.features.depth_clamp) return;

    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const color_memory = probe.memories[0].?;
    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC }, 0) orelse
        return probe.check(false, "a depth image with memory behind it");
    const frame = probe.framebuffer(pass, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");
    const read_back, const back_bytes = probe.buffer(side * side * 2, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer to read the depth into");
    const whole = facet.BufferImageCopy{ .image_extent = extent, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } };

    // The left half at 0.25, then all of it where the bounds allow.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 },
        .{ -1, 1, 0.25 },  .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 },
        .{ -1, -1, 0.5 },  .{ 1, -1, 0.5 },  .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },   .{ 1, -1, 0.5 },  .{ 1, 1, 0.5 },
        // Wholly behind the near plane.
        .{ -1, -1, -0.5 }, .{ 1, -1, -0.5 }, .{ -1, 1, -0.5 },
        .{ -1, 1, -0.5 },  .{ 1, -1, -0.5 }, .{ 1, 1, -0.5 },
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const blue: u32 = 0xFF00_00FF;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(color[0], color_memory) orelse return probe.check(false, "the picture read back");

    if (probe.features.depth_bounds) {
        const marks = flatPipeline(probe, pass, module.?, layout.?) orelse return probe.check(false, "a pipeline that writes the depth");
        const in_bounds = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = bounded }) orelse
            return probe.check(false, "a pipeline whose bounds are tested");
        probe.check(true, "a pipeline whose bounds are tested");
        const dynamic_states = [1]facet.DynamicState{.depth_bounds};
        const by_command = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = .{ .depth_bounds_test_enable = true }, .dynamic = &dynamic_states }) orelse
            return probe.check(false, "a pipeline whose bounds a command sets");

        for ([3]struct { ?*facet.Pipeline, ?[2]f32, u32, u32, [*:0]const u8 }{
            .{ in_bounds, null, green, blue, "drawn where the depth already there is inside the bounds" },
            .{ by_command, .{ 0, 0.5 }, green, blue, "the same bounds set by a command" },
            .{ by_command, .{ 0.6, 1 }, red, green, "and the further half with other bounds" },
        }) |one| {
            const pipeline, const set, const wanted_left, const wanted_right, const name = one;
            const commands = probe.record() orelse return probe.check(false, "a recording");
            fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
            fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
            fb.CmdBindPipeline(commands, .graphics, marks);
            fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
            fb.CmdDraw(commands, 6, 1, 0, 0);
            fb.CmdBindPipeline(commands, .graphics, pipeline.?);
            if (set) |asked| fb.CmdSetDepthBounds(commands, asked[0], asked[1]);
            fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
            fb.CmdDraw(commands, 6, 1, 6, 0);
            fb.CmdEndRenderPass(commands);
            if (!probe.submit()) return probe.check(false, "the frame submitted");
            probe.checkEqual(wanted_left, pixelAt(pixels, pitch, 16, 8), name);
            probe.checkEqual(wanted_right, pixelAt(pixels, pitch, 48, 40), "and the other half of it");
        }
    }

    if (probe.features.depth_clamp) {
        // The viewport's own range, so what a clamped depth is held at is
        // not the whole of it.
        const low: f32 = 0.25;
        const writes = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .always };
        const plain = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = writes, .min_depth = low, .max_depth = 0.75 }) orelse
            return probe.check(false, "a pipeline that cuts at the near plane");
        const clamped = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = writes, .raster = clamping, .min_depth = low, .max_depth = 0.75 }) orelse
            return probe.check(false, "a pipeline that clamps its depth");
        probe.check(true, "a pipeline that clamps its depth");
        for ([2]struct { ?*facet.Pipeline, u32, [*:0]const u8 }{
            .{ plain, blue, "what lies behind the near plane is cut away without the clamp" },
            .{ clamped, red, "and drawn with it" },
        }) |one| {
            const pipeline, const wanted, const name = one;
            @memset(back_bytes[0 .. side * side * 2], 0xAA);
            const commands = probe.record() orelse return probe.check(false, "a recording for the clamp");
            fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
            fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
            fb.CmdBindPipeline(commands, .graphics, pipeline.?);
            fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
            fb.CmdDraw(commands, 6, 1, 12, 0);
            fb.CmdEndRenderPass(commands);
            if (stores) fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
            if (!probe.submit()) return probe.check(false, "the clamping frame submitted");
            probe.checkEqual(wanted, pixelAt(pixels, pitch, 16, 8), name);
            probe.checkEqual(wanted, pixelAt(pixels, pitch, 48, 40), "the same in another tile");
            // Its depth held at the viewport's nearest where it was
            // drawn, and the clear's where it was not - on a device that
            // keeps a depth to read back at all.
            if (stores) {
                const nearest: u16 = @intFromFloat(@round(low * 65535));
                const wanted_depth: u16 = if (wanted == red) nearest else 0xFFFF;
                probe.checkEqual(wanted_depth, depthAt(back_bytes, 16, 8), "and the depth it left");
            }
        }
    }
}

// --- 1.41: a compute group of many invocations -------------------------------

/// A group of sixteen invocations: each writes its own number in the group
/// into the memory they share, and then - where a barrier would stand,
/// between the two loops of the one call the group gets - each is copied out
/// to where its number in the dispatch says.
const Grouped = struct {
    fn run(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 0) orelse return;
        const held = groups.sharedAs(u32, 64) orelse return;
        for (0..groups.local[1]) |y| for (0..groups.local[0]) |x| {
            const local = [3]u32{ @intCast(x), @intCast(y), 0 };
            held[groups.localIndex(local)] = groups.localIndex(local) + 1;
        };
        for (0..groups.local[1]) |y| for (0..groups.local[0]) |x| {
            const local = [3]u32{ @intCast(x), @intCast(y), 0 };
            const at = groups.globalInvocation(local);
            const where = at[0] + at[1] * groups.local[0] * groups.count[0];
            if (where < out.len) out[where] = held[groups.localIndex(local)] + groups.invocations() * 100;
        };
    }

    /// An entry that asked for neither: one invocation a group, and no
    /// shared memory to be had.
    fn alone(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 0) orelse return;
        if (out.len < 52) return;
        out[48] = groups.invocations();
        out[49] = groups.shared_bytes;
        out[50] = if (groups.sharedAs(u32, 1) == null) 1 else 0;
        out[51] = groups.localIndex(.{ 0, 0, 0 }) + 1;
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.computeGroup("main", &run, .{ 8, 2, 1 }, 256),
        facet.shader.compute("alone", &alone),
        // Refused: more invocations a group than the device holds, and more
        // shared memory than it has.
        facet.shader.computeGroup("crowd", &run, .{ 64, 64, 1 }, 0),
        facet.shader.computeGroup("greedy", &run, .{ 1, 1, 1 }, 60 * 1024),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn groupChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    // What the entry carries is what the library goes by.
    probe.checkEqual(8, Grouped.entries[0].localSize()[0], "the entry carries its group's size");
    probe.checkEqual(1024, Grouped.entries[0].sharedBytes(), "and the bytes it shares, a whole KiB of them");
    probe.checkEqual(1, Grouped.entries[1].localSize()[1], "an entry that asked for nothing holds one invocation");

    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    const limits = &properties.limits;
    probe.check(limits.max_compute_work_group_size[0] >= 8 and limits.max_compute_work_group_size[1] >= 2, "the limits say how large a group may be");
    probe.check(limits.max_compute_work_group_invocations >= 16, "and how many invocations it may hold");
    probe.check(limits.max_compute_shared_memory_size >= 1024, "and how much they may share");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Grouped.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a storage buffer");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const storage, const storage_bytes = probe.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = storage, .range = facet.WHOLE_SIZE };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
    const out: [*]u32 = @ptrCast(@alignCast(storage_bytes));

    const names = [2][*:0]const u8{ "main", "alone" };
    var infos: [names.len]facet.ComputePipelineCreateInfo = undefined;
    for (&infos, names) |*info, name| info.* = .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = name }, .layout = layout.? };
    var pipelines: [names.len]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, names.len, &infos, &pipelines) != .success) return probe.check(false, "the compute pipelines");
    for (pipelines) |made| _ = Probe.keep(&probe.pipelines, made);

    // A group over the device's limits is refused, not cut to what fits.
    for ([2][*:0]const u8{ "crowd", "greedy" }) |name| {
        var refused: [1]?*facet.Pipeline = undefined;
        const over = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = name }, .layout = layout.? };
        probe.check(fb.CreateComputePipelines(device, null, 1, @ptrCast(&over), &refused) == .error_feature_not_present, "a group over the limits refused");
        probe.check(refused[0] == null, "and nothing given back for it");
    }

    // Two groups of sixteen invocations: thirty-two in all, each writing
    // where its own number in the dispatch says.
    @memset(storage_bytes[0..256], 0);
    const commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 2, 1, 1);
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the dispatches submitted");
    var right = true;
    for (0..2) |y| for (0..16) |x| {
        const wanted: u32 = @intCast(x % 8 + 8 * y + 1 + 1600);
        right = right and out[x + 16 * y] == wanted;
    };
    probe.check(right, "every invocation of every group ran, through the memory they share");
    probe.checkEqual(0, out[32], "and none wrote past them");
    probe.checkEqual(1, out[48], "an entry that asked for nothing is one invocation a group");
    probe.checkEqual(0, out[49], "with nothing shared");
    probe.checkEqual(1, out[50], "and nothing to be had where none was asked for");
    probe.checkEqual(1, out[51], "its one invocation is the group's first");
}

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
    storageImageChecks(&probe);
    texelBufferChecks(&probe);
    blendChecks(&probe);
    biasChecks(&probe);
    dynamicChecks(&probe);
    queryChecks(&probe);
    inputChecks(&probe);
    stencilChecks(&probe);
    sampledDepthChecks(&probe);
    boundsChecks(&probe);
    groupChecks(&probe);
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
