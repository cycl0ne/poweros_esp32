// SPDX-License-Identifier: MIT
//! Host tests of facet.library's drawing: render passes, framebuffers,
//! shader modules, descriptor sets and pipelines, made and refused, and
//! frames drawn through them - a triangle, depths in order, and the cube
//! as C:test/FacetCube draws it (c/test/raster/facetscene.zig), against the
//! picture the rasterizer draws of it by itself
//! (c/test/raster/reference/cube.ppm): into an image, and through a
//! swapchain on a window of the test's own, copied where the window is.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const rig_zig = @import("facet.zig");
const Rig = rig_zig.Rig;
const scenes = @import("../../../c/test/raster/scenes.zig");
const _cmdupdate = @import("../command/cmdupdatebuffer.zig");
const scene = @import("../../../c/test/raster/facetscene.zig");
const _objects = @import("../_objects.zig");
const _surface = @import("../surface/_surface.zig");
const _instance = @import("../instance/_instance.zig");
const Instance = _instance.Instance;
const _driver = @import("../driver/_driver.zig");
const cpu = @import("../driver/cpu/cpu.zig");
const _sync = @import("../sync/_sync.zig");
const Device = @import("../device/_device.zig").Device;
const DeviceMemory = @import("../memory/_memory.zig").DeviceMemory;
const Queue = @import("../queue/_queue.zig").Queue;
const CommandBuffer = @import("../command/_command.zig").CommandBuffer;
const _render = @import("../render/_render.zig");
const _shader = @import("../shader/_shader.zig");
const _descriptor = @import("../descriptor/_descriptor.zig");
const _sampler = @import("../sampler/_sampler.zig");
const _pipeline = @import("../pipeline/_pipeline.zig");
const testing = std.testing;

test {
    _ = @import("../driver/_tessellate.zig");
    _ = @import("../driver/_driver.zig");
    _ = @import("../query/_query.zig");
}

/// What a test draws with: a device and its queue, a command buffer and a
/// fence, and what it made, given back by `down`.
const Bench = struct {
    rig: Rig,
    instance: *facet.Instance,
    physical: *facet.PhysicalDevice,
    device: *facet.Device,
    queue: *facet.Queue,
    pool: *facet.CommandPool,
    commands: *facet.CommandBuffer,
    fence: *facet.Fence,
    memories: [16]*facet.DeviceMemory = undefined,
    memory_count: u32 = 0,
    images: [16]*facet.Image = undefined,
    image_count: u32 = 0,
    views: [16]*facet.ImageView = undefined,
    view_count: u32 = 0,
    buffers: [8]*facet.Buffer = undefined,
    buffer_count: u32 = 0,

    fn up() !Bench {
        return on(null);
    }

    /// With `driver`'s table in place of the physical device's own.
    fn on(driver: ?*const _driver.Ops) !Bench {
        var rig = try Rig.up();
        const instance, const physical = try rig.instance();
        if (driver) |ops| _objects.of(_instance.PhysicalDevice, physical).ops = ops;
        const device = try rig.device(physical);
        var queue: ?*facet.Queue = null;
        rig.fb.GetDeviceQueue(device, 0, 0, &queue);
        var pool: ?*facet.CommandPool = null;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &pool));
        var commands: [1]?*facet.CommandBuffer = undefined;
        try testing.expectEqual(facet.Result.success, rig.fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.?, .command_buffer_count = 1 }, &commands));
        var fence: ?*facet.Fence = null;
        try testing.expectEqual(facet.Result.success, rig.fb.CreateFence(device, &.{}, &fence));
        return .{ .rig = rig, .instance = instance, .physical = physical, .device = device, .queue = queue.?, .pool = pool.?, .commands = commands[0].?, .fence = fence.? };
    }

    fn down(bench: *Bench) void {
        const fb = bench.rig.fb;
        const device = bench.device;
        _ = fb.DeviceWaitIdle(device);
        for (bench.views[0..bench.view_count]) |each| fb.DestroyImageView(device, each);
        for (bench.images[0..bench.image_count]) |each| fb.DestroyImage(device, each);
        for (bench.buffers[0..bench.buffer_count]) |each| fb.DestroyBuffer(device, each);
        for (bench.memories[0..bench.memory_count]) |each| fb.FreeMemory(device, each);
        fb.DestroyFence(device, bench.fence);
        fb.DestroyCommandPool(device, bench.pool);
        fb.DestroyDevice(device);
        fb.DestroyInstance(bench.instance);
        bench.rig.down() catch |err| std.debug.panic("{}", .{err});
    }

    /// A block of memory of type `type_index`.
    fn memory(bench: *Bench, bytes: u64, type_index: u32) !*facet.DeviceMemory {
        var made: ?*facet.DeviceMemory = null;
        try testing.expectEqual(facet.Result.success, bench.rig.fb.AllocateMemory(bench.device, &.{ .allocation_size = bytes, .memory_type_index = type_index }, &made));
        bench.memories[bench.memory_count] = made.?;
        bench.memory_count += 1;
        return made.?;
    }

    /// A buffer of `bytes`, bound into memory of its own, and its bytes.
    fn buffer(bench: *Bench, bytes: u64, usage: u32) !struct { *facet.Buffer, [*]u8 } {
        const made, const block, const data = try rig_zig.mappedBuffer(&bench.rig, bench.device, bytes, usage);
        bench.buffers[bench.buffer_count] = made;
        bench.buffer_count += 1;
        bench.memories[bench.memory_count] = block;
        bench.memory_count += 1;
        return .{ made, data };
    }

    /// An image as `info` says, bound into memory of its own - of the
    /// lazily allocated type, type 2, with `lazy` - and a view of it.
    fn image(bench: *Bench, info: facet.ImageCreateInfo, lazy: bool) !struct { *facet.Image, *facet.ImageView } {
        const made = try bench.bareImage(info, lazy);
        const aspect = if (info.format == .d16_unorm) facet.IMAGE_ASPECT_DEPTH else facet.IMAGE_ASPECT_COLOR;
        return .{ made, try bench.viewOf(.{ .image = made, .format = info.format, .subresource_range = .{ .aspect_mask = aspect } }) };
    }

    fn viewOf(bench: *Bench, info: facet.ImageViewCreateInfo) !*facet.ImageView {
        var view: ?*facet.ImageView = null;
        try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateImageView(bench.device, &info, &view));
        bench.views[bench.view_count] = view.?;
        bench.view_count += 1;
        return view.?;
    }

    fn bareImage(bench: *Bench, info: facet.ImageCreateInfo, lazy: bool) !*facet.Image {
        const fb = bench.rig.fb;
        var made: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.success, fb.CreateImage(bench.device, &info, &made));
        bench.images[bench.image_count] = made.?;
        bench.image_count += 1;
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(bench.device, made.?, &needs);
        const block = try bench.memory(needs.size, if (lazy) 2 else 0);
        try testing.expectEqual(facet.Result.success, fb.BindImageMemory(bench.device, made.?, block, 0));
        return made.?;
    }

    /// The command buffer, begun.
    fn record(bench: *Bench) !*facet.CommandBuffer {
        try testing.expectEqual(facet.Result.success, bench.rig.fb.BeginCommandBuffer(bench.commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }));
        return bench.commands;
    }

    /// The command buffer ended, submitted and waited for.
    fn submit(bench: *Bench) !void {
        const fb = bench.rig.fb;
        try testing.expectEqual(facet.Result.success, fb.EndCommandBuffer(bench.commands));
        try testing.expectEqual(facet.Result.success, fb.ResetFences(bench.device, 1, @ptrCast(&bench.fence)));
        const submit_info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&bench.commands) };
        try testing.expectEqual(facet.Result.success, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit_info), bench.fence));
        try testing.expectEqual(facet.Result.success, fb.WaitForFences(bench.device, 1, @ptrCast(&bench.fence), true, facet.WAIT_FOREVER_NS));
    }
};

/// A linear colour image drawn into: its pixels as 0xAARRGGBB.
const Picture = struct {
    image: *facet.Image,
    view: *facet.ImageView,
    pixels: [*]const u8,
    pitch: usize,
    width: u32,
    height: u32,

    fn of(bench: *Bench, width: u32, height: u32) !Picture {
        const image, const view = try bench.image(.{
            .format = .b8g8r8a8_unorm,
            .extent = .{ .width = width, .height = height },
            .tiling = .linear,
            .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC,
        }, false);
        var layout: facet.SubresourceLayout = undefined;
        bench.rig.fb.GetImageSubresourceLayout(bench.device, image, &.{}, &layout);
        const made = _objects.of(@import("../image/_image.zig").Image, image);
        return .{ .image = image, .view = view, .pixels = made.data.?, .pitch = @intCast(layout.row_pitch), .width = width, .height = height };
    }

    fn at(picture: *const Picture, x: u32, y: u32) u32 {
        return std.mem.readInt(u32, picture.pixels[y * picture.pitch + x * 4 ..][0..4], .little);
    }
};

// --- shaders -----------------------------------------------------------------

/// One colour, the push constants', over triangles whose vertices are
/// three floats at location 0, already in clip space.
const Flat = struct {
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn fragment(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, fragments.resources.constants(u32).*);
    }

    const entries = [_]shader.Entry{ shader.vertex("main", &vertex, 0), shader.fragment("main", &fragment, 0) };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

// --- a driver watched ---------------------------------------------------------

/// The cores as a driver, what they are asked counted. A command buffer is
/// done before `done` is signalled, as one a piece of hardware runs is
/// before its interrupt: `told_early` says whether the program heard first.
const Watched = struct {
    var opened: u32 = 0;
    var closed: u32 = 0;
    var allocated: u32 = 0;
    var freed: u32 = 0;
    var made: u32 = 0;
    var unmade: u32 = 0;
    var executed: u32 = 0;
    var told_early = false;
    var fence: ?*_sync.Fence = null;

    const ops = _driver.Ops{
        .describe = cpu.ops.describe,
        .format_properties = cpu.ops.format_properties,
        .allocate_memory = &allocateMemory,
        .free_memory = &freeMemory,
        .make_pipeline = &makeOne,
        .unmake_pipeline = &unmakePipeline,
        .open_queue = &openQueue,
        .close_queue = &closeQueue,
        .execute = &execute,
    };

    fn allocateMemory(device: *Device, memory: *DeviceMemory) callconv(.c) facet.Result {
        allocated += 1;
        return cpu.ops.allocate_memory(device, memory);
    }

    fn freeMemory(device: *Device, memory: *DeviceMemory) callconv(.c) void {
        freed += 1;
        cpu.ops.free_memory(device, memory);
    }

    fn makeOne(pipeline: *_pipeline.Pipeline) callconv(.c) facet.Result {
        made += 1;
        return cpu.ops.make_pipeline(pipeline);
    }

    fn unmakePipeline(pipeline: *_pipeline.Pipeline) callconv(.c) void {
        unmade += 1;
        cpu.ops.unmake_pipeline(pipeline);
    }

    fn openQueue(queue: *Queue) callconv(.c) bool {
        opened += 1;
        return cpu.ops.open_queue(queue);
    }

    fn closeQueue(queue: *Queue) callconv(.c) void {
        closed += 1;
        cpu.ops.close_queue(queue);
    }

    fn execute(queue: *Queue, buffer: *CommandBuffer, done: *sdk.exec.Waitable) callconv(.c) void {
        executed += 1;
        var finished: sdk.exec.Waitable = .{};
        cpu.ops.execute(queue, buffer, &finished);
        told_early = fence.?.waitable.signalled != 0;
        queue.device.sys.SignalWaitable(done);
    }
};

// --- what the tests make -----------------------------------------------------

fn renderPass(bench: *Bench, color_load: facet.AttachmentLoadOp, with_depth: bool) !*facet.RenderPass {
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = color_load, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = if (with_depth) &depth else null };
    var made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateRenderPass(bench.device, &.{ .attachment_count = if (with_depth) 2 else 1, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &made));
    return made.?;
}

fn framebuffer(bench: *Bench, pass: *facet.RenderPass, views: []const *facet.ImageView, width: u32, height: u32) !*facet.Framebuffer {
    var made: ?*facet.Framebuffer = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateFramebuffer(bench.device, &.{ .render_pass = pass, .attachment_count = @intCast(views.len), .attachments = views.ptr, .width = width, .height = height }, &made));
    return made.?;
}

fn module(bench: *Bench, code: *const shader.Code) !*facet.ShaderModule {
    var made: ?*facet.ShaderModule = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateShaderModule(bench.device, &.{ .code = code }, &made));
    return made.?;
}

/// The state of a pipeline a test changes, with what the rest takes.
const PipelineState = struct {
    module: *facet.ShaderModule,
    name: [*:0]const u8 = "main",
    layout: *facet.PipelineLayout,
    pass: *facet.RenderPass,
    stride: u32 = 12,
    attributes: []const facet.VertexInputAttributeDescription = &.{.{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat }},
    topology: facet.PrimitiveTopology = .triangle_list,
    restart: bool = false,
    raster: facet.PipelineRasterizationStateCreateInfo = .{},
    depth: facet.PipelineDepthStencilStateCreateInfo = .{},
    blend: facet.PipelineColorBlendAttachmentState = .{},
    width: f32 = 64,
    height: f32 = 64,
    dynamic: []const facet.DynamicState = &.{},
    flags: u32 = 0,
    subpass: u32 = 0,
    blend_count: u32 = 1,
};

fn makePipeline(bench: *Bench, state: PipelineState) struct { facet.Result, ?*facet.Pipeline } {
    const stages = [2]facet.PipelineShaderStageCreateInfo{
        .{ .stage = facet.SHADER_STAGE_VERTEX, .module = state.module, .name = state.name },
        .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = state.module, .name = state.name },
    };
    const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = state.stride };
    const input = facet.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = @intCast(state.attributes.len),
        .vertex_attribute_descriptions = state.attributes.ptr,
    };
    const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = state.topology, .primitive_restart_enable = state.restart };
    const viewport = facet.Viewport{ .width = state.width, .height = state.height };
    const scissor = facet.Rect2D{ .extent = .{ .width = @intFromFloat(state.width), .height = @intFromFloat(state.height) } };
    const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
    const blends: [4]facet.PipelineColorBlendAttachmentState = @splat(state.blend);
    const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = state.blend_count, .attachments = &blends };
    const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = @intCast(state.dynamic.len), .dynamic_states = state.dynamic.ptr };
    const info = facet.GraphicsPipelineCreateInfo{
        .flags = state.flags,
        .stage_count = 2,
        .stages = &stages,
        .vertex_input_state = &input,
        .input_assembly_state = &assembly,
        .viewport_state = &view,
        .rasterization_state = &state.raster,
        .depth_stencil_state = &state.depth,
        .color_blend_state = &blend,
        .dynamic_state = &dynamic,
        .layout = state.layout,
        .render_pass = state.pass,
        .subpass = state.subpass,
    };
    var made: [1]?*facet.Pipeline = undefined;
    const result = bench.rig.fb.CreateGraphicsPipelines(bench.device, null, 1, @ptrCast(&info), &made);
    return .{ result, made[0] };
}

fn pipelineLayout(bench: *Bench, set_layouts: []const *facet.DescriptorSetLayout, push: u32) !*facet.PipelineLayout {
    const range = facet.PushConstantRange{ .size = push };
    var made: ?*facet.PipelineLayout = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreatePipelineLayout(bench.device, &.{
        .set_layout_count = @intCast(set_layouts.len),
        .set_layouts = set_layouts.ptr,
        .push_constant_range_count = if (push == 0) 0 else 1,
        .push_constant_ranges = @ptrCast(&range),
    }, &made));
    return made.?;
}

/// A clear value of a colour, 0xAARRGGBB, and of the depth 1.
fn clears(color: u32) [2]facet.ClearValue {
    var rgba: [4]f32 = undefined;
    for (&rgba, [4]u5{ 16, 8, 0, 24 }) |*channel, shift| channel.* = @as(f32, @floatFromInt(color >> shift & 0xFF)) / 255;
    return .{ .{ .color = .{ .float32 = rgba } }, .{ .depth_stencil = .{ .depth = 1 } } };
}

// --- the tests ---------------------------------------------------------------

test "a render pass: one subpass, a colour attachment and perhaps a depth one; what facet.library cannot draw refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    const pass = try renderPass(&bench, .load, true);
    const made = _objects.of(_render.RenderPass, pass);
    try testing.expectEqual(@as(u32, 0), made.parts[0].color);
    try testing.expectEqual(@as(?u32, 1), made.parts[0].depth);
    try testing.expectEqual(.keep, made.parts[0].color_load);
    fb.DestroyRenderPass(device, pass);
    fb.DestroyRenderPass(device, null);

    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    const refused = [_]struct { facet.Result, [2]facet.AttachmentDescription }{
        // The depth stored, or loaded: it lives in the tiles alone.
        .{ .error_feature_not_present, .{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .d16_unorm, .store_op = .store, .final_layout = .general } } },
        .{ .error_feature_not_present, .{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .d16_unorm, .load_op = .load, .final_layout = .general } } },
        // A colour attachment of a float, a depth one of 32 bits.
        .{ .error_format_not_supported, .{ .{ .format = .r32_sfloat, .final_layout = .general }, .{ .format = .d16_unorm, .final_layout = .general } } },
        .{ .error_format_not_supported, .{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .r32_sfloat, .final_layout = .general } } },
        // Multisampled.
        .{ .error_feature_not_present, .{ .{ .format = .b8g8r8a8_unorm, .samples = 4, .final_layout = .general }, .{ .format = .d16_unorm, .final_layout = .general } } },
    };
    for (refused) |case| {
        var none: ?*facet.RenderPass = null;
        try testing.expectEqual(case[0], fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &case[1], .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &none));
        try testing.expect(none == null);
    }
    // A reference past the attachments; more subpasses than there can be; none
    // of colour.
    const fine = [2]facet.AttachmentDescription{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .d16_unorm, .final_layout = .general } };
    var none: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = &fine, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &none));
    const five: [5]facet.SubpassDescription = @splat(subpass);
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &fine, .subpass_count = 5, .subpasses = &five }, &none));
    const depth_alone = facet.SubpassDescription{ .depth_stencil_attachment = &depth };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &fine, .subpass_count = 1, .subpasses = @ptrCast(&depth_alone) }, &none));
}

test "a framebuffer: a view for each attachment, of images that fit the pass" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const picture = try Picture.of(&bench, 64, 64);
    _, const depth = try bench.image(.{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, true);
    _, const sampled = try bench.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_SAMPLED }, false);

    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth }, 48, 64);
    const made = _objects.of(_render.Framebuffer, frame);
    try testing.expectEqual(@as(u32, 48), made.width);
    try testing.expect(made.targets[0].depth != null);
    fb.DestroyFramebuffer(device, frame);
    fb.DestroyFramebuffer(device, null);

    var none: ?*facet.Framebuffer = null;
    const cases = [_]struct { [2]*facet.ImageView, u32, u32 }{
        // Larger than its images; a texture to draw into; a colour image for depth.
        .{ .{ picture.view, depth }, 65, 64 },
        .{ .{ sampled, depth }, 64, 64 },
        .{ .{ picture.view, picture.view }, 64, 64 },
    };
    for (cases) |case| {
        try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateFramebuffer(device, &.{ .render_pass = pass, .attachment_count = 2, .attachments = &case[0], .width = case[1], .height = case[2] }, &none));
    }
    // One view for a pass of two attachments.
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateFramebuffer(device, &.{ .render_pass = pass, .attachment_count = 1, .attachments = @ptrCast(&picture.view), .width = 64, .height = 64 }, &none));
    try testing.expect(none == null);
}

test "a shader module: the entries of a shader.Code, found by stage and name; SPIR-V refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    const made = try module(&bench, &scene.code);
    defer fb.DestroyShaderModule(device, made);
    const kept = _objects.of(_shader.ShaderModule, made);
    try testing.expectEqual(@as(usize, 5), kept.entries().len);
    const box = _shader.find(kept, facet.SHADER_STAGE_FRAGMENT, "box").?;
    try testing.expectEqual(@as(u32, 2), box.varyingCount());
    try testing.expect(_shader.find(kept, facet.SHADER_STAGE_VERTEX, "main") == null);
    fb.DestroyShaderModule(device, null);

    var none: ?*facet.ShaderModule = null;
    const spirv = [5]u32{ 0x0723_0203, 0x0001_0000, 0, 1, 0 };
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateShaderModule(device, &.{ .code_size = @sizeOf(@TypeOf(spirv)), .code = &spirv }, &none));
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateShaderModule(device, &.{ .code_size = 4, .code = &Flat.code }, &none));
    const unknown = [1]shader.Entry{.{ .name = "main", .stage = 0x40, .function = &Flat.vertex, .varyings = 0 }};
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateShaderModule(device, &.{ .code = &shader.Code{ .entry_count = 1, .entries = &unknown } }, &none));
    const too_many = [1]shader.Entry{shader.vertex("main", &Flat.vertex, 9)};
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateShaderModule(device, &.{ .code = &shader.Code{ .entry_count = 1, .entries = &too_many } }, &none));
    try testing.expect(none == null);
}

test "descriptor sets: a layout's bindings as slots, written and copied as shaders read them; a pool's most" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // Binding 0 two textures, binding 1 none, binding 2 a uniform buffer.
    const bindings = [_]facet.DescriptorSetLayoutBinding{
        .{ .binding = 2, .descriptor_type = .uniform_buffer },
        .{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 2 },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .bindings = &bindings }, &set_layout));
    const layout_made = _objects.of(_descriptor.SetLayout, set_layout.?);
    try testing.expectEqual(@as(u32, 3), layout_made.binding_count);
    try testing.expectEqual(@as(u32, 3), layout_made.slot_count);
    try testing.expectEqual(@as(u16, 2), layout_made.bindings()[2].first);

    var none: ?*facet.DescriptorSetLayout = null;
    // Samplers and combined image samplers are kinds a layout may have;
    // the kinds there are none of, and a sampler the layout would hold
    // itself, are refused.
    const combined = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&combined) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
    none = null;
    const storage_image = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_image };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&storage_image) }, &none));
    var kept: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{}, &kept));
    defer fb.DestroySampler(device, kept);
    const held = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .immutable_samplers = @ptrCast(&kept) };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&held) }, &none));
    const twice = [2]facet.DescriptorSetLayoutBinding{ bindings[0], bindings[0] };
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &twice }, &none));

    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    const layouts = [3]*facet.DescriptorSetLayout{ set_layout.?, set_layout.?, set_layout.? };
    var sets: [3]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.error_out_of_pool_memory, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 3, .set_layouts = &layouts }, &sets));
    for (sets) |set| try testing.expect(set == null);
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 2, .set_layouts = &layouts }, &sets));
    // The layout may go: the sets keep what they need of it.
    fb.DestroyDescriptorSetLayout(device, set_layout);

    const uniform, const uniform_bytes = try bench.buffer(256, facet.BUFFER_USAGE_UNIFORM_BUFFER);
    _, const texture_view = try bench.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_SAMPLED }, false);
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = uniform, .offset = 64, .range = 32 };
    // Two images from element 1 of binding 0 on: the second runs on into
    // binding 2, a buffer's, and is passed over.
    const images = [2]facet.DescriptorImageInfo{ .{ .image_view = texture_view }, .{ .image_view = texture_view } };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 2, .descriptor_type = .uniform_buffer, .buffer_info = @ptrCast(&buffer_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 0, .dst_array_element = 1, .descriptor_count = 2, .descriptor_type = .sampled_image, .image_info = &images },
    };
    const copy = facet.CopyDescriptorSet{ .src_set = sets[0].?, .src_binding = 0, .dst_set = sets[1].?, .dst_binding = 0, .descriptor_count = 3 };
    fb.UpdateDescriptorSets(device, writes.len, &writes, 1, @ptrCast(&copy));

    for (sets[0..2]) |set| {
        const made = _objects.of(_descriptor.Set, set.?);
        const resources = shader.Resources{ .sets = .{ &made.view, null, null, null } };
        try testing.expect(resources.sampled(0, 0, 0) == null);
        const view = _objects.of(@import("../image/_image.zig").ImageView, texture_view);
        try testing.expectEqual(@as(?*const facet.texture.Texture, &view.texels), resources.sampled(0, 0, 1));
        try testing.expect(resources.sampled(0, 0, 2) == null);
        try testing.expect(resources.sampled(0, 1, 0) == null);
        const Block = extern struct { values: [8]u32 };
        try testing.expectEqual(@as(?*const Block, @ptrCast(@alignCast(uniform_bytes + 64))), resources.buffer(Block, 0, 2));
        try testing.expect(resources.buffer([9]u32, 0, 2) == null);
        try testing.expect(resources.buffer(u32, 1, 0) == null);
    }

    try testing.expectEqual(facet.Result.success, fb.FreeDescriptorSets(device, pool.?, 1, @ptrCast(&sets[1])));
    var again: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = &layouts }, &again));
    try testing.expectEqual(facet.Result.success, fb.ResetDescriptorPool(device, pool.?, 0));
    try testing.expectEqual(@as(u32, 0), _objects.of(_descriptor.Pool, pool.?).count);
}

test "a pipeline: its functions and its state settled as it is made; what facet.library cannot draw refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const shaders = try module(&bench, &scene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);

    const base = PipelineState{ .module = flat, .layout = layout, .pass = pass };
    var state = base;
    state.raster = .{ .cull_mode = facet.CULL_MODE_BACK, .front_face = .clockwise };
    state.depth = .{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .greater_or_equal };
    state.blend = .{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one_minus_src_alpha, .src_alpha_blend_factor = .one };
    state.dynamic = &.{.scissor};
    const result, const pipeline = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, result);
    const made = _objects.of(_pipeline.Pipeline, pipeline.?);
    try testing.expectEqual(.back, made.cull);
    try testing.expectEqual(.clockwise, made.front);
    try testing.expectEqual(.greater_or_equal, made.depth_test.?);
    try testing.expect(made.depth_write);
    try testing.expect(!made.prepass);
    try testing.expect(made.mixing.enabled);
    try testing.expectEqual(.one_minus_src_alpha, made.mixing.dst_color);
    try testing.expectEqual(@as(f32, 64), made.viewport.?.width);
    try testing.expect(made.scissor == null);
    try testing.expectEqual(@as(u32, 1), made.locations);
    fb.DestroyPipeline(device, pipeline);
    fb.DestroyPipeline(device, null);

    var added = base;
    added.blend = .{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one };
    const added_result, const added_pipeline = makePipeline(&bench, added);
    try testing.expectEqual(facet.Result.success, added_result);
    try testing.expectEqual(.one, _objects.of(_pipeline.Pipeline, added_pipeline.?).mixing.dst_color);
    fb.DestroyPipeline(device, added_pipeline);

    // The rasterizer discarding, or both faces culled: made, draws nothing.
    state = base;
    state.raster = .{ .cull_mode = facet.CULL_MODE_FRONT_AND_BACK };
    const culled_result, const culled = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, culled_result);
    try testing.expect(_objects.of(_pipeline.Pipeline, culled.?).draws_nothing);
    fb.DestroyPipeline(device, culled);

    // What the cores draw each with, and that the quick ways keep to their terms.
    const _cpu_draw = @import("../driver/cpu/_draw.zig");
    const laid: _pipeline.Mixing = .{ .enabled = true, .src_color = .src_alpha, .dst_color = .one_minus_src_alpha };
    var mixing = laid;
    mixing.src_alpha = .src_alpha;
    mixing.dst_alpha = .one_minus_src_alpha;
    try testing.expectEqual(.alpha, _cpu_draw.blendOf(&mixing));
    mixing.src_alpha = .zero;
    mixing.dst_alpha = .one;
    try testing.expectEqual(.alpha_keep, _cpu_draw.blendOf(&mixing));
    mixing.dst_color = .one;
    try testing.expectEqual(.add_keep, _cpu_draw.blendOf(&mixing));
    mixing.src_alpha = .src_alpha;
    mixing.dst_alpha = .one;
    try testing.expectEqual(.add, _cpu_draw.blendOf(&mixing));
    mixing.dst_alpha = .zero;
    try testing.expectEqual(.general, _cpu_draw.blendOf(&mixing));
    try testing.expectEqual(.general, _cpu_draw.blendOf(&laid));
    try testing.expectEqual(.off, _cpu_draw.blendOf(&_pipeline.Mixing{}));
    try testing.expectEqual(.general, _cpu_draw.blendOf(&_pipeline.Mixing{ .mask = facet.COLOR_COMPONENT_R }));
    mixing = laid;
    mixing.src_alpha = .src_alpha;
    mixing.dst_alpha = .one_minus_src_alpha;
    mixing.mask = facet.COLOR_COMPONENT_R;
    try testing.expectEqual(.general, _cpu_draw.blendOf(&mixing));
    // Over no alpha, what is there is opaque.
    const over = (_pipeline.Mixing{ .enabled = true, .src_color = .one_minus_dst_alpha, .dst_color = .dst_alpha, .src_alpha = .src_alpha_saturate }).overOpaque();
    try testing.expectEqual(.zero, over.src_color);
    try testing.expectEqual(.one, over.dst_color);
    try testing.expectEqual(.zero, over.src_alpha);

    const Change = struct { facet.Result, PipelineState };
    var changes: [9]Change = @splat(.{ .success, base });
    changes[0][0] = .error_feature_not_present;
    changes[0][1].topology = @enumFromInt(11);
    changes[1][0] = .error_feature_not_present;
    changes[1][1].depth = .{ .depth_bounds_test_enable = true };
    changes[2][0] = .error_feature_not_present;
    changes[2][1].blend = .{ .blend_enable = true, .src_color_blend_factor = @enumFromInt(15), .dst_color_blend_factor = .one };
    changes[3][0] = .error_feature_not_present;
    changes[3][1].blend = .{ .blend_enable = true, .color_blend_op = @enumFromInt(5) };
    changes[4][0] = .error_feature_not_present;
    changes[4][1].raster = .{ .polygon_mode = @enumFromInt(3) };
    changes[5][0] = .error_format_not_supported;
    changes[5][1].attributes = &.{.{ .location = 0, .binding = 0, .format = .r5g6b5_unorm_pack16 }};
    changes[6][0] = .error_initialization_failed;
    changes[6][1].attributes = &.{.{ .location = 0, .binding = 1, .format = .r32_sfloat }};
    // No such entry; a vertex and a fragment function of other varyings.
    changes[7][0] = .error_invalid_shader_nv;
    changes[7][1].name = "box";
    changes[8][0] = .error_invalid_shader_nv;
    changes[8][1].module = shaders;
    for (changes) |change| {
        const refused, const none = makePipeline(&bench, change[1]);
        try testing.expectEqual(change[0], refused);
        try testing.expect(none == null);
    }
}

test "a device's work goes through its driver's table; its fence waits for the driver's done" {
    var bench = try Bench.on(&Watched.ops);
    const fb = bench.rig.fb;
    const device = bench.device;
    try testing.expectEqual(@as(u32, 1), Watched.opened);

    _ = try bench.memory(4096, 0);
    try testing.expectEqual(@as(u32, 1), Watched.allocated);
    // The lazily allocated type has nothing behind it to ask for.
    _ = try bench.memory(4096, 2);
    try testing.expectEqual(@as(u32, 1), Watched.allocated);

    const pass = try renderPass(&bench, .clear, false);
    const flat = try module(&bench, &Flat.code);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    _, const pipeline = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass });
    try testing.expectEqual(@as(u32, 1), Watched.made);
    fb.DestroyPipeline(device, pipeline);
    try testing.expectEqual(@as(u32, 1), Watched.unmade);
    fb.DestroyPipelineLayout(device, layout);
    fb.DestroyShaderModule(device, flat);
    fb.DestroyRenderPass(device, pass);

    Watched.fence = _objects.of(_sync.Fence, bench.fence);
    _ = try bench.record();
    try bench.submit();
    try testing.expectEqual(@as(u32, 1), Watched.executed);
    try testing.expect(!Watched.told_early);

    bench.down();
    try testing.expectEqual(@as(u32, 1), Watched.freed);
    try testing.expectEqual(@as(u32, 1), Watched.closed);
}

/// A driver that loses its device at the first command buffer it is given.
const Losing = struct {
    var executed: u32 = 0;

    const ops = ops: {
        var made = cpu.ops;
        made.execute = &execute;
        break :ops made;
    };

    fn execute(queue: *Queue, buffer: *CommandBuffer, done: *sdk.exec.Waitable) callconv(.c) void {
        _ = buffer;
        executed += 1;
        queue.device.lose();
        queue.device.sys.SignalWaitable(done);
    }
};

test "a device lost: its fence signalled all the same, nothing more played, and every call says so" {
    Losing.executed = 0;
    var bench = try Bench.on(&Losing.ops);
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var second: [1]?*facet.CommandBuffer = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateCommandBuffers(device, &.{ .command_pool = bench.pool, .command_buffer_count = 1 }, &second));
    const both = [2]*facet.CommandBuffer{ bench.commands, second[0].? };
    for (both) |commands| {
        try testing.expectEqual(facet.Result.success, fb.BeginCommandBuffer(commands, &.{}));
        try testing.expectEqual(facet.Result.success, fb.EndCommandBuffer(commands));
    }
    const submit_info = facet.SubmitInfo{ .command_buffer_count = both.len, .command_buffers = @ptrCast(&both) };
    try testing.expectEqual(facet.Result.success, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit_info), bench.fence));
    try testing.expectEqual(@as(u32, 1), Losing.executed);
    try testing.expect(_objects.of(_sync.Fence, bench.fence).waitable.signalled != 0);

    try testing.expectEqual(facet.Result.error_device_lost, fb.GetFenceStatus(device, bench.fence));
    try testing.expectEqual(facet.Result.error_device_lost, fb.WaitForFences(device, 1, @ptrCast(&bench.fence), true, facet.WAIT_FOREVER_NS));
    // A fence nothing will signal is not waited for.
    try testing.expectEqual(facet.Result.success, fb.ResetFences(device, 1, @ptrCast(&bench.fence)));
    try testing.expectEqual(facet.Result.error_device_lost, fb.WaitForFences(device, 1, @ptrCast(&bench.fence), true, facet.WAIT_FOREVER_NS));
    try testing.expectEqual(facet.Result.error_device_lost, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit_info), bench.fence));
    try testing.expectEqual(@as(u32, 1), Losing.executed);
    try testing.expectEqual(facet.Result.error_device_lost, fb.QueueWaitIdle(bench.queue));
    try testing.expectEqual(facet.Result.error_device_lost, fb.DeviceWaitIdle(device));
}

test "a frame drawn: a triangle coloured by its fragment function, the clear colour round it, a strip after it kept" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const cleared = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, cleared);
    const kept = try renderPass(&bench, .load, false);
    defer fb.DestroyRenderPass(device, kept);
    const frame = try framebuffer(&bench, cleared, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    _, const list = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = cleared });
    defer fb.DestroyPipeline(device, list);
    _, const strip = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = kept, .topology = .triangle_strip, .restart = true, .dynamic = &.{ .viewport, .scissor } });
    defer fb.DestroyPipeline(device, strip);

    // The top left half; then the bottom right quarter as a strip of two
    // triangles, after a restart that leaves out a stray vertex.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ 0, 0, 0.5 },   .{ 1, 0, 0.5 },  .{ 0, 1, 0.5 },
        .{ 1, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const indices = [_]u16{ 2, 0xFFFF, 3, 4, 5, 6 };
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));

    const offset: u64 = 0;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const blue = clears(0xFF00_00FF);
    var commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = cleared, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    // Drawn outside a pass: nothing.
    fb.CmdDraw(commands, 3, 1, 3, 0);
    try bench.submit();

    try testing.expectEqual(green, picture.at(2, 2));
    try testing.expectEqual(green, picture.at(60, 2));
    try testing.expectEqual(green, picture.at(2, 60));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(62, 62));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(40, 40));

    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = kept, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } } }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, strip.?);
    fb.CmdSetViewport(commands, 0, 1, @ptrCast(&facet.Viewport{ .width = 64, .height = 64 }));
    fb.CmdSetScissor(commands, 0, 1, @ptrCast(&facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } }));
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindIndexBuffer(commands, index_buffer, 0, .uint16);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDrawIndexed(commands, indices.len, 1, 0, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // Kept where nothing was drawn; the strip's two triangles over the
    // quarter, both faces drawn.
    try testing.expectEqual(green, picture.at(2, 2));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(50, 20));
    try testing.expectEqual(red, picture.at(40, 40));
    try testing.expectEqual(red, picture.at(62, 62));
    try testing.expectEqual(red, picture.at(33, 62));
    try testing.expectEqual(red, picture.at(62, 33));
}

test "points and lines: where they should be, and as wide; a triangle's edges and corners, culled as its fill is" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const cleared = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, cleared);
    const frame = try framebuffer(&bench, cleared, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);

    // Pixel `n`'s centre, from -1 to 1 over 64 pixels.
    const c = struct {
        fn of(n: f32) f32 {
            return (n + 0.5) / 32 - 1;
        }
    }.of;
    const vertices = [_][3]f32{
        // A line on row 10, from column 16 to the edge of 48, and one on column 8.
        .{ c(16) - 0.5 / 32.0, c(10), 0.5 }, .{ c(48) - 0.5 / 32.0, c(10), 0.5 },
        .{ c(8), c(20), 0.5 },               .{ c(8), c(40), 0.5 },
        // A strip of the same two, joined.
        .{ c(20), c(30), 0.5 },              .{ c(40), c(30), 0.5 },
        .{ c(40), c(50), 0.5 },
        // Points.
        .{ c(5), c(5), 0.5 },                .{ c(60), c(60), 0.5 },
        // A triangle one way round, and the other.
        .{ -0.5, -0.5, 0.5 },                .{ 0.5, -0.5, 0.5 },
        .{ -0.5, 0.5, 0.5 },                 .{ -0.5, -0.5, 0.5 },
        .{ -0.5, 0.5, 0.5 },                 .{ 0.5, -0.5, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));

    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const Way = struct {
        topology: facet.PrimitiveTopology = .triangle_list,
        raster: facet.PipelineRasterizationStateCreateInfo = .{},
        dynamic: []const facet.DynamicState = &.{},
        width: ?f32 = null,
        first: u32,
        count: u32,
    };
    const Draw = struct {
        fn run(on: *Bench, pass: *facet.RenderPass, into: *facet.Framebuffer, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, buffer: *facet.Buffer, way: Way) !void {
            const facets = on.rig.fb;
            const result, const pipeline = makePipeline(on, .{ .module = shaders, .layout = by, .pass = pass, .topology = way.topology, .raster = way.raster, .dynamic = way.dynamic });
            try testing.expectEqual(facet.Result.success, result);
            const commands = try on.record();
            facets.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = into, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clears(0xFF00_00FF)) }, .@"inline");
            facets.CmdBindPipeline(commands, .graphics, pipeline.?);
            facets.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&offset));
            facets.CmdPushConstants(commands, by, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
            if (way.width) |width| facets.CmdSetLineWidth(commands, width);
            facets.CmdDraw(commands, way.count, 1, way.first, 0);
            facets.CmdEndRenderPass(commands);
            try on.submit();
            facets.DestroyPipeline(on.device, pipeline);
        }
    };
    const clear: u32 = 0xFF00_00FF;

    try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .topology = .line_list, .first = 0, .count = 4 });
    for ([_]u32{ 16, 30, 47 }) |x| try testing.expectEqual(red, picture.at(x, 10));
    try testing.expectEqual(clear, picture.at(15, 10));
    try testing.expectEqual(clear, picture.at(48, 10));
    try testing.expectEqual(clear, picture.at(30, 9));
    try testing.expectEqual(clear, picture.at(30, 11));
    try testing.expectEqual(red, picture.at(8, 30));
    try testing.expectEqual(clear, picture.at(7, 30));
    try testing.expectEqual(clear, picture.at(9, 30));

    // Wider, by a command: rows 9 to 11.
    try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .topology = .line_list, .first = 0, .count = 2, .dynamic = &.{.line_width}, .width = 3 });
    for ([_]u32{ 9, 10, 11 }) |y| try testing.expectEqual(red, picture.at(30, y));
    try testing.expectEqual(clear, picture.at(30, 8));
    try testing.expectEqual(clear, picture.at(30, 12));

    try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .topology = .line_strip, .first = 4, .count = 3 });
    try testing.expectEqual(red, picture.at(30, 30));
    try testing.expectEqual(red, picture.at(40, 40));
    try testing.expectEqual(clear, picture.at(30, 40));

    // A point is one pixel.
    try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .topology = .point_list, .first = 7, .count = 2 });
    try testing.expectEqual(red, picture.at(5, 5));
    try testing.expectEqual(red, picture.at(60, 60));
    for ([_][2]u32{ .{ 4, 5 }, .{ 6, 5 }, .{ 5, 4 }, .{ 5, 6 } }) |near| try testing.expectEqual(clear, picture.at(near[0], near[1]));

    // Filled, or as edges or corners: the same one way round is culled.
    const culled = facet.PipelineRasterizationStateCreateInfo{ .cull_mode = facet.CULL_MODE_BACK };
    for ([2]u32{ 9, 12 }) |first| {
        var filled = culled;
        try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .raster = filled, .first = first, .count = 3 });
        const shows = picture.at(20, 20) == red;
        filled.polygon_mode = .line;
        try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .raster = filled, .first = first, .count = 3 });
        try testing.expectEqual(clear, picture.at(20, 20));
        // Its top edge, on the row of -0.5.
        try testing.expectEqual(shows, picture.at(32, 15) == red or picture.at(32, 16) == red);
        filled.polygon_mode = .point;
        try Draw.run(&bench, cleared, frame, flat, layout, vertex_buffer, .{ .raster = filled, .first = first, .count = 3 });
        try testing.expectEqual(clear, picture.at(32, 16));
        var seen = false;
        for ([_]u32{ 15, 16 }) |y| for ([_]u32{ 15, 16 }) |x| {
            if (picture.at(x, y) == red) seen = true;
        };
        try testing.expectEqual(shows, seen);
    }
}

test "the stencil: marked, then drawn only where marked; a face's own test; its own attachment and with depth" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    const vertices = [_][3]f32{
        // All of the picture.
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
        // The left half, one way round, nearer; and the right, the other.
        .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 }, .{ -1, 1, 0.25 }, .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 },
        .{ 0, -1, 0.25 },  .{ 0, 1, 0.25 },  .{ 1, -1, 0.25 }, .{ 1, -1, 0.25 }, .{ 0, 1, 0.25 },  .{ 1, 1, 0.25 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const clear: u32 = 0xFF00_00FF;

    for ([2]facet.Format{ .s8_uint, .d16_unorm_s8_uint }) |format| {
        const usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT;
        _, const stencil_view = try bench.image(.{ .format = format, .extent = .{ .width = 64, .height = 64 }, .usage = usage }, true);
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
            .{ .format = format, .load_op = .clear, .stencil_load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        var pass: ?*facet.RenderPass = null;
        try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass));
        defer fb.DestroyRenderPass(device, pass);
        const frame = try framebuffer(&bench, pass.?, &.{ picture.view, stencil_view }, 64, 64);
        defer fb.DestroyFramebuffer(device, frame);

        const Passes = struct {
            mark: ?*facet.Pipeline,
            draw: ?*facet.Pipeline,
        };
        const make = struct {
            fn pipeline(on: *Bench, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, into: *facet.RenderPass, depth_state: facet.PipelineDepthStencilStateCreateInfo, dynamic: []const facet.DynamicState) !?*facet.Pipeline {
                const result, const made = makePipeline(on, .{ .module = shaders, .layout = by, .pass = into, .depth = depth_state, .dynamic = dynamic });
                try testing.expectEqual(facet.Result.success, result);
                return made;
            }
        }.pipeline;
        const always = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = 1 };
        const equal = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 1 };
        const marks = Passes{
            .mark = try make(&bench, flat, layout, pass.?, .{ .stencil_test_enable = true, .front = always, .back = .{ .compare_op = .always } }, &.{}),
            .draw = try make(&bench, flat, layout, pass.?, .{ .stencil_test_enable = true, .front = equal, .back = equal }, &.{}),
        };
        defer fb.DestroyPipeline(device, marks.mark);
        defer fb.DestroyPipeline(device, marks.draw);
        const commands = try bench.record();
        const values = clears(clear);
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass.?, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &values }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, marks.mark.?);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
        // Two halves, of faces apart: only one marks.
        fb.CmdDraw(commands, 12, 1, 6, 0);
        fb.CmdBindPipeline(commands, .graphics, marks.draw.?);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();
        // One half red then green, marked; the other red, its back face
        // having passed without marking: green over all the marked and
        // none of the rest.
        const left = picture.at(16, 32);
        const right = picture.at(48, 32);
        try testing.expect((left == green and right == red) or (left == red and right == green));
    }
}

test "indirect draws read their numbers as they are played; secondary command buffers play into the primary's pass" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    const vertices = [_][3]f32{
        // The left half, and the right.
        .{ -1, -1, 0.5 }, .{ 0, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 0, -1, 0.5 }, .{ 0, 1, 0.5 },
        .{ 0, -1, 0.5 },  .{ 1, -1, 0.5 }, .{ 0, 1, 0.5 },  .{ 0, 1, 0.5 },  .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const indices = [_]u16{ 6, 7, 8, 9, 10, 11 };
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));
    const numbers, const number_bytes = try bench.buffer(256, facet.BUFFER_USAGE_INDIRECT_BUFFER);
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const clear: u32 = 0xFF00_00FF;
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const result, const pipeline = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, pipeline);
    const values = clears(clear);
    const begin = facet.RenderPassBeginInfo{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &values };

    // Two draws 32 bytes apart, the numbers written once it is recorded.
    var commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &begin, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, pipeline.?);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDrawIndirect(commands, numbers, 8, 2, 32);
    fb.CmdEndRenderPass(commands);
    const first = facet.DrawIndirectCommand{ .vertex_count = 6, .instance_count = 1, .first_vertex = 0, .first_instance = 0 };
    const none = facet.DrawIndirectCommand{ .vertex_count = 6, .instance_count = 0, .first_vertex = 6, .first_instance = 0 };
    number_bytes[8..][0..@sizeOf(facet.DrawIndirectCommand)].* = std.mem.toBytes(first);
    number_bytes[40..][0..@sizeOf(facet.DrawIndirectCommand)].* = std.mem.toBytes(none);
    try bench.submit();
    try testing.expectEqual(red, picture.at(16, 32));
    try testing.expectEqual(clear, picture.at(48, 32));

    // Indexed.
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &begin, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindIndexBuffer(commands, index_buffer, 0, .uint16);
    fb.CmdBindPipeline(commands, .graphics, pipeline.?);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    const indexed = facet.DrawIndexedIndirectCommand{ .index_count = 6, .instance_count = 1, .first_index = 0, .vertex_offset = 0, .first_instance = 0 };
    number_bytes[0..@sizeOf(facet.DrawIndexedIndirectCommand)].* = std.mem.toBytes(indexed);
    fb.CmdDrawIndexedIndirect(commands, numbers, 0, 1, 0);
    // Past the buffer, and a stride too small: no more.
    fb.CmdDrawIndexedIndirect(commands, numbers, 252, 1, 0);
    fb.CmdDrawIndexedIndirect(commands, numbers, 0, 2, 4);
    fb.CmdEndRenderPass(commands);
    try bench.submit();
    try testing.expectEqual(clear, picture.at(16, 32));
    try testing.expectEqual(green, picture.at(48, 32));

    // A secondary, in the pass of a primary.
    var allocated: [1]?*facet.CommandBuffer = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateCommandBuffers(device, &.{ .command_pool = bench.pool, .level = .secondary }, &allocated));
    const secondary = allocated[0].?;
    const inherited = facet.CommandBufferInheritanceInfo{ .render_pass = pass, .framebuffer = frame };
    try testing.expectEqual(facet.Result.success, fb.BeginCommandBuffer(secondary, &.{ .flags = facet.COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE, .inheritance_info = &inherited }));
    fb.CmdBindVertexBuffers(secondary, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(secondary, .graphics, pipeline.?);
    fb.CmdPushConstants(secondary, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(secondary, 6, 1, 0, 0);
    // In a secondary, it does nothing.
    fb.CmdExecuteCommands(secondary, 1, @ptrCast(&secondary));
    try testing.expectEqual(facet.Result.success, fb.EndCommandBuffer(secondary));
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &begin, .secondary_command_buffers);
    fb.CmdExecuteCommands(commands, 1, @ptrCast(&secondary));
    fb.CmdEndRenderPass(commands);
    try bench.submit();
    try testing.expectEqual(green, picture.at(16, 32));
    try testing.expectEqual(clear, picture.at(48, 32));

    // Given to a queue, it plays nothing; nor is a primary played as one.
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &begin, .@"inline");
    fb.CmdExecuteCommands(commands, 1, @ptrCast(&commands));
    fb.CmdEndRenderPass(commands);
    try bench.submit();
    try testing.expectEqual(clear, picture.at(16, 32));
    const submit_info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&secondary) };
    try testing.expectEqual(facet.Result.success, fb.QueueSubmit(bench.queue, 1, @ptrCast(&submit_info), null));
    try testing.expectEqual(facet.Result.success, fb.QueueWaitIdle(bench.queue));
    try testing.expectEqual(clear, picture.at(16, 32));
}

test "a compute function writes a buffer, group by group, apart from what draws have bound" {
    const Doubler = struct {
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 0).?;
            const at = groups.group[0] + groups.group[1] * groups.count[0] + groups.group[2] * groups.count[0] * groups.count[1];
            out[at] = at * 2 + groups.resources.constants(u32).*;
        }
        fn other(groups: *const shader.Groups) callconv(.c) void {
            groups.resources.storage(u32, 0, 0).?[0] = 0xDEAD;
        }
        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("other", &other), shader.vertex("main", &Flat.vertex, 0) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const doubler = try module(&bench, &Doubler.code);
    defer fb.DestroyShaderModule(device, doubler);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .stage_flags = facet.SHADER_STAGE_COMPUTE };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const out_buffer, const out_bytes = try bench.buffer(240 * @sizeOf(u32), facet.BUFFER_USAGE_STORAGE_BUFFER);
    const numbers, const number_bytes = try bench.buffer(64, facet.BUFFER_USAGE_INDIRECT_BUFFER);
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = out_buffer, .range = facet.WHOLE_SIZE };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
    const out: [*]u32 = @ptrCast(@alignCast(out_bytes));
    @memset(out[0..240], 0);

    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = doubler }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = doubler, .name = "other" }, .layout = layout },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 2, &infos, &pipelines));
    defer fb.DestroyPipeline(device, pipelines[0]);
    defer fb.DestroyPipeline(device, pipelines[1]);

    // Refused: a stage it is not, a name the module has not.
    var refused: [1]?*facet.Pipeline = undefined;
    const not_compute = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_VERTEX, .module = doubler }, .layout = layout };
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateComputePipelines(device, null, 1, @ptrCast(&not_compute), &refused));
    try testing.expectEqual(@as(?*facet.Pipeline, null), refused[0]);
    const not_there = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = doubler, .name = "nothing" }, .layout = layout };
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateComputePipelines(device, null, 1, @ptrCast(&not_there), &refused));

    const seven: u32 = 7;
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    // A compute pipeline bound for drawing is not bound at all.
    fb.CmdBindPipeline(commands, .graphics, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 4, &seven);
    fb.CmdDispatch(commands, 5, 4, 3);
    try bench.submit();
    for (0..60) |k| try testing.expectEqual(@as(u32, @intCast(k)) * 2 + 7, out[k]);
    try testing.expectEqual(@as(u32, 0), out[60]);

    // Its numbers in a buffer, read as it is played.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    const nine: u32 = 9;
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 4, &nine);
    fb.CmdDispatchIndirect(commands, numbers, 4);
    fb.CmdDispatchIndirect(commands, numbers, 60);
    number_bytes[4..][0..12].* = std.mem.toBytes(facet.DispatchIndirectCommand{ .x = 10, .y = 1, .z = 1 });
    try bench.submit();
    for (0..10) |k| try testing.expectEqual(@as(u32, @intCast(k)) * 2 + 9, out[k]);
    try testing.expectEqual(@as(u32, 10) * 2 + 7, out[10]);
}

test "tessellation: patches made into triangles and lines, on the picture where the evaluation function puts them" {
    const Bent = struct {
        var last_points: u32 = 0;
        fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
            for (0..vertices.count) |k| {
                const p = vertices.input(@intCast(k), 0);
                // One more float than the fragment function reads.
                vertices.output(@intCast(k))[0..5].* = .{ p[0], p[1], p[2], 1, 0.5 };
            }
        }
        fn control(patch: *const shader.Patch, levels: *shader.Levels) callconv(.c) void {
            last_points = patch.count;
            levels.outer = .{ 3, 4, 5, 6 };
            levels.inner = .{ 4, 5 };
        }
        fn triangleControl(patch: *const shader.Patch, levels: *shader.Levels) callconv(.c) void {
            control(patch, levels);
            // The second patch is left out.
            if (patch.number == 1) levels.outer[0] = 0;
        }
        fn triangle(evaluations: *const shader.Evaluations) callconv(.c) void {
            const a = evaluations.patch.point(0);
            const b = evaluations.patch.point(1);
            const c = evaluations.patch.point(2);
            for (0..evaluations.count) |k| {
                const at = evaluations.coordinates[k];
                const out = evaluations.output(@intCast(k));
                for (0..3) |axis| out[axis] = a[axis] * at[0] + b[axis] * at[1] + c[axis] * at[2];
                out[3] = 1;
            }
        }
        fn quad(evaluations: *const shader.Evaluations) callconv(.c) void {
            const a = evaluations.patch.point(0);
            const b = evaluations.patch.point(1);
            const c = evaluations.patch.point(2);
            const d = evaluations.patch.point(3);
            for (0..evaluations.count) |k| {
                const u = evaluations.coordinates[k][0];
                const v = evaluations.coordinates[k][1];
                const out = evaluations.output(@intCast(k));
                for (0..3) |axis| out[axis] = (a[axis] * (1 - u) + b[axis] * u) * (1 - v) + (d[axis] * (1 - u) + c[axis] * u) * v;
                out[3] = 1;
            }
        }
        fn fragment(fragments: *const shader.Fragments) callconv(.c) void {
            shader.fill(fragments, 0xFFFF_0000);
        }
        const entries = [_]shader.Entry{
            shader.vertex("main", &vertex, 1),
            shader.fragment("main", &fragment, 0),
            shader.control("main", &control),
            shader.control("triangle", &triangleControl),
            shader.evaluation("triangles", &triangle, 0, .{ .domain = .triangles }),
            shader.evaluation("clockwise", &triangle, 0, .{ .domain = .triangles, .clockwise = true }),
            shader.evaluation("quads", &quad, 0, .{ .domain = .quads }),
            shader.evaluation("isolines", &quad, 0, .{ .domain = .isolines }),
            shader.evaluation("varied", &quad, 2, .{ .domain = .quads }),
        };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const bent = try module(&bench, &Bent.code);
    defer fb.DestroyShaderModule(device, bent);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const vertices = [_][3]f32{
        // Going round on the picture: the whole of it.
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 }, .{ -1, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const clear: u32 = 0xFF00_00FF;
    const red: u32 = 0xFFFF_0000;

    const Made = struct {
        fn of(on: *Bench, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, into: *facet.RenderPass, control: [*:0]const u8, evaluation: [*:0]const u8, points: u32, topology: facet.PrimitiveTopology, raster: facet.PipelineRasterizationStateCreateInfo) struct { facet.Result, ?*facet.Pipeline } {
            const stages = [4]facet.PipelineShaderStageCreateInfo{
                .{ .stage = facet.SHADER_STAGE_VERTEX, .module = shaders },
                .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = shaders },
                .{ .stage = facet.SHADER_STAGE_TESSELLATION_CONTROL, .module = shaders, .name = control },
                .{ .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION, .module = shaders, .name = evaluation },
            };
            const stride = facet.VertexInputBindingDescription{ .binding = 0, .stride = 12 };
            const attribute = facet.VertexInputAttributeDescription{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat };
            const input = facet.PipelineVertexInputStateCreateInfo{ .vertex_binding_description_count = 1, .vertex_binding_descriptions = @ptrCast(&stride), .vertex_attribute_description_count = 1, .vertex_attribute_descriptions = @ptrCast(&attribute) };
            const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = topology };
            const tessellation = facet.PipelineTessellationStateCreateInfo{ .patch_control_points = points };
            const viewport = facet.Viewport{ .width = 64, .height = 64 };
            const scissor = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };
            const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
            const attachment = facet.PipelineColorBlendAttachmentState{};
            const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment) };
            const depth = facet.PipelineDepthStencilStateCreateInfo{};
            const info = facet.GraphicsPipelineCreateInfo{
                .stage_count = 4,
                .stages = &stages,
                .vertex_input_state = &input,
                .input_assembly_state = &assembly,
                .tessellation_state = &tessellation,
                .viewport_state = &view,
                .rasterization_state = &raster,
                .depth_stencil_state = &depth,
                .color_blend_state = &blend,
                .layout = by,
                .render_pass = into,
            };
            var made: [1]?*facet.Pipeline = undefined;
            const result = on.rig.fb.CreateGraphicsPipelines(on.device, null, 1, @ptrCast(&info), &made);
            return .{ result, made[0] };
        }
    };
    const draw = struct {
        fn run(on: *Bench, into: *facet.RenderPass, onto: *facet.Framebuffer, pipeline: *facet.Pipeline, buffer: *facet.Buffer, where: *const u64, count: u32) !void {
            const values = clears(0xFF00_00FF);
            const commands = try on.record();
            on.rig.fb.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &values }, .@"inline");
            on.rig.fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(where));
            on.rig.fb.CmdBindPipeline(commands, .graphics, pipeline);
            on.rig.fb.CmdDraw(commands, count, 1, 0, 0);
            on.rig.fb.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.run;

    // A square, whole, cut however finely.
    var result, const quads = Made.of(&bench, bent, layout, pass, "main", "quads", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, quads);
    try draw(&bench, pass, frame, quads.?, vertex_buffer, &offset, 4);
    try testing.expectEqual(@as(u32, 4), Bent.last_points);
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) try testing.expectEqual(red, picture.at(x, y));
    }

    // Two patches of three, the second left out: half of it, up to the diagonal.
    result, const triangles = Made.of(&bench, bent, layout, pass, "triangle", "triangles", 3, .patch_list, .{});
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, triangles);
    try draw(&bench, pass, frame, triangles.?, vertex_buffer, &offset, 4);
    try testing.expectEqual(red, picture.at(40, 16));
    try testing.expectEqual(clear, picture.at(16, 40));

    // Culled by the way round it is said to go.
    result, const culled = Made.of(&bench, bent, layout, pass, "main", "triangles", 3, .patch_list, .{ .cull_mode = facet.CULL_MODE_FRONT, .front_face = .clockwise });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, culled);
    try draw(&bench, pass, frame, culled.?, vertex_buffer, &offset, 3);
    const one_way = picture.at(40, 16);
    result, const other_way = Made.of(&bench, bent, layout, pass, "main", "clockwise", 3, .patch_list, .{ .cull_mode = facet.CULL_MODE_FRONT, .front_face = .clockwise });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, other_way);
    try draw(&bench, pass, frame, other_way.?, vertex_buffer, &offset, 3);
    try testing.expect(one_way != picture.at(40, 16));

    // Isolines: lines of constant v, the rest not touched.
    result, const lines = Made.of(&bench, bent, layout, pass, "main", "isolines", 4, .patch_list, .{ .line_width = 1 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, lines);
    try draw(&bench, pass, frame, lines.?, vertex_buffer, &offset, 4);
    // Three lines, at the top and a third and two thirds of the way down.
    var drawn: u32 = 0;
    y = 0;
    while (y < 64) : (y += 1) {
        if (picture.at(32, y) == red) drawn += 1;
    }
    try testing.expect(drawn >= 2 and drawn <= 6);
    try testing.expectEqual(clear, picture.at(32, 63));

    // Refused: a patch of no vertices or too many; not a patch list; varyings
    // that do not come to the fragment function's.
    result, _ = Made.of(&bench, bent, layout, pass, "main", "quads", 0, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "quads", 33, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "quads", 4, .triangle_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "varied", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    const plain, _ = makePipeline(&bench, .{ .module = bent, .layout = layout, .pass = pass, .topology = .patch_list });
    try testing.expect(plain != .success);
}

test "images copied, blitted, read back, and parts of an attachment cleared in the middle of a pass" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const one = try Picture.of(&bench, 16, 16);
    const two = try Picture.of(&bench, 16, 16);
    const cleared = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, cleared);
    const frame = try framebuffer(&bench, cleared, &.{one.view}, 16, 16);
    defer fb.DestroyFramebuffer(device, frame);
    const blue: u32 = 0xFF00_00FF;
    const red: u32 = 0xFFFF_0000;

    // A corner cleared red in the middle of the pass, over blue.
    var commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = cleared, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 16, .height = 16 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clears(blue)) }, .@"inline");
    const attachment = facet.ClearAttachment{ .clear_value = clears(red)[0] };
    const rect = facet.ClearRect{ .rect = .{ .extent = .{ .width = 8, .height = 8 } } };
    fb.CmdClearAttachments(commands, 1, @ptrCast(&attachment), 1, @ptrCast(&rect));
    fb.CmdEndRenderPass(commands);
    try bench.submit();
    try testing.expectEqual(red, one.at(0, 0));
    try testing.expectEqual(red, one.at(7, 7));
    try testing.expectEqual(blue, one.at(8, 7));
    try testing.expectEqual(blue, one.at(7, 8));

    // Copied, moved along.
    commands = try bench.record();
    const moved = facet.ImageCopy{ .dst_offset = .{ .x = 4, .y = 4 }, .extent = .{ .width = 8, .height = 8 } };
    fb.CmdCopyImage(commands, one.image, .general, two.image, .general, 1, @ptrCast(&moved));
    try bench.submit();
    try testing.expectEqual(red, two.at(4, 4));
    try testing.expectEqual(red, two.at(11, 11));
    try testing.expect(two.at(3, 3) != red);
    try testing.expect(two.at(12, 12) != red);

    // The whole, turned round left to right.
    commands = try bench.record();
    const turned = facet.ImageBlit{ .src_offsets = .{ .{}, .{ .x = 16, .y = 16, .z = 1 } }, .dst_offsets = .{ .{ .x = 16 }, .{ .y = 16, .z = 1 } } };
    fb.CmdBlitImage(commands, one.image, .general, two.image, .general, 1, @ptrCast(&turned), .nearest);
    try bench.submit();
    try testing.expectEqual(red, two.at(15, 0));
    try testing.expectEqual(red, two.at(8, 7));
    try testing.expectEqual(blue, two.at(7, 0));
    try testing.expectEqual(blue, two.at(0, 15));

    // A part of it read back, its first row and the next.
    const back, const back_bytes = try bench.buffer(64, facet.BUFFER_USAGE_TRANSFER_DST);
    commands = try bench.record();
    const part = facet.BufferImageCopy{ .image_offset = .{ .x = 6, .y = 0 }, .image_extent = .{ .width = 4, .height = 2 }, .buffer_row_length = 8 };
    fb.CmdCopyImageToBuffer(commands, one.image, .general, back, 1, @ptrCast(&part));
    try bench.submit();
    try testing.expectEqual(red, std.mem.readInt(u32, back_bytes[0..4], .little));
    try testing.expectEqual(blue, std.mem.readInt(u32, back_bytes[8..12], .little));
    try testing.expectEqual(red, std.mem.readInt(u32, back_bytes[32..36], .little));
}

test "depths in order: nearer kept whatever was drawn first, with the depth pre-pass or without; a scissor and a render area cut what is drawn" {
    for ([_]u32{ 0, facet.PIPELINE_CREATE_DEPTH_PREPASS }) |flags| try depthsInOrder(flags);
}

fn depthsInOrder(flags: u32) !void {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    _, const depth = try bench.image(.{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, true);
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    _, const tested = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass, .depth = .{ .depth_test_enable = true, .depth_write_enable = true }, .dynamic = &.{.scissor}, .flags = flags });
    defer fb.DestroyPipeline(device, tested);

    // Whole squares at depths 0.8, 0.2 over the left half, and 0.5.
    const square = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const depths = [3]f32{ 0.8, 0.2, 0.5 };
    var vertices: [12][3]f32 = undefined;
    for (0..3) |s| for (square, 0..) |corner, k| {
        const z = depths[s];
        const right: f32 = if (s == 1) 0 else corner[0];
        vertices[s * 4 + k] = .{ @min(corner[0], right), corner[1], z };
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const indices = scenes.quad_indices;
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));

    const colors = [3]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF };
    const black = clears(0xFF00_0000);
    @memset(@constCast(picture.pixels)[0 .. picture.pitch * 64], 0x11);
    const offset: u64 = 0;
    const commands = try bench.record();
    // The render area leaves out the bottom row of pixels, the scissor of
    // the last square the top eight rows.
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 63 } }, .clear_value_count = 2, .clear_values = &black }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, tested.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindIndexBuffer(commands, index_buffer, 0, .uint16);
    for (colors, 0..) |color, s| {
        const top: i32 = if (s == 2) 8 else 0;
        fb.CmdSetScissor(commands, 0, 1, @ptrCast(&facet.Rect2D{ .offset = .{ .y = top }, .extent = .{ .width = 64, .height = 64 } }));
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &color);
        fb.CmdDrawIndexed(commands, indices.len, 1, 0, @intCast(s * 4), 0);
    }
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    try testing.expectEqual(colors[1], picture.at(10, 30));
    try testing.expectEqual(colors[2], picture.at(50, 30));
    try testing.expectEqual(colors[0], picture.at(50, 4));
    try testing.expectEqual(colors[1], picture.at(10, 4));
    try testing.expectEqual(@as(u32, 0x1111_1111), picture.at(50, 63));
    try testing.expectEqual(colors[2], picture.at(50, 62));
}

test "CmdFillBuffer sets a run four bytes at a time, and leaves a run that is not the buffer's alone" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const buffer, const bytes = try bench.buffer(64, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(bytes[0..64], 0x11);

    const commands = try bench.record();
    fb.CmdFillBuffer(commands, buffer, 8, 16, 0xAABB_CCDD);
    // Past the end: left out, and the buffer untouched by it.
    fb.CmdFillBuffer(commands, buffer, 56, 16, 0x2222_2222);
    try bench.submit();

    for (bytes[0..8]) |each| try testing.expectEqual(@as(u8, 0x11), each);
    const filled: [*]align(1) const u32 = @ptrCast(bytes + 8);
    for (filled[0..4]) |word| try testing.expectEqual(@as(u32, 0xAABB_CCDD), word);
    for (bytes[24..64]) |each| try testing.expectEqual(@as(u8, 0x11), each);
}

test "CmdUpdateBuffer writes bytes it took as it was recorded, not the caller's by then" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const buffer, const bytes = try bench.buffer(64, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(bytes[0..64], 0);

    var given: [16]u8 = undefined;
    for (&given, 0..) |*each, k| each.* = @intCast(k + 1);
    const commands = try bench.record();
    fb.CmdUpdateBuffer(commands, buffer, 4, given.len, &given);
    // The command has its own copy: what the program does with these now
    // cannot reach the buffer.
    @memset(&given, 0xEE);
    // More than one of these writes: nothing recorded at all.
    var too_many: [4]u8 = @splat(0x55);
    fb.CmdUpdateBuffer(commands, buffer, 32, _cmdupdate.most_update_bytes + 4, &too_many);
    try bench.submit();

    for (bytes[0..4]) |each| try testing.expectEqual(@as(u8, 0), each);
    for (bytes[4..20], 1..) |each, k| try testing.expectEqual(@as(u8, @intCast(k)), each);
    for (bytes[20..64]) |each| try testing.expectEqual(@as(u8, 0), each);
}

test "CmdClearColorImage sets every texel of the levels it names, and no others" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const side = 8;
    const image = try bench.bareImage(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = side, .height = side },
        .mip_levels = 2,
        .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    const out, const read = try bench.buffer(side * side * 4, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(read[0 .. side * side * 4], 0);

    // Red, and only the first level of it.
    const color = facet.ClearColorValue{ .float32 = .{ 1, 0, 0, 1 } };
    const range = facet.ImageSubresourceRange{ .base_mip_level = 0, .level_count = 1 };
    const region = facet.BufferImageCopy{ .image_extent = .{ .width = side, .height = side } };
    const commands = try bench.record();
    fb.CmdClearColorImage(commands, image, .transfer_dst_optimal, &color, 1, @ptrCast(&range));
    fb.CmdCopyImageToBuffer(commands, image, .transfer_src_optimal, out, 1, @ptrCast(&region));
    try bench.submit();

    const texels: [*]align(1) const u32 = @ptrCast(read);
    for (texels[0 .. side * side]) |texel| try testing.expectEqual(@as(u32, 0xFFFF_0000), texel);

    // The second level was not named, so it keeps whatever it held: cleared
    // to green on its own, the first level stays red.
    const green = facet.ClearColorValue{ .float32 = .{ 0, 1, 0, 1 } };
    const second = facet.ImageSubresourceRange{ .base_mip_level = 1, .level_count = 1 };
    const again = try bench.record();
    fb.CmdClearColorImage(again, image, .transfer_dst_optimal, &green, 1, @ptrCast(&second));
    fb.CmdCopyImageToBuffer(again, image, .transfer_src_optimal, out, 1, @ptrCast(&region));
    try bench.submit();
    for (texels[0 .. side * side]) |texel| try testing.expectEqual(@as(u32, 0xFFFF_0000), texel);
}

/// A cut-out texture drawn over a flat quad behind it: what shows whether a
/// dropped pixel left its depth behind.
const CutoutScene = struct {
    /// A quad filling the picture at z = 0.2, textured from its position.
    const quad = [4][3]f32{ .{ -1, -1, 0.2 }, .{ 1, -1, 0.2 }, .{ 1, 1, 0.2 }, .{ -1, 1, 0.2 } };

    fn cut(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) / 2, (p[1] + 1) / 2 };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("cut", &cut, 2),
        shader.fixedFragment("cut", .{ .kind = .texture_cutout, .sampling = .{ .filter = .nearest } }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a cut-out texture drops its pixels and leaves no depth behind them" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // The cores hold a dropping form's depths back; this is what says so.
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.discarding_fragment_forms);
    try testing.expectEqual(@as(u32, 2), CutoutScene.entries[1].varyingCount());

    // An 8 x 8 texture: its left half clear, its right half opaque red.
    const texture_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, false);
    const texture_view = try bench.viewOf(.{ .image = texture_image, .format = .r8g8b8a8_unorm });
    const staging, const staged = try bench.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..8) |y| for (0..8) |x| {
        staged[(y * 8 + x) * 4 ..][0..4].* = if (x < 4) .{ 0, 0, 0, 0 } else .{ 255, 0, 0, 255 };
    };

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));
    const image_info = facet.DescriptorImageInfo{ .image_view = texture_view };
    const write = facet.WriteDescriptorSet{ .dst_set = set[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const picture = try Picture.of(&bench, 64, 64);
    _, const depth = try bench.image(.{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, true);
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);

    const cut_module = try module(&bench, &CutoutScene.code);
    defer fb.DestroyShaderModule(device, cut_module);
    const cut_layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, cut_layout);
    const tested: facet.PipelineDepthStencilStateCreateInfo = .{ .depth_test_enable = true, .depth_write_enable = true };
    const cut_result, const cut_pipeline = makePipeline(&bench, .{ .module = cut_module, .name = "cut", .layout = cut_layout, .pass = pass, .depth = tested });
    try testing.expectEqual(facet.Result.success, cut_result);
    defer fb.DestroyPipeline(device, cut_pipeline);

    const flat_module = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat_module);
    const flat_layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, flat_layout);
    const flat_result, const flat_pipeline = makePipeline(&bench, .{ .module = flat_module, .layout = flat_layout, .pass = pass, .depth = tested });
    try testing.expectEqual(facet.Result.success, flat_result);
    defer fb.DestroyPipeline(device, flat_pipeline);

    // The cut-out quad near, at 0.2; the flat one behind it, at 0.5.
    const far = [4][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 }, .{ -1, 1, 0.5 } };
    const vertices = CutoutScene.quad ++ far;
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const indices = scenes.quad_indices;
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));

    const blue: u32 = 0xFF00_00FF;
    const black = clears(0xFF00_0000);
    const offset: u64 = 0;
    const region = facet.BufferImageCopy{ .image_extent = .{ .width = 8, .height = 8 } };
    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, texture_image, .transfer_dst_optimal, 1, @ptrCast(&region));
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &black }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindIndexBuffer(commands, index_buffer, 0, .uint16);
    // Near first, so that the one behind it has to pass a depth the dropped
    // pixels must not have written.
    fb.CmdBindDescriptorSets(commands, .graphics, cut_layout, 0, 1, @ptrCast(&set), 0, null);
    fb.CmdBindPipeline(commands, .graphics, cut_pipeline.?);
    fb.CmdDrawIndexed(commands, indices.len, 1, 0, 0, 0);
    fb.CmdBindPipeline(commands, .graphics, flat_pipeline.?);
    fb.CmdPushConstants(commands, flat_layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &blue);
    fb.CmdDrawIndexed(commands, indices.len, 1, 0, 4, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // Where the texture was opaque the near quad stands, and the far one was
    // held off by its depth. Where it was clear, nothing of the near quad is
    // left - not its colour and not its depth - so the far one shows through.
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(48, 20));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(40, 50));
    try testing.expectEqual(blue, picture.at(16, 20));
    try testing.expectEqual(blue, picture.at(4, 50));
}

/// What the sampler tests draw: one quad over the whole picture, with the
/// set written with the sampler of the moment first, so that one frame a
/// sampler shows what that sampler does.
const SamplerFrame = struct {
    bench: *Bench,
    set: *facet.DescriptorSet,
    layout: *facet.PipelineLayout,
    pass: *facet.RenderPass,
    frame: *facet.Framebuffer,
    view: *facet.ImageView,
    vertices: *facet.Buffer,
    indices: *facet.Buffer,
    cleared: *const [2]facet.ClearValue,

    fn draw(frames: SamplerFrame, with: ?*facet.Sampler, pipeline: ?*facet.Pipeline) !void {
        const fb = frames.bench.rig.fb;
        const image_info = facet.DescriptorImageInfo{ .sampler = with, .image_view = frames.view };
        const write = facet.WriteDescriptorSet{ .dst_set = frames.set, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&image_info) };
        fb.UpdateDescriptorSets(frames.bench.device, 1, @ptrCast(&write), 0, null);
        const offset: u64 = 0;
        const commands = try frames.bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = frames.pass, .framebuffer = frames.frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = frames.cleared }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&frames.vertices), @ptrCast(&offset));
        fb.CmdBindIndexBuffer(commands, frames.indices, 0, .uint16);
        fb.CmdBindDescriptorSets(commands, .graphics, frames.layout, 0, 1, @ptrCast(&frames.set), 0, null);
        fb.CmdBindPipeline(commands, .graphics, pipeline.?);
        fb.CmdDrawIndexed(commands, scenes.quad_indices.len, 1, 0, 0, 0);
        fb.CmdEndRenderPass(commands);
        try frames.bench.submit();
    }
};

/// A quad over the whole picture, for the forms that sample through the
/// sampler bound beside the texture.
const SamplerScene = struct {
    const quad = [4][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };

    /// s and t from -0.5 to 1.5 over it, so that a quarter of the picture
    /// at each edge lies past the texture: what the wrap puts there is what
    /// shows.
    fn wide(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, p[0] + 0.5, p[1] + 0.5 };
        }
    }

    /// s and t over the texture once, and a half as the reference a shadow
    /// sample is compared with.
    fn shadow(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) / 2, (p[1] + 1) / 2, 0.5 };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("wide", &wide, 2),
        shader.fixedFragment("wide", .{ .kind = .texture_sampled }),
        shader.vertex("shadow", &shadow, 3),
        shader.fixedFragment("shadow", .{ .kind = .texture_shadow }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a sampler bound beside the texture: the wrap and the border it says, and a shadow sample against a reference" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // The cores do the sampling, so they take everything a sampler says.
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.samplers);
    try testing.expect(features.sampler_anisotropy);
    try testing.expect(!features.immutable_samplers);
    try testing.expect(!features.unnormalized_coordinates);
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    try testing.expectEqual(@as(u32, 16), properties.limits.max_sampler_anisotropy);

    // What CreateSampler has not got, and what it holds rather than refuses.
    var refused: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateSampler(device, &.{ .unnormalized_coordinates = true }, &refused));
    try testing.expect(refused == null);
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateSampler(device, &.{ .address_mode_u = .mirror_clamp_to_edge }, &refused));
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateSampler(device, &.{ .compare_enable = true, .compare_op = @enumFromInt(9) }, &refused));
    var most: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{ .anisotropy_enable = true, .max_anisotropy = 1000 }, &most));
    try testing.expectEqual(@as(f32, 16), _objects.of(_sampler.Sampler, most.?).kept.anisotropy);
    // Without anisotropy_enable it is one sample, whatever was asked for.
    var one: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{ .max_anisotropy = 8 }, &one));
    try testing.expectEqual(@as(f32, 1), _objects.of(_sampler.Sampler, one.?).kept.anisotropy);
    fb.DestroySampler(device, most);
    fb.DestroySampler(device, one);
    fb.DestroySampler(device, null);

    // An 8 x 8 texture, red on the left and blue on the right: the red is
    // where a shadow sample's depth is 1, the blue where it is 0.
    const red: u32 = 0xFFFF_0000;
    const blue: u32 = 0xFF00_00FF;
    const white: u32 = 0xFFFF_FFFF;
    const black: u32 = 0xFF00_0000;
    const texture_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, false);
    const texture_view = try bench.viewOf(.{ .image = texture_image, .format = .r8g8b8a8_unorm });
    const staging, const staged = try bench.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..8) |y| for (0..8) |x| {
        staged[(y * 8 + x) * 4 ..][0..4].* = if (x < 4) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
    };

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));

    const picture = try Picture.of(&bench, 64, 64);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const scene_module = try module(&bench, &SamplerScene.code);
    defer fb.DestroyShaderModule(device, scene_module);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const wide_result, const wide_pipeline = makePipeline(&bench, .{ .module = scene_module, .name = "wide", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, wide_result);
    defer fb.DestroyPipeline(device, wide_pipeline);
    const shadow_result, const shadow_pipeline = makePipeline(&bench, .{ .module = scene_module, .name = "shadow", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, shadow_result);
    defer fb.DestroyPipeline(device, shadow_pipeline);

    const vertices = SamplerScene.quad;
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const indices = scenes.quad_indices;
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));
    const region = facet.BufferImageCopy{ .image_extent = .{ .width = 8, .height = 8 } };
    const clear = clears(0xFF00_FF00);

    // The texture into the image once, before the frames that read it.
    {
        const commands = try bench.record();
        fb.CmdCopyBufferToImage(commands, staging, texture_image, .transfer_dst_optimal, 1, @ptrCast(&region));
        try bench.submit();
    }

    const frames = SamplerFrame{
        .bench = &bench,
        .set = set[0].?,
        .layout = layout,
        .pass = pass,
        .frame = frame,
        .view = texture_view,
        .vertices = vertex_buffer,
        .indices = index_buffer,
        .cleared = &clear,
    };

    // Each wrap mode, read a quarter of the picture past the texture's left
    // edge (column 12, where s is about -0.11) and inside it.
    const Case = struct { mode: facet.SamplerAddressMode, outside: u32 };
    for ([_]Case{
        // The texture again: the far side of it, which is blue.
        .{ .mode = .repeat, .outside = blue },
        // Turned round, so the near side again: red.
        .{ .mode = .mirrored_repeat, .outside = red },
        .{ .mode = .clamp_to_edge, .outside = red },
        .{ .mode = .clamp_to_border, .outside = white },
    }) |case| {
        var sampler: ?*facet.Sampler = null;
        try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = case.mode,
            .address_mode_v = case.mode,
            .border_color = .float_opaque_white,
        }, &sampler));
        defer fb.DestroySampler(device, sampler);
        try frames.draw(sampler, wide_pipeline);
        try testing.expectEqual(case.outside, picture.at(12, 32));
        // Inside it the texture itself, whatever the wrap: its left half
        // and its right.
        try testing.expectEqual(red, picture.at(20, 32));
        try testing.expectEqual(blue, picture.at(44, 32));
    }

    // A combined image sampler written with no sampler: the form says so
    // rather than sampling some other way.
    try frames.draw(null, wide_pipeline);
    try testing.expectEqual(shader.missing, picture.at(32, 32));

    // The shadow form: the reference is 0.5, and what is compared is the
    // red channel - 1 on the texture's left half, 0 on its right.
    var shadow_sampler: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .compare_enable = true,
        .compare_op = .less,
    }, &shadow_sampler));
    defer fb.DestroySampler(device, shadow_sampler);
    try frames.draw(shadow_sampler, shadow_pipeline);
    try testing.expectEqual(white, picture.at(16, 32));
    try testing.expectEqual(black, picture.at(48, 32));
}

/// Quads that fill the picture, at a depth, and what they fill it with.
const SubpassScene = struct {
    const quad = [6][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ -1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 } };
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const blue: u32 = 0xFF00_00FF;
    const yellow: u32 = 0xFFFF_FF00;

    /// The instance, in eighths, is how far the quad is.
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], @as(f32, @floatFromInt(vertices.instance)) / 8, 1 };
        }
    }
    fn fragmentRed(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, red);
    }
    fn fragmentGreen(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, green);
    }
    /// A colour of its own for each attachment.
    fn fragmentOutputs(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, if (fragments.resources.output == 0) blue else yellow);
    }
    const entries = [_]shader.Entry{
        shader.vertex("red", &vertex, 0),
        shader.fragment("red", &fragmentRed, 0),
        shader.vertex("green", &vertex, 0),
        shader.fragment("green", &fragmentGreen, 0),
        shader.vertex("outputs", &vertex, 0),
        shader.fragment("outputs", &fragmentOutputs, 0),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

// --- query pools --------------------------------------------------------------

/// A pool of `count` queries of `kind`, with `statistics` for a statistics
/// one.
fn queryPool(bench: *Bench, kind: facet.QueryType, count: u32, statistics: u32) !*facet.QueryPool {
    var made: ?*facet.QueryPool = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateQueryPool(bench.device, &.{ .query_type = kind, .query_count = count, .pipeline_statistics = statistics }, &made));
    return made.?;
}

/// Query `index` of `pool` read as a 64-bit value, waited for.
fn queryValue(bench: *Bench, pool: *facet.QueryPool, index: u32) !u64 {
    var value: u64 = 0;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.GetQueryPoolResults(bench.device, pool, index, 1, @sizeOf(u64), &value, @sizeOf(u64), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT));
    return value;
}

/// The pixels of `picture` that are `color`.
fn pixelsOf(picture: *const Picture, color: u32) u32 {
    var found: u32 = 0;
    for (0..picture.height) |y| {
        for (0..picture.width) |x| {
            if (picture.at(@intCast(x), @intCast(y)) == color) found += 1;
        }
    }
    return found;
}

test "an occlusion query counts the samples that passed, and a statistics query what each stage was given" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    _, const list = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass });
    defer fb.DestroyPipeline(device, list);

    // The cores count both; a device that counts neither says so instead.
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.occlusion_queries);
    try testing.expect(features.pipeline_statistics_queries);

    const occlusion = try queryPool(&bench, .occlusion, 2, 0);
    defer fb.DestroyQueryPool(device, occlusion);
    const wanted = facet.QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_VERTICES |
        facet.QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_PRIMITIVES |
        facet.QUERY_PIPELINE_STATISTIC_VERTEX_SHADER_INVOCATIONS |
        facet.QUERY_PIPELINE_STATISTIC_CLIPPING_INVOCATIONS |
        facet.QUERY_PIPELINE_STATISTIC_CLIPPING_PRIMITIVES |
        facet.QUERY_PIPELINE_STATISTIC_FRAGMENT_SHADER_INVOCATIONS;
    const statistics = try queryPool(&bench, .pipeline_statistics, 1, wanted);
    defer fb.DestroyQueryPool(device, statistics);

    // The top left half of the picture, as its own instance each: the
    // same triangle twice over, one on top of the other.
    const vertices = [_][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 } };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const green: u32 = 0xFF00_FF00;
    const blue = clears(0xFF00_00FF);

    // A query read before it was begun is not ready, and nothing was
    // written where it would have gone.
    var untouched: u64 = 0xDEAD_BEEF;
    try testing.expectEqual(facet.Result.not_ready, fb.GetQueryPoolResults(device, occlusion, 0, 1, @sizeOf(u64), &untouched, @sizeOf(u64), facet.QUERY_RESULT_64));
    try testing.expectEqual(0xDEAD_BEEF, untouched);

    // The query begins before the pass and ends after it: the samples are
    // counted as the tiles are drawn, which is where the pass ends.
    var commands = try bench.record();
    fb.CmdResetQueryPool(commands, occlusion, 0, 2);
    fb.CmdBeginQuery(commands, occlusion, 0, facet.QUERY_CONTROL_PRECISE);
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdEndQuery(commands, occlusion, 0);
    try bench.submit();

    // Every pixel the triangle covered passed the tests, and no other.
    const drawn = pixelsOf(&picture, green);
    try testing.expect(drawn > 1000);
    try testing.expectEqual(drawn, try queryValue(&bench, occlusion, 0));
    // The one that was reset but never begun is still not ready.
    try testing.expectEqual(facet.Result.not_ready, fb.GetQueryPoolResults(device, occlusion, 1, 1, @sizeOf(u64), &untouched, @sizeOf(u64), facet.QUERY_RESULT_64));

    // The same draw again, two instances of it, with the statistics
    // counted instead.
    commands = try bench.record();
    fb.CmdResetQueryPool(commands, statistics, 0, 1);
    fb.CmdBeginQuery(commands, statistics, 0, 0);
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 3, 2, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdEndQuery(commands, statistics, 0);
    try bench.submit();

    // Six values, in the order of their bits: the vertices and the
    // triangles input assembly was given, the vertex function's calls,
    // what clipping was given and what came out of it, and the pixels the
    // fragment function was called for.
    var values: [6]u64 = @splat(0);
    try testing.expectEqual(facet.Result.success, fb.GetQueryPoolResults(device, statistics, 0, 1, @sizeOf(@TypeOf(values)), &values, @sizeOf(@TypeOf(values)), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT));
    try testing.expectEqual(6, values[0]);
    try testing.expectEqual(2, values[1]);
    try testing.expectEqual(6, values[2]);
    try testing.expectEqual(2, values[3]);
    try testing.expectEqual(2, values[4]);
    // A quad at a time, all four of its pixels as a GPU shades them, and
    // at least the pixels that were kept of both instances.
    try testing.expect(values[5] % 4 == 0);
    try testing.expect(values[5] >= 2 * drawn);
}

test "query values copied into a buffer: as wide as asked, with availability, and nothing written outside it" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    _, const list = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass });
    defer fb.DestroyPipeline(device, list);
    const occlusion = try queryPool(&bench, .occlusion, 2, 0);
    defer fb.DestroyQueryPool(device, occlusion);

    const vertices = [_][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 } };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const into, const bytes = try bench.buffer(64, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(bytes[0..64], 0xAA);
    const offset: u64 = 0;
    const green: u32 = 0xFF00_FF00;
    const blue = clears(0xFF00_00FF);

    var commands = try bench.record();
    fb.CmdResetQueryPool(commands, occlusion, 0, 2);
    fb.CmdBeginQuery(commands, occlusion, 0, 0);
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdEndQuery(commands, occlusion, 0);
    try bench.submit();
    const drawn = pixelsOf(&picture, green);

    // Both queries copied into the buffer 8 bytes apart, four bytes of
    // value and four of availability: the second was never begun.
    commands = try bench.record();
    fb.CmdCopyQueryPoolResults(commands, occlusion, 0, 2, into, 16, 8, facet.QUERY_RESULT_WITH_AVAILABILITY);
    // A copy that would not lie inside the buffer writes nothing of it.
    fb.CmdCopyQueryPoolResults(commands, occlusion, 0, 2, into, 56, 8, facet.QUERY_RESULT_WITH_AVAILABILITY);
    try bench.submit();

    try testing.expectEqual(drawn, std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(1, std.mem.readInt(u32, bytes[20..24], .little));
    // Not available: it says so, and its value was left as it was.
    try testing.expectEqual(0xAAAA_AAAA, std.mem.readInt(u32, bytes[24..28], .little));
    try testing.expectEqual(0, std.mem.readInt(u32, bytes[28..32], .little));
    // Before the offset and where the copy that was too large would have
    // gone: untouched.
    try testing.expectEqual(0xAAAA_AAAA, std.mem.readInt(u32, bytes[12..16], .little));
    try testing.expectEqual(0xAAAA_AAAA, std.mem.readInt(u32, bytes[56..60], .little));
}

test "a query pool refused: a kind the device does not count, a statistic no stage of the library has, and none at all" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var made: ?*facet.QueryPool = null;

    // There is no geometry shader, so neither statistic of one is counted.
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateQueryPool(device, &.{
        .query_type = .pipeline_statistics,
        .query_count = 1,
        .pipeline_statistics = facet.QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_VERTICES | facet.QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_INVOCATIONS,
    }, &made));
    try testing.expectEqual(null, made);
    // A bit that is no statistic at all.
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateQueryPool(device, &.{ .query_type = .pipeline_statistics, .query_count = 1, .pipeline_statistics = 1 << 20 }, &made));
    // A statistics pool that counts nothing, and a pool of no queries.
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateQueryPool(device, &.{ .query_type = .pipeline_statistics, .query_count = 1 }, &made));
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateQueryPool(device, &.{ .query_type = .occlusion, .query_count = 0 }, &made));
    try testing.expectEqual(null, made);

    // A timestamp is the E-clock, which the library opens as timer.device:
    // the host's ROM has none, so no device of it writes one, and what the
    // device says of itself says the same.
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    var family: facet.QueueFamilyProperties = undefined;
    var count: u32 = 1;
    fb.GetPhysicalDeviceQueueFamilyProperties(bench.physical, &count, @ptrCast(&family));
    if (features.timestamp_queries) {
        try testing.expect(family.timestamp_valid_bits > 0);
        try testing.expect(properties.limits.timestamp_period_ns > 0);
        const pool = try queryPool(&bench, .timestamp, 1, 0);
        fb.DestroyQueryPool(device, pool);
    } else {
        try testing.expectEqual(0, family.timestamp_valid_bits);
        try testing.expectEqual(0, properties.limits.timestamp_period_ns);
        try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateQueryPool(device, &.{ .query_type = .timestamp, .query_count = 1 }, &made));
        try testing.expectEqual(null, made);
    }

    // Nothing given back for a pool that was never made.
    fb.DestroyQueryPool(device, null);
}

test "subpasses one after another, a depth kept only for the same attachments; a subpass's several colour attachments, each with its colour" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const first = try Picture.of(&bench, 64, 64);
    const second = try Picture.of(&bench, 64, 64);
    _, const depth_view = try bench.image(.{ .format = .d16_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, true);

    const attachments = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
    };
    const only_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const both = [2]facet.AttachmentReference{ .{ .attachment = 1, .layout = .general }, .{ .attachment = 0, .layout = .general } };
    const twice = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .general }, .{ .attachment = 0, .layout = .general } };
    const depth = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
    const drawn_on = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = &only_first, .depth_stencil_attachment = &depth };
    const into_both = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &both };

    // Two of the same, then both pictures.
    const subpasses = [3]facet.SubpassDescription{ drawn_on, drawn_on, into_both };
    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 3, .subpasses = &subpasses }, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;

    // The depth wanted again after another subpass: it is not stored. An
    // attachment twice in a subpass.
    const other_depth = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = both[0..1], .depth_stencil_attachment = &depth };
    const apart = [3]facet.SubpassDescription{ drawn_on, into_both, other_depth };
    var none: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 3, .subpasses = &apart }, &none));
    const twice_over = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &twice };
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&twice_over) }, &none));

    const frame = try framebuffer(&bench, pass, &.{ first.view, second.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const shaders = try module(&bench, &SubpassScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true };
    const red_result, const red = makePipeline(&bench, .{ .module = shaders, .name = "red", .layout = layout, .pass = pass, .depth = tested });
    try testing.expectEqual(facet.Result.success, red_result);
    defer fb.DestroyPipeline(device, red);
    const green_result, const green = makePipeline(&bench, .{ .module = shaders, .name = "green", .layout = layout, .pass = pass, .subpass = 1, .depth = tested });
    try testing.expectEqual(facet.Result.success, green_result);
    defer fb.DestroyPipeline(device, green);
    const outputs_result, const outputs = makePipeline(&bench, .{ .module = shaders, .name = "outputs", .layout = layout, .pass = pass, .subpass = 2, .blend_count = 2, .dynamic = &.{.scissor} });
    try testing.expectEqual(facet.Result.success, outputs_result);
    defer fb.DestroyPipeline(device, outputs);

    // No such subpass; a blend state short of the subpass's attachments; two
    // that do not agree.
    var refused_result, _ = makePipeline(&bench, .{ .module = shaders, .name = "red", .layout = layout, .pass = pass, .subpass = 3 });
    try testing.expectEqual(facet.Result.error_initialization_failed, refused_result);
    refused_result, _ = makePipeline(&bench, .{ .module = shaders, .name = "outputs", .layout = layout, .pass = pass, .subpass = 2 });
    try testing.expectEqual(facet.Result.error_initialization_failed, refused_result);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(SubpassScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(SubpassScene.quad))], std.mem.asBytes(&SubpassScene.quad));
    const clear_values = [3]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const offset: u64 = 0;
    const left_half = facet.Rect2D{ .extent = .{ .width = 32, .height = 64 } };
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 3, .clear_values = &clear_values }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, red.?);
    fb.CmdDraw(commands, 6, 1, 0, 2);
    fb.CmdNextSubpass(commands, .@"inline");
    // Behind the red, in the same tiles: not seen.
    fb.CmdBindPipeline(commands, .graphics, green.?);
    fb.CmdDraw(commands, 6, 1, 0, 6);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, outputs.?);
    fb.CmdSetScissor(commands, 0, 1, @ptrCast(&left_half));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    // A part cleared of the first of them alone.
    const corner = facet.ClearRect{ .rect = .{ .offset = .{ .y = 48 }, .extent = .{ .width = 8, .height = 8 } } };
    const clear_first = facet.ClearAttachment{ .color_attachment = 0, .clear_value = .{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } } };
    fb.CmdClearAttachments(commands, 1, @ptrCast(&clear_first), 1, @ptrCast(&corner));
    // Past the last: nothing.
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // The second is the subpass's first, in blue: cleared white beside it.
    try testing.expectEqual(SubpassScene.blue, second.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), second.at(56, 8));
    try testing.expectEqual(SubpassScene.green, second.at(4, 52));
    // The first kept its red beside its yellow, cleared only the once.
    try testing.expectEqual(SubpassScene.yellow, first.at(8, 8));
    try testing.expectEqual(SubpassScene.red, first.at(56, 8));
    try testing.expectEqual(SubpassScene.yellow, first.at(4, 52));
}

/// What reads the textures of layers below: a quad over the whole picture, its
/// instance the layer, face or slice.
const LayerScene = struct {
    const quad = [6][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ -1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 } };

    fn out(vertices: *const shader.Vertices, k: usize) *[7]f32 {
        return vertices.output(@intCast(k))[0..7];
    }

    fn flat(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2 };
        }
    }

    fn array(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            out(vertices, k).* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2, @floatFromInt(vertices.instance) };
        }
    }

    fn cube(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const a = p[0];
            const b = p[1];
            const towards: [3]f32 = switch (vertices.instance) {
                0 => .{ 1, -b, -a },
                1 => .{ -1, -b, a },
                2 => .{ a, 1, b },
                3 => .{ a, -1, -b },
                4 => .{ a, -b, 1 },
                else => .{ -a, -b, -1 },
            };
            out(vertices, k).* = .{ p[0], p[1], 0, 1, towards[0], towards[1], towards[2] };
        }
    }

    fn volume(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            out(vertices, k).* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2, (@as(f32, @floatFromInt(vertices.instance)) + 0.5) / 4 };
        }
    }

    const nearest = facet.texture.Sampling{ .filter = .nearest };
    const entries = [_]shader.Entry{
        shader.vertex("flat", &flat, 2),
        shader.fixedFragment("flat", .{ .kind = .texture, .sampling = nearest }),
        shader.vertex("array", &array, 3),
        shader.fixedFragment("array", .{ .kind = .texture_array, .sampling = nearest }),
        shader.vertex("cube", &cube, 3),
        shader.fixedFragment("cube", .{ .kind = .texture_cube, .sampling = nearest }),
        shader.vertex("volume", &volume, 3),
        shader.fixedFragment("volume", .{ .kind = .texture_3d, .sampling = nearest }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A layer's red, and its quarters in green and blue: 0xAARRGGBB is
    /// what a sample of the corners of the picture should give.
    fn texel(layer: usize, x: usize, y: usize) [4]u8 {
        return .{ @intCast(10 + 40 * layer), if (x < 8) 0 else 255, if (y < 8) 0 else 255, 255 };
    }

    fn colorOf(layer: u32, right: bool, low: bool) u32 {
        return 0xFF00_0000 | (10 + 40 * layer) << 16 | @as(u32, if (right) 0xFF00 else 0) | @as(u32, if (low) 0xFF else 0);
    }
};

test "textures of layers: arrays, cube maps, 3D, copied a layer at a time; compressed and float ones unpacked" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const side16 = facet.Extent3D{ .width = 16, .height = 16 };

    const refused = [_]facet.ImageCreateInfo{
        .{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 2, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 3 }, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 4 }, .mip_levels = 2, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 4, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = .{ .width = 16, .height = 8 }, .array_layers = 6, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 257, .usage = usage },
        .{ .format = .bc1_rgb_unorm_block, .extent = side16, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
        .{ .format = .bc1_rgb_unorm_block, .extent = side16, .tiling = .linear, .usage = usage },
    };
    for (refused) |info| {
        var none: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &info, &none));
    }

    const array_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 3, .usage = usage | facet.IMAGE_USAGE_TRANSFER_SRC }, false);
    const cube_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 6, .usage = usage }, false);
    const volume_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 4 }, .usage = usage }, false);
    const into_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 2, .usage = usage }, false);
    const packed_image = try bench.bareImage(.{ .format = .bc1_rgba_unorm_block, .extent = side16, .usage = usage }, false);
    const half_image = try bench.bareImage(.{ .format = .r16g16b16a16_sfloat, .extent = .{ .width = 4, .height = 4 }, .usage = usage }, false);

    // What a view of each may be.
    const not_views = [_]facet.ImageViewCreateInfo{
        .{ .image = array_image, .format = .r8g8b8a8_unorm },
        .{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .cube },
        .{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .@"2d_array", .subresource_range = .{ .base_array_layer = 3 } },
        .{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .@"3d" },
        .{ .image = cube_image, .format = .r8g8b8a8_unorm, .view_type = .cube, .subresource_range = .{ .layer_count = 5 } },
        .{ .image = volume_image, .format = .r8g8b8a8_unorm },
        .{ .image = packed_image, .format = .r8g8b8a8_unorm },
    };
    for (not_views) |info| {
        var none: ?*facet.ImageView = null;
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImageView(device, &info, &none));
    }
    const array_view = try bench.viewOf(.{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .@"2d_array" });
    const layer_view = try bench.viewOf(.{ .image = array_image, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_array_layer = 1, .layer_count = 1 } });
    const cube_view = try bench.viewOf(.{ .image = cube_image, .format = .r8g8b8a8_unorm, .view_type = .cube });
    const volume_view = try bench.viewOf(.{ .image = volume_image, .format = .r8g8b8a8_unorm, .view_type = .@"3d" });
    const into_view = try bench.viewOf(.{ .image = into_image, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_array_layer = 1, .layer_count = 1 } });
    const packed_view = try bench.viewOf(.{ .image = packed_image, .format = .bc1_rgba_unorm_block });
    const half_view = try bench.viewOf(.{ .image = half_image, .format = .r16g16b16a16_sfloat });

    // Six stacks of texels one after another, the most any image takes.
    const stack_bytes = 16 * 16 * 4;
    const staging, const staged = try bench.buffer(stack_bytes * 6 + 256, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..6) |layer| for (0..16) |y| for (0..16) |x| {
        staged[layer * stack_bytes + (y * 16 + x) * 4 ..][0..4].* = LayerScene.texel(layer, x, y);
    };
    // Sixteen blocks of BC1, a block's every texel its first colour: red on
    // the left and blue on the right.
    const blocks_at = stack_bytes * 6;
    for (0..16) |block| {
        const color: u16 = if (block % 4 < 2) 0xF800 else 0x001F;
        std.mem.writeInt(u16, staged[blocks_at + block * 8 ..][0..2], color, .little);
        std.mem.writeInt(u16, staged[blocks_at + block * 8 + 2 ..][0..2], 0, .little);
        std.mem.writeInt(u32, staged[blocks_at + block * 8 + 4 ..][0..4], 0, .little);
    }
    const halves_at = blocks_at + 128;
    for (0..16) |k| staged[halves_at + k * 8 ..][0..8].* = .{ 0x00, 0x3C, 0x00, 0x38, 0x00, 0x40, 0x00, 0x3C };

    const whole = facet.BufferImageCopy{ .image_subresource = .{ .layer_count = 3 }, .image_extent = side16 };
    const slices = facet.BufferImageCopy{ .image_extent = .{ .width = 16, .height = 16, .depth = 4 } };
    var faces: [6]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*face, k| face.* = .{ .buffer_offset = k * stack_bytes, .image_subresource = .{ .base_array_layer = @intCast(k) }, .image_extent = side16 };
    const blocks = facet.BufferImageCopy{ .buffer_offset = blocks_at, .image_extent = side16 };
    const halves = facet.BufferImageCopy{ .buffer_offset = halves_at, .image_extent = .{ .width = 4, .height = 4 } };
    const layer_copy = facet.ImageCopy{ .src_subresource = .{ .base_array_layer = 2 }, .dst_subresource = .{ .base_array_layer = 1 }, .extent = side16 };
    const read_region = facet.BufferImageCopy{ .image_subresource = .{ .base_array_layer = 1, .layer_count = 2 }, .image_extent = side16 };
    _, const read_back = try bench.buffer(stack_bytes * 2, facet.BUFFER_USAGE_TRANSFER_DST);
    const read_buffer = bench.buffers[bench.buffer_count - 1];

    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, array_image, .transfer_dst_optimal, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, staging, cube_image, .transfer_dst_optimal, 6, &faces);
    fb.CmdCopyBufferToImage(commands, staging, volume_image, .transfer_dst_optimal, 1, @ptrCast(&slices));
    fb.CmdCopyBufferToImage(commands, staging, packed_image, .transfer_dst_optimal, 1, @ptrCast(&blocks));
    fb.CmdCopyBufferToImage(commands, staging, half_image, .transfer_dst_optimal, 1, @ptrCast(&halves));
    fb.CmdCopyImage(commands, array_image, .general, into_image, .general, 1, @ptrCast(&layer_copy));
    fb.CmdCopyImageToBuffer(commands, array_image, .general, read_buffer, 1, @ptrCast(&read_region));
    try bench.submit();
    try testing.expectEqualSlices(u8, &LayerScene.texel(1, 8, 0), read_back[8 * 4..][0..4]);
    try testing.expectEqualSlices(u8, &LayerScene.texel(2, 0, 8), read_back[stack_bytes + 8 * 16 * 4 ..][0..4]);

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));

    const shaders = try module(&bench, &LayerScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const picture = try Picture.of(&bench, 64, 64);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(LayerScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(LayerScene.quad))], std.mem.asBytes(&LayerScene.quad));

    const Run = struct {
        view: *facet.ImageView,
        name: [*:0]const u8,
        instance: u32,
    };
    const offset: u64 = 0;
    const black = clears(0xFF00_0000);
    const draw = struct {
        fn draw(on: *Bench, run: Run, made_layout: *facet.PipelineLayout, into: *facet.RenderPass, into_frame: *facet.Framebuffer, code_module: *facet.ShaderModule, sets: *[1]?*facet.DescriptorSet, vertices: *facet.Buffer, first: *const u64, clear_values: *const [2]facet.ClearValue) !void {
            const f = on.rig.fb;
            const image_info = facet.DescriptorImageInfo{ .image_view = run.view };
            const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const result, const pipeline = makePipeline(on, .{ .module = code_module, .name = run.name, .layout = made_layout, .pass = into });
            try testing.expectEqual(facet.Result.success, result);
            defer f.DestroyPipeline(on.device, pipeline);
            const recording = try on.record();
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = into_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = clear_values }, .@"inline");
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdBindDescriptorSets(recording, .graphics, made_layout, 0, 1, @ptrCast(sets), 0, null);
            f.CmdBindPipeline(recording, .graphics, pipeline.?);
            f.CmdDraw(recording, 6, 1, 0, run.instance);
            f.CmdEndRenderPass(recording);
            try on.submit();
        }
    }.draw;

    const layered = [_]struct { run: Run, layer: u32 }{
        .{ .run = .{ .view = array_view, .name = "array", .instance = 0 }, .layer = 0 },
        .{ .run = .{ .view = array_view, .name = "array", .instance = 2 }, .layer = 2 },
        // Past the last layer: the last.
        .{ .run = .{ .view = array_view, .name = "array", .instance = 9 }, .layer = 2 },
        .{ .run = .{ .view = layer_view, .name = "flat", .instance = 0 }, .layer = 1 },
        .{ .run = .{ .view = into_view, .name = "flat", .instance = 0 }, .layer = 2 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 0 }, .layer = 0 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 1 }, .layer = 1 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 2 }, .layer = 2 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 3 }, .layer = 3 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 4 }, .layer = 4 },
        .{ .run = .{ .view = cube_view, .name = "cube", .instance = 5 }, .layer = 5 },
        .{ .run = .{ .view = volume_view, .name = "volume", .instance = 0 }, .layer = 0 },
        .{ .run = .{ .view = volume_view, .name = "volume", .instance = 3 }, .layer = 3 },
    };
    for (layered) |each| {
        try draw(&bench, each.run, layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
        try testing.expectEqual(LayerScene.colorOf(each.layer, false, false), picture.at(8, 8));
        try testing.expectEqual(LayerScene.colorOf(each.layer, true, false), picture.at(56, 8));
        try testing.expectEqual(LayerScene.colorOf(each.layer, false, true), picture.at(8, 56));
        try testing.expectEqual(LayerScene.colorOf(each.layer, true, true), picture.at(56, 56));
    }
    try draw(&bench, .{ .view = packed_view, .name = "flat", .instance = 0 }, layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
    try draw(&bench, .{ .view = half_view, .name = "flat", .instance = 0 }, layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_80FF), picture.at(32, 32));
}

test "the cube through the API, as the rasterizer draws it by itself" {
    var bench = try Bench.up();
    defer bench.down();
    const picture = try Picture.of(&bench, 160, 120);
    try drawCube(&bench, picture.view, 160, 120);
    try expectLike(&picture, "cube");
}

/// The cube as C:test/FacetCube draws it, turned a little, into `target`
/// of `width` x `height`: the pattern's texture copied in, the backdrop
/// and the box drawn over a depth image, and waited for.
fn drawCube(bench: *Bench, target: *facet.ImageView, width: u32, height: u32) !void {
    const fb = bench.rig.fb;
    const device = bench.device;
    _, const depth = try bench.image(.{ .format = .d16_unorm, .extent = .{ .width = width, .height = height }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, true);
    const pass = try renderPass(bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(bench, pass, &.{ target, depth }, width, height);
    defer fb.DestroyFramebuffer(device, frame);

    // The pattern's texture, its levels staged row by row and copied in.
    const levels = scenes.texture_levels;
    const pattern_memory = try testing.allocator.alignedAlloc(u8, .@"8", scenes.textureBytes(.rgba8888));
    defer testing.allocator.free(pattern_memory);
    const pattern = scenes.patternTexture(.rgba8888, pattern_memory.ptr);
    const texture_image, const texture_view = try bench.image(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = scenes.texture_side, .height = scenes.texture_side },
        .mip_levels = levels,
        .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
    }, false);
    const staging, const staged = try bench.buffer(scene.staged_bytes, facet.BUFFER_USAGE_TRANSFER_SRC);
    const regions = scene.stage(&pattern, staged);

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));
    const image_info = facet.DescriptorImageInfo{ .image_view = texture_view };
    const write = facet.WriteDescriptorSet{ .dst_set = set[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const shaders = try module(bench, &scene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(bench, &.{set_layout.?}, 64);
    defer fb.DestroyPipelineLayout(device, layout);
    const less = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true };
    const common = PipelineState{ .module = shaders, .layout = layout, .pass = pass, .stride = @sizeOf(scene.Vertex), .attributes = &scene.attributes, .depth = less, .width = @floatFromInt(width), .height = @floatFromInt(height) };
    var backdrop_state = common;
    backdrop_state.name = "backdrop";
    var box_state = common;
    box_state.name = "box";
    box_state.raster = .{ .cull_mode = facet.CULL_MODE_BACK, .front_face = .clockwise };
    const backdrop_result, const backdrop = makePipeline(bench, backdrop_state);
    try testing.expectEqual(facet.Result.success, backdrop_result);
    defer fb.DestroyPipeline(device, backdrop);
    const box_result, const box = makePipeline(bench, box_state);
    try testing.expectEqual(facet.Result.success, box_result);
    defer fb.DestroyPipeline(device, box);

    // The backdrop's four vertices and the cube's after them, in one
    // buffer; their indices likewise.
    const backdrop_vertices = scenes.backdrop(scene.Vertex);
    const cube_vertices = scenes.cube(scene.Vertex);
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(backdrop_vertices)) + @sizeOf(@TypeOf(cube_vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(backdrop_vertices))], std.mem.asBytes(&backdrop_vertices));
    @memcpy(vertex_bytes[@sizeOf(@TypeOf(backdrop_vertices))..][0..@sizeOf(@TypeOf(cube_vertices))], std.mem.asBytes(&cube_vertices));
    const indices = scenes.quad_indices ++ scenes.cube_indices;
    const index_buffer, const index_bytes = try bench.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
    @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], std.mem.asBytes(&indices));

    const transform = scenes.cubeTransform(0.6, 4.5, @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)));
    const black = clears(0xFF00_0000);
    const offset: u64 = 0;
    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, texture_image, .transfer_dst_optimal, levels, &regions);
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = width, .height = height } }, .clear_value_count = 2, .clear_values = &black }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindIndexBuffer(commands, index_buffer, 0, .uint16);
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&set), 0, null);
    fb.CmdBindPipeline(commands, .graphics, backdrop.?);
    fb.CmdDrawIndexed(commands, scenes.quad_indices.len, 1, 0, 0, 0);
    fb.CmdBindPipeline(commands, .graphics, box.?);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(@TypeOf(transform)), &transform);
    fb.CmdDrawIndexed(commands, scenes.cube_indices.len, 1, scenes.quad_indices.len, backdrop_vertices.len, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();
}

/// The picture against c/test/raster/reference/`name`.ppm, as
/// reference.zig holds the rasterizer's own: 2 apart in a channel
/// anywhere, more in a few pixels. When it is further, what was drawn is
/// written to .zig-cache/raster/NAME-facet.ppm.
/// A window of the test's own on a screen of its own, as window.zig is
/// one of intuition's: a swapchain's pictures are memory, and showing one
/// copies it onto the screen where the window is then, but for what
/// covers it - as BltBitMapRastPort does through the window's layer.
const Window = struct {
    left: u32 = 20,
    top: u32 = 10,
    /// Another window over part of it: x, y, width and height.
    cover: ?[4]u32 = null,
    screen: [screen_height][screen_width]u32 = @splat(@splat(screen_colour)),
    pictures: [2][cube_width * cube_height]u32 align(64) = undefined,
    made: u32 = 0,
    shows: u32 = 0,

    const screen_width = 240;
    const screen_height = 180;
    const screen_colour: u32 = 0xFF55_6677;
    const cube_width = 160;
    const cube_height = 120;

    const ops = _surface.Ops{ .copies = true, .shape = &shape, .most = &most, .make = &make, .unmake = &unmake, .show = &show, .close = &close };

    fn of(surface: *_surface.Surface) *Window {
        return @ptrCast(@alignCast(surface.context.?));
    }

    fn shape(_: *_surface.Surface) ?_surface.Shape {
        return .{ .width = cube_width, .height = cube_height, .format = .b8g8r8a8_unorm };
    }

    fn most(_: *_surface.Surface) u32 {
        return 2;
    }

    fn make(surface: *_surface.Surface, pictures: []_surface.Picture) bool {
        const window = of(surface);
        for (pictures, 0..) |*picture, k| picture.* = .{ .pixels = @ptrCast(&window.pictures[k]), .pitch = cube_width * 4, .handle = &window.pictures[k] };
        window.made += @intCast(pictures.len);
        return true;
    }

    fn unmake(surface: *_surface.Surface, pictures: []_surface.Picture, _: ?u32) void {
        of(surface).made -= @intCast(pictures.len);
    }

    fn show(surface: *_surface.Surface, picture: *_surface.Picture) bool {
        const window = of(surface);
        const from: *const [cube_width * cube_height]u32 = @ptrCast(@alignCast(picture.handle.?));
        for (0..cube_height) |y| for (0..cube_width) |x| {
            const at_x = window.left + x;
            const at_y = window.top + y;
            if (window.cover) |cover| if (at_x >= cover[0] and at_x < cover[0] + cover[2] and at_y >= cover[1] and at_y < cover[1] + cover[3]) continue;
            window.screen[at_y][at_x] = from[y * cube_width + x];
        };
        window.shows += 1;
        return true;
    }

    fn close(_: *_surface.Surface) void {}

    /// A surface over it, made as CreateWindowSurface makes one.
    fn surfaceOn(window: *Window, bench: *Bench) !*facet.Surface {
        const owner = _objects.of(Instance, bench.instance);
        const surface = _objects.create(bench.rig.sys, _surface.Surface) orelse return error.NoMemory;
        surface.* = .{ .instance = owner, .ops = &ops, .context = window };
        owner.surfaces += 1;
        return _objects.handle(facet.Surface, surface);
    }

    /// The part of the screen where the window is now, as a picture.
    fn inside(window: *const Window) Picture {
        return .{
            .image = undefined,
            .view = undefined,
            .pixels = @ptrCast(&window.screen[window.top][window.left]),
            .pitch = screen_width * 4,
            .width = cube_width,
            .height = cube_height,
        };
    }

    /// Whether the screen is its own colour everywhere outside the window,
    /// and where the window is covered.
    fn untouchedRound(window: *const Window) bool {
        for (window.screen, 0..) |row, y| for (row, 0..) |pixel, x| {
            const in_window = x >= window.left and x < window.left + cube_width and y >= window.top and y < window.top + cube_height;
            const covered = if (window.cover) |cover| x >= cover[0] and x < cover[0] + cover[2] and y >= cover[1] and y < cover[1] + cover[3] else false;
            if ((!in_window or covered) and pixel != screen_colour) return false;
        };
        return true;
    }
};

test "the cube in a window: copied where the window is, not over what covers it, again where it moved" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const window = try testing.allocator.create(Window);
    defer testing.allocator.destroy(window);
    window.* = .{ .cover = .{ 100, 60, 80, 50 } };
    const surface = try window.surfaceOn(&bench);
    defer fb.DestroySurface(bench.instance, surface);

    var capabilities: facet.SurfaceCapabilities = undefined;
    try testing.expectEqual(facet.Result.success, fb.GetPhysicalDeviceSurfaceCapabilities(bench.physical, surface, &capabilities));
    var swapchain: ?*facet.Swapchain = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSwapchain(device, &.{
        .surface = surface,
        .min_image_count = 1,
        .image_format = .b8g8r8a8_unorm,
        .image_extent = capabilities.current_extent,
    }, &swapchain));
    defer fb.DestroySwapchain(device, swapchain);
    var count: u32 = 1;
    var images: [1]*facet.Image = undefined;
    try testing.expectEqual(facet.Result.success, fb.GetSwapchainImages(device, swapchain.?, &count, &images));
    var view: ?*facet.ImageView = null;
    try testing.expectEqual(facet.Result.success, fb.CreateImageView(device, &.{ .image = images[0], .format = .b8g8r8a8_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR } }, &view));
    defer fb.DestroyImageView(device, view);

    // Drawn and presented: copied into the window but where it is covered.
    var index: u32 = 99;
    try testing.expectEqual(facet.Result.success, fb.AcquireNextImage(device, swapchain.?, 0, null, null, &index));
    try testing.expectEqual(@as(u32, 0), index);
    try drawCube(&bench, view.?, Window.cube_width, Window.cube_height);
    const present = facet.PresentInfo{ .swapchains = @ptrCast(&swapchain), .image_indices = @ptrCast(&index) };
    try testing.expectEqual(facet.Result.success, fb.QueuePresent(bench.queue, &present));
    try testing.expectEqual(@as(u32, 1), window.shows);
    try testing.expect(window.untouchedRound());
    try testing.expect(window.screen[60][100] == Window.screen_colour and window.screen[60][99] != Window.screen_colour);

    // Copied, the image is free at once; uncovered and moved, the window
    // shows the whole picture where it is now.
    try testing.expectEqual(facet.Result.success, fb.AcquireNextImage(device, swapchain.?, 0, null, null, &index));
    window.cover = null;
    window.left = 70;
    window.top = 50;
    try testing.expectEqual(facet.Result.success, fb.QueuePresent(bench.queue, &present));
    try expectLike(&window.inside(), "cube");
}

fn expectLike(picture: *const Picture, comptime name: []const u8) !void {
    const kept = @embedFile("../../../c/test/raster/reference/" ++ name ++ ".ppm");
    const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ 160, 120 });
    try testing.expect(picture.width == 160 and picture.height == 120);
    try testing.expect(kept.len == header.len + 160 * 120 * 3 and std.mem.eql(u8, kept[0..header.len], header));
    var apart: u32 = 0;
    var worst: u32 = 0;
    var bytes: [header.len + 160 * 120 * 3]u8 = undefined;
    @memcpy(bytes[0..header.len], header);
    for (0..120) |y| for (0..160) |x| {
        const pixel = picture.at(@intCast(x), @intCast(y));
        const place = header.len + (y * 160 + x) * 3;
        var most: u32 = 0;
        for (0..3) |channel| {
            const got: u8 = @truncate(pixel >> @intCast(16 - channel * 8));
            bytes[place + channel] = got;
            most = @max(most, @abs(@as(i32, got) - kept[place + channel]));
        }
        worst = @max(worst, most);
        if (most > 2) apart += 1;
    };
    if (apart <= 160 * 120 / 1000) return;
    std.debug.print("{s}: {d} pixels apart from the reference (worst by {d}); drawn: .zig-cache/raster/{s}-facet.ppm\n", .{ name, apart, worst, name });
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(testing.io, ".zig-cache/raster") catch {};
    cwd.writeFile(testing.io, .{ .sub_path = ".zig-cache/raster/" ++ name ++ "-facet.ppm", .data = &bytes }) catch {};
    return error.TestExpectedEqual;
}
