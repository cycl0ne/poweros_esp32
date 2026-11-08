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
const texture_zig = facet.texture;
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

    /// The same, the point each vertex makes as wide as the vertex's own
    /// z says in pixels: Vulkan's `PointSize` (since 1.70). Every vertex
    /// is drawn at z = 0.5, so the size is read off the buffer and the
    /// depth stays out of it.
    fn sized(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], 0.5, 1 };
            vertices.setPointSize(@intCast(k), p[2]);
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("main", &vertex, 0),
        shader.fragment("main", &fragment, 0),
        shader.vertex("sized", &sized, 0),
        shader.fragment("sized", &fragment, 0),
    };
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
    /// What the subpass's second colour attachment is blended by, where it
    /// is not the first's (`PhysicalDeviceFeatures.independent_blend`).
    second_blend: ?facet.PipelineColorBlendAttachmentState = null,
    width: f32 = 64,
    height: f32 = 64,
    /// Where z = 0 and z = 1 land in the depth.
    min_depth: f32 = 0,
    max_depth: f32 = 1,
    dynamic: []const facet.DynamicState = &.{},
    flags: u32 = 0,
    subpass: u32 = 0,
    blend_count: u32 = 1,
    /// The one set of blend constants a pipeline shares, and one set for
    /// each colour attachment where facet's own are given (since 1.51).
    blend_constants: [4]f32 = @splat(0),
    attachment_constants: ?[*]const [4]f32 = null,
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
    const viewport = facet.Viewport{ .width = state.width, .height = state.height, .min_depth = state.min_depth, .max_depth = state.max_depth };
    const scissor = facet.Rect2D{ .extent = .{ .width = @intFromFloat(state.width), .height = @intFromFloat(state.height) } };
    const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
    var blends: [4]facet.PipelineColorBlendAttachmentState = @splat(state.blend);
    if (state.second_blend) |other| blends[1] = other;
    const blend = facet.PipelineColorBlendStateCreateInfo{
        .attachment_count = state.blend_count,
        .attachments = &blends,
        .blend_constants = state.blend_constants,
        .attachment_constants = state.attachment_constants,
    };
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
    try testing.expectEqual(@as(u32, 0), made.parts[0].colors[0]);
    try testing.expectEqual(@as(u32, 1), made.parts[0].color_count);
    try testing.expectEqual(@as(?u32, 1), made.parts[0].depth);
    try testing.expectEqual(.keep, made.parts[0].color_loads[0]);
    fb.DestroyRenderPass(device, pass);
    fb.DestroyRenderPass(device, null);

    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    const refused = [_]struct { facet.Result, [2]facet.AttachmentDescription }{
        // A depth kept, of a format with no depth in it, and a stencil
        // kept of one with no stencil: each op wants its own plane.
        .{ .error_feature_not_present, .{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .s8_uint, .load_op = .load, .final_layout = .general } } },
        .{ .error_feature_not_present, .{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .d16_unorm, .stencil_store_op = .store, .final_layout = .general } } },
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

    // A depth of d16_unorm kept, which the cores do: the part says it is
    // read as each tile starts and written back as it is drawn.
    const kept = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .final_layout = .general },
        .{ .format = .d16_unorm, .load_op = .load, .store_op = .store, .final_layout = .general },
    };
    var keeping: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &kept, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &keeping));
    const plan = _objects.of(_render.RenderPass, keeping.?);
    try testing.expect(plan.parts[0].loads_depth);
    try testing.expect(plan.parts[0].stores_depth);
    try testing.expect(!plan.parts[0].loads_stencil);
    try testing.expect(!plan.parts[0].stores_stencil);
    fb.DestroyRenderPass(device, keeping);

    // Since 1.38 the stencil keeps its own as well, in its own plane of
    // the same rows: a format that holds both, with all four ops.
    const both = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .final_layout = .general },
        .{ .format = .d16_unorm_s8_uint, .load_op = .load, .store_op = .store, .stencil_load_op = .load, .stencil_store_op = .store, .final_layout = .general },
    };
    var keeping_both: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &both, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &keeping_both));
    const four = _objects.of(_render.RenderPass, keeping_both.?);
    try testing.expect(four.parts[0].loads_depth and four.parts[0].stores_depth);
    try testing.expect(four.parts[0].loads_stencil and four.parts[0].stores_stencil);
    fb.DestroyRenderPass(device, keeping_both);

    // A stencil alone, of s8_uint: no depth to keep, and its own two ops.
    const stencil_only = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .final_layout = .general },
        .{ .format = .s8_uint, .stencil_load_op = .load, .stencil_store_op = .store, .final_layout = .general },
    };
    var keeping_stencil: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &stencil_only, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &keeping_stencil));
    const alone = _objects.of(_render.RenderPass, keeping_stencil.?);
    try testing.expect(!alone.parts[0].loads_depth and !alone.parts[0].stores_depth);
    try testing.expect(alone.parts[0].loads_stencil and alone.parts[0].stores_stencil);
    fb.DestroyRenderPass(device, keeping_stencil);

    // A device that keeps no stencil refuses either of its ops, and keeps
    // taking the depth's.
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.stored_stencil = false;
    defer physical.features.stored_stencil = true;
    var refused_stencil: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &stencil_only, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &refused_stencil));
    try testing.expect(refused_stencil == null);
    var still: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &kept, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &still));
    fb.DestroyRenderPass(device, still);
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
    // A storage image is a kind the cores have; one of a kind nothing
    // writes through at all is refused.
    const storage_image = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_image };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&storage_image) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
    none = null;
    const texel_buffer = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_texel_buffer };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&texel_buffer) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
    none = null;
    // An input attachment is a kind the cores have, since 1.37; a kind
    // Vulkan has not got at all is refused.
    const input = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&input) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
    none = null;
    const nothing = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = @enumFromInt(11) };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&nothing) }, &none));
    var kept: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{}, &kept));
    defer fb.DestroySampler(device, kept);
    // A sampler the layout holds of its own, since 1.49: taken, and in
    // the slots of every set made of it.
    const held = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .immutable_samplers = @ptrCast(&kept) };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&held) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
    none = null;
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
    try testing.expect(made.mixings[0].enabled);
    try testing.expectEqual(.one_minus_src_alpha, made.mixings[0].dst_color);
    try testing.expectEqual(@as(f32, 64), made.viewport.?.width);
    try testing.expect(made.scissor == null);
    try testing.expectEqual(@as(u32, 1), made.locations);
    fb.DestroyPipeline(device, pipeline);
    fb.DestroyPipeline(device, null);

    var added = base;
    added.blend = .{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one };
    const added_result, const added_pipeline = makePipeline(&bench, added);
    try testing.expectEqual(facet.Result.success, added_result);
    try testing.expectEqual(.one, _objects.of(_pipeline.Pipeline, added_pipeline.?).mixings[0].dst_color);
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
    // A vertex binding whose stride is past the most.
    changes[1][0] = .error_feature_not_present;
    changes[1][1].stride = 4096;
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
                     .{ c(5), c(5), 0.5 },
        .{ c(60), c(60), 0.5 },
        // A triangle one way round, and the other.
                     .{ -0.5, -0.5, 0.5 },
        .{ 0.5, -0.5, 0.5 },                 .{ -0.5, 0.5, 0.5 },
        .{ -0.5, -0.5, 0.5 },                .{ -0.5, 0.5, 0.5 },
        .{ 0.5, -0.5, 0.5 },
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

test "a point is as wide as its vertex says: PointSize, and held inside the range the limits give" {
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

    // The range the device gives: one pixel at the narrow end, and wider
    // than one at the other, which is what Vulkan's `largePoints` says.
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    const range = properties.limits.point_size_range;
    try testing.expectEqual(@as(f32, 1), range[0]);
    try testing.expect(range[1] > 1);
    try testing.expectEqual(@as(f32, 0), properties.limits.point_size_granularity);

    // A point at the middle of pixel (16, 16), its size in z: one pixel,
    // eight pixels, none at all, and far more than the range holds.
    const at = struct {
        fn at(x: u32, y: u32, size: f32) [3]f32 {
            return .{ (@as(f32, @floatFromInt(x)) + 0.5) / 32 - 1, (@as(f32, @floatFromInt(y)) + 0.5) / 32 - 1, size };
        }
    }.at;
    const vertices = [5][3]f32{
        at(16, 16, 1),
        at(48, 16, 8),
        at(16, 48, 0),
        at(48, 48, 1000),
        at(32, 32, std.math.nan(f32)),
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const clear: u32 = 0xFF00_00FF;

    const drawn = struct {
        fn drawn(on: *Bench, pass: *facet.RenderPass, into: *facet.Framebuffer, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, buffer: *facet.Buffer, first: u32, count: u32, color: *const u32) !void {
            const facets = on.rig.fb;
            const result, const pipeline = makePipeline(on, .{ .module = shaders, .name = "sized", .layout = by, .pass = pass, .topology = .point_list });
            try testing.expectEqual(facet.Result.success, result);
            defer facets.DestroyPipeline(on.device, pipeline);
            const commands = try on.record();
            facets.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = into, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clears(0xFF00_00FF)) }, .@"inline");
            facets.CmdBindPipeline(commands, .graphics, pipeline.?);
            facets.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&offset));
            facets.CmdPushConstants(commands, by, facet.SHADER_STAGE_FRAGMENT, 0, 4, color);
            facets.CmdDraw(commands, count, 1, first, 0);
            facets.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.drawn;

    // A size of 1 is the one pixel every point was before 1.70.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 0, 1, &red);
    try testing.expectEqual(red, picture.at(16, 16));
    for ([_][2]u32{ .{ 15, 16 }, .{ 17, 16 }, .{ 16, 15 }, .{ 16, 17 } }) |near| try testing.expectEqual(clear, picture.at(near[0], near[1]));

    // Eight pixels across and down, about the vertex: three pixels either
    // way are inside it and six are not.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 1, 1, &red);
    try testing.expectEqual(red, picture.at(48, 16));
    for ([_][2]u32{ .{ 45, 16 }, .{ 51, 16 }, .{ 48, 13 }, .{ 48, 19 }, .{ 45, 13 }, .{ 51, 19 } }) |inside| try testing.expectEqual(red, picture.at(inside[0], inside[1]));
    for ([_][2]u32{ .{ 42, 16 }, .{ 54, 16 }, .{ 48, 10 }, .{ 48, 22 } }) |outside| try testing.expectEqual(clear, picture.at(outside[0], outside[1]));

    // A size of 0 comes to the one pixel: nothing is dropped and nothing
    // is widened.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 2, 1, &red);
    try testing.expectEqual(red, picture.at(16, 48));
    for ([_][2]u32{ .{ 15, 48 }, .{ 17, 48 }, .{ 16, 47 }, .{ 16, 49 } }) |near| try testing.expectEqual(clear, picture.at(near[0], near[1]));

    // And so does a NaN, which is no size at all.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 4, 1, &red);
    try testing.expectEqual(red, picture.at(32, 32));
    for ([_][2]u32{ .{ 31, 32 }, .{ 33, 32 }, .{ 32, 31 }, .{ 32, 33 } }) |near| try testing.expectEqual(clear, picture.at(near[0], near[1]));

    // And a size far above the range's end is held to the end, which on
    // this device covers the whole picture rather than drawing nothing.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 3, 1, &red);
    try testing.expectEqual(red, picture.at(48, 48));
    try testing.expectEqual(red, picture.at(2, 2));
    try testing.expectEqual(red, picture.at(62, 62));

    // All four at once, each its own size: the one-pixel point and the
    // eight-pixel one both there.
    try drawn(&bench, cleared, frame, flat, layout, vertex_buffer, 0, 3, &red);
    try testing.expectEqual(red, picture.at(16, 16));
    try testing.expectEqual(clear, picture.at(15, 16));
    try testing.expectEqual(red, picture.at(48, 19));
    try testing.expectEqual(red, picture.at(16, 48));
    try testing.expectEqual(clear, picture.at(17, 48));

    // A draw of lines takes no point size: the vertex function may say one
    // whatever the pipeline draws, and nothing comes of it.
    const lines = struct {
        fn lines(on: *Bench, pass: *facet.RenderPass, into: *facet.Framebuffer, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, buffer: *facet.Buffer, color: *const u32) !void {
            const facets = on.rig.fb;
            const result, const pipeline = makePipeline(on, .{ .module = shaders, .name = "sized", .layout = by, .pass = pass, .topology = .line_list });
            try testing.expectEqual(facet.Result.success, result);
            defer facets.DestroyPipeline(on.device, pipeline);
            const commands = try on.record();
            facets.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = into, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clears(0xFF00_00FF)) }, .@"inline");
            facets.CmdBindPipeline(commands, .graphics, pipeline.?);
            facets.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&offset));
            facets.CmdPushConstants(commands, by, facet.SHADER_STAGE_FRAGMENT, 0, 4, color);
            facets.CmdDraw(commands, 2, 1, 0, 0);
            facets.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.lines;
    // The line from (16, 16) to (48, 16), one pixel high whatever the
    // sizes those two vertices asked for.
    try lines(&bench, cleared, frame, flat, layout, vertex_buffer, &red);
    try testing.expectEqual(red, picture.at(32, 16));
    try testing.expectEqual(clear, picture.at(32, 13));
    try testing.expectEqual(clear, picture.at(32, 19));
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
        .{ -1, -1, 0.5 },  .{ 1, -1, 0.5 },  .{ -1, 1, 0.5 },  .{ -1, 1, 0.5 },  .{ 1, -1, 0.5 },  .{ 1, 1, 0.5 },
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

test "a compute group of many invocations, which share memory" {
    const Reduce = struct {
        /// A group of eight invocations, each squaring its own number in the
        /// dispatch: the squares go into the memory the group shares, and
        /// then - where a barrier would stand, between the two loops of the
        /// one call - they are added up.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 0).?;
            const held = groups.sharedAs(u32, 8) orelse return;
            for (0..groups.local[0]) |k| {
                const at = groups.globalInvocation(.{ @intCast(k), 0, 0 });
                held[groups.localIndex(.{ @intCast(k), 0, 0 })] = at[0] * at[0];
            }
            var sum: u32 = 0;
            for (held[0..groups.local[0]]) |value| sum += value;
            out[groups.group[0]] = sum;
            out[16 + groups.group[0]] = groups.invocations();
        }

        /// An entry that asked for nothing: one invocation a group, and no
        /// shared memory to be had.
        fn alone(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 0).?;
            out[32] = groups.invocations();
            out[33] = groups.shared_bytes;
            out[34] = if (groups.sharedAs(u32, 1) == null) 1 else 0;
            out[35] = groups.localIndex(.{ 0, 0, 0 }) + 1;
        }

        /// What the shared memory holds before anything wrote it, and how far
        /// it goes. One group a dispatch, so what it finds is what the
        /// dispatch began with and not another group's leavings.
        fn peek(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 0).?;
            const held = groups.sharedAs(u32, 256) orelse return;
            var sum: u32 = 0;
            for (held) |value| sum += value;
            out[48] = sum + 1;
            out[49] = if (groups.sharedAs(u32, 257) == null) 1 else 0;
            held[0] = 0xDEAD;
        }

        const entries = [_]shader.Entry{
            shader.computeGroup("main", &run, .{ 8, 1, 1 }, 32),
            shader.compute("alone", &alone),
            shader.computeGroup("peek", &peek, .{ 1, 1, 1 }, 1024),
            // Refused: more invocations a group than the device holds, and
            // more shared memory than it has.
            shader.computeGroup("crowd", &run, .{ 1024, 1024, 64 }, 0),
            shader.computeGroup("greedy", &run, .{ 1, 1, 1 }, 32 * 1024),
        };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    // What the entry carries, which is all the library has to go by.
    try testing.expectEqual([3]u32{ 8, 1, 1 }, Reduce.entries[0].localSize());
    try testing.expectEqual(@as(u32, 1024), Reduce.entries[0].sharedBytes());
    try testing.expectEqual([3]u32{ 1, 1, 1 }, Reduce.entries[1].localSize());
    try testing.expectEqual(@as(u32, 0), Reduce.entries[1].sharedBytes());
    try testing.expectEqual([3]u32{ 1024, 1024, 64 }, Reduce.entries[3].localSize());
    try testing.expectEqual(@as(u32, 32 * 1024), Reduce.entries[4].sharedBytes());
    // An axis under one is one, and one over what it holds is what it holds.
    const cut = shader.computeGroup("cut", &Reduce.alone, .{ 0, 4096, 4096 }, 1);
    try testing.expectEqual([3]u32{ 1, 1024, 64 }, cut.localSize());
    try testing.expectEqual(@as(u32, 1024), cut.sharedBytes());

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    try testing.expectEqual([3]u32{ 1024, 1024, 64 }, properties.limits.max_compute_work_group_size);
    try testing.expectEqual(@as(u32, 1024), properties.limits.max_compute_work_group_invocations);
    try testing.expectEqual(@as(u32, 16 * 1024), properties.limits.max_compute_shared_memory_size);

    const code = try module(&bench, &Reduce.code);
    defer fb.DestroyShaderModule(device, code);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .stage_flags = facet.SHADER_STAGE_COMPUTE };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const out_buffer, const out_bytes = try bench.buffer(64 * @sizeOf(u32), facet.BUFFER_USAGE_STORAGE_BUFFER);
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = out_buffer, .range = facet.WHOLE_SIZE };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
    const out: [*]u32 = @ptrCast(@alignCast(out_bytes));
    @memset(out[0..64], 0);

    const names = [_][*:0]const u8{ "main", "alone", "peek" };
    var infos: [names.len]facet.ComputePipelineCreateInfo = undefined;
    for (&infos, names) |*info, name| info.* = .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = code, .name = name }, .layout = layout };
    var pipelines: [names.len]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, names.len, &infos, &pipelines));
    defer for (pipelines) |made| fb.DestroyPipeline(device, made);

    // A group over the device's limits is refused rather than cut to it.
    var refused: [1]?*facet.Pipeline = undefined;
    for ([_][*:0]const u8{ "crowd", "greedy" }) |name| {
        const over = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = code, .name = name }, .layout = layout };
        try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateComputePipelines(device, null, 1, @ptrCast(&over), &refused));
        try testing.expectEqual(@as(?*facet.Pipeline, null), refused[0]);
    }

    // Two groups of eight invocations, and what a statistics query counts is
    // the invocations: the groups times what each holds.
    const statistics = try queryPool(&bench, .pipeline_statistics, 1, facet.QUERY_PIPELINE_STATISTIC_COMPUTE_SHADER_INVOCATIONS);
    defer fb.DestroyQueryPool(device, statistics);
    var commands = try bench.record();
    fb.CmdResetQueryPool(commands, statistics, 0, 1);
    fb.CmdBeginQuery(commands, statistics, 0, 0);
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 2, 1, 1);
    fb.CmdEndQuery(commands, statistics, 0);
    try bench.submit();
    // 0 to 7 squared and added up, then 8 to 15.
    try testing.expectEqual(@as(u32, 140), out[0]);
    try testing.expectEqual(@as(u32, 1100), out[1]);
    try testing.expectEqual(@as(u32, 0), out[2]);
    try testing.expectEqual(@as(u32, 8), out[16]);
    try testing.expectEqual(@as(u32, 8), out[17]);
    try testing.expectEqual(@as(u64, 16), try queryValue(&bench, statistics, 0));

    // An entry that asked for nothing: one invocation, nothing shared.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 1), out[32]);
    try testing.expectEqual(@as(u32, 0), out[33]);
    try testing.expectEqual(@as(u32, 1), out[34]);
    try testing.expectEqual(@as(u32, 1), out[35]);

    // The shared memory a dispatch starts with is cleared, and it goes as far
    // as the entry asked and no further.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 1), out[48]);
    try testing.expectEqual(@as(u32, 1), out[49]);

    // And the dispatch after it starts with it cleared again, whatever the
    // one before left in it.
    out[48] = 0;
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 1), out[48]);
}

test "a storage image written through by a compute function and by a fragment function, and read back as a texture" {
    const Paint = struct {
        /// Each group writes one texel of the image bound at set 0 binding
        /// 0: its own numbers, so what is written says which group wrote
        /// it.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const image = groups.resources.written(0, 0, 0) orelse return;
            const color = 0xFF00_0000 | groups.group[0] << 16 | groups.group[1] << 8 | groups.resources.constants(u32).*;
            image.setColor(0, 0, groups.group[0], groups.group[1], color);
        }
        /// The same through a sampled image, which may not be written: it
        /// writes the push constants into the buffer instead, so the test
        /// can tell it ran and found nothing.
        fn refused(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 1) orelse return;
            out[0] = if (groups.resources.written(0, 0, 0) == null) 0xA11_600D else 0xBAD;
        }
        /// A fragment function that writes the image as well as its pixel:
        /// one texel for each pixel it colours, so a draw fills both.
        fn fragment(fragments: *const shader.Fragments) callconv(.c) void {
            shader.fill(fragments, 0xFF00_FF00);
            const image = fragments.resources.written(0, 0, 0) orelse return;
            for (0..fragments.count) |k| {
                const quad = fragments.quads[k];
                for (0..4) |i| {
                    if (quad.kept >> @intCast(i) & 1 == 0) continue;
                    const x = quad.x + @as(u32, @intCast(i & 1));
                    const y = quad.y + @as(u32, @intCast(i >> 1));
                    if (x < 8 and y < 8) image.setColor(0, 0, x, y, 0xFFFF_0000);
                }
            }
        }
        const entries = [_]shader.Entry{
            shader.compute("main", &run),
            shader.compute("refused", &refused),
            shader.vertex("main", &Flat.vertex, 0),
            shader.fragment("main", &fragment, 0),
        };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.storage_images);
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .r8g8b8a8_unorm, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0);

    // An image made to be written through, and one that was not.
    const image, const view = try bench.image(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    _, const sampled_only = try bench.image(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_SAMPLED,
    }, false);

    const module_made = try module(&bench, &Paint.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE | facet.SHADER_STAGE_FRAGMENT },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(16, facet.BUFFER_USAGE_STORAGE_BUFFER);
    @memset(told_bytes[0..16], 0);

    const image_info = facet.DescriptorImageInfo{ .image_view = view };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);

    const compute_infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "refused" }, .layout = layout },
    };
    var computes: [2]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 2, &compute_infos, &computes));
    defer fb.DestroyPipeline(device, computes[0]);
    defer fb.DestroyPipeline(device, computes[1]);

    // A group for each texel of the 8 x 8.
    const four: u32 = 4;
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, computes[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 4, &four);
    fb.CmdDispatch(commands, 8, 8, 1);
    try bench.submit();

    // Read back through a buffer, as a transfer reads a texture.
    const back, const back_bytes = try bench.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 8, .height = 8 } };
    commands = try bench.record();
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&whole));
    try bench.submit();
    // r8g8b8a8 in the buffer, so the bytes are r, g, b, a in order: the
    // group's x, its y, the push constants, and opaque.
    try testing.expectEqual(0xFF04_0000, std.mem.readInt(u32, back_bytes[0..4], .little));
    try testing.expectEqual(0xFF04_0003, std.mem.readInt(u32, back_bytes[3 * 4 ..][0..4], .little));
    try testing.expectEqual(0xFF04_0507, std.mem.readInt(u32, back_bytes[(5 * 8 + 7) * 4 ..][0..4], .little));

    // The sampled-only image written into the same binding: the write does
    // not take, so the function finds nothing to write through.
    const sampled_info = facet.DescriptorImageInfo{ .image_view = sampled_only };
    const refused_write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&sampled_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&refused_write), 0, null);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, computes[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(0xA11_600D, std.mem.readInt(u32, told_bytes[0..4], .little));

    // A sampled image written as a sampled image is read, not written:
    // `written` says no, `sampled` says yes.
    const as_sampled = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&sampled_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&as_sampled), 0, null);
    const slot = _descriptor.slotAt(_objects.of(_descriptor.Set, sets[0].?), 0, 0).?;
    try testing.expect(!slot.slot.writable);

    // The image bound again, and a fragment function writing it while it
    // draws: the picture takes the fill and the image the other colour.
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&writes[0]), 0, null);
    const picture = try Picture.of(&bench, 8, 8);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 8, 8);
    defer fb.DestroyFramebuffer(device, frame);
    _, const drawing = makePipeline(&bench, .{ .module = module_made, .layout = layout, .pass = pass, .width = 8, .height = 8 });
    defer fb.DestroyPipeline(device, drawing);
    const vertices = [_][3]f32{ .{ -1, -1, 0.5 }, .{ 3, -1, 0.5 }, .{ -1, 3, 0.5 } };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const blue = clears(0xFF00_00FF);
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 8, .height = 8 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, drawing.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&whole));
    try bench.submit();
    try testing.expectEqual(@as(u32, 0xFF00_FF00), picture.at(1, 1));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), picture.at(7, 7));
    // 0xFFFF0000 as r8g8b8a8 in a buffer: red, nothing, nothing, opaque.
    try testing.expectEqual(0xFF00_00FF, std.mem.readInt(u32, back_bytes[0..4], .little));
    try testing.expectEqual(0xFF00_00FF, std.mem.readInt(u32, back_bytes[(7 * 8 + 7) * 4 ..][0..4], .little));
}

test "a storage image's level and layer named from inside the function, and one it has not got" {
    const Named = struct {
        /// Group (x, y) writes texel (x, y) of the level and the layer the
        /// push constants name, its colour saying which: the level in red
        /// and the layer in green.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const image = groups.resources.written(0, 0, 0) orelse return;
            const where = groups.resources.constants([2]u32).*;
            const color = 0xFF00_0000 | (10 + 40 * where[0]) << 16 | (10 + 40 * where[1]) << 8 | groups.group[0];
            image.setColor(where[1], where[0], groups.group[0], groups.group[1], color);
        }

        /// What the function finds of the shape, and of a texel it reads
        /// back: the levels and the layers, the first level's size, the
        /// texel the push constants name, and a texel of a level, a layer
        /// and a place the view has not got.
        fn told(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 1) orelse return;
            const image = groups.resources.written(0, 0, 0) orelse {
                out[0] = 0xFFFF_FFFF;
                return;
            };
            const where = groups.resources.constants([2]u32).*;
            out[0] = image.levels;
            out[1] = image.layer_count;
            out[2] = image.width(0);
            out[3] = image.height(0);
            out[4] = image.width(1);
            out[5] = image.colorAt(where[1], where[0], 0, 0);
            // Transparent black, each of them: a level past the last, a
            // layer past the last, and a place past the level's own size.
            out[6] = image.colorAt(0, image.levels, 0, 0);
            out[7] = image.colorAt(image.layer_count, 0, 0, 0);
            out[8] = image.colorAt(0, 0, image.width(0), 0);
            out[9] = image.colorAt(0, 0, 0, image.height(0));
            // And what `holds` says of the same.
            out[10] = @intFromBool(image.holds(image.layer_count - 1, image.levels - 1, 0, 0));
            out[11] = @intFromBool(image.holds(0, image.levels, 0, 0));
        }

        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("told", &told) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.storage_images);

    // Three layers and three levels, written through and never sampled:
    // since 1.55 an image of layers needs no SAMPLED beside STORAGE.
    const image = try bench.bareImage(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .mip_levels = 3,
        .array_layers = 3,
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    const view = try bench.viewOf(.{ .image = image, .format = .r8g8b8a8_unorm, .view_type = .@"2d_array" });

    const module_made = try module(&bench, &Named.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 8);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER);
    @memset(told_bytes[0..64], 0);
    const image_info = facet.DescriptorImageInfo{ .image_view = view };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);
    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "told" }, .layout = layout },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 2, &infos, &pipelines));
    defer for (pipelines) |one| fb.DestroyPipeline(device, one);

    // Level 0 of layer 0, level 1 of layer 2, and level 2 of layer 1:
    // each written over its own size, 8, 4 and 2 texels a side.
    const Where = struct { level: u32, layer: u32, side: u32 };
    const places = [_]Where{
        .{ .level = 0, .layer = 0, .side = 8 },
        .{ .level = 1, .layer = 2, .side = 4 },
        .{ .level = 2, .layer = 1, .side = 2 },
        .{ .level = 0, .layer = 1, .side = 8 },
        // A level the view has not got, and then a layer it has not got:
        // nothing is written either time, so what is there stays.
        .{ .level = 3, .layer = 0, .side = 1 },
        .{ .level = 0, .layer = 3, .side = 1 },
    };
    for (places) |place| {
        const named = [2]u32{ place.level, place.layer };
        const commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 8, &named);
        fb.CmdDispatch(commands, place.side, place.side, 1);
        try bench.submit();
    }

    // Read each level of each layer back through a buffer: the colour
    // says which level and which layer wrote it, and a level and a layer
    // nothing wrote is still black.
    const back, const back_bytes = try bench.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_DST);
    const colorOf = struct {
        fn colorOf(level: u32, layer: u32, x: u32) u32 {
            return 0xFF00_0000 | (10 + 40 * level) << 16 | (10 + 40 * layer) << 8 | x;
        }
    }.colorOf;
    // 0xAARRGGBB as r8g8b8a8 in a buffer: the bytes are r, g, b, a in
    // order, so the little-endian word reads 0xAABBGGRR.
    const swizzled = struct {
        fn swizzled(color: u32) u32 {
            return (color & 0xFF00_0000) | (color & 0xFF) << 16 | (color & 0xFF00) | (color >> 16 & 0xFF);
        }
    }.swizzled;
    for (places[0..4]) |place| {
        @memset(back_bytes[0 .. 8 * 8 * 4], 0);
        const region = facet.BufferImageCopy{
            .image_subresource = .{ .mip_level = place.level, .base_array_layer = place.layer },
            .image_extent = .{ .width = place.side, .height = place.side },
        };
        const commands = try bench.record();
        fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&region));
        try bench.submit();
        // r8g8b8a8 in the buffer: the bytes are r, g, b, a in order, so
        // the word reads 0xAABBGGRR.
        const first = std.mem.readInt(u32, back_bytes[0..4], .little);
        const last_at = ((place.side - 1) * place.side + place.side - 1) * 4;
        const last = std.mem.readInt(u32, back_bytes[last_at..][0..4], .little);
        try testing.expectEqual(swizzled(colorOf(place.level, place.layer, 0)), first);
        try testing.expectEqual(swizzled(colorOf(place.level, place.layer, place.side - 1)), last);
    }

    // What the function sees of the shape, and of a texel it reads back.
    const asked = [2]u32{ 1, 2 };
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 8, &asked);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    const out: [*]const u32 = @ptrCast(@alignCast(told_bytes));
    try testing.expectEqual(@as(u32, 3), out[0]);
    try testing.expectEqual(@as(u32, 3), out[1]);
    try testing.expectEqual(@as(u32, 8), out[2]);
    try testing.expectEqual(@as(u32, 8), out[3]);
    try testing.expectEqual(@as(u32, 4), out[4]);
    // Level 1 of layer 2, which the second dispatch wrote.
    try testing.expectEqual(colorOf(1, 2, 0), out[5]);
    // A level, a layer or a place the view has not got: transparent black.
    try testing.expectEqual(@as(u32, 0), out[6]);
    try testing.expectEqual(@as(u32, 0), out[7]);
    try testing.expectEqual(@as(u32, 0), out[8]);
    try testing.expectEqual(@as(u32, 0), out[9]);
    try testing.expectEqual(@as(u32, 1), out[10]);
    try testing.expectEqual(@as(u32, 0), out[11]);

    // A view of one level and one layer of the same image: its level 0 is
    // the image's level 1, so the function writing level 0 writes that.
    const narrow = try bench.viewOf(.{
        .image = image,
        .format = .r8g8b8a8_unorm,
        .subresource_range = .{ .base_mip_level = 1, .level_count = 1, .base_array_layer = 1, .layer_count = 1 },
    });
    const narrow_info = facet.DescriptorImageInfo{ .image_view = narrow };
    const to_narrow = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&narrow_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_narrow), 0, null);
    const at_first = [2]u32{ 0, 0 };
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 8, &at_first);
    fb.CmdDispatch(commands, 4, 4, 1);
    try bench.submit();
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    const second = facet.BufferImageCopy{
        .image_subresource = .{ .mip_level = 1, .base_array_layer = 1 },
        .image_extent = .{ .width = 4, .height = 4 },
    };
    commands = try bench.record();
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&second));
    try bench.submit();
    try testing.expectEqual(swizzled(colorOf(0, 0, 0)), std.mem.readInt(u32, back_bytes[0..4], .little));
    // And the function sees one level and one layer of it.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 8, &at_first);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 1), out[1]);
    try testing.expectEqual(@as(u32, 4), out[2]);
}

test "a colour attachment written through as a storage image: its rows, before the pass draws into them and after" {
    const Both = struct {
        /// Group (x, y) writes texel (x, y) of the image bound at set 0
        /// binding 0 - the attachment's own rows - with the colour the
        /// push constants carry.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const image = groups.resources.written(0, 0, 0) orelse return;
            image.setColor(0, 0, groups.group[0], groups.group[1], groups.resources.constants(u32).*);
        }

        /// What the function sees of it: whether it is there to write
        /// through at all, its size, and a texel read back.
        fn told(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 1) orelse return;
            const image = groups.resources.written(0, 0, 0) orelse {
                out[0] = 0xFFFF_FFFF;
                return;
            };
            out[0] = image.levels;
            out[1] = image.layer_count;
            out[2] = image.width(0);
            out[3] = image.height(0);
            out[4] = image.colorAt(0, 0, 0, 0);
            out[5] = image.colorAt(0, 0, 7, 7);
            // Past the rows: transparent black, as any storage image has it.
            out[6] = image.colorAt(0, 0, image.width(0), 0);
        }

        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("told", &told) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.storage_images);

    // The linear features say the rows of a format may be written
    // through: b8g8r8a8's are, r8g8b8a8's are not - no texture reads a
    // word with red in its low byte.
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .b8g8r8a8_unorm, &properties);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0);
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .r8g8b8a8_unorm, &properties);
    try testing.expect(properties.linear_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE == 0);

    // Drawn into and written through at once, which was refused before
    // 1.56. Sampled as well is still refused, a sample wanting the
    // blocked layout, and so is the format whose rows no texture reads.
    const usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_SRC;
    const image = try bench.bareImage(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = usage }, false);
    const view = try bench.viewOf(.{ .image = image, .format = .b8g8r8a8_unorm });
    var refused: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = usage | facet.IMAGE_USAGE_SAMPLED }, &refused));
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = usage }, &refused));
    try testing.expect(refused == null);

    const module_made = try module(&bench, &Both.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER);
    @memset(told_bytes[0..64], 0);
    const image_info = facet.DescriptorImageInfo{ .image_view = view };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);
    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "told" }, .layout = layout },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 2, &infos, &pipelines));
    defer for (pipelines) |one| fb.DestroyPipeline(device, one);

    // Written through first: the rows take the colour at once.
    const green: u32 = 0xFF00_FF00;
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 4, &green);
    fb.CmdDispatch(commands, 8, 8, 1);
    try bench.submit();
    const back, const back_bytes = try bench.buffer(8 * 8 * 4, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 8, .height = 8 } };
    commands = try bench.record();
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&whole));
    try bench.submit();
    // b8g8r8a8 in the buffer: the word reads 0xAARRGGBB as it is.
    try testing.expectEqual(green, std.mem.readInt(u32, back_bytes[0..4], .little));
    try testing.expectEqual(green, std.mem.readInt(u32, back_bytes[(7 * 8 + 7) * 4 ..][0..4], .little));

    // And the function reads its own rows back, and nothing past them.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    const out: [*]const u32 = @ptrCast(@alignCast(told_bytes));
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 1), out[1]);
    try testing.expectEqual(@as(u32, 8), out[2]);
    try testing.expectEqual(@as(u32, 8), out[3]);
    try testing.expectEqual(green, out[4]);
    try testing.expectEqual(green, out[5]);
    try testing.expectEqual(@as(u32, 0), out[6]);

    // Then drawn into: a pass over the same image, clearing it to blue.
    // What a subpass draws reaches the rows when it stores, so the clear
    // is what is there afterwards and the earlier write is gone.
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{view}, 8, 8);
    defer fb.DestroyFramebuffer(device, frame);
    const blue = clears(0xFF00_00FF);
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 8, .height = 8 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&whole));
    try bench.submit();
    try testing.expectEqual(@as(u32, 0xFF00_00FF), std.mem.readInt(u32, back_bytes[0..4], .little));

    // And written through again afterwards: the rows take the colour over
    // what the pass left, there being nothing of the pass left in the
    // tiles once it has ended.
    const red: u32 = 0xFFFF_0000;
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 4, &red);
    fb.CmdDispatch(commands, 8, 8, 1);
    fb.CmdCopyImageToBuffer(commands, image, .general, back, 1, @ptrCast(&whole));
    try bench.submit();
    try testing.expectEqual(red, std.mem.readInt(u32, back_bytes[0..4], .little));
}

test "storage images of floats and of channels of their own: a texel written and read back at the width it keeps" {
    const Floats = struct {
        /// Group (x, y) writes texel (x, y) of the image bound at set 0
        /// binding 0 from four floats the push constants carry, and then
        /// reads it back into the buffer at binding 1: what the format
        /// kept of them, which is the point of keeping floats.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const image = groups.resources.written(0, 0, 0) orelse return;
            const out = groups.resources.storage(f32, 0, 1) orelse return;
            const parts = groups.resources.constants([4]f32).*;
            const x = groups.group[0];
            const y = groups.group[1];
            image.setParts(0, 0, x, y, parts);
            if (x != 0 or y != 0) return;
            const read = image.partsAt(0, 0, 0, 0);
            for (read, 0..) |part, k| out[k] = part;
            // The colour the same texel reads as, and what the texel past
            // the level reads as: all zero, as any storage image has it.
            const color = image.colorAt(0, 0, 0, 0);
            out[4] = @bitCast(color);
            const none = image.partsAt(0, 0, image.width(0), 0);
            for (none, 0..) |part, k| out[5 + k] = part;
        }

        const entries = [_]shader.Entry{shader.compute("main", &run)};
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.storage_images);
    try testing.expect(features.kept_floats);
    // And since 1.69 a texture whose channels are its own, since 1.70
    // one of whole numbers.
    try testing.expect(features.wide_channels);
    try testing.expect(features.whole_textures);

    // Every float format says it may be written through since 1.57, and
    // one float a texel is a format of its own: R32_SFLOAT as an image.
    // The channels of 1.69 say the same.
    for ([9]facet.Format{ .r16g16b16a16_sfloat, .r32g32b32a32_sfloat, .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32, .r32_sfloat, .r8g8_unorm, .r16_unorm, .r16g16_unorm, .r16g16b16a16_unorm }) |format| {
        var properties: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(bench.physical, format, &properties);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
    }
    // The whole numbers of 1.70 say the same, but are never filtered
    // linearly and never drawn into: there is nothing to mix between two
    // whole numbers, and nothing blends one.
    for ([6]facet.Format{ .r8_uint, .r8g8b8a8_uint, .r8g8b8a8_sint, .r16g16b16a16_uint, .r32_sint, .r32g32b32a32_uint }) |format| {
        var properties: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(bench.physical, format, &properties);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT);
        try testing.expect(properties.buffer_features & facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER != 0);
    }

    const module_made = try module(&bench, &Floats.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 16);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER);
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const to_buffer = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_buffer), 0, null);
    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout };
    var pipeline: [1]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipeline));
    defer fb.DestroyPipeline(device, pipeline[0]);
    const out: [*]const f32 = @ptrCast(@alignCast(told_bytes));

    // Each format written with the same four floats and read back: what
    // it keeps of them. A whole number above 1 is what a colour could
    // never have carried, which is why these are kept as floats.
    const Kind = struct { format: facet.Format, want: [4]f32, mercy: f32, says: []const u8 };
    const kinds = [_]Kind{
        // Halves hold 1.5, 2.5 and 0.25 exactly.
        .{ .format = .r16g16b16a16_sfloat, .want = .{ 1.5, 2.5, 0.25, 0.5 }, .mercy = 0, .says = "four halves" },
        // Floats hold whatever was given.
        .{ .format = .r32g32b32a32_sfloat, .want = .{ 1.5, 2.5, 0.25, 0.5 }, .mercy = 0, .says = "four floats" },
        // 11, 11 and 10 bits, no sign and no alpha: the alpha reads as 1.
        .{ .format = .b10g11r11_ufloat_pack32, .want = .{ 1.5, 2.5, 0.25, 1 }, .mercy = 0.02, .says = "packed floats" },
        // Three mantissas over one exponent, and no alpha either.
        .{ .format = .e5b9g9r9_ufloat_pack32, .want = .{ 1.5, 2.5, 0.25, 1 }, .mercy = 0.02, .says = "a shared exponent" },
        // One float, read as (red, 0, 0, 1) the way one byte of red is.
        .{ .format = .r32_sfloat, .want = .{ 1.5, 0, 0, 1 }, .mercy = 0, .says = "one float a texel" },
        // 1.69: channels of the texture's own, each held to 0 to 1 - a
        // whole number above 1 is what these cannot carry and a float
        // format can. Two bytes of red and green read as
        // (red, green, 0, 1), and 16 bits a channel keep 0.25 and 0.5 to
        // a part in 65535.
        .{ .format = .r8g8_unorm, .want = .{ 1, 1, 0, 1 }, .mercy = 0, .says = "two bytes of red and green" },
        .{ .format = .r16_unorm, .want = .{ 1, 0, 0, 1 }, .mercy = 0, .says = "16 bits of red" },
        .{ .format = .r16g16_unorm, .want = .{ 1, 1, 0, 1 }, .mercy = 0, .says = "16 bits of red and green" },
        .{ .format = .r16g16b16a16_unorm, .want = .{ 1, 1, 0.25, 0.5 }, .mercy = 0.0001, .says = "16 bits a channel" },
    };
    const given = [4]f32{ 1.5, 2.5, 0.25, 0.5 };
    for (kinds) |kind| {
        const image = try bench.bareImage(.{
            .format = kind.format,
            .extent = .{ .width = 8, .height = 8 },
            .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
        }, false);
        const view = try bench.viewOf(.{ .image = image, .format = kind.format });
        const image_info = facet.DescriptorImageInfo{ .image_view = view };
        const to_image = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_image), 0, null);
        @memset(told_bytes[0..64], 0);
        const commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipeline[0].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 16, &given);
        fb.CmdDispatch(commands, 8, 8, 1);
        try bench.submit();
        for (kind.want, 0..) |want, k| {
            if (kind.mercy == 0) try testing.expectEqual(want, out[k]) else try testing.expectApproxEqAbs(want, out[k], kind.mercy);
        }
        // The colour the same texel reads as: each channel held inside 0
        // to 1 and rounded to 8 bits, which is all the tiles hold.
        const color: u32 = @bitCast(out[4]);
        try testing.expectEqual(@as(u32, 0xFF), color >> 16 & 0xFF);
        // And a place past the level: all zero.
        for (0..4) |k| try testing.expectEqual(@as(f32, 0), out[5 + k]);
    }

    // A compressed image asked for as a storage image is still unpacked
    // to 8888: nothing writes one texel of a block. It wants SAMPLED
    // beside it, being unpacked to be sampled.
    const blocks = try bench.bareImage(.{
        .format = .bc1_rgba_unorm_block,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
    }, false);
    var requirements: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, blocks, &requirements);
    // 8 x 8 of 8888, spread over 64 bits a texel, against the 32 bytes of
    // four BC1 blocks: it was unpacked.
    try testing.expect(requirements.size >= 8 * 8 * 8);
    var denied: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
        .format = .bc1_rgba_unorm_block,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_DST,
    }, &denied));
    try testing.expect(denied == null);

    // --- 1.69: what 16 bits a channel keeps that 8 could not ---
    // Three parts in 65535 is nothing at all in 8 bits, and a part in
    // 65535 over a half is the next value up from it: both come back.
    const fine = [4]f32{ 3.0 / 65535.0, 32769.0 / 65535.0, 1, 0 };
    const wide = try bench.bareImage(.{
        .format = .r16g16b16a16_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    const wide_view = try bench.viewOf(.{ .image = wide, .format = .r16g16b16a16_unorm });
    const wide_info = facet.DescriptorImageInfo{ .image_view = wide_view };
    const to_wide = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&wide_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_wide), 0, null);
    @memset(told_bytes[0..64], 0);
    const fine_commands = try bench.record();
    fb.CmdBindPipeline(fine_commands, .compute, pipeline[0].?);
    fb.CmdBindDescriptorSets(fine_commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(fine_commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 16, &fine);
    fb.CmdDispatch(fine_commands, 8, 8, 1);
    try bench.submit();
    try testing.expectApproxEqAbs(fine[0], out[0], 1.0 / 65535.0);
    try testing.expect(out[0] > 0);
    try testing.expectApproxEqAbs(fine[1], out[1], 1.0 / 65535.0);
    // A colour of 8 bits a channel would have rounded both to the same
    // byte as a half: these are a part in 65535 apart from it.
    try testing.expect(out[1] != 0.5);
    try testing.expect(out[1] != 128.0 / 255.0);
    // The colour the same texel reads as is still the top 8 bits: the
    // three parts in 65535 are 0 there, and the half is 128.
    const rounded: u32 = @bitCast(out[4]);
    try testing.expectEqual(@as(u32, 0), rounded >> 16 & 0xFF);
    try testing.expectEqual(@as(u32, 128), rounded >> 8 & 0xFF);

    // An image of such a format that no function reads or writes is
    // refused: these are kept for a function, as a small texel is.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
        .format = .r16g16b16a16_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, &denied));
    try testing.expect(denied == null);
    // And one of them is no colour attachment.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
        .format = .r16g16_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT,
    }, &denied));
    try testing.expect(denied == null);
}

test "storage images of whole numbers: a texel written and read back as the numbers it keeps" {
    const Wholes = struct {
        /// Group (x, y) writes texel (x, y) of the image bound at set 0
        /// binding 0 from four whole numbers the push constants carry as
        /// i32, and then reads texel (0, 0) back into the buffer at
        /// binding 1 with `wholesAt`: the numbers themselves, where a
        /// colour and a float carry neither 70000 nor 2^24 + 1 - which is
        /// the point of keeping whole numbers. (Since 1.70.)
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const image = groups.resources.written(0, 0, 0) orelse return;
            const out = groups.resources.storage(i64, 0, 1) orelse return;
            const given = groups.resources.constants([4]i32).*;
            var parts: [4]i64 = undefined;
            for (&parts, given) |*part, one| part.* = one;
            const x = groups.group[0];
            const y = groups.group[1];
            image.setWholes(0, 0, x, y, parts);
            if (x != 0 or y != 0) return;
            const read = image.wholesAt(0, 0, 0, 0);
            for (read, 0..) |one, k| out[k] = one;
            // The colour the same texel reads as, and the numbers a place
            // past the level reads as: all zero, as any storage image has
            // it.
            out[4] = image.colorAt(0, 0, 0, 0);
            const none = image.wholesAt(0, 0, image.width(0), 0);
            for (none, 0..) |one, k| out[5 + k] = one;
        }

        const entries = [_]shader.Entry{shader.compute("main", &run)};
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.storage_images);
    try testing.expect(features.whole_textures);

    const module_made = try module(&bench, &Wholes.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 16);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(128, facet.BUFFER_USAGE_STORAGE_BUFFER);
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const to_buffer = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_buffer), 0, null);
    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout };
    var whole_pipeline: [1]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &whole_pipeline));
    defer fb.DestroyPipeline(device, whole_pipeline[0]);
    const whole_out: [*]const i64 = @ptrCast(@alignCast(told_bytes));
    var denied: ?*facet.Image = null;

    // Every such format says it may be written through and sampled, and
    // never filtered linearly or drawn into: there is nothing to mix
    // between two whole numbers, and nothing blends one.
    for ([6]facet.Format{ .r8_uint, .r8g8b8a8_uint, .r8g8b8a8_sint, .r16g16b16a16_uint, .r32_sint, .r32g32b32a32_uint }) |format| {
        var properties: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(bench.physical, format, &properties);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT);
        try testing.expect(properties.buffer_features & facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER != 0);
    }

    // The same four numbers written into every format: 300 is above a
    // byte, -5 below what an unsigned channel holds, and 70000 above 16
    // bits. Nothing is scaled on the way: a whole number goes in as
    // itself and comes back as itself, held to the channel's ends.
    const Whole = struct { format: facet.Format, want: [4]i64, says: []const u8 };
    const wholes = [_]Whole{
        // One channel of 8 bits: 300 held to 255, and the three it has
        // not got read as 0, 0 and 1.
        .{ .format = .r8_uint, .want = .{ 255, 0, 0, 1 }, .says = "one byte, unsigned" },
        .{ .format = .r8g8b8a8_uint, .want = .{ 255, 0, 255, 1 }, .says = "four bytes, unsigned" },
        // Signed: 127 is as far as a byte goes, and -5 fits.
        .{ .format = .r8g8b8a8_sint, .want = .{ 127, -5, 127, 1 }, .says = "four bytes, signed" },
        .{ .format = .r16g16b16a16_uint, .want = .{ 300, 0, 65535, 1 }, .says = "16 bits a channel, unsigned" },
        .{ .format = .r16g16b16a16_sint, .want = .{ 300, -5, 32767, 1 }, .says = "16 bits a channel, signed" },
        .{ .format = .r32_uint, .want = .{ 300, 0, 0, 1 }, .says = "one number of 32 bits" },
        .{ .format = .r32g32_sint, .want = .{ 300, -5, 0, 1 }, .says = "two of 32 bits, signed" },
        // 32 bits hold all three as they are.
        .{ .format = .r32g32b32a32_uint, .want = .{ 300, 0, 70000, 1 }, .says = "four of 32 bits, unsigned" },
        .{ .format = .r32g32b32a32_sint, .want = .{ 300, -5, 70000, 1 }, .says = "four of 32 bits, signed" },
    };
    const whole_given = [4]i32{ 300, -5, 70000, 1 };
    for (wholes) |kind| {
        const image = try bench.bareImage(.{
            .format = kind.format,
            .extent = .{ .width = 8, .height = 8 },
            .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
        }, false);
        const view = try bench.viewOf(.{ .image = image, .format = kind.format });
        const image_info = facet.DescriptorImageInfo{ .image_view = view };
        const to_image = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_image), 0, null);
        @memset(told_bytes[0..128], 0);
        const commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, whole_pipeline[0].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 16, &whole_given);
        fb.CmdDispatch(commands, 8, 8, 1);
        try bench.submit();
        for (kind.want, 0..) |want, k| {
            testing.expectEqual(want, whole_out[k]) catch |failed| {
                std.debug.print("{s}: channel {d}\n", .{ kind.says, k });
                return failed;
            };
        }
        // The colour such a texel reads as: each number held to 0 to 1
        // and over 255, the way a texel buffer of the format reads one -
        // so a red of 300 is a red at the full and a green of 0 nothing.
        const color: u32 = @intCast(whole_out[4] & 0xFFFF_FFFF);
        try testing.expectEqual(@as(u32, 255), color >> 16 & 0xFF);
        try testing.expectEqual(@as(u32, 0), color >> 8 & 0xFF);
        // And a place past the level: all zero.
        for (0..4) |k| try testing.expectEqual(@as(i64, 0), whole_out[5 + k]);
    }

    // What 32 bits of whole number keep that a float cannot: 2^24 + 1 is
    // the first whole number a float rounds, and `wholesAt` reads it
    // back as it is where `partsAt` would give 2^24.
    const exact = try bench.bareImage(.{
        .format = .r32_sint,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    const exact_view = try bench.viewOf(.{ .image = exact, .format = .r32_sint });
    const exact_info = facet.DescriptorImageInfo{ .image_view = exact_view };
    const to_exact = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&exact_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_exact), 0, null);
    @memset(told_bytes[0..128], 0);
    const odd = [4]i32{ (1 << 24) + 1, -1, 0, 0 };
    const exact_commands = try bench.record();
    fb.CmdBindPipeline(exact_commands, .compute, whole_pipeline[0].?);
    fb.CmdBindDescriptorSets(exact_commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(exact_commands, layout, facet.SHADER_STAGE_COMPUTE, 0, 16, &odd);
    fb.CmdDispatch(exact_commands, 8, 8, 1);
    try bench.submit();
    try testing.expectEqual(@as(i64, (1 << 24) + 1), whole_out[0]);
    try testing.expect(@as(f32, @floatFromInt(whole_out[0])) == @as(f32, 1 << 24));

    // An image of whole numbers that no function reads or writes is
    // refused, as a wide one is, and one of them is no colour attachment
    // either: nothing blends a whole number.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
        .format = .r32g32b32a32_uint,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, &denied));
    try testing.expect(denied == null);
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{
        .format = .r8g8b8a8_uint,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT,
    }, &denied));
    try testing.expect(denied == null);
}

test "a buffer read as texels of a format: a uniform one read, a storage one written, and the formats refused" {
    const Texels = struct {
        /// Each group reads texel k of binding 0 and writes what it made
        /// of it into texel k of binding 1: the two formats need not
        /// match, which is the point of reading by format.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const from = groups.resources.texels(0, 0, 0) orelse return;
            var into = groups.resources.texels(0, 1, 0) orelse return;
            const k = groups.group[0];
            const parts = from.at(k);
            into.set(k, .{ parts[1], parts[0], parts[2] * 0.5, 1 });
        }
        /// What the function found, for the test to read: the counts, and
        /// whether the uniform one may be written.
        fn told(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 2) orelse return;
            const from = groups.resources.texels(0, 0, 0);
            const into = groups.resources.texels(0, 1, 0);
            out[0] = if (from) |one| one.count else 0xFFFF_FFFF;
            out[1] = if (from) |one| @intFromBool(one.writable) else 0xFFFF_FFFF;
            out[2] = if (into) |one| one.count else 0xFFFF_FFFF;
            out[3] = if (into) |one| @intFromBool(one.writable) else 0xFFFF_FFFF;
            // A colour read whatever the format: the first texel of each.
            out[4] = if (from) |one| one.colorAt(0) else 0;
            out[5] = if (into) |one| one.colorAt(0) else 0;
        }
        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("told", &told) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.texel_buffers);

    // Four texels of four floats read, four of 8888 written.
    const floats, const float_bytes = try bench.buffer(4 * 16, facet.BUFFER_USAGE_UNIFORM_TEXEL_BUFFER);
    const colors, const color_bytes = try bench.buffer(4 * 4, facet.BUFFER_USAGE_STORAGE_TEXEL_BUFFER);
    const given = [4][4]f32{
        .{ 1, 0, 0, 1 },
        .{ 0, 1, 0, 1 },
        .{ 0, 0, 1, 1 },
        .{ 1, 1, 1, 1 },
    };
    @memcpy(float_bytes[0..64], std.mem.asBytes(&given));
    @memset(color_bytes[0..16], 0);

    var reading: ?*facet.BufferView = null;
    try testing.expectEqual(facet.Result.success, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat }, &reading));
    defer fb.DestroyBufferView(device, reading);
    var writing: ?*facet.BufferView = null;
    try testing.expectEqual(facet.Result.success, fb.CreateBufferView(device, &.{ .buffer = colors, .format = .r8g8b8a8_unorm }, &writing));
    defer fb.DestroyBufferView(device, writing);

    // Refused: a format no view takes, a buffer not made for one, an
    // offset that is not a texel's, a range of nothing.
    var none: ?*facet.BufferView = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .d16_unorm }, &none));
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .bc1_rgb_unorm_block }, &none));
    const plain, _ = try bench.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER);
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateBufferView(device, &.{ .buffer = plain, .format = .r32_sfloat }, &none));
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat, .offset = 4 }, &none));
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat, .offset = 64 }, &none));
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat, .range = 8 }, &none));
    try testing.expect(none == null);
    fb.DestroyBufferView(device, null);

    // A view of the second texel on, which is what the shader then sees as
    // texel 0.
    var from_second: ?*facet.BufferView = null;
    try testing.expectEqual(facet.Result.success, fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32a32_sfloat, .offset = 16, .range = 32 }, &from_second));
    defer fb.DestroyBufferView(device, from_second);

    const module_made = try module(&bench, &Texels.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [3]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 3, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(32, facet.BUFFER_USAGE_STORAGE_BUFFER);
    @memset(told_bytes[0..32], 0);
    const told_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const writes = [3]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&reading) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&writing) },
        .{ .dst_set = sets[0].?, .dst_binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&told_info) },
    };
    fb.UpdateDescriptorSets(device, 3, &writes, 0, null);

    const infos = [2]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "told" }, .layout = layout },
    };
    var pipelines: [2]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 2, &infos, &pipelines));
    defer fb.DestroyPipeline(device, pipelines[0]);
    defer fb.DestroyPipeline(device, pipelines[1]);

    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 4, 1, 1);
    try bench.submit();

    // Read as floats, written as 8888 with red and green swapped and blue
    // halved: r, g, b, a in the buffer's bytes.
    try testing.expectEqual(0xFF00_FF00, std.mem.readInt(u32, color_bytes[0..4], .little));
    try testing.expectEqual(0xFF00_00FF, std.mem.readInt(u32, color_bytes[4..8], .little));
    try testing.expectEqual(0xFF80_0000, std.mem.readInt(u32, color_bytes[8..12], .little));
    try testing.expectEqual(0xFF80_FFFF, std.mem.readInt(u32, color_bytes[12..16], .little));

    // What the function sees of each: the counts, that only the storage one
    // may be written, and the first texel as a colour either way.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    const out: [*]const u32 = @ptrCast(@alignCast(told_bytes));
    try testing.expectEqual(@as(u32, 4), out[0]);
    try testing.expectEqual(@as(u32, 0), out[1]);
    try testing.expectEqual(@as(u32, 4), out[2]);
    try testing.expectEqual(@as(u32, 1), out[3]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), out[4]);
    try testing.expectEqual(@as(u32, 0xFF00_FF00), out[5]);

    // A uniform texel buffer is not written through: the same function
    // bound the other way round writes nothing into it.
    const swapped = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&writing) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&from_second) },
    };
    fb.UpdateDescriptorSets(device, 2, &swapped, 0, null);
    const before = std.mem.readInt(u32, color_bytes[0..4], .little);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 2, 1, 1);
    try bench.submit();
    try testing.expectEqual(before, std.mem.readInt(u32, color_bytes[0..4], .little));
    // The view of the second texel on: two texels, written from the colours.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 2), out[2]);
    // Its texel 0 is the buffer's second, 16 bytes in, and the dispatch
    // wrote the first colour there: green read as (0, 1, 0, 1) and written
    // with the first two the other way round, so (1, 0, 0, 1) as floats.
    const written: [*]const f32 = @ptrCast(@alignCast(float_bytes + 16));
    try testing.expectEqual(@as(f32, 1), written[0]);
    try testing.expectEqual(@as(f32, 0), written[1]);
    try testing.expectEqual(@as(f32, 0), written[2]);
    try testing.expectEqual(@as(f32, 1), written[3]);
}

test "texel buffers of whole numbers and of 16 bits a channel: every format of the grid, and the whole numbers exact" {
    const Grid = struct {
        /// Texel k of binding 0 copied into texel k of binding 1 by
        /// floats, whatever the two formats are.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const from = groups.resources.texels(0, 0, 0) orelse return;
            var into = groups.resources.texels(0, 1, 0) orelse return;
            const k = groups.group[0];
            into.set(k, from.at(k));
        }

        /// The same by whole numbers, which is what a 32-bit integer
        /// format wants: `at`'s float does not carry one past 2^24.
        fn wholes(groups: *const shader.Groups) callconv(.c) void {
            const from = groups.resources.texels(0, 0, 0) orelse return;
            var into = groups.resources.texels(0, 1, 0) orelse return;
            const k = groups.group[0];
            into.setInt(k, from.intAt(k));
        }

        /// What the function sees of binding 0: how many texels it has,
        /// its first texel as four floats, and as four whole numbers.
        fn told(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 2) orelse return;
            const from = groups.resources.texels(0, 0, 0) orelse {
                out[0] = 0xFFFF_FFFF;
                return;
            };
            out[0] = from.count;
            const parts = from.at(0);
            for (parts, 0..) |part, k| out[1 + k] = @bitCast(part);
            const numbers = from.intAt(0);
            for (numbers, 0..) |number, k| {
                const bits: u64 = @bitCast(number);
                out[5 + k * 2] = @truncate(bits);
                out[6 + k * 2] = @truncate(bits >> 32);
            }
        }

        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("wholes", &wholes), shader.compute("told", &told) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };

    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.texel_buffers);

    // Every format the grid of 1.54 added, with the bytes a texel takes:
    // one channel, two or four, of 8, 16 or 32 bits.
    const Grain = struct { format: facet.Format, size: u32 };
    const grid = [_]Grain{
        .{ .format = .r8_unorm, .size = 1 },
        .{ .format = .r8g8_unorm, .size = 2 },
        .{ .format = .r8_uint, .size = 1 },
        .{ .format = .r8g8_uint, .size = 2 },
        .{ .format = .r8g8b8a8_uint, .size = 4 },
        .{ .format = .r8_sint, .size = 1 },
        .{ .format = .r8g8_sint, .size = 2 },
        .{ .format = .r8g8b8a8_sint, .size = 4 },
        .{ .format = .r16_unorm, .size = 2 },
        .{ .format = .r16g16_unorm, .size = 4 },
        .{ .format = .r16g16b16a16_unorm, .size = 8 },
        .{ .format = .r16_uint, .size = 2 },
        .{ .format = .r16g16_uint, .size = 4 },
        .{ .format = .r16g16b16a16_uint, .size = 8 },
        .{ .format = .r16_sint, .size = 2 },
        .{ .format = .r16g16_sint, .size = 4 },
        .{ .format = .r16g16b16a16_sint, .size = 8 },
        .{ .format = .r16_sfloat, .size = 2 },
        .{ .format = .r16g16_sfloat, .size = 4 },
        .{ .format = .r16g16b16a16_sfloat, .size = 8 },
        .{ .format = .r32_uint, .size = 4 },
        .{ .format = .r32g32_uint, .size = 8 },
        .{ .format = .r32g32b32a32_uint, .size = 16 },
        .{ .format = .r32_sint, .size = 4 },
        .{ .format = .r32g32_sint, .size = 8 },
        .{ .format = .r32g32b32a32_sint, .size = 16 },
        // The rest of them, since 1.68.
        .{ .format = .r8_snorm, .size = 1 },
        .{ .format = .r8g8_snorm, .size = 2 },
        .{ .format = .r8g8b8a8_snorm, .size = 4 },
        .{ .format = .r16_snorm, .size = 2 },
        .{ .format = .r16g16_snorm, .size = 4 },
        .{ .format = .r16g16b16a16_snorm, .size = 8 },
        .{ .format = .r8_srgb, .size = 1 },
        .{ .format = .r8g8_srgb, .size = 2 },
        .{ .format = .r8g8b8a8_srgb, .size = 4 },
        .{ .format = .b8g8r8a8_srgb, .size = 4 },
        .{ .format = .a8b8g8r8_unorm_pack32, .size = 4 },
        .{ .format = .a8b8g8r8_srgb_pack32, .size = 4 },
        .{ .format = .a2r10g10b10_unorm_pack32, .size = 4 },
        .{ .format = .a2r10g10b10_uint_pack32, .size = 4 },
        .{ .format = .a2b10g10r10_unorm_pack32, .size = 4 },
        .{ .format = .a2b10g10r10_uint_pack32, .size = 4 },
        .{ .format = .b10g11r11_ufloat_pack32, .size = 4 },
        .{ .format = .e5b9g9r9_ufloat_pack32, .size = 4 },
        .{ .format = .r32g32b32_uint, .size = 12 },
        .{ .format = .r32g32b32_sint, .size = 12 },
    };

    // Every one of them says a texel buffer and nothing else - no image
    // is kept in them, and no vertex attribute is read in one. The two
    // that an image is kept in, r8_unorm and r16g16b16a16_sfloat, say
    // what they always said as well.
    const texel_features = facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER;
    for (grid) |grain| {
        var properties: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(bench.physical, grain.format, &properties);
        try testing.expectEqual(texel_features, properties.buffer_features & texel_features);
        try testing.expectEqual(@as(u32, 0), properties.buffer_features & facet.FORMAT_FEATURE_VERTEX_BUFFER);
    }

    const span = 64;
    const source, const source_bytes = try bench.buffer(span, facet.BUFFER_USAGE_UNIFORM_TEXEL_BUFFER);
    const target, const target_bytes = try bench.buffer(span, facet.BUFFER_USAGE_STORAGE_TEXEL_BUFFER);

    const module_made = try module(&bench, &Grid.code);
    defer fb.DestroyShaderModule(device, module_made);
    const bindings = [3]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 3, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const told, const told_bytes = try bench.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER);
    const told_info = facet.DescriptorBufferInfo{ .buffer = told, .range = facet.WHOLE_SIZE };
    const to_told = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&told_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_told), 0, null);

    const infos = [3]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "wholes" }, .layout = layout },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module_made, .name = "told" }, .layout = layout },
    };
    var pipelines: [3]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 3, &infos, &pipelines));
    defer for (pipelines) |one| fb.DestroyPipeline(device, one);
    const out: [*]const u32 = @ptrCast(@alignCast(told_bytes));

    // A view of each, and a dispatch that tells how many texels it found:
    // the buffer's bytes divided by the format's size, which is what the
    // library made of the format.
    for (grid) |grain| {
        var view: ?*facet.BufferView = null;
        try testing.expectEqual(facet.Result.success, fb.CreateBufferView(device, &.{ .buffer = source, .format = grain.format }, &view));
        defer fb.DestroyBufferView(device, view);
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&view) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        @memset(told_bytes[0..64], 0);
        const commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDispatch(commands, 1, 1, 1);
        try bench.submit();
        try testing.expectEqual(span / grain.size, out[0]);
        // An offset or a range that is not a whole texel is refused, and
        // so is a range of nothing.
        if (grain.size > 1) {
            var none: ?*facet.BufferView = null;
            try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateBufferView(device, &.{ .buffer = source, .format = grain.format, .offset = 1 }, &none));
            try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateBufferView(device, &.{ .buffer = source, .format = grain.format, .range = grain.size - 1 }, &none));
            try testing.expect(none == null);
        }
    }

    // A view of `format` over `buffer`, written into binding `at`.
    const bind = struct {
        fn bind(on: *Bench, buffer: *facet.Buffer, format: facet.Format, at: u32, kind: facet.DescriptorType, into: *[1]?*facet.DescriptorSet) !*facet.BufferView {
            var view: ?*facet.BufferView = null;
            try testing.expectEqual(facet.Result.success, on.rig.fb.CreateBufferView(on.device, &.{ .buffer = buffer, .format = format }, &view));
            const write = facet.WriteDescriptorSet{ .dst_set = into[0].?, .dst_binding = at, .descriptor_type = kind, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&view) };
            on.rig.fb.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            return view.?;
        }
    }.bind;

    // A whole number read as itself: r8_uint's 0 to 255, copied by floats
    // into r16_uint, where it is the same number in two bytes.
    source_bytes[0] = 7;
    source_bytes[1] = 200;
    @memset(target_bytes[0..span], 0);
    const from_u8 = try bind(&bench, source, .r8_uint, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_u8);
    const into_u16 = try bind(&bench, target, .r16_uint, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_u16);
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 2, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, target_bytes[0..2], .little));
    try testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, target_bytes[2..4], .little));
    // And what the function saw of the first: 7 as a float and as a whole
    // number, with the parts the format has not got 0 and alpha 1.
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(f32, 7), @as(f32, @bitCast(out[1])));
    try testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(out[2])));
    try testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(out[4])));
    try testing.expectEqual(@as(u32, 7), out[5]);
    try testing.expectEqual(@as(u32, 1), out[11]);

    // A signed one: -300 and 300 of r16g16_sint, read as themselves and
    // written into r32g32_sint.
    std.mem.writeInt(i16, source_bytes[0..2], -300, .little);
    std.mem.writeInt(i16, source_bytes[2..4], 300, .little);
    @memset(target_bytes[0..span], 0);
    const from_i16 = try bind(&bench, source, .r16g16_sint, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_i16);
    const into_i32 = try bind(&bench, target, .r32g32_sint, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_i32);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(i32, -300), std.mem.readInt(i32, target_bytes[0..4], .little));
    try testing.expectEqual(@as(i32, 300), std.mem.readInt(i32, target_bytes[4..8], .little));

    // 16 bits a channel as 0 to 1: a half of 65535 reads as about 0.5,
    // which 8 bits could not tell from the next step up.
    std.mem.writeInt(u16, source_bytes[0..2], 32768, .little);
    const from_u16 = try bind(&bench, source, .r16_unorm, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_u16);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, @bitCast(out[1])), 0.0001);
    // Its whole number is what it keeps, not 0 or 1.
    try testing.expectEqual(@as(u32, 32768), out[5]);

    // Half-floats: 1.5 and -0.25 of r16g16b16a16_sfloat, read as they are.
    const halves = [4]f16{ 1.5, -0.25, 3, 0.5 };
    for (halves, 0..) |half, k| std.mem.writeInt(u16, source_bytes[k * 2 ..][0..2], @bitCast(half), .little);
    const from_f16 = try bind(&bench, source, .r16g16b16a16_sfloat, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_f16);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(out[1])));
    try testing.expectEqual(@as(f32, -0.25), @as(f32, @bitCast(out[2])));
    try testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(out[4])));

    // A 32-bit whole number past 2^24, which the float of `at` cannot
    // carry: `intAt` reads it as it lies, and `setInt` writes it back.
    const big: u32 = 4_000_000_001;
    std.mem.writeInt(u32, source_bytes[0..4], big, .little);
    @memset(target_bytes[0..span], 0);
    const from_u32 = try bind(&bench, source, .r32_uint, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_u32);
    const into_u32 = try bind(&bench, target, .r32_uint, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_u32);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(big, std.mem.readInt(u32, target_bytes[0..4], .little));
    // The same copied by floats instead loses the low bits, the float
    // carrying 24 of them.
    @memset(target_bytes[0..span], 0);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expect(std.mem.readInt(u32, target_bytes[0..4], .little) != big);
    // A value past what the channel carries is held to the largest it
    // does, not wrapped: 4 thousand million into r16_uint is 65535.
    const into_small = try bind(&bench, target, .r16_uint, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_small);
    @memset(target_bytes[0..span], 0);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, target_bytes[0..2], .little));

    // --- 1.68: `_snorm`, `_srgb`, the packed words, three channels ---

    // `_snorm`: -128, -127, 0 and 127 of r8g8b8a8_snorm read as -1, -1, 0
    // and 1 - the value below the largest the channel holds standing for
    // -1 as well - and copied by floats into 16 bits they are -32767 and
    // 32767, the largest those channels hold.
    source_bytes[0] = 0x80;
    source_bytes[1] = 0x81;
    source_bytes[2] = 0;
    source_bytes[3] = 127;
    @memset(target_bytes[0..span], 0);
    const from_i8n = try bind(&bench, source, .r8g8b8a8_snorm, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_i8n);
    const into_i16n = try bind(&bench, target, .r16g16b16a16_snorm, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_i16n);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(f32, -1), @as(f32, @bitCast(out[1])));
    try testing.expectEqual(@as(f32, -1), @as(f32, @bitCast(out[2])));
    try testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(out[3])));
    try testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(out[4])));
    // Its whole numbers are what it keeps, signed.
    try testing.expectEqual(@as(i32, -128), @as(i32, @bitCast(out[5])));
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, target_bytes[0..2], .little));
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, target_bytes[4..6], .little));
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, target_bytes[6..8], .little));

    // `_srgb`: 188 of 255 is about half the light, not three quarters of
    // it, and the alpha is straight whatever the colour channels do.
    source_bytes[0] = 188;
    source_bytes[1] = 188;
    source_bytes[2] = 188;
    source_bytes[3] = 128;
    const from_srgb = try bind(&bench, source, .r8g8b8a8_srgb, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_srgb);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, @bitCast(out[1])), 0.005);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), @as(f32, @bitCast(out[4])), 0.0001);
    // Its whole numbers are the bytes it keeps, the transfer function not
    // among them.
    try testing.expectEqual(@as(u32, 188), out[5]);
    // And written back the other way: half the light is 188 again.
    @memset(target_bytes[0..span], 0);
    const into_srgb = try bind(&bench, target, .r8g8b8a8_srgb, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_srgb);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expect(target_bytes[0] == 188 or target_bytes[0] == 187);
    try testing.expectEqual(@as(u8, 128), target_bytes[3]);
    // The same bytes read as `_unorm` are 188 of 255, the light of them
    // being another question.
    const from_plain = try bind(&bench, source, .r8g8b8a8_unorm, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_plain);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectApproxEqAbs(@as(f32, 188.0 / 255.0), @as(f32, @bitCast(out[1])), 0.0001);

    // A word of three channels of 10 bits and an alpha of 2: red whole,
    // green half, blue nothing, alpha whole. a2b10g10r10 keeps red in the
    // low bits and a2r10g10b10 keeps blue there, so the one word reads
    // the two ways round.
    const packed_word: u32 = 3 << 30 | 0 << 20 | 512 << 10 | 1023;
    std.mem.writeInt(u32, source_bytes[0..4], packed_word, .little);
    for ([2]facet.Format{ .a2b10g10r10_unorm_pack32, .a2r10g10b10_unorm_pack32 }) |one| {
        const view = try bind(&bench, source, one, 0, .uniform_texel_buffer, &sets);
        defer fb.DestroyBufferView(device, view);
        commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDispatch(commands, 1, 1, 1);
        try bench.submit();
        const red: f32 = @bitCast(out[1]);
        const blue: f32 = @bitCast(out[3]);
        try testing.expectEqual(@as(u32, 1), out[0] * 0 + 1);
        if (one == .a2b10g10r10_unorm_pack32) {
            try testing.expectEqual(@as(f32, 1), red);
            try testing.expectEqual(@as(f32, 0), blue);
        } else {
            try testing.expectEqual(@as(f32, 0), red);
            try testing.expectEqual(@as(f32, 1), blue);
        }
        try testing.expectApproxEqAbs(@as(f32, 512.0 / 1023.0), @as(f32, @bitCast(out[2])), 0.0001);
        try testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(out[4])));
    }
    // The `_uint` pair gives the whole numbers themselves, the alpha's 3
    // among them.
    const from_packed_u = try bind(&bench, source, .a2b10g10r10_uint_pack32, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_packed_u);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(f32, 1023), @as(f32, @bitCast(out[1])));
    try testing.expectEqual(@as(f32, 512), @as(f32, @bitCast(out[2])));
    try testing.expectEqual(@as(f32, 3), @as(f32, @bitCast(out[4])));
    try testing.expectEqual(@as(u32, 1023), out[5]);
    // Written back through the unorm one: 1, half and nothing again, and
    // the word itself the one it came from.
    @memset(target_bytes[0..span], 0);
    const from_packed = try bind(&bench, source, .a2b10g10r10_unorm_pack32, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_packed);
    const into_packed = try bind(&bench, target, .a2b10g10r10_unorm_pack32, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_packed);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(packed_word, std.mem.readInt(u32, target_bytes[0..4], .little));

    // The floats of one word: 2, a half and a quarter written and read
    // back, each format to what it carries. Neither holds an alpha, which
    // reads as 1.
    for ([2]facet.Format{ .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 }) |one| {
        @memset(source_bytes[0..span], 0);
        const floats = [4]f32{ 2, 0.5, 0.25, 1 };
        const kept: shader.TexelFormat = if (one == .b10g11r11_ufloat_pack32) .rg11b10f else .rgb9e5;
        var writing = shader.Texels{ .bytes = source_bytes, .count = 4, .format = kept, .writable = true };
        writing.set(0, floats);
        const view = try bind(&bench, source, one, 0, .uniform_texel_buffer, &sets);
        defer fb.DestroyBufferView(device, view);
        commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDispatch(commands, 1, 1, 1);
        try bench.submit();
        try testing.expectApproxEqAbs(@as(f32, 2), @as(f32, @bitCast(out[1])), 0.02);
        try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, @bitCast(out[2])), 0.01);
        try testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, @bitCast(out[3])), 0.01);
        try testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(out[4])));
    }

    // Three channels of 32 bits, whole: a number past 2^24 in each, read
    // and written by whole numbers, with the alpha the format has not got
    // 1 and the fourth channel left alone.
    const high: u32 = 3_000_000_007;
    for (0..3) |k| std.mem.writeInt(u32, source_bytes[k * 4 ..][0..4], high, .little);
    @memset(target_bytes[0..span], 0);
    const from_three = try bind(&bench, source, .r32g32b32_uint, 0, .uniform_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, from_three);
    const into_three = try bind(&bench, target, .r32g32b32_uint, 1, .storage_texel_buffer, &sets);
    defer fb.DestroyBufferView(device, into_three);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    for (0..3) |k| try testing.expectEqual(high, std.mem.readInt(u32, target_bytes[k * 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, target_bytes[12..16], .little));
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
        /// What the patch carries as a whole: three floats the control
        /// function writes and the evaluation function reads back.
        var carried: [3]f32 = @splat(-1);
        /// The smallest coordinate above 0 the evaluation function was
        /// given: where the first cut of an edge fell.
        var smallest: f32 = 1;
        fn carryControl(patch: *const shader.Patch, levels: *shader.Levels) callconv(.c) void {
            last_points = patch.count;
            // Half a piece more than three: the fraction a spacing spends.
            levels.outer = .{ 3.5, 3.5, 3.5, 3.5 };
            levels.inner = .{ 3.5, 3.5 };
            // The colour of the whole patch, worked out the once: red.
            const own = patch.ownValues();
            if (own.len == 3) own[0..3].* = .{ 1, 0, 0 };
        }
        fn spent(evaluations: *const shader.Evaluations) callconv(.c) void {
            const own = evaluations.patch.ownValues();
            if (own.len == 3) carried = own[0..3].*;
            for (0..evaluations.count) |k| {
                const u = evaluations.coordinates[k][0];
                if (u > 0 and u < smallest) smallest = u;
            }
            quad(evaluations);
        }
        /// The patch's colour handed on as the four varyings the `color`
        /// form reads: the vertex function carries one float, so what is
        /// drawn is wider than the patch's own vertices are.
        fn painted(evaluations: *const shader.Evaluations) callconv(.c) void {
            spent(evaluations);
            const own = evaluations.patch.ownValues();
            const full = shader.channel(1);
            for (0..evaluations.count) |k| {
                const out = evaluations.output(@intCast(k));
                out[4..8].* = if (own.len == 3) .{ own[0] * full, own[1] * full, own[2] * full, full } else @splat(0);
            }
        }
        const entries = [_]shader.Entry{
            shader.vertex("main", &vertex, 1),
            shader.fragment("main", &fragment, 0),
            shader.control("main", &control, 0),
            shader.control("triangle", &triangleControl, 0),
            shader.control("carry", &carryControl, 3),
            shader.control("hoard", &carryControl, 17),
            shader.evaluation("triangles", &triangle, 0, .{ .domain = .triangles }),
            shader.evaluation("clockwise", &triangle, 0, .{ .domain = .triangles, .clockwise = true }),
            shader.evaluation("quads", &quad, 0, .{ .domain = .quads }),
            shader.evaluation("isolines", &quad, 0, .{ .domain = .isolines }),
            shader.evaluation("varied", &quad, 2, .{ .domain = .quads }),
            shader.evaluation("equally", &spent, 0, .{ .domain = .quads }),
            shader.evaluation("evenly", &spent, 0, .{ .domain = .quads, .spacing = .fractional_even }),
            shader.evaluation("oddly", &spent, 0, .{ .domain = .quads, .spacing = .fractional_odd }),
            shader.fixedFragment("painted", .{ .kind = .color }),
            shader.evaluation("painted", &painted, 4, .{ .domain = .quads }),
            .{ .name = "nohow", .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION, .function = &spent, .varyings = 1 << 8 | 3 << 11 },
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
        fn of(on: *Bench, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, into: *facet.RenderPass, fragment: [*:0]const u8, control: [*:0]const u8, evaluation: [*:0]const u8, points: u32, topology: facet.PrimitiveTopology, raster: facet.PipelineRasterizationStateCreateInfo) struct { facet.Result, ?*facet.Pipeline } {
            const stages = [4]facet.PipelineShaderStageCreateInfo{
                .{ .stage = facet.SHADER_STAGE_VERTEX, .module = shaders },
                .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = shaders, .name = fragment },
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
    var result, const quads = Made.of(&bench, bent, layout, pass, "main", "main", "quads", 4, .patch_list, .{});
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
    result, const triangles = Made.of(&bench, bent, layout, pass, "main", "triangle", "triangles", 3, .patch_list, .{});
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, triangles);
    try draw(&bench, pass, frame, triangles.?, vertex_buffer, &offset, 4);
    try testing.expectEqual(red, picture.at(40, 16));
    try testing.expectEqual(clear, picture.at(16, 40));

    // Culled by the way round it is said to go.
    result, const culled = Made.of(&bench, bent, layout, pass, "main", "main", "triangles", 3, .patch_list, .{ .cull_mode = facet.CULL_MODE_FRONT, .front_face = .clockwise });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, culled);
    try draw(&bench, pass, frame, culled.?, vertex_buffer, &offset, 3);
    const one_way = picture.at(40, 16);
    result, const other_way = Made.of(&bench, bent, layout, pass, "main", "main", "clockwise", 3, .patch_list, .{ .cull_mode = facet.CULL_MODE_FRONT, .front_face = .clockwise });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, other_way);
    try draw(&bench, pass, frame, other_way.?, vertex_buffer, &offset, 3);
    try testing.expect(one_way != picture.at(40, 16));

    // Isolines: lines of constant v, the rest not touched.
    result, const lines = Made.of(&bench, bent, layout, pass, "main", "main", "isolines", 4, .patch_list, .{ .line_width = 1 });
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
    result, _ = Made.of(&bench, bent, layout, pass, "main", "main", "quads", 0, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "main", "quads", 33, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "main", "quads", 4, .triangle_list, .{});
    try testing.expectEqual(facet.Result.error_initialization_failed, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "main", "varied", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    const plain, _ = makePipeline(&bench, .{ .module = bent, .layout = layout, .pass = pass, .topology = .patch_list });
    try testing.expect(plain != .success);

    // The floats the patch carries from its control function, and where
    // the fraction of a level goes (since 1.50). A level of 3.5 along
    // every edge: four pieces of one length, or four with the half piece
    // split between the two ends, or five the same way.
    const Spent = struct {
        fn of(on: *Bench, shaders: *facet.ShaderModule, by: *facet.PipelineLayout, into: *facet.RenderPass, onto: *facet.Framebuffer, buffer: *facet.Buffer, where: *const u64, evaluation: [*:0]const u8) !f32 {
            const got, const pipeline = Made.of(on, shaders, by, into, "main", "carry", evaluation, 4, .patch_list, .{});
            try testing.expectEqual(facet.Result.success, got);
            defer on.rig.fb.DestroyPipeline(on.device, pipeline);
            Bent.smallest = 1;
            Bent.carried = @splat(-1);
            try draw(on, into, onto, pipeline.?, buffer, where, 4);
            // The colour, written by the one function and read by the other.
            try testing.expectEqual([3]f32{ 1, 0, 0 }, Bent.carried);
            return Bent.smallest;
        }
    }.of;
    // Rounded up to 4 pieces, all of one length: the first cut at 1/4.
    try testing.expectApproxEqAbs(@as(f32, 0.25), try Spent(&bench, bent, layout, pass, frame, vertex_buffer, &offset, "equally"), 0.001);
    // 4 pieces again, two of them short: (3.5 - 2) / (2 * 3.5) of the edge.
    try testing.expectApproxEqAbs(@as(f32, 1.5 / 7.0), try Spent(&bench, bent, layout, pass, frame, vertex_buffer, &offset, "evenly"), 0.001);
    // 5 pieces, the two short ones (3.5 - 3) / (2 * 3.5) of the edge.
    try testing.expectApproxEqAbs(@as(f32, 0.5 / 7.0), try Spent(&bench, bent, layout, pass, frame, vertex_buffer, &offset, "oddly"), 0.001);

    // What is drawn carries the evaluation function's varyings, not the
    // vertex function's one: the patch's colour, read by a fixed form.
    const colored = Made.of(&bench, bent, layout, pass, "painted", "carry", "painted", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.success, colored[0]);
    defer fb.DestroyPipeline(device, colored[1]);
    try draw(&bench, pass, frame, colored[1].?, vertex_buffer, &offset, 4);
    try testing.expectEqual(red, picture.at(32, 32));
    try testing.expectEqual(red, picture.at(1, 62));

    // Refused: more floats for the patch than the device holds, and a
    // spacing of a value this library has not.
    result, _ = Made.of(&bench, bent, layout, pass, "main", "hoard", "quads", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_feature_not_present, result);
    result, _ = Made.of(&bench, bent, layout, pass, "main", "carry", "nohow", 4, .patch_list, .{});
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
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

/// A render pass whose depth attachment is kept: read as each tile starts
/// where `load` says, written back where `store` says.
fn keepingPass(bench: *Bench, color_load: facet.AttachmentLoadOp, load: facet.AttachmentLoadOp, store: facet.AttachmentStoreOp) !*facet.RenderPass {
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = color_load, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .d16_unorm, .load_op = load, .store_op = store, .final_layout = .depth_stencil_attachment_optimal },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    var made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateRenderPass(bench.device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &made));
    return made.?;
}

test "a depth attachment that outlives its pass: stored as the tiles are drawn, read back, loaded again, and cleared without a pass" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    // Memory of its own, not the lazily allocated type: it is written.
    const depth_image, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST,
    }, false);
    const storing = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, storing);
    const loading = try keepingPass(&bench, .load, .load, .store);
    defer fb.DestroyRenderPass(device, loading);
    const frame = try framebuffer(&bench, storing, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const again = try framebuffer(&bench, loading, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, again);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    _, const list = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = storing, .depth = tested });
    defer fb.DestroyPipeline(device, list);
    _, const after = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = loading, .depth = tested });
    defer fb.DestroyPipeline(device, after);

    // The top left half at 0.25, the bottom right at 0.75.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.25 }, .{ 1, -1, 0.25 }, .{ -1, 1, 0.25 },
        .{ 1, 1, 0.75 },   .{ -1, 1, 0.75 }, .{ 1, -1, 0.75 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const read_back, const back_bytes = try bench.buffer(64 * 64 * 2, facet.BUFFER_USAGE_TRANSFER_DST | facet.BUFFER_USAGE_TRANSFER_SRC);
    @memset(back_bytes[0 .. 64 * 64 * 2], 0xAA);
    const offset: u64 = 0;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const blue = clears(0xFF00_00FF);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 64, .height = 64 }, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } };

    // Both triangles drawn, the depth stored, and read into the buffer.
    var commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, depth_image, .general, read_back, 1, @ptrCast(&whole));
    try bench.submit();

    // 0.25 and 0.75 of 65535, where each triangle covered a pixel, and the
    // clear's 1 where neither did. The halves meet on the diagonal, so a
    // pixel is read well inside each.
    const near: u16 = @intFromFloat(@round(0.25 * 65535));
    const far: u16 = @intFromFloat(@round(0.75 * 65535));
    try testing.expectEqual(near, depthAt(back_bytes, 4, 4));
    try testing.expectEqual(far, depthAt(back_bytes, 60, 60));
    // The halves meet on the diagonal from (64, 0) to (0, 64): the near one
    // is where x + y is under 64.
    try testing.expectEqual(near, depthAt(back_bytes, 2, 60));
    try testing.expectEqual(near, depthAt(back_bytes, 60, 2));
    try testing.expectEqual(far, depthAt(back_bytes, 40, 40));

    // The same pass again with the depth loaded: the nearer triangle is
    // drawn over the whole picture, and only the half whose stored depth is
    // further than 0.5 takes it.
    const across = [_][3]f32{ .{ -1, -1, 0.5 }, .{ 3, -1, 0.5 }, .{ -1, 3, 0.5 } };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(across))], std.mem.asBytes(&across));
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = loading, .framebuffer = again, .render_area = .{ .extent = .{ .width = 64, .height = 64 } } }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, after.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, depth_image, .general, read_back, 1, @ptrCast(&whole));
    try bench.submit();

    // Where the stored depth was 0.75 the new triangle is nearer and wins;
    // where it was 0.25 it does not. The depth stored again says the same.
    try testing.expectEqual(green, picture.at(4, 4));
    try testing.expectEqual(red, picture.at(60, 60));
    const half: u16 = @intFromFloat(@round(0.5 * 65535));
    try testing.expectEqual(near, depthAt(back_bytes, 4, 4));
    try testing.expectEqual(half, depthAt(back_bytes, 60, 60));

    // Cleared without a pass over it, which wants no framebuffer.
    const value = facet.ClearDepthStencilValue{ .depth = 1 };
    const range = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
    commands = try bench.record();
    fb.CmdClearDepthStencilImage(commands, depth_image, 0, &value, 1, @ptrCast(&range));
    fb.CmdCopyImageToBuffer(commands, depth_image, .general, read_back, 1, @ptrCast(&whole));
    try bench.submit();
    try testing.expectEqual(0xFFFF, depthAt(back_bytes, 4, 4));
    try testing.expectEqual(0xFFFF, depthAt(back_bytes, 60, 60));

    // Bytes written into it the other way, and read back as they were.
    const written = [4]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0 };
    @memcpy(back_bytes[0..8], std.mem.asBytes(&written));
    const corner = facet.BufferImageCopy{ .image_extent = .{ .width = 2, .height = 2 }, .buffer_row_length = 2, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } };
    commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, read_back, depth_image, .general, 1, @ptrCast(&corner));
    try bench.submit();
    @memset(back_bytes[0 .. 64 * 64 * 2], 0);
    commands = try bench.record();
    fb.CmdCopyImageToBuffer(commands, depth_image, .general, read_back, 1, @ptrCast(&whole));
    try bench.submit();
    try testing.expectEqual(0x1234, depthAt(back_bytes, 0, 0));
    try testing.expectEqual(0x5678, depthAt(back_bytes, 1, 0));
    try testing.expectEqual(0x9ABC, depthAt(back_bytes, 0, 1));
    try testing.expectEqual(0xDEF0, depthAt(back_bytes, 1, 1));
}

/// A depth read back into a buffer, 64 pixels a row, 16 bits each.
fn depthAt(bytes: [*]const u8, x: u32, y: u32) u16 {
    return std.mem.readInt(u16, bytes[(y * 64 + x) * 2 ..][0..2], .little);
}

// --- 1.40: the depth clamp and the depth bounds test ------------------------

test "the depth bounds test: a pixel drawn only where the depth already there lies between them, as the pipeline or a command says" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    _, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT,
    }, true);
    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);

    // The left half at 0.25, written; then all of it, tested against the
    // bounds alone.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 },
        .{ -1, 1, 0.25 },  .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 },
        .{ -1, -1, 0.5 },  .{ 1, -1, 0.5 },  .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },   .{ 1, -1, 0.5 },  .{ 1, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const clear: u32 = 0xFF00_00FF;
    const values = clears(clear);
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };

    const writes = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    const marks_result, const marks = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass, .depth = writes });
    try testing.expectEqual(facet.Result.success, marks_result);
    defer fb.DestroyPipeline(device, marks);

    // Three pipelines: the nearer half, the further half, and the bounds
    // a command sets.
    const Case = struct { facet.PipelineDepthStencilStateCreateInfo, []const facet.DynamicState, ?[2]f32, u32, u32, []const u8 };
    const cases = [4]Case{
        .{ .{ .depth_bounds_test_enable = true, .min_depth_bounds = 0, .max_depth_bounds = 0.5 }, &.{}, null, green, clear, "the nearer bounds" },
        .{ .{ .depth_bounds_test_enable = true, .min_depth_bounds = 0.6, .max_depth_bounds = 1 }, &.{}, null, red, green, "the further bounds" },
        .{ .{ .depth_bounds_test_enable = true }, &.{.depth_bounds}, .{ 0, 0.5 }, green, clear, "what a command set" },
        // The bounds the wrong way round keep nothing, as in Vulkan.
        .{ .{ .depth_bounds_test_enable = true, .min_depth_bounds = 0.9, .max_depth_bounds = 0.1 }, &.{}, null, red, clear, "bounds the wrong way round" },
    };
    for (cases) |one| {
        const depth_state, const dynamic, const set, const wanted_left, const wanted_right, const name = one;
        _ = name;
        const result, const bounded = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass, .depth = depth_state, .dynamic = dynamic });
        try testing.expectEqual(facet.Result.success, result);
        defer fb.DestroyPipeline(device, bounded);
        const commands = try bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &values }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        // The left half's depth, in red.
        fb.CmdBindPipeline(commands, .graphics, marks.?);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        // Then all of it, in green, where the bounds allow.
        fb.CmdBindPipeline(commands, .graphics, bounded.?);
        if (set) |asked| fb.CmdSetDepthBounds(commands, asked[0], asked[1]);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
        fb.CmdDraw(commands, 6, 1, 6, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();
        try testing.expectEqual(wanted_left, picture.at(16, 8));
        try testing.expectEqual(wanted_left, picture.at(16, 40));
        try testing.expectEqual(wanted_right, picture.at(48, 8));
        try testing.expectEqual(wanted_right, picture.at(48, 40));
    }

    // A device that has no such test refuses the pipeline.
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.depth_bounds = false;
    defer physical.features.depth_bounds = true;
    const refused, const none = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = pass, .depth = .{ .depth_bounds_test_enable = true } });
    try testing.expectEqual(facet.Result.error_feature_not_present, refused);
    try testing.expect(none == null);
}

test "the depth clamp: what lies past the near plane is drawn all the same, its depth held inside the viewport's range" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    // The depth kept, so what the clamp left can be read back.
    const depth_image, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, false);
    const kept = _objects.of(@import("../image/_image.zig").Image, depth_image);
    const pass = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);

    // Wholly behind the near plane, wholly past the far one, and across
    // the near plane from behind it to in front.
    const vertices = [_][3]f32{
        .{ -1, -1, -0.5 }, .{ 1, -1, -0.5 }, .{ -1, 1, -0.5 },
        .{ -1, 1, -0.5 },  .{ 1, -1, -0.5 }, .{ 1, 1, -0.5 },
        .{ -1, -1, 2 },    .{ 1, -1, 2 },    .{ -1, 1, 2 },
        .{ -1, 1, 2 },     .{ 1, -1, 2 },    .{ 1, 1, 2 },
        .{ -1, -1, -1 },   .{ 1, -1, 1 },    .{ -1, 1, -1 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const red: u32 = 0xFFFF_0000;
    const clear: u32 = 0xFF00_00FF;
    const writes = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .always };

    // The viewport's range, so what the clamp holds a depth to is its own
    // and not the whole of it.
    const low: f32 = 0.25;
    const high: f32 = 0.75;
    const shape = PipelineState{ .module = flat, .layout = layout, .pass = pass, .depth = writes, .min_depth = low, .max_depth = high };
    const plain_result, const plain = makePipeline(&bench, shape);
    try testing.expectEqual(facet.Result.success, plain_result);
    defer fb.DestroyPipeline(device, plain);
    var clamping = shape;
    clamping.raster = .{ .depth_clamp_enable = true };
    const clamped_result, const clamped = makePipeline(&bench, clamping);
    try testing.expectEqual(facet.Result.success, clamped_result);
    defer fb.DestroyPipeline(device, clamped);

    const run = struct {
        fn of(on: *Bench, into: *facet.RenderPass, onto: *facet.Framebuffer, by: *facet.PipelineLayout, pipeline: ?*facet.Pipeline, buffer: *facet.Buffer, first: u32, count: u32, color: u32) !void {
            const fb_of = on.rig.fb;
            const at: u64 = 0;
            const painted = clears(0xFF00_00FF);
            const commands = try on.record();
            fb_of.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &painted }, .@"inline");
            fb_of.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&at));
            fb_of.CmdBindPipeline(commands, .graphics, pipeline.?);
            fb_of.CmdPushConstants(commands, by, facet.SHADER_STAGE_FRAGMENT, 0, 4, &color);
            fb_of.CmdDraw(commands, count, 1, first, 0);
            fb_of.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.of;
    const depthAtOf = struct {
        fn of(image: anytype, x: u32, y: u32) u16 {
            return std.mem.readInt(u16, image.data.?[@as(usize, y) * image.pitch + @as(usize, x) * 2 ..][0..2], .little);
        }
    }.of;

    // Behind the near plane: cut away without the clamp, drawn with it,
    // its depth held at the viewport's nearest.
    try run(&bench, pass, frame, layout, plain, vertex_buffer, 0, 6, red);
    try testing.expectEqual(clear, picture.at(16, 8));
    try run(&bench, pass, frame, layout, clamped, vertex_buffer, 0, 6, red);
    try testing.expectEqual(red, picture.at(16, 8));
    try testing.expectEqual(red, picture.at(48, 40));
    const nearest: u16 = @intFromFloat(@round(low * 65535));
    const furthest: u16 = @intFromFloat(@round(high * 65535));
    try testing.expectEqual(nearest, depthAtOf(kept, 16, 8));

    // Past the far plane: the same, held at the viewport's furthest.
    try run(&bench, pass, frame, layout, plain, vertex_buffer, 6, 6, red);
    try testing.expectEqual(clear, picture.at(16, 8));
    try run(&bench, pass, frame, layout, clamped, vertex_buffer, 6, 6, red);
    try testing.expectEqual(red, picture.at(16, 8));
    try testing.expectEqual(furthest, depthAtOf(kept, 16, 8));

    // Across the near plane: the part in front is drawn either way, and
    // the part behind only with the clamp.
    try run(&bench, pass, frame, layout, plain, vertex_buffer, 12, 3, red);
    const front_plain = picture.at(56, 4);
    try run(&bench, pass, frame, layout, clamped, vertex_buffer, 12, 3, red);
    try testing.expectEqual(front_plain, picture.at(56, 4));
    try testing.expectEqual(red, picture.at(2, 2));
    try testing.expectEqual(nearest, depthAtOf(kept, 2, 2));

    // A device that does not clamp refuses the pipeline.
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.depth_clamp = false;
    defer physical.features.depth_clamp = true;
    const refused, const none = makePipeline(&bench, clamping);
    try testing.expectEqual(facet.Result.error_feature_not_present, refused);
    try testing.expect(none == null);
}

// --- 1.39: a depth image sampled where it lies ------------------------------

/// A shadow sample of a depth texture: the s, t and the reference are
/// varyings 0 to 2, and what it writes is how much of the sample passed.
const Shadowed = struct {
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1], uv[2] };
        }
    }

    fn fragment(fragments: *const shader.Fragments) callconv(.c) void {
        shader.texturedBy(
            true,
            .{ .format = .d16, .filter = .nearest, .address = .clamp },
            fragments,
            fragments.resources.sampled(0, 0, 0),
            fragments.resources.samplerOf(0, 0, 0),
        );
    }

    const entries = [_]shader.Entry{ shader.vertex("main", &vertex, 3), shader.fragment("main", &fragment, 3) };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a depth image sampled where it lies: the pass stores it, a shadow sample compares it at all 16 bits" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    // Drawn into as a depth attachment, and sampled: one image, in rows,
    // and nothing copied.
    const depth_image, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED,
    }, false);
    const kept = _objects.of(@import("../image/_image.zig").Image, depth_image);
    try testing.expectEqual(texture_zig.Format.d16, kept.texels.format);
    try testing.expectEqual(kept.pitch, kept.texels.pitch);

    // What is refused: no memory behind it, and a storage image of it. A
    // format with a stencil in it is sampled since 1.58.
    var none: ?*facet.Image = null;
    for ([2]facet.ImageCreateInfo{
        .{ .format = .d16_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT },
        .{ .format = .d16_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE },
    }) |info| {
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &info, &none));
        try testing.expect(none == null);
    }
    // One sampled wants memory something is behind: the lazily allocated
    // type is not among the ones it may be bound into.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, depth_image, &needs);
    try testing.expectEqual(@as(u32, 0), needs.memory_type_bits & (@as(u32, 1) << 2));

    // The first pass draws a quad over the left half at 0.25 and stores
    // the depth; the clear leaves 1 over the rest.
    const storing = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, storing);
    const frame = try framebuffer(&bench, storing, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const flat_layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, flat_layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    const list_result, const list = makePipeline(&bench, .{ .module = flat, .layout = flat_layout, .pass = storing, .depth = tested });
    try testing.expectEqual(facet.Result.success, list_result);
    defer fb.DestroyPipeline(device, list);

    const left_half = [6][3]f32{
        .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 },
        .{ -1, 1, 0.25 },  .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(1024, facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(left_half))], std.mem.asBytes(&left_half));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const blue = clears(0xFF00_00FF);
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };

    const first_pass = try bench.record();
    fb.CmdBeginRenderPass(first_pass, &.{ .render_pass = storing, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(first_pass, .graphics, list.?);
    fb.CmdBindVertexBuffers(first_pass, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdPushConstants(first_pass, flat_layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDraw(first_pass, 6, 1, 0, 0);
    fb.CmdEndRenderPass(first_pass);
    try bench.submit();
    const near: u16 = @intFromFloat(@round(0.25 * 65535));
    try testing.expectEqual(near, std.mem.readInt(u16, kept.data.?[8 * kept.pitch + 16 * 2 ..][0..2], .little));

    // The second pass samples that image through a sampler that compares,
    // over a picture of its own.
    const into = try Picture.of(&bench, 64, 64);
    const shadow = try module(&bench, &Shadowed.code);
    defer fb.DestroyShaderModule(device, shadow);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var sampler: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .compare_enable = true,
        .compare_op = .less,
    }, &sampler));
    defer fb.DestroySampler(device, sampler);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const info = facet.DescriptorImageInfo{ .sampler = sampler, .image_view = depth_view };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
    const slot = _objects.of(_descriptor.Set, sets[0].?).view.slots[0];
    try testing.expect(slot.pointer != null and slot.sampler != null);

    const reading = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, reading);
    const onto = try framebuffer(&bench, reading, &.{into.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, onto);
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const shade_result, const shade = makePipeline(&bench, .{ .module = shadow, .layout = layout, .pass = reading, .stride = 24, .attributes = &attributes });
    try testing.expectEqual(facet.Result.success, shade_result);
    defer fb.DestroyPipeline(device, shade);

    const white: u32 = 0xFFFF_FFFF;
    const black: u32 = 0xFF00_0000;
    // A quad over the whole picture, s and t over the whole depth image,
    // and the reference each run compares with.
    const run = struct {
        fn with(on: *Bench, bytes: [*]u8, buffer: *facet.Buffer, pass: *facet.RenderPass, onto_frame: *facet.Framebuffer, pipeline: ?*facet.Pipeline, set: *facet.DescriptorSet, by: *facet.PipelineLayout, reference: f32) !void {
            const quad = [6][6]f32{
                .{ -1, -1, 0.5, 0, 0, reference },
                .{ 1, -1, 0.5, 1, 0, reference },
                .{ -1, 1, 0.5, 0, 1, reference },
                .{ -1, 1, 0.5, 0, 1, reference },
                .{ 1, -1, 0.5, 1, 0, reference },
                .{ 1, 1, 0.5, 1, 1, reference },
            };
            @memcpy(bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
            const fb_of = on.rig.fb;
            const at: u64 = 0;
            const values = clears(0xFF00_00FF);
            const commands = try on.record();
            fb_of.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &values }, .@"inline");
            fb_of.CmdBindPipeline(commands, .graphics, pipeline.?);
            fb_of.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&at));
            fb_of.CmdBindDescriptorSets(commands, .graphics, by, 0, 1, @ptrCast(&set), 0, null);
            fb_of.CmdDraw(commands, 6, 1, 0, 0);
            fb_of.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.with;

    // A reference halfway: nearer than the 1 the clear left, further than
    // the 0.25 the quad stored. So the half that was drawn into fails the
    // test and the rest passes it.
    try run(&bench, vertex_bytes, vertex_buffer, reading, onto, shade, sets[0].?, layout, 0.5);
    try testing.expectEqual(black, into.at(16, 8));
    try testing.expectEqual(black, into.at(16, 40));
    try testing.expectEqual(white, into.at(48, 8));
    try testing.expectEqual(white, into.at(48, 40));

    // All 16 bits are compared: two references four 65535ths apart, one
    // either side of the stored 0.25, come out differently. Read as 8 bits
    // both would be the same.
    const whole: f32 = 65535;
    try run(&bench, vertex_bytes, vertex_buffer, reading, onto, shade, sets[0].?, layout, (@as(f32, @floatFromInt(near)) - 4) / whole);
    try testing.expectEqual(white, into.at(16, 8));
    try run(&bench, vertex_bytes, vertex_buffer, reading, onto, shade, sets[0].?, layout, (@as(f32, @floatFromInt(near)) + 4) / whole);
    try testing.expectEqual(black, into.at(16, 8));
}

// --- 1.58: a sampled depth image's layers and its planes --------------------

/// A plain sample of whatever is bound, through the sampler bound beside
/// it: the s and the t are varyings 0 and 1, and the colour is what the
/// texture's own format reads as - a depth as a grey of its top 8 bits, a
/// stencil as red alone.
const Planed = struct {
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1] };
        }
    }

    const entries = [_]shader.Entry{ shader.vertex("main", &vertex, 2), shader.fixedFragment("main", .{ .kind = .texture_sampled }) };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a sampled depth image of layers: a pass draws into the layer its view names, and a view's aspect picks the plane a sample reads" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const image_zig = @import("../image/_image.zig");
    const side = facet.Extent3D{ .width = 64, .height = 64 };
    const wanted = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED;

    // Three layers since 1.58: a layer's rows after the one before,
    // `layer_bytes` apart and each on a cache line.
    const layered = try bench.bareImage(.{ .format = .d16_unorm, .extent = side, .array_layers = 3, .usage = wanted }, false);
    const kept = _objects.of(image_zig.Image, layered);
    try testing.expectEqual(@as(u32, 3), kept.layers);
    try testing.expectEqual(std.mem.alignForward(u64, @as(u64, kept.pitch) * 64, 64), kept.layer_bytes);
    try testing.expectEqual(kept.layer_bytes * 3, kept.bytes);

    // Slices it has not got, nor more levels than halving the longer side
    // gives: a slice of a 3D image is nothing a pass draws into, and
    // levels of its own it has had since 1.63.
    for ([2]facet.ImageCreateInfo{
        .{ .format = .d16_unorm, .image_type = .@"3d", .extent = .{ .width = 64, .height = 64, .depth = 2 }, .usage = wanted },
        .{ .format = .d16_unorm, .extent = side, .mip_levels = 8, .usage = wanted },
    }) |info| {
        var none: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &info, &none));
        try testing.expect(none == null);
    }

    // A view of one layer: the texture it samples is that layer's rows,
    // `layer_bytes` into the image's memory.
    var layer_views: [3]*facet.ImageView = undefined;
    for (&layer_views, 0..) |*view, k| {
        view.* = try bench.viewOf(.{
            .image = layered,
            .format = .d16_unorm,
            .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_array_layer = @intCast(k), .layer_count = 1 },
        });
        const texels = &_objects.of(image_zig.ImageView, view.*).texels;
        try testing.expectEqual(texture_zig.Format.d16, texels.format);
        try testing.expectEqual(@as(u32, 1), texels.layer_count);
        try testing.expectEqual(kept.data.? + k * @as(usize, @intCast(kept.layer_bytes)), texels.memory);
    }
    // All three at once, for a sample that names the layer itself.
    const array_view = try bench.viewOf(.{
        .image = layered,
        .format = .d16_unorm,
        .view_type = .@"2d_array",
        .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH },
    });
    const array_texels = &_objects.of(image_zig.ImageView, array_view).texels;
    try testing.expectEqual(@as(u32, 3), array_texels.layer_count);
    try testing.expectEqual(@as(u32, @intCast(kept.layer_bytes)), array_texels.layer_bytes);

    // A plane the format has not got, and both planes at once: neither is
    // a texture, so neither is a view.
    var no_view: ?*facet.ImageView = null;
    for ([2]u32{ facet.IMAGE_ASPECT_STENCIL, facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL }) |aspect| {
        try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImageView(device, &.{
            .image = layered,
            .format = .d16_unorm,
            .subresource_range = .{ .aspect_mask = aspect },
        }, &no_view));
        try testing.expect(no_view == null);
    }

    // A pass over each layer in turn, a quad of its own depth over the
    // whole of it: what it writes is the layer its view names and no
    // other.
    const picture = try Picture.of(&bench, 64, 64);
    const storing = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, storing);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const flat_layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, flat_layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .always };
    const flat_result, const list = makePipeline(&bench, .{ .module = flat, .layout = flat_layout, .pass = storing, .depth = tested });
    try testing.expectEqual(facet.Result.success, flat_result);
    defer fb.DestroyPipeline(device, list);

    const depths = [3]f32{ 0.25, 0.5, 0.75 };
    var stored: [3]u16 = undefined;
    for (&stored, depths) |*value, depth| value.* = @intFromFloat(@round(depth * 65535));
    const vertex_buffer, const vertex_bytes = try bench.buffer(1024, facet.BUFFER_USAGE_VERTEX_BUFFER);
    const layerDepth = struct {
        fn of(image: anytype, layer: u32, x: u32, y: u32) u16 {
            const place = layer * @as(usize, @intCast(image.layer_bytes)) + @as(usize, y) * image.pitch + @as(usize, x) * 2;
            return std.mem.readInt(u16, image.data.?[place..][0..2], .little);
        }
    }.of;
    for (layer_views, depths, 0..) |view, depth, k| {
        const quad = [6][3]f32{
            .{ -1, -1, depth }, .{ 1, -1, depth }, .{ -1, 1, depth },
            .{ -1, 1, depth },  .{ 1, -1, depth }, .{ 1, 1, depth },
        };
        @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
        const frame = try framebuffer(&bench, storing, &.{ picture.view, view }, 64, 64);
        defer fb.DestroyFramebuffer(device, frame);
        const red: u32 = 0xFFFF_0000;
        const blue = clears(0xFF00_00FF);
        const at: u64 = 0;
        const commands = try bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &blue }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, list.?);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&at));
        fb.CmdPushConstants(commands, flat_layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();
        try testing.expectEqual(stored[k], layerDepth(kept, @intCast(k), 16, 8));
        try testing.expectEqual(stored[k], layerDepth(kept, @intCast(k), 48, 40));
    }
    // Every layer still its own: none of the passes wrote another's.
    for (stored, 0..) |value, k| try testing.expectEqual(value, layerDepth(kept, @intCast(k), 32, 32));

    // Cleared a layer at a time as well: the range's own layers and no
    // others.
    const furthest = facet.ClearDepthStencilValue{ .depth = 1 };
    const one_layer = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_array_layer = 1, .layer_count = 1 };
    const clearing = try bench.record();
    fb.CmdClearDepthStencilImage(clearing, layered, 0, &furthest, 1, @ptrCast(&one_layer));
    try bench.submit();
    try testing.expectEqual(@as(u16, 0xFFFF), layerDepth(kept, 1, 32, 32));
    try testing.expectEqual(stored[0], layerDepth(kept, 0, 32, 32));
    try testing.expectEqual(stored[2], layerDepth(kept, 2, 32, 32));
    stored[1] = 0xFFFF;

    // What a sample of each view reads: a plain sample of a depth is a
    // grey of its top 8 bits, so every layer comes out as its own grey.
    const into = try Picture.of(&bench, 64, 64);
    const planed = try module(&bench, &Planed.code);
    defer fb.DestroyShaderModule(device, planed);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var sampler: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{ .mag_filter = .nearest, .min_filter = .nearest, .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge }, &sampler));
    defer fb.DestroySampler(device, sampler);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const reading = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, reading);
    const onto = try framebuffer(&bench, reading, &.{into.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, onto);
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const plane_result, const plane = makePipeline(&bench, .{ .module = planed, .layout = layout, .pass = reading, .stride = 24, .attributes = &attributes });
    try testing.expectEqual(facet.Result.success, plane_result);
    defer fb.DestroyPipeline(device, plane);

    const sample = struct {
        fn of(on: *Bench, bytes: [*]u8, buffer: *facet.Buffer, view: *facet.ImageView, with: ?*facet.Sampler, set: *facet.DescriptorSet, pass: *facet.RenderPass, frame: *facet.Framebuffer, pipeline: ?*facet.Pipeline, by: *facet.PipelineLayout) !void {
            const fb_of = on.rig.fb;
            const info = facet.DescriptorImageInfo{ .sampler = with, .image_view = view };
            const write = facet.WriteDescriptorSet{ .dst_set = set, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
            fb_of.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const quad = [6][6]f32{
                .{ -1, -1, 0.5, 0, 0, 0 },
                .{ 1, -1, 0.5, 1, 0, 0 },
                .{ -1, 1, 0.5, 0, 1, 0 },
                .{ -1, 1, 0.5, 0, 1, 0 },
                .{ 1, -1, 0.5, 1, 0, 0 },
                .{ 1, 1, 0.5, 1, 1, 0 },
            };
            @memcpy(bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
            const at: u64 = 0;
            const values = clears(0xFF00_00FF);
            const commands = try on.record();
            fb_of.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &values }, .@"inline");
            fb_of.CmdBindPipeline(commands, .graphics, pipeline.?);
            fb_of.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&at));
            fb_of.CmdBindDescriptorSets(commands, .graphics, by, 0, 1, @ptrCast(&set), 0, null);
            fb_of.CmdDraw(commands, 6, 1, 0, 0);
            fb_of.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.of;

    for (layer_views, stored) |view, value| {
        try sample(&bench, vertex_bytes, vertex_buffer, view, sampler, sets[0].?, reading, onto, plane, layout);
        const grey: u32 = 0xFF00_0000 | @as(u32, value >> 8) * 0x01_01_01;
        try testing.expectEqual(grey, into.at(16, 8));
        try testing.expectEqual(grey, into.at(48, 40));
    }

    // A format that holds both planes: the depth where the pixel starts
    // and the stencil two bytes in, each read `bytesOf` bytes apart - so
    // the one rows are two textures, which a view's aspect picks between.
    const both = try bench.bareImage(.{ .format = .d16_unorm_s8_uint, .extent = side, .usage = wanted | facet.IMAGE_USAGE_TRANSFER_DST }, false);
    const both_kept = _objects.of(image_zig.Image, both);
    const depth_plane = try bench.viewOf(.{ .image = both, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } });
    const stencil_plane = try bench.viewOf(.{ .image = both, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL } });
    const depth_texels = &_objects.of(image_zig.ImageView, depth_plane).texels;
    const stencil_texels = &_objects.of(image_zig.ImageView, stencil_plane).texels;
    try testing.expectEqual(texture_zig.Format.d16, depth_texels.format);
    try testing.expectEqual(texture_zig.Format.r8, stencil_texels.format);
    try testing.expectEqual(@as(u32, 4), depth_texels.stride);
    try testing.expectEqual(@as(u32, 4), stencil_texels.stride);
    try testing.expectEqual(both_kept.data.?, depth_texels.memory);
    try testing.expectEqual(both_kept.data.? + 2, stencil_texels.memory);
    // Both planes at once is no texture.
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImageView(device, &.{
        .image = both,
        .format = .d16_unorm_s8_uint,
        .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL },
    }, &no_view));
    try testing.expect(no_view == null);

    // Both cleared, and each plane sampled on its own: the depth a grey
    // of its top 8 bits, the stencil red alone, as a texel of one byte is
    // read.
    const filled = facet.ClearDepthStencilValue{ .depth = 0.25, .stencil = 0x60 };
    const both_aspects = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL };
    const filling = try bench.record();
    fb.CmdClearDepthStencilImage(filling, both, 0, &filled, 1, @ptrCast(&both_aspects));
    try bench.submit();
    try sample(&bench, vertex_bytes, vertex_buffer, depth_plane, sampler, sets[0].?, reading, onto, plane, layout);
    try testing.expectEqual(@as(u32, 0xFF40_4040), into.at(16, 8));
    try sample(&bench, vertex_bytes, vertex_buffer, stencil_plane, sampler, sets[0].?, reading, onto, plane, layout);
    try testing.expectEqual(@as(u32, 0xFF60_0000), into.at(16, 8));

    // A format of a stencil alone: its one plane, which a view asking for
    // neither takes - the default, and what every view of such an image
    // asked for before 1.58.
    const stencil_only = try bench.bareImage(.{ .format = .s8_uint, .extent = side, .usage = wanted | facet.IMAGE_USAGE_TRANSFER_DST }, false);
    const alone = try bench.viewOf(.{ .image = stencil_only, .format = .s8_uint, .subresource_range = .{} });
    const alone_texels = &_objects.of(image_zig.ImageView, alone).texels;
    try testing.expectEqual(texture_zig.Format.r8, alone_texels.format);
    try testing.expectEqual(@as(u32, 1), alone_texels.stride);
    try testing.expectEqual(_objects.of(image_zig.Image, stencil_only).data.?, alone_texels.memory);
    const greyed = facet.ClearDepthStencilValue{ .depth = 0, .stencil = 0x30 };
    const graying = try bench.record();
    fb.CmdClearDepthStencilImage(graying, stencil_only, 0, &greyed, 1, @ptrCast(&both_aspects));
    try bench.submit();
    try sample(&bench, vertex_bytes, vertex_buffer, alone, sampler, sets[0].?, reading, onto, plane, layout);
    try testing.expectEqual(@as(u32, 0xFF30_0000), into.at(16, 8));
}

/// A render pass whose stencil attachment is kept: a colour attachment of
/// 8888 and a depth one of `format`, with all four of its ops given.
fn stencilPass(bench: *Bench, format: facet.Format, color_load: facet.AttachmentLoadOp, ops: [4]u8) !*facet.RenderPass {
    const load: [2]facet.AttachmentLoadOp = .{ if (ops[0] == 'l') .load else .clear, if (ops[2] == 'l') .load else .clear };
    const store: [2]facet.AttachmentStoreOp = .{ if (ops[1] == 's') .store else .dont_care, if (ops[3] == 's') .store else .dont_care };
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = color_load, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{
            .format = format,
            .load_op = load[0],
            .store_op = store[0],
            .stencil_load_op = load[1],
            .stencil_store_op = store[1],
            .final_layout = .depth_stencil_attachment_optimal,
        },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    var made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, bench.rig.fb.CreateRenderPass(bench.device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &made));
    return made.?;
}

test "a stencil attachment that outlives its pass: stored as the tiles are drawn, loaded by the next pass, read back and cleared" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    // All of the picture, then its left half.
    const vertices = [_][3]f32{
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
        .{ -1, -1, 0.5 }, .{ 0, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 0, -1, 0.5 }, .{ 0, 1, 0.5 },
    };
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const red: u32 = 0xFFFF_0000;
    const green: u32 = 0xFF00_FF00;
    const clear: u32 = 0xFF00_00FF;
    const values = clears(clear);
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };
    const marked: u8 = 5;

    // Both formats that hold a stencil: one of stencil alone, a byte a
    // pixel, and one that holds a depth beside it, four.
    for ([2]facet.Format{ .s8_uint, .d16_unorm_s8_uint }) |format| {
        const picture = try Picture.of(&bench, 64, 64);
        const stencil_image, const stencil_view = try bench.image(.{
            .format = format,
            .extent = .{ .width = 64, .height = 64 },
            .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST,
        }, false);
        const kept = _objects.of(@import("../image/_image.zig").Image, stencil_image);
        const stride: usize = if (format == .s8_uint) 1 else 4;
        const stencilAt = struct {
            fn of(image: anytype, step: usize, x: u32, y: u32) u8 {
                // The stencil of a pixel is its last byte but one where a
                // depth lies before it, and its only byte otherwise.
                const inside: usize = if (step == 1) 0 else 2;
                const at = @as(usize, y) * image.pitch + @as(usize, x) * step + inside;
                return image.data.?[at];
            }
        }.of;

        // The first pass marks the left half and stores the stencil.
        const storing = try stencilPass(&bench, format, .clear, "dcds".*);
        defer fb.DestroyRenderPass(device, storing);
        const frame = try framebuffer(&bench, storing, &.{ picture.view, stencil_view }, 64, 64);
        defer fb.DestroyFramebuffer(device, frame);
        const marks = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = marked };
        const mark_result, const mark = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = storing, .depth = .{ .stencil_test_enable = true, .front = marks, .back = marks } });
        try testing.expectEqual(facet.Result.success, mark_result);
        defer fb.DestroyPipeline(device, mark);

        var commands = try bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &values }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, mark.?);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
        fb.CmdDraw(commands, 6, 1, 6, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();

        // What the tiles wrote into the image: the reference where it was
        // drawn, the clear's 0 where it was not, in more than one tile.
        try testing.expectEqual(marked, stencilAt(kept, stride, 16, 8));
        try testing.expectEqual(marked, stencilAt(kept, stride, 16, 40));
        try testing.expectEqual(@as(u8, 0), stencilAt(kept, stride, 48, 8));
        try testing.expectEqual(@as(u8, 0), stencilAt(kept, stride, 48, 40));

        // The second pass loads it and draws over the whole picture where
        // the stencil is the reference: the half the first pass marked.
        const loading = try stencilPass(&bench, format, .clear, "dcld".*);
        defer fb.DestroyRenderPass(device, loading);
        const again = try framebuffer(&bench, loading, &.{ picture.view, stencil_view }, 64, 64);
        defer fb.DestroyFramebuffer(device, again);
        const equal = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = marked };
        const draw_result, const draw = makePipeline(&bench, .{ .module = flat, .layout = layout, .pass = loading, .depth = .{ .stencil_test_enable = true, .front = equal, .back = equal } });
        try testing.expectEqual(facet.Result.success, draw_result);
        defer fb.DestroyPipeline(device, draw);
        commands = try bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = loading, .framebuffer = again, .render_area = area, .clear_value_count = 2, .clear_values = &values }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, draw.?);
        fb.CmdPushConstants(commands, layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();
        try testing.expectEqual(green, picture.at(16, 8));
        try testing.expectEqual(green, picture.at(16, 40));
        try testing.expectEqual(clear, picture.at(48, 8));
        try testing.expectEqual(clear, picture.at(48, 40));

        // Read into a buffer, a pixel's whole bytes at a time, and cleared
        // without a pass over it.
        const pixels = 64 * 64 * stride;
        const read_back, const back_bytes = try bench.buffer(pixels, facet.BUFFER_USAGE_TRANSFER_DST);
        @memset(back_bytes[0..pixels], 0xAA);
        const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 64, .height = 64 }, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL } };
        commands = try bench.record();
        fb.CmdCopyImageToBuffer(commands, stencil_image, .general, read_back, 1, @ptrCast(&whole));
        try bench.submit();
        const stencil_byte = if (stride == 1) @as(usize, 0) else 2;
        try testing.expectEqual(marked, back_bytes[(8 * 64 + 16) * stride + stencil_byte]);
        try testing.expectEqual(@as(u8, 0), back_bytes[(8 * 64 + 48) * stride + stencil_byte]);

        const depth_word = @as(usize, 8) * kept.pitch + @as(usize, 16) * stride;
        const depth_was = kept.data.?[depth_word];
        const value = facet.ClearDepthStencilValue{ .depth = 1, .stencil = 9 };
        const range = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL };
        commands = try bench.record();
        fb.CmdClearDepthStencilImage(commands, stencil_image, 0, &value, 1, @ptrCast(&range));
        try bench.submit();
        try testing.expectEqual(@as(u8, 9), stencilAt(kept, stride, 16, 8));
        try testing.expectEqual(@as(u8, 9), stencilAt(kept, stride, 48, 40));
        // The depth of a format that holds one is left as it was: the
        // stencil aspect alone was asked for.
        if (stride == 4) try testing.expectEqual(depth_was, kept.data.?[depth_word]);

        // Both aspects at once: the depth too, 1 being the furthest.
        const both_aspects = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL };
        const other = facet.ClearDepthStencilValue{ .depth = 1, .stencil = 3 };
        commands = try bench.record();
        fb.CmdClearDepthStencilImage(commands, stencil_image, 0, &other, 1, @ptrCast(&both_aspects));
        try bench.submit();
        try testing.expectEqual(@as(u8, 3), stencilAt(kept, stride, 16, 8));
        if (stride == 4) try testing.expectEqual(@as(u8, 0xFF), kept.data.?[depth_word]);
    }
}

test "a depth kept wants memory behind it: a transient image is refused the framebuffer, and a pass is refused the device that has no plane" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 32, 32);
    const storing = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, storing);
    // Lazily allocated: its pixels live in the tiles and there is nothing
    // in memory for the pass to write.
    const transient_image, const transient = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 32, .height = 32 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT,
    }, true);
    const views = [2]*facet.ImageView{ picture.view, transient };
    var none: ?*facet.Framebuffer = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateFramebuffer(device, &.{ .render_pass = storing, .attachment_count = 2, .attachments = &views, .width = 32, .height = 32 }, &none));
    try testing.expect(none == null);

    // A pass that keeps nothing takes it, as it always did.
    const tiles_only = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, tiles_only);
    var made: ?*facet.Framebuffer = null;
    try testing.expectEqual(facet.Result.success, fb.CreateFramebuffer(device, &.{ .render_pass = tiles_only, .attachment_count = 2, .attachments = &views, .width = 32, .height = 32 }, &made));
    fb.DestroyFramebuffer(device, made);

    // A transient image cleared without a pass: nothing to write, and no
    // complaint. One with a stencil in it cannot be written at all.
    const value = facet.ClearDepthStencilValue{ .depth = 0.5 };
    const range = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
    const commands = try bench.record();
    fb.CmdClearDepthStencilImage(commands, transient_image, 0, &value, 1, @ptrCast(&range));
    try bench.submit();
}

test "a device that keeps no depth, as the V3D keeps none: the pass that asks for one is refused" {
    var bench = try Bench.up();
    defer bench.down();
    // The physical device as the V3D describes itself: it draws in tiles of
    // its own and stores none of their depth.
    _objects.of(_instance.PhysicalDevice, bench.physical).features.stored_depth = false;
    var features: facet.PhysicalDeviceFeatures = undefined;
    bench.rig.fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(!features.stored_depth);
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .final_layout = .general },
        .{ .format = .d16_unorm, .store_op = .store, .final_layout = .general },
    };
    const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
    var refused: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, bench.rig.fb.CreateRenderPass(bench.device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &refused));
    try testing.expect(refused == null);
    // Loaded is refused the same way, and a pass that keeps neither is made.
    const loading = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .final_layout = .general },
        .{ .format = .d16_unorm, .load_op = .load, .final_layout = .general },
    };
    try testing.expectEqual(facet.Result.error_feature_not_present, bench.rig.fb.CreateRenderPass(bench.device, &.{ .attachment_count = 2, .attachments = &loading, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &refused));
    const tiles_only = try renderPass(&bench, .clear, true);
    bench.rig.fb.DestroyRenderPass(bench.device, tiles_only);
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

    /// s and t in the texels of the 8 x 8 texture, 0 to 8 over the quad:
    /// what a sampler of unnormalized coordinates is given (since 1.67).
    fn texels(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) * 4, (p[1] + 1) * 4 };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("wide", &wide, 2),
        shader.fixedFragment("wide", .{ .kind = .texture_sampled }),
        shader.vertex("shadow", &shadow, 3),
        shader.fixedFragment("shadow", .{ .kind = .texture_shadow }),
        shader.vertex("texels", &texels, 2),
        shader.fixedFragment("texels", .{ .kind = .texture_sampled }),
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
    try testing.expect(features.immutable_samplers);
    try testing.expect(features.unnormalized_coordinates);
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    try testing.expectEqual(@as(u32, 16), properties.limits.max_sampler_anisotropy);

    // What CreateSampler has not got, and what it holds rather than refuses.
    var refused: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateSampler(device, &.{ .address_mode_u = @enumFromInt(9) }, &refused));
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

    // 1.67: a sampler in texels, and the five things Vulkan asks of one -
    // each of them refused, and the sampler itself made.
    const in_texels = facet.SamplerCreateInfo{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .unnormalized_coordinates = true,
    };
    for ([_]facet.SamplerCreateInfo{
        shaped: {
            var one_filter = in_texels;
            one_filter.min_filter = .linear;
            break :shaped one_filter;
        },
        shaped: {
            var mipmapped = in_texels;
            mipmapped.mipmap_mode = .linear;
            break :shaped mipmapped;
        },
        shaped: {
            var levelled = in_texels;
            levelled.max_lod = texture_zig.lod_unclamped;
            break :shaped levelled;
        },
        shaped: {
            var held_off = in_texels;
            held_off.min_lod = 1;
            break :shaped held_off;
        },
        shaped: {
            var wide_tap = in_texels;
            wide_tap.anisotropy_enable = true;
            wide_tap.max_anisotropy = 4;
            break :shaped wide_tap;
        },
        shaped: {
            var compared = in_texels;
            compared.compare_enable = true;
            compared.compare_op = .less;
            break :shaped compared;
        },
        shaped: {
            var tiled_edge = in_texels;
            tiled_edge.address_mode_u = .repeat;
            break :shaped tiled_edge;
        },
        shaped: {
            var mirrored_edge = in_texels;
            mirrored_edge.address_mode_v = .mirrored_repeat;
            break :shaped mirrored_edge;
        },
    }) |asked| {
        try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateSampler(device, &asked, &refused));
        try testing.expect(refused == null);
    }
    // The w mode is taken as it is given: Vulkan has no 3D texture read
    // this way, and a bordered edge is one of the two it does ask for.
    for ([_]facet.SamplerCreateInfo{
        shaped: {
            var through = in_texels;
            through.address_mode_w = .repeat;
            break :shaped through;
        },
        shaped: {
            var bordered = in_texels;
            bordered.address_mode_u = .clamp_to_border;
            bordered.address_mode_v = .clamp_to_border;
            break :shaped bordered;
        },
    }) |asked| {
        var taken: ?*facet.Sampler = null;
        try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &asked, &taken));
        try testing.expect(_objects.of(_sampler.Sampler, taken.?).kept.unnormalized);
        fb.DestroySampler(device, taken);
    }

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
        // Turned round once below 0 and then held: column -1 is column 0,
        // which is red (since 1.49).
        .{ .mode = .mirror_clamp_to_edge, .outside = red },
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

    // 1.67: a sampler in texels reads the texel its coordinates name. The
    // quad carries s and t from 0 to 8 - the texture's own columns and
    // rows - so the left half of the picture is the texture's red half and
    // the right half its blue one.
    const texels_result, const texels_pipeline = makePipeline(&bench, .{ .module = scene_module, .name = "texels", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, texels_result);
    defer fb.DestroyPipeline(device, texels_pipeline);
    var by_texel: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &in_texels, &by_texel));
    defer fb.DestroySampler(device, by_texel);
    try frames.draw(by_texel, texels_pipeline);
    try testing.expectEqual(red, picture.at(8, 32));
    try testing.expectEqual(red, picture.at(28, 32));
    try testing.expectEqual(blue, picture.at(36, 32));
    try testing.expectEqual(blue, picture.at(56, 32));
    // The same coordinates through a sampler of 0 to 1 are eight times
    // across the texture, held at its edge: blue everywhere but the first
    // eighth of the picture, which is what says these are texels and not
    // coordinates that happen to work out.
    var by_part: ?*facet.Sampler = null;
    var normalized = in_texels;
    normalized.unnormalized_coordinates = false;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &normalized, &by_part));
    defer fb.DestroySampler(device, by_part);
    try frames.draw(by_part, texels_pipeline);
    try testing.expectEqual(red, picture.at(2, 32));
    try testing.expectEqual(blue, picture.at(8, 32));
    try testing.expectEqual(blue, picture.at(28, 32));
    try testing.expectEqual(blue, picture.at(56, 32));

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
    /// The same colour into every attachment, so that what differs between
    /// them is the mixing alone.
    fn fragmentWhite(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, 0xFFFF_FFFF);
    }
    const entries = [_]shader.Entry{
        shader.vertex("red", &vertex, 0),
        shader.fragment("red", &fragmentRed, 0),
        shader.vertex("green", &vertex, 0),
        shader.fragment("green", &fragmentGreen, 0),
        shader.vertex("outputs", &vertex, 0),
        shader.fragment("outputs", &fragmentOutputs, 0),
        shader.vertex("white", &vertex, 0),
        shader.fragment("white", &fragmentWhite, 0),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a subpass's colour attachments, each blended its own way" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const first = try Picture.of(&bench, 64, 64);
    const second = try Picture.of(&bench, 64, 64);
    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const colors = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .general }, .{ .attachment = 1, .layout = .general } };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &colors };
    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;
    const frame = try framebuffer(&bench, pass, &.{ first.view, second.view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const shaders = try module(&bench, &SubpassScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);

    // The first attachment takes the red channel alone and keeps the rest
    // of what is there; the second takes the whole colour, mixed.
    const red_alone = facet.PipelineColorBlendAttachmentState{ .color_write_mask = facet.COLOR_COMPONENT_R };
    const whole = facet.PipelineColorBlendAttachmentState{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .zero };
    const result, const pipeline = makePipeline(&bench, .{ .module = shaders, .name = "white", .layout = layout, .pass = pass, .blend = red_alone, .second_blend = whole, .blend_count = 2 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, pipeline);
    const made = _objects.of(_pipeline.Pipeline, pipeline.?);
    try testing.expectEqual(@as(u32, facet.COLOR_COMPONENT_R), made.mixings[0].mask);
    try testing.expect(!made.mixings[0].enabled);
    try testing.expectEqual(@as(u32, facet.COLOR_COMPONENT_ALL), made.mixings[1].mask);
    try testing.expect(made.mixings[1].enabled);
    try testing.expectEqual(.zero, made.mixings[1].dst_color);
    // The ones no attachment of the subpass asked for hold the default.
    try testing.expect(!made.mixings[2].enabled);
    try testing.expectEqual(@as(u32, facet.COLOR_COMPONENT_ALL), made.mixings[2].mask);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(SubpassScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(SubpassScene.quad))], std.mem.asBytes(&SubpassScene.quad));
    const clear_values = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } } };
    const offset: u64 = 0;
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &clear_values }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, pipeline.?);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // Both were cleared blue and drawn white over: the first kept the blue
    // under the red it took, the second is white.
    try testing.expectEqual(@as(u32, 0xFFFF_00FF), first.at(32, 32));
    try testing.expectEqual(@as(u32, 0xFFFF_00FF), first.at(1, 62));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), second.at(32, 32));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), second.at(1, 62));
}

test "a device that blends every colour attachment the same way: the pipeline whose attachments differ is refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    // A device as one without the feature describes itself.
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.independent_blend = false;
    defer physical.features.independent_blend = true;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(!features.independent_blend);

    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .store_op = .store, .final_layout = .general },
    };
    const colors = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .general }, .{ .attachment = 1, .layout = .general } };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &colors };
    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;
    const shaders = try module(&bench, &SubpassScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);

    const red_alone = facet.PipelineColorBlendAttachmentState{ .color_write_mask = facet.COLOR_COMPONENT_R };
    const refused, const none = makePipeline(&bench, .{ .module = shaders, .name = "white", .layout = layout, .pass = pass, .blend = red_alone, .second_blend = .{}, .blend_count = 2 });
    try testing.expectEqual(facet.Result.error_feature_not_present, refused);
    try testing.expect(none == null);
    // The same state for both is made, as it was before 1.33.
    const result, const pipeline = makePipeline(&bench, .{ .module = shaders, .name = "white", .layout = layout, .pass = pass, .blend = red_alone, .blend_count = 2 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, pipeline);
    const made = _objects.of(_pipeline.Pipeline, pipeline.?);
    try testing.expectEqual(@as(u32, facet.COLOR_COMPONENT_R), made.mixings[1].mask);
}

// --- 1.37: input attachments -------------------------------------------------

/// Two subpasses: the first writes a colour, the second reads the pixel it
/// wrote at the same place and writes it with green and blue swapped, so
/// the picture says which pixel was read.
const Deferred = struct {
    const quad = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 } };
    const written: u32 = 0xFF11_2233;
    const swapped: u32 = 0xFF11_3322;
    /// What it draws where it finds no attachment to read.
    const missing: u32 = 0xFF00_0000;

    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn write(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, written);
    }

    /// What the attachment holds at this very pixel, its green and blue
    /// the other way round; `missing` where there is nothing to read.
    fn read(fragments: *const shader.Fragments) callconv(.c) void {
        const from = fragments.resources.input(0, 0, 0) orelse return shader.fill(fragments, missing);
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

    const entries = [_]shader.Entry{
        shader.vertex("write", &vertex, 0),
        shader.fragment("write", &write, 0),
        shader.vertex("read", &vertex, 0),
        shader.fragment("read", &read, 0),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// A quad drawn into a depth attachment, and the functions that read that
/// attachment back pixel by pixel in the subpass after it: the depth as a
/// grey of its own value, and a stencil as the number it holds. (1.62.)
const DepthRead = struct {
    /// The left half, nearer than the clear; and the whole target.
    const half = [6][3]f32{ .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 }, .{ -1, 1, 0.25 }, .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 } };
    const whole = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 } };
    const written: u32 = 0xFF11_2233;
    /// What it draws where there is nothing to read.
    const missing: u32 = 0xFF00_0000;

    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn write(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, written);
    }

    fn readDepth(fragments: *const shader.Fragments) callconv(.c) void {
        paint(fragments, 255);
    }

    fn readStencil(fragments: *const shader.Fragments) callconv(.c) void {
        paint(fragments, 1);
    }

    /// The attachment's first channel at each pixel, times `by`, as the
    /// red: a depth of 0 to 1 scaled to a byte, a stencil as it stands.
    fn paint(fragments: *const shader.Fragments, by: f32) void {
        const from = fragments.resources.input(0, 0, 0) orelse return shader.fill(fragments, missing);
        for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |spot, *out| {
            inline for (0..4) |i| {
                const x = fragments.x + @as(u32, spot.x) + @as(u32, i & 1);
                const y = fragments.y + @as(u32, spot.y) + @as(u32, i >> 1);
                const value = from.at(x, y)[0] * by;
                const byte: u32 = @intFromFloat(@min(@max(value, 0), 255) + 0.5);
                out[i] = 0xFF00_0000 | byte << 16;
            }
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("write", &vertex, 0),
        shader.fragment("write", &write, 0),
        shader.vertex("depth", &vertex, 0),
        shader.fragment("depth", &readDepth, 0),
        shader.vertex("stencil", &vertex, 0),
        shader.fragment("stencil", &readStencil, 0),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a depth attachment of levels: a pass draws into the level its view names, and a sample reads the level it is held to" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const image_zig = @import("../image/_image.zig");
    const side = facet.Extent3D{ .width = 32, .height = 32 };
    const wanted = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED;

    // Three levels since 1.63 - 32 by 32, 16 by 16 and 8 by 8 - of two
    // layers: a level's rows after the level before it, each level's
    // pitch as wide as that level is and each level on a cache line, and
    // the whole pyramid again for the second layer.
    const mipped = try bench.bareImage(.{ .format = .d16_unorm, .extent = side, .mip_levels = 3, .array_layers = 2, .usage = wanted }, false);
    const kept = _objects.of(image_zig.Image, mipped);
    try testing.expectEqual(@as(u32, 3), kept.levels);
    // The same rule again, by hand: the pitch of a level, where it begins
    // inside a layer, and what the pyramid takes.
    const Mip = struct {
        fn pitch(level: u32) u32 {
            return std.mem.alignForward(u32, @max(@as(u32, 32) >> @intCast(level), 1) * 2, 64);
        }
        fn bytes(level: u32) u64 {
            return std.mem.alignForward(u64, @as(u64, pitch(level)) * @max(@as(u32, 32) >> @intCast(level), 1), 64);
        }
        fn whole(levels: u32) u64 {
            var sum: u64 = 0;
            for (0..levels) |lod| sum += bytes(@intCast(lod));
            return sum;
        }
        fn at(level: u32, layer: u32) usize {
            return @intCast(layer * whole(3) + whole(level));
        }
    };
    try testing.expectEqual(Mip.whole(3), kept.layer_bytes);
    try testing.expectEqual(Mip.whole(3) * 2, kept.bytes);

    // What the program is told of a level of a layer, which is what it
    // holds: 1.63 answers for a depth attachment, where it answered 0.
    var layout: facet.SubresourceLayout = undefined;
    fb.GetImageSubresourceLayout(device, mipped, &.{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .mip_level = 1, .array_layer = 1 }, &layout);
    try testing.expectEqual(@as(u64, Mip.at(1, 1)), layout.offset);
    try testing.expectEqual(@as(u64, Mip.pitch(1)), layout.row_pitch);
    try testing.expectEqual(@as(u64, Mip.pitch(1)) * 16, layout.size);
    try testing.expectEqual(Mip.whole(3), layout.array_pitch);
    // A level it has not got says nothing.
    fb.GetImageSubresourceLayout(device, mipped, &.{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .mip_level = 3 }, &layout);
    try testing.expectEqual(@as(u64, 0), layout.row_pitch);

    const levelDepth = struct {
        fn of(data: [*]u8, level: u32, layer: u32, x: u32, y: u32) u16 {
            const place = Mip.at(level, layer) + @as(usize, y) * Mip.pitch(level) + @as(usize, x) * 2;
            return std.mem.readInt(u16, data[place..][0..2], .little);
        }
    }.of;

    // Cleared without a pass: every level of every layer, which is what
    // a range of all of them names.
    const furthest = facet.ClearDepthStencilValue{ .depth = 1 };
    const everything = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
    const clearing = try bench.record();
    fb.CmdClearDepthStencilImage(clearing, mipped, 0, &furthest, 1, @ptrCast(&everything));
    try bench.submit();
    for (0..2) |layer| for (0..3) |level| {
        const far = levelDepth(kept.data.?, @intCast(level), @intCast(layer), 0, 0);
        try testing.expectEqual(@as(u16, 0xFFFF), far);
        const side_of = @max(@as(u32, 32) >> @intCast(level), 1);
        try testing.expectEqual(@as(u16, 0xFFFF), levelDepth(kept.data.?, @intCast(level), @intCast(layer), side_of - 1, side_of - 1));
    };

    // A pass over level 1 of layer 1: a quad of its own depth over the
    // whole of that level, through a framebuffer of that level's size.
    const level_view = try bench.viewOf(.{
        .image = mipped,
        .format = .d16_unorm,
        .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_mip_level = 1, .level_count = 1, .base_array_layer = 1, .layer_count = 1 },
    });
    const picture = try Picture.of(&bench, 32, 32);
    const storing = try keepingPass(&bench, .clear, .clear, .store);
    defer fb.DestroyRenderPass(device, storing);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const flat_layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, flat_layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .always };
    const flat_result, const list = makePipeline(&bench, .{ .module = flat, .layout = flat_layout, .pass = storing, .depth = tested, .width = 16, .height = 16 });
    try testing.expectEqual(facet.Result.success, flat_result);
    defer fb.DestroyPipeline(device, list);
    const frame = try framebuffer(&bench, storing, &.{ picture.view, level_view }, 16, 16);
    defer fb.DestroyFramebuffer(device, frame);
    const vertex_buffer, const vertex_bytes = try bench.buffer(1024, facet.BUFFER_USAGE_VERTEX_BUFFER);
    const quad = [6][3]f32{
        .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 },
        .{ -1, 1, 0.5 },  .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const red: u32 = 0xFFFF_0000;
    const blue = clears(0xFF00_00FF);
    const at: u64 = 0;
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 16, .height = 16 } }, .clear_value_count = 2, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, list.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&at));
    fb.CmdPushConstants(commands, flat_layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // That level holds the quad's depth, over the whole of it; the levels
    // either side of it, and the same level of the other layer, still
    // hold what the clear left.
    const middle: u16 = @intFromFloat(@round(0.5 * 65535));
    try testing.expectEqual(middle, levelDepth(kept.data.?, 1, 1, 0, 0));
    try testing.expectEqual(middle, levelDepth(kept.data.?, 1, 1, 15, 15));
    try testing.expectEqual(@as(u16, 0xFFFF), levelDepth(kept.data.?, 0, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), levelDepth(kept.data.?, 2, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), levelDepth(kept.data.?, 1, 0, 0, 0));

    // A view of all three levels of that layer, sampled: the sampler
    // holds the level it reads, so the level drawn into comes out as its
    // own grey and the one beside it as the clear's.
    const whole_view = try bench.viewOf(.{
        .image = mipped,
        .format = .d16_unorm,
        .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_array_layer = 1, .layer_count = 1 },
    });
    const texels = &_objects.of(image_zig.ImageView, whole_view).texels;
    try testing.expectEqual(@as(u32, 3), texels.levels);
    try testing.expectEqual(kept.data.? + Mip.at(0, 1), texels.memory);
    try testing.expectEqual(@as(u32, Mip.pitch(0)), texels.pitch);
    try testing.expectEqual(@as(u32, @intCast(Mip.whole(1))), texels.layout[1].start);
    try testing.expectEqual(@as(u32, Mip.pitch(1)), texels.layout[1].pitch);
    try testing.expectEqual(@as(u32, 16), texels.layout[1].width);

    const into = try Picture.of(&bench, 32, 32);
    const planed = try module(&bench, &Planed.code);
    defer fb.DestroyShaderModule(device, planed);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const sampled_layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, sampled_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const reading = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, reading);
    const onto = try framebuffer(&bench, reading, &.{into.view}, 32, 32);
    defer fb.DestroyFramebuffer(device, onto);
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const plane_result, const plane = makePipeline(&bench, .{ .module = planed, .layout = sampled_layout, .pass = reading, .stride = 24, .attributes = &attributes, .width = 32, .height = 32 });
    try testing.expectEqual(facet.Result.success, plane_result);
    defer fb.DestroyPipeline(device, plane);
    const sampling = [6][6]f32{
        .{ -1, -1, 0.5, 0, 0, 0 },
        .{ 1, -1, 0.5, 1, 0, 0 },
        .{ -1, 1, 0.5, 0, 1, 0 },
        .{ -1, 1, 0.5, 0, 1, 0 },
        .{ 1, -1, 0.5, 1, 0, 0 },
        .{ 1, 1, 0.5, 1, 1, 0 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(sampling))], std.mem.asBytes(&sampling));

    for ([2]struct { f32, u16 }{ .{ 1, middle }, .{ 0, 0xFFFF } }) |one| {
        const lod, const value = one;
        var sampler: ?*facet.Sampler = null;
        try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .min_lod = lod,
            .max_lod = lod,
        }, &sampler));
        defer fb.DestroySampler(device, sampler);
        const info = facet.DescriptorImageInfo{ .sampler = sampler, .image_view = whole_view };
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        const values = clears(0xFF00_00FF);
        const drawing = try bench.record();
        fb.CmdBeginRenderPass(drawing, &.{ .render_pass = reading, .framebuffer = onto, .render_area = .{ .extent = .{ .width = 32, .height = 32 } }, .clear_value_count = 1, .clear_values = &values }, .@"inline");
        fb.CmdBindPipeline(drawing, .graphics, plane.?);
        fb.CmdBindVertexBuffers(drawing, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&at));
        fb.CmdBindDescriptorSets(drawing, .graphics, sampled_layout, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDraw(drawing, 6, 1, 0, 0);
        fb.CmdEndRenderPass(drawing);
        try bench.submit();
        const grey: u32 = 0xFF00_0000 | @as(u32, value >> 8) * 0x01_01_01;
        try testing.expectEqual(grey, into.at(8, 8));
        try testing.expectEqual(grey, into.at(24, 24));
    }
}

test "a depth attachment read as an input attachment: what the subpass before drew, plane by plane" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.input_attachments and features.sampled_depth and features.stored_both);

    const picture = try Picture.of(&bench, 64, 64);
    const depth_usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT;
    const side = facet.Extent3D{ .width = 64, .height = 64 };
    _, const plain_view = try bench.image(.{ .format = .d16_unorm, .extent = side, .usage = depth_usage }, false);
    const both_image, const both_view = try bench.image(.{ .format = .d16_unorm_s8_uint, .extent = side, .usage = depth_usage }, false);
    // The stencil of that same image: the other plane of the same rows.
    const stencil_view = try bench.viewOf(.{ .image = both_image, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL } });

    // A depth read pixel by pixel wants memory behind it, so a transient
    // one is refused.
    var none: ?*facet.Image = null;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = depth_usage | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &none));
    try testing.expect(none == null);

    const to_color = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const of_depth = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const subpasses = [2]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &to_color, .depth_stencil_attachment = &of_depth[0] },
        .{ .input_attachment_count = 1, .input_attachments = &of_depth, .color_attachment_count = 1, .color_attachments = &to_color },
    };

    const shaders = try module(&bench, &DepthRead.code);
    defer fb.DestroyShaderModule(device, shaders);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 3 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    const layouts = [3]*facet.DescriptorSetLayout{ set_layout.?, set_layout.?, set_layout.? };
    var sets: [3]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 3, .set_layouts = &layouts }, &sets));
    const infos = [3]facet.DescriptorImageInfo{
        .{ .image_view = plain_view, .image_layout = .general },
        .{ .image_view = both_view, .image_layout = .general },
        .{ .image_view = stencil_view, .image_layout = .general },
    };
    var writes: [3]facet.WriteDescriptorSet = undefined;
    for (&writes, 0..) |*one, k| one.* = .{ .dst_set = sets[k].?, .dst_binding = 0, .descriptor_type = .input_attachment, .image_info = @ptrCast(&infos[k]) };
    fb.UpdateDescriptorSets(device, 3, &writes, 0, null);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(DepthRead.half)) * 2, facet.BUFFER_USAGE_VERTEX_BUFFER);
    const quad_bytes = @sizeOf(@TypeOf(DepthRead.half));
    @memcpy(vertex_bytes[0..quad_bytes], std.mem.asBytes(&DepthRead.half));
    @memcpy(vertex_bytes[quad_bytes..][0..quad_bytes], std.mem.asBytes(&DepthRead.whole));
    const first_quad: u64 = 0;
    const second_quad: u64 = quad_bytes;
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };
    const starts = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } } };
    const writing = facet.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = true,
        .depth_write_enable = true,
        .depth_compare_op = .less,
        .stencil_test_enable = true,
        .front = .{ .fail_op = .replace, .pass_op = .replace, .depth_fail_op = .replace, .compare_op = .always, .write_mask = 0xFF, .reference = 0x30 },
        .back = .{ .fail_op = .replace, .pass_op = .replace, .depth_fail_op = .replace, .compare_op = .always, .write_mask = 0xFF, .reference = 0x30 },
    };

    // The depth of a format of depth alone, then the two planes of one
    // that holds both: the depth every four bytes, and the stencil beside
    // it.
    for ([3]struct { facet.Format, *facet.ImageView, u32, [*:0]const u8, u32, u32 }{
        .{ .d16_unorm, plain_view, 0, "depth", 0xFF40_0000, 0xFFFF_0000 },
        .{ .d16_unorm_s8_uint, both_view, 1, "depth", 0xFF40_0000, 0xFFFF_0000 },
        .{ .d16_unorm_s8_uint, both_view, 2, "stencil", 0xFF30_0000, 0xFF00_0000 },
    }) |one| {
        const format, const view, const which, const name, const left, const right = one;
        // The stencil's own two ops are for a format that has one: a
        // store asked of a format without it is refused.
        const has_stencil = format == .d16_unorm_s8_uint;
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
            .{
                .format = format,
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = if (has_stencil) .clear else .dont_care,
                .stencil_store_op = if (has_stencil) .store else .dont_care,
                .final_layout = .general,
            },
        };
        var pass_made: ?*facet.RenderPass = null;
        try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 2, .subpasses = &subpasses }, &pass_made));
        defer fb.DestroyRenderPass(device, pass_made);
        const pass = pass_made.?;
        const frame = try framebuffer(&bench, pass, &.{ picture.view, view }, 64, 64);
        defer fb.DestroyFramebuffer(device, frame);
        const made_writer, const writer = makePipeline(&bench, .{ .module = shaders, .name = "write", .layout = layout, .pass = pass, .depth = writing });
        try testing.expectEqual(facet.Result.success, made_writer);
        defer fb.DestroyPipeline(device, writer);
        const made_reader, const reader = makePipeline(&bench, .{ .module = shaders, .name = name, .layout = layout, .pass = pass, .subpass = 1 });
        try testing.expectEqual(facet.Result.success, made_reader);
        defer fb.DestroyPipeline(device, reader);

        const commands = try bench.record();
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &starts }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&first_quad));
        fb.CmdBindPipeline(commands, .graphics, writer.?);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdNextSubpass(commands, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&second_quad));
        fb.CmdBindPipeline(commands, .graphics, reader.?);
        fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&sets[which]), 0, null);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        try bench.submit();

        // The left half is what the first subpass left there, the right
        // half what the clear did.
        try nearColor(left, picture.at(16, 32), 1);
        try nearColor(right, picture.at(48, 32), 1);
    }
}

/// A subpass that reads the attachment it draws into: one function writes
/// a colour, the other reads what is already at the pixel and writes it
/// back with its green and blue the other way round (1.64).
const SelfRead = struct {
    const half = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 0, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 0, -1, 0.5 }, .{ 0, 1, 0.5 } };
    const whole = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 } };
    const written: u32 = 0xFF11_2233;
    /// What it draws where there is no attachment to read.
    const missing: u32 = 0xFF00_0000;

    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    fn write(fragments: *const shader.Fragments) callconv(.c) void {
        shader.fill(fragments, written);
    }

    /// What the attachment holds at the fragment's own pixel, its green
    /// and blue the other way round: read through the input attachment
    /// descriptor, which for the one being drawn is the tile.
    fn mix(fragments: *const shader.Fragments) callconv(.c) void {
        const from = fragments.input(0, 0, 0) orelse return shader.fill(fragments, missing);
        for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
            inline for (0..4) |i| {
                const x = fragments.x + @as(u32, quad.x) + @as(u32, i & 1);
                const y = fragments.y + @as(u32, quad.y) + @as(u32, i >> 1);
                const color = from.colorAt(x, y);
                out[i] = (color & 0xFFFF_0000) | (color & 0xFF) << 8 | (color >> 8 & 0xFF);
            }
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("write", &vertex, 0),
        shader.fragment("write", &write, 0),
        shader.vertex("mix", &vertex, 0),
        shader.fragment("mix", &mix, 0),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a subpass that reads the attachment it draws into: the pixel as the tile holds it, where a dependency by region says so" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    const image_zig = @import("../image/_image.zig");
    // Drawn into and read: an attachment made to be read as one, as any
    // input attachment's image is.
    const shown, const shown_view = try bench.image(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .tiling = .linear,
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT,
    }, false);
    _ = shown;
    const other, const other_view = try bench.image(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .tiling = .linear,
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT,
    }, false);
    _ = other;
    const shown_kept = _objects.of(image_zig.ImageView, shown_view).image;
    const other_kept = _objects.of(image_zig.ImageView, other_view).image;
    const pixelOf = struct {
        fn of(image: *const image_zig.Image, x: u32, y: u32) u32 {
            return std.mem.readInt(u32, image.data.?[@as(usize, y) * image.pitch + x * 4 ..][0..4], .little);
        }
    }.of;
    const attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general };
    const its_own = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const reads_itself = facet.SubpassDescription{
        .input_attachment_count = 1,
        .input_attachments = &its_own,
        .color_attachment_count = 1,
        .color_attachments = &its_own,
    };
    const by_region = facet.SubpassDependency{
        .src_subpass = 0,
        .dst_subpass = 0,
        .src_stage_mask = 0,
        .dst_stage_mask = 0,
        .dependency_flags = facet.DEPENDENCY_BY_REGION,
    };
    const whole_pass = facet.RenderPassCreateInfo{
        .attachment_count = 1,
        .attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .subpasses = @ptrCast(&reads_itself),
        .dependency_count = 1,
        .dependencies = @ptrCast(&by_region),
    };

    // Without the dependency it is the loop it always was; with a
    // dependency that is not by region, too.
    var refused: ?*facet.RenderPass = null;
    var without = whole_pass;
    without.dependency_count = 0;
    without.dependencies = null;
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &without, &refused));
    const not_by_region = facet.SubpassDependency{ .src_subpass = 0, .dst_subpass = 0, .src_stage_mask = 0, .dst_stage_mask = 0 };
    var whole_frame = whole_pass;
    whole_frame.dependencies = @ptrCast(&not_by_region);
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &whole_frame, &refused));
    try testing.expect(refused == null);

    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &whole_pass, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;

    // Reading the depth attachment it draws into is not among this,
    // dependency or no dependency.
    const with_depth = [2]facet.AttachmentDescription{
        attachment,
        .{ .format = .d16_unorm, .final_layout = .general },
    };
    const of_depth = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const reads_depth = facet.SubpassDescription{
        .input_attachment_count = 1,
        .input_attachments = &of_depth,
        .color_attachment_count = 1,
        .color_attachments = &its_own,
        .depth_stencil_attachment = &of_depth[0],
    };
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &.{
        .attachment_count = 2,
        .attachments = &with_depth,
        .subpass_count = 1,
        .subpasses = @ptrCast(&reads_depth),
        .dependency_count = 1,
        .dependencies = @ptrCast(&by_region),
    }, &refused));
    try testing.expect(refused == null);

    const shaders = try module(&bench, &SelfRead.code);
    defer fb.DestroyShaderModule(device, shaders);
    // The descriptor the function reads it through, which is the Vulkan
    // way of saying which attachment it reads: a view of the image being
    // drawn into, and one of another image to tell them apart by.
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    const layouts = [2]*facet.DescriptorSetLayout{ set_layout.?, set_layout.? };
    var sets: [2]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 2, .set_layouts = &layouts }, &sets));
    const infos = [2]facet.DescriptorImageInfo{
        .{ .image_view = shown_view, .image_layout = .general },
        .{ .image_view = other_view, .image_layout = .general },
    };
    var writes: [2]facet.WriteDescriptorSet = undefined;
    for (&writes, 0..) |*one, k| one.* = .{ .dst_set = sets[k].?, .dst_binding = 0, .descriptor_type = .input_attachment, .image_info = @ptrCast(&infos[k]) };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);
    const frame = try framebuffer(&bench, pass, &.{shown_view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const made_writer, const writer = makePipeline(&bench, .{ .module = shaders, .name = "write", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, made_writer);
    defer fb.DestroyPipeline(device, writer);
    const made_mixer, const mixer = makePipeline(&bench, .{ .module = shaders, .name = "mix", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, made_mixer);
    defer fb.DestroyPipeline(device, mixer);

    const vertex_buffer, const vertex_bytes = try bench.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER);
    const quad_bytes = @sizeOf(@TypeOf(SelfRead.half));
    @memcpy(vertex_bytes[0..quad_bytes], std.mem.asBytes(&SelfRead.half));
    @memcpy(vertex_bytes[quad_bytes..][0..quad_bytes], std.mem.asBytes(&SelfRead.whole));
    const first_quad: u64 = 0;
    const second_quad: u64 = quad_bytes;
    const blue = clears(0xFF00_00FF);

    // The first draw writes its colour over the left half; the second
    // draws over the whole of it, reading what is at each pixel - the
    // first draw's colour on the left, the clear's on the right.
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, writer.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&first_quad));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdBindPipeline(commands, .graphics, mixer.?);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&second_quad));
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&sets[0]), 0, null);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // Every pixel is what was there with its green and blue swapped: the
    // first draw's colour on the left, and the clear's on the right,
    // which is the pixel's own and no other's. Two tiles of each, the
    // tiles being drawn one at a time.
    const swapped = SelfRead.written & 0xFFFF_0000 | (SelfRead.written & 0xFF) << 8 | (SelfRead.written >> 8 & 0xFF);
    try testing.expectEqual(swapped, pixelOf(shown_kept, 16, 8));
    try testing.expectEqual(swapped, pixelOf(shown_kept, 16, 40));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), pixelOf(shown_kept, 48, 8));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), pixelOf(shown_kept, 48, 40));

    // The same pass with a descriptor of another image: that is not the
    // attachment being drawn, so it is read where it lies - its own
    // memory, which nothing has written, rather than the tile.
    @memset(other_kept.data.?[0 .. @as(usize, other_kept.pitch) * 64], 0);
    for (0..64) |y| std.mem.writeInt(u32, other_kept.data.?[y * other_kept.pitch + 16 * 4 ..][0..4], 0xFF44_5566, .little);
    const again = try bench.record();
    fb.CmdBeginRenderPass(again, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &blue }, .@"inline");
    fb.CmdBindPipeline(again, .graphics, mixer.?);
    fb.CmdBindVertexBuffers(again, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&second_quad));
    fb.CmdBindDescriptorSets(again, .graphics, layout, 0, 1, @ptrCast(&sets[1]), 0, null);
    fb.CmdDraw(again, 6, 1, 0, 0);
    fb.CmdEndRenderPass(again);
    try bench.submit();
    try testing.expectEqual(@as(u32, 0xFF44_6655), pixelOf(shown_kept, 16, 8));
    // Where that other image holds nothing, nothing is what it reads.
    try testing.expectEqual(@as(u32, 0), pixelOf(shown_kept, 48, 8));
}

/// Two colours within `apart` of each other in every channel: what a
/// blend by a constant may differ by between one rounding and another.
fn nearColor(wanted: u32, found: u32, apart: u32) !void {
    inline for (0..4) |k| {
        const shift = k * 8;
        const a = (wanted >> shift) & 0xFF;
        const b = (found >> shift) & 0xFF;
        if ((if (a > b) a - b else b - a) > apart) return testing.expectEqual(wanted, found);
    }
}

/// Three colour attachments written in the one fragment call
/// (`shader.fragmentOutputs`, SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER).
const TogetherScene = struct {
    const quad = [6][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ -1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 } };
    /// How often a fragment function was called, over the whole draw.
    var calls: u32 = 0;
    /// What the last call was told it writes.
    var outputs: u32 = 0;

    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    /// Red, green and blue, one for each attachment, in the one call.
    fn three(fragments: *const shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        const colors = [3]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF };
        for (colors, 0..) |color, output| {
            const into = fragments.colorsOf(@intCast(output));
            for (into[0..fragments.count]) |*quad_colors| quad_colors.* = @splat(color);
        }
    }

    /// White into all three at once: what differs between them is then
    /// the blending alone.
    fn white(fragments: *const shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        for (0..fragments.output_count) |output| {
            const into = fragments.colorsOf(@intCast(output));
            for (into[0..fragments.count]) |*quad_colors| quad_colors.* = @splat(0xFFFF_FFFF);
        }
    }

    /// The one colour a replayed subpass's fragment function writes, the
    /// attachment being drawn saying which.
    fn one(fragments: *const shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        const colors = [3]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF };
        shader.fill(fragments, colors[@min(fragments.resources.output, 2)]);
    }

    const entries = [_]shader.Entry{
        shader.vertex("three", &vertex, 0),
        shader.fragmentOutputs("three", &three, 0, 3),
        shader.vertex("white", &vertex, 0),
        shader.fragmentOutputs("white", &white, 0, 3),
        shader.vertex("one", &vertex, 0),
        shader.fragment("one", &one, 0),
        shader.vertex("four", &vertex, 0),
        shader.fragmentOutputs("four", &three, 0, 4),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a subpass's colour attachments drawn together: one fragment call writes them all, each blended its own way" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const red = try Picture.of(&bench, 64, 64);
    const green = try Picture.of(&bench, 64, 64);
    const blue = try Picture.of(&bench, 64, 64);
    const descriptions = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const colors = [3]facet.AttachmentReference{
        .{ .attachment = 0, .layout = .general },
        .{ .attachment = 1, .layout = .general },
        .{ .attachment = 2, .layout = .general },
    };
    const together = facet.SubpassDescription{
        .flags = facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER,
        .color_attachment_count = 3,
        .color_attachments = &colors,
    };
    const apart = facet.SubpassDescription{ .color_attachment_count = 3, .color_attachments = &colors };
    const info = facet.RenderPassCreateInfo{ .attachment_count = 3, .attachments = &descriptions, .subpass_count = 1, .subpasses = @ptrCast(&together) };
    var pass_made: ?*facet.RenderPass = null;
    const asked = fb.CreateRenderPass(device, &info, &pass_made);
    const shaders = try module(&bench, &TogetherScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);

    try testing.expectEqual(facet.Result.success, asked);
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;
    // The one part of the subpass draws all three.
    const plan = _objects.of(_render.RenderPass, pass);
    try testing.expectEqual(@as(u32, 1), plan.part_count);
    try testing.expectEqual(@as(u32, 3), plan.parts[0].color_count);
    try testing.expectEqual(@as(u32, 2), plan.parts[0].colors[2]);

    const frame = try framebuffer(&bench, pass, &.{ red.view, green.view, blue.view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(TogetherScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(TogetherScene.quad))], std.mem.asBytes(&TogetherScene.quad));
    const offset: u64 = 0;
    const clear_values = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
    };
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };

    const draw = struct {
        fn run(on: *Bench, into: *facet.RenderPass, onto: *facet.Framebuffer, pipeline: *facet.Pipeline, buffer: *facet.Buffer, where: *const u64, constants: ?u32) !void {
            const commands = try on.record();
            on.rig.fb.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = area, .clear_value_count = 3, .clear_values = &clear_values }, .@"inline");
            on.rig.fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(where));
            on.rig.fb.CmdBindPipeline(commands, .graphics, pipeline);
            if (constants) |at| {
                on.rig.fb.CmdSetBlendConstants(commands, &.{ 1, 1, 1, 1 });
                on.rig.fb.CmdSetBlendConstantsAt(commands, at, &.{ 0.25, 0.25, 0.25, 1 });
            }
            on.rig.fb.CmdDraw(commands, 6, 1, 0, 0);
            on.rig.fb.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.run;

    // One call for all three attachments: each gets its own colour, and
    // the function was told it writes three.
    var result, const all = makePipeline(&bench, .{ .module = shaders, .name = "three", .layout = layout, .pass = pass, .blend_count = 3 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, all);
    TogetherScene.calls = 0;
    try draw(&bench, pass, frame, all.?, vertex_buffer, &offset, null);
    try testing.expectEqual(@as(u32, 3), TogetherScene.outputs);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), red.at(32, 32));
    try testing.expectEqual(@as(u32, 0xFF00_FF00), green.at(32, 32));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), blue.at(1, 62));
    const together_calls = TogetherScene.calls;
    try testing.expect(together_calls > 0);

    // The same three attachments drawn once for each, which is what there
    // was before: three times the calls for the one picture each.
    var plain: ?*facet.RenderPass = null;
    var without = info;
    without.subpasses = @ptrCast(&apart);
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &without, &plain));
    defer fb.DestroyRenderPass(device, plain);
    const plain_frame = try framebuffer(&bench, plain.?, &.{ red.view, green.view, blue.view }, 64, 64);
    defer fb.DestroyFramebuffer(device, plain_frame);
    result, const each = makePipeline(&bench, .{ .module = shaders, .name = "one", .layout = layout, .pass = plain.?, .blend_count = 3 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, each);
    TogetherScene.calls = 0;
    try draw(&bench, plain.?, plain_frame, each.?, vertex_buffer, &offset, null);
    try testing.expectEqual(@as(u32, 1), TogetherScene.outputs);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), red.at(32, 32));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), blue.at(32, 32));
    try testing.expectEqual(@as(u32, 3) * together_calls, TogetherScene.calls);

    // Each attachment cleared to its own colour, both ways round: the
    // clears belong to the subpass's attachments in order, whether one
    // part draws them all or a part draws each.
    const own_clears = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
    };
    for ([2]*facet.RenderPass{ pass, plain.? }, [2]*facet.Framebuffer{ frame, plain_frame }) |into, onto| {
        const cleared = try bench.record();
        fb.CmdBeginRenderPass(cleared, &.{ .render_pass = into, .framebuffer = onto, .render_area = area, .clear_value_count = 3, .clear_values = &own_clears }, .@"inline");
        fb.CmdEndRenderPass(cleared);
        try bench.submit();
        try testing.expectEqual(@as(u32, 0xFFFF_0000), red.at(32, 32));
        try testing.expectEqual(@as(u32, 0xFF00_FF00), green.at(32, 32));
        try testing.expectEqual(@as(u32, 0xFF00_00FF), blue.at(32, 32));
    }

    // Each attachment blended by constants of its own, which Vulkan
    // shares between them: white drawn, mixed by the constant colour.
    const by_constant = facet.PipelineColorBlendAttachmentState{
        .blend_enable = true,
        .src_color_blend_factor = .constant_color,
        .dst_color_blend_factor = .zero,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
    };
    const sets = [3][4]f32{ .{ 1, 1, 1, 1 }, .{ 0.5, 0.5, 0.5, 1 }, .{ 0.25, 0.25, 0.25, 1 } };
    const blends: [3]facet.PipelineColorBlendAttachmentState = @splat(by_constant);
    result, const mixed = makePipeline(&bench, .{
        .module = shaders,
        .name = "white",
        .layout = layout,
        .pass = pass,
        .blend = blends[0],
        .second_blend = blends[1],
        .blend_count = 3,
        .attachment_constants = &sets,
    });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, mixed);
    const made = _objects.of(_pipeline.Pipeline, mixed.?);
    try testing.expectEqual(@as(?[4]f32, .{ 0.25, 0.25, 0.25, 1 }), made.mixings[2].constants);
    try draw(&bench, pass, frame, mixed.?, vertex_buffer, &offset, null);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), red.at(32, 32));
    try nearColor(0xFF80_8080, green.at(32, 32), 2);
    try nearColor(0xFF40_4040, blue.at(32, 32), 2);

    // And by what a command set: the one set over all of them, and one
    // attachment's own over that.
    result, const dynamic = makePipeline(&bench, .{
        .module = shaders,
        .name = "white",
        .layout = layout,
        .pass = pass,
        .blend = by_constant,
        .second_blend = by_constant,
        .blend_count = 3,
        .dynamic = &.{.blend_constants},
    });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, dynamic);
    try draw(&bench, pass, frame, dynamic.?, vertex_buffer, &offset, 1);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), red.at(32, 32));
    try nearColor(0xFF40_4040, green.at(32, 32), 2);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), blue.at(32, 32));

    // Refused: a fragment function that writes other than the subpass's
    // colour attachments, either way round.
    result, _ = makePipeline(&bench, .{ .module = shaders, .name = "one", .layout = layout, .pass = pass, .blend_count = 3 });
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    result, _ = makePipeline(&bench, .{ .module = shaders, .name = "four", .layout = layout, .pass = pass, .blend_count = 3 });
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    result, _ = makePipeline(&bench, .{ .module = shaders, .name = "three", .layout = layout, .pass = plain.?, .blend_count = 3 });
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    // And a subpass flag the library has not.
    var odd = info;
    var oddly = together;
    oddly.flags = 1;
    odd.subpasses = @ptrCast(&oddly);
    var refused: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &odd, &refused));
}

test "a device whose fragment programs write the one colour, as the V3D's do: the subpass that asks for several is refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.several_outputs = false;
    defer physical.features.several_outputs = true;
    const descriptions = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const colors = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .general }, .{ .attachment = 1, .layout = .general } };
    const together = facet.SubpassDescription{
        .flags = facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER,
        .color_attachment_count = 2,
        .color_attachments = &colors,
    };
    var refused: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &descriptions, .subpass_count = 1, .subpasses = @ptrCast(&together) }, &refused));
    try testing.expectEqual(@as(?*facet.RenderPass, null), refused);

    // The same subpass without the flag is drawn as it always was, once
    // for each attachment, and a function of several colours is refused
    // the pipeline there.
    const apart = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &colors };
    var plain: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &descriptions, .subpass_count = 1, .subpasses = @ptrCast(&apart) }, &plain));
    defer fb.DestroyRenderPass(device, plain);
    const shaders = try module(&bench, &TogetherScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const result, _ = makePipeline(&bench, .{ .module = shaders, .name = "three", .layout = layout, .pass = plain.?, .blend_count = 2 });
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, result);
    const taken, const drawn = makePipeline(&bench, .{ .module = shaders, .name = "one", .layout = layout, .pass = plain.?, .blend_count = 2 });
    try testing.expectEqual(facet.Result.success, taken);
    fb.DestroyPipeline(device, drawn);
}

test "an input attachment: what one subpass drew read pixel by pixel by the next" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // The first attachment is drawn and then read; the second is only
    // drawn into.
    const first_image, const first_view = try bench.image(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .tiling = .linear,
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT,
    }, false);
    const second = try Picture.of(&bench, 64, 64);

    // An image made without the usage, and ones the usage cannot go with.
    var none: ?*facet.Image = null;
    const plain_image, const plain_view = try bench.image(.{
        .format = .b8g8r8a8_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .tiling = .linear,
        .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT,
    }, false);
    _ = plain_image;
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_INPUT_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED }, &none));
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_INPUT_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &none));
    try testing.expect(none == null);

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
    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 2, .subpasses = &subpasses }, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;

    // A depth attachment read as an input attachment is made since 1.62;
    // one of a format no pixels are kept in is refused all the same.
    var another: ?*facet.RenderPass = null;
    const depth_formats = [2]facet.AttachmentDescription{
        .{ .format = .d16_unorm, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const of_depth = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const reads_depth = facet.SubpassDescription{ .input_attachment_count = 1, .input_attachments = &of_depth, .color_attachment_count = 1, .color_attachments = &to_second };
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &depth_formats, .subpass_count = 1, .subpasses = @ptrCast(&reads_depth) }, &another));
    fb.DestroyRenderPass(device, another);
    var refused: ?*facet.RenderPass = null;
    const odd_formats = [2]facet.AttachmentDescription{
        .{ .format = .r16g16b16a16_sfloat, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &odd_formats, .subpass_count = 1, .subpasses = @ptrCast(&reads_depth) }, &refused));
    try testing.expect(refused == null);

    const frame = try framebuffer(&bench, pass, &.{ first_view, second.view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const shaders = try module(&bench, &Deferred.code);
    defer fb.DestroyShaderModule(device, shaders);

    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    const layouts = [2]*facet.DescriptorSetLayout{ set_layout.?, set_layout.? };
    var sets: [2]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 2, .set_layouts = &layouts }, &sets));
    // The one that is made to be read, and one that is not: the second
    // write is left out, so its slot stays empty.
    const infos = [2]facet.DescriptorImageInfo{ .{ .image_view = first_view }, .{ .image_view = plain_view } };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .input_attachment, .image_info = @ptrCast(&infos[0]) },
        .{ .dst_set = sets[1].?, .dst_binding = 0, .descriptor_type = .input_attachment, .image_info = @ptrCast(&infos[1]) },
    };
    fb.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
    const read_slot = _objects.of(_descriptor.Set, sets[0].?).view.slots[0];
    try testing.expect(read_slot.pointer != null);
    try testing.expect(_objects.of(_descriptor.Set, sets[1].?).view.slots[0].pointer == null);

    const writer_result, const writer = makePipeline(&bench, .{ .module = shaders, .name = "write", .layout = layout, .pass = pass });
    try testing.expectEqual(facet.Result.success, writer_result);
    defer fb.DestroyPipeline(device, writer);
    const reader_result, const reader = makePipeline(&bench, .{ .module = shaders, .name = "read", .layout = layout, .pass = pass, .subpass = 1 });
    try testing.expectEqual(facet.Result.success, reader_result);
    defer fb.DestroyPipeline(device, reader);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(Deferred.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(Deferred.quad))], std.mem.asBytes(&Deferred.quad));
    const values = clears(0xFF00_00FF);
    const offset: u64 = 0;
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };

    var commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &values }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, writer.?);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, reader.?);
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&sets[0]), 0, null);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // What the first subpass drew, and what the second read of it.
    const first = _objects.of(@import("../image/_image.zig").Image, first_image);
    const pitch = first.pitch;
    const pixels = first.data.?;
    try testing.expectEqual(Deferred.written, std.mem.readInt(u32, pixels[8 * pitch + 8 * 4 ..][0..4], .little));
    try testing.expectEqual(Deferred.swapped, second.at(8, 8));
    try testing.expectEqual(Deferred.swapped, second.at(63, 63));
    try testing.expectEqual(Deferred.swapped, second.at(40, 20));

    // The set whose image was not made to be read leaves its slot empty:
    // the function finds nothing and says so.
    commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &values }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, writer.?);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, reader.?);
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&sets[1]), 0, null);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();
    try testing.expectEqual(Deferred.missing, second.at(8, 8));
}

test "a device that reads no attachment, as the V3D reads none: the subpass and the set layout are refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.input_attachments = false;
    defer physical.features.input_attachments = true;

    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .input_attachment };
    var none: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &none));
    try testing.expect(none == null);

    const attachments = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const to_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const to_second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const reads = facet.SubpassDescription{ .input_attachment_count = 1, .input_attachments = &to_first, .color_attachment_count = 1, .color_attachments = &to_second };
    var refused: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&reads) }, &refused));
    try testing.expect(refused == null);
    // A subpass that reads none is made as it was.
    const draws = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = &to_first };
    var made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&draws) }, &made));
    fb.DestroyRenderPass(device, made);
}

test "a buffer binding that is an array: every element reached, each dynamic one shifted its own way" {
    const Pick = struct {
        /// Element by element through `bufferAt` and `storageAt`, which a
        /// binding of more than one buffer needs (since 1.43).
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const out = groups.resources.storage(u32, 0, 1) orelse return;
            if (out.len < 8) return;
            inline for (0..4) |k| {
                const one = groups.resources.bufferAt(u32, 0, 0, k);
                out[k] = if (one) |value| value.* else 0xDEAD;
            }
            if (groups.resources.storageAt(u32, 0, 1, 1)) |second| {
                if (second.len > 0) second[0] = 0x5151;
                out[4] = @intCast(second.len);
            }
            // Past the binding's last element: nothing there.
            out[5] = if (groups.resources.bufferAt(u32, 0, 0, 4) == null) 1 else 0;
            // And its first, which `buffer` reaches as it always did.
            out[6] = if (groups.resources.buffer(u32, 0, 0)) |first| first.* else 0xDEAD;
        }
        const entries = [_]shader.Entry{shader.compute("main", &run)};
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    const picker = try module(&bench, &Pick.code);
    defer fb.DestroyShaderModule(device, picker);
    // Four dynamic buffers in one binding, which is all a set holds, and
    // two plain ones in the next.
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = shader.MAX_DYNAMIC_OFFSETS, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 2, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));

    // Each of the four reads a range of its own, and each has an offset of
    // its own: byte 16k + 4k of the uniform buffer, which holds its own
    // number of four at every one.
    const uniform, const uniform_bytes = try bench.buffer(256, facet.BUFFER_USAGE_UNIFORM_BUFFER);
    const out_buffer, const out_bytes = try bench.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER);
    const in: [*]u32 = @ptrCast(@alignCast(uniform_bytes));
    const out: [*]u32 = @ptrCast(@alignCast(out_bytes));
    for (0..64) |k| in[k] = @intCast(k);
    @memset(out[0..64], 0);
    var uniforms: [shader.MAX_DYNAMIC_OFFSETS]facet.DescriptorBufferInfo = undefined;
    for (&uniforms, 0..) |*info, k| info.* = .{ .buffer = uniform, .offset = k * 16, .range = 16 };
    const storages = [2]facet.DescriptorBufferInfo{
        .{ .buffer = out_buffer, .offset = 0, .range = 64 },
        .{ .buffer = out_buffer, .offset = 128, .range = 32 },
    };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = uniforms.len, .buffer_info = &uniforms },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = storages.len, .buffer_info = &storages },
    };
    fb.UpdateDescriptorSets(device, writes.len, &writes, 0, null);

    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = picker }, .layout = layout };
    var pipelines: [1]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipelines));
    defer fb.DestroyPipeline(device, pipelines[0]);

    var offsets: [shader.MAX_DYNAMIC_OFFSETS]u32 = undefined;
    for (&offsets, 0..) |*shift, k| shift.* = @intCast(k * 4);
    const commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), offsets.len, &offsets);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();

    // Element k read byte 16k + 4k, which holds 4k + k.
    for (0..shader.MAX_DYNAMIC_OFFSETS) |k| try testing.expectEqual(@as(u32, @intCast(k * 5)), out[k]);
    try testing.expectEqual(@as(u32, 8), out[4]);
    try testing.expectEqual(@as(u32, 1), out[5]);
    try testing.expectEqual(@as(u32, 0), out[6]);
    try testing.expectEqual(@as(u32, 0x5151), out[32]);
}

test "dynamic buffer descriptors: one set read from where the bind says, draw after draw" {
    const Reader = struct {
        /// What it was given of the uniform's range, into the storage
        /// buffer's own: both dynamic, so both are the bind's doing.
        fn run(groups: *const shader.Groups) callconv(.c) void {
            const from = groups.resources.buffer([4]u32, 0, 0) orelse return;
            const into = groups.resources.storage(u32, 0, 1) orelse return;
            if (into.len < 4) return;
            into[0..4].* = from.*;
        }
        /// How many of each a function may reach, to say what the shift
        /// left of the ranges.
        fn counted(groups: *const shader.Groups) callconv(.c) void {
            const into = groups.resources.storage(u32, 0, 1) orelse return;
            if (into.len < 2) return;
            into[0] = @intCast(into.len);
            into[1] = if (groups.resources.buffer([32]u32, 0, 0) == null) 0 else 1;
        }
        const entries = [_]shader.Entry{ shader.compute("main", &run), shader.compute("counted", &counted) };
        const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
    };
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.dynamic_descriptors);
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(bench.physical, &properties);
    try testing.expectEqual(@as(u32, shader.MAX_DYNAMIC_OFFSETS), properties.limits.max_descriptor_set_dynamic_buffers);

    const reader = try module(&bench, &Reader.code);
    defer fb.DestroyShaderModule(device, reader);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_buffer_dynamic, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer_dynamic, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .bindings = &bindings }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);

    // A set holds only so many of them.
    var none: ?*facet.DescriptorSetLayout = null;
    const too_many = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .uniform_buffer_dynamic, .descriptor_count = shader.MAX_DYNAMIC_OFFSETS + 1 };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&too_many) }, &none));
    try testing.expect(none == null);

    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));
    const set = sets[0].?;

    // Each dynamic descriptor was told which of the set's offsets shifts
    // it, in the order the bindings run.
    const made = _objects.of(_descriptor.Set, set);
    try testing.expectEqual(@as(u32, 2), made.dynamic_count);
    try testing.expectEqual(@as(u8, 1), made.view.slots[0].dynamic);
    try testing.expectEqual(@as(u8, 2), made.view.slots[1].dynamic);

    const uniform, const uniform_bytes = try bench.buffer(256, facet.BUFFER_USAGE_UNIFORM_BUFFER);
    const out_buffer, const out_bytes = try bench.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER);
    const in: [*]u32 = @ptrCast(@alignCast(uniform_bytes));
    const out: [*]u32 = @ptrCast(@alignCast(out_bytes));
    for (0..64) |k| in[k] = @intCast(100 + k);
    @memset(out[0..64], 0);
    const infos = [2]facet.DescriptorBufferInfo{
        .{ .buffer = uniform, .range = 128 },
        .{ .buffer = out_buffer, .range = 128 },
    };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = set, .dst_binding = 0, .descriptor_type = .uniform_buffer_dynamic, .buffer_info = @ptrCast(&infos[0]) },
        .{ .dst_set = set, .dst_binding = 1, .descriptor_type = .storage_buffer_dynamic, .buffer_info = @ptrCast(&infos[1]) },
    };
    fb.UpdateDescriptorSets(device, writes.len, &writes, 0, null);
    // The write left the slots where they were in the order.
    try testing.expectEqual(@as(u8, 1), made.view.slots[0].dynamic);
    try testing.expectEqual(@as(u8, 2), made.view.slots[1].dynamic);

    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = reader }, .layout = layout };
    var pipelines: [1]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipelines));
    defer fb.DestroyPipeline(device, pipelines[0]);
    const counting = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = reader, .name = "counted" }, .layout = layout };
    var counters: [1]?*facet.Pipeline = undefined;
    try testing.expectEqual(facet.Result.success, fb.CreateComputePipelines(device, null, 1, @ptrCast(&counting), &counters));
    defer fb.DestroyPipeline(device, counters[0]);

    // The same set three times over, each bind with offsets of its own:
    // the uniform read from there, and written there in the output.
    const cases = [3][2]u32{ .{ 0, 0 }, .{ 16, 32 }, .{ 64, 4 } };
    for (cases) |offsets| {
        @memset(out[0..64], 0);
        const commands = try bench.record();
        fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 2, &offsets);
        fb.CmdDispatch(commands, 1, 1, 1);
        try bench.submit();
        const from = offsets[0] / 4;
        const into = offsets[1] / 4;
        for (0..4) |k| try testing.expectEqual(in[from + k], out[into + k]);
        if (into > 0) try testing.expectEqual(@as(u32, 0), out[into - 1]);
    }

    // What is left of a range from the offset is what a function reaches:
    // 128 bytes shifted by 64 leaves 16 of its 32 numbers, and the whole
    // 32 of the uniform's range no longer fit in what is left of it.
    @memset(out[0..64], 0);
    var commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, counters[0].?);
    const far = [2]u32{ 64, 0 };
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 2, &far);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 32), out[0]);
    try testing.expectEqual(@as(u32, 0), out[1]);
    @memset(out[0..64], 0);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, counters[0].?);
    const near = [2]u32{ 0, 64 };
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 2, &near);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    try testing.expectEqual(@as(u32, 16), out[16]);
    try testing.expectEqual(@as(u32, 1), out[17]);

    // Offsets left out are 0: the descriptors are read from where their
    // writes left them.
    @memset(out[0..64], 0);
    commands = try bench.record();
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    try bench.submit();
    for (0..4) |k| try testing.expectEqual(in[k], out[k]);
}

test "a device without dynamic buffer descriptors: the set layout that asks for one is refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.dynamic_descriptors = false;
    defer physical.features.dynamic_descriptors = true;
    var none: ?*facet.DescriptorSetLayout = null;
    for ([2]facet.DescriptorType{ .uniform_buffer_dynamic, .storage_buffer_dynamic }) |kind| {
        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = kind };
        try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &none));
        try testing.expect(none == null);
    }
    // The kinds that are not dynamic are made as they were.
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .uniform_buffer };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &none));
    fb.DestroyDescriptorSetLayout(device, none);
}

// --- 1.33: the depth bias ----------------------------------------------------

/// One frame of the depth bias tests: `first` drawn green with the depth
/// written, then `second` drawn red over it with `biased`, whose bias
/// `set` may give it. What the picture holds after says whether the second
/// draw's depth won.
const BiasFrame = struct {
    pass: *facet.RenderPass,
    frame: *facet.Framebuffer,
    layout: *facet.PipelineLayout,
    buffer: *facet.Buffer,
    bytes: [*]u8,
    plain: *facet.Pipeline,
    biased: *facet.Pipeline,
    first: *const [6][3]f32,
    second: *const [6][3]f32,
    /// What CmdSetDepthBias sets before the second draw, or null for none.
    set: ?_pipeline.Bias = null,
};

fn biasedFrame(bench: *Bench, what: BiasFrame) !void {
    const fb = bench.rig.fb;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const quad_bytes = @sizeOf([6][3]f32);
    @memcpy(what.bytes[0..quad_bytes], std.mem.asBytes(what.first));
    @memcpy(what.bytes[quad_bytes..][0..quad_bytes], std.mem.asBytes(what.second));
    const offset: u64 = 0;
    const clear = clears(0xFF00_00FF);
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = what.pass, .framebuffer = what.frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 2, .clear_values = &clear }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&what.buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, what.plain);
    fb.CmdPushConstants(commands, what.layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &green);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdBindPipeline(commands, .graphics, what.biased);
    fb.CmdPushConstants(commands, what.layout, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
    if (what.set) |bias| fb.CmdSetDepthBias(commands, bias.constant, bias.clamp, bias.slope);
    fb.CmdDraw(commands, 6, 1, 6, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();
}

test "a depth bias: the pipeline's and the command's, by the constant and the slope, held inside the clamp" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const picture = try Picture.of(&bench, 64, 64);
    _, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT,
    }, true);
    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const frame = try framebuffer(&bench, pass, &.{ picture.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);

    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    const base = PipelineState{ .module = flat, .layout = layout, .pass = pass, .depth = tested };
    const plain_result, const plain = makePipeline(&bench, base);
    try testing.expectEqual(facet.Result.success, plain_result);
    defer fb.DestroyPipeline(device, plain);
    try testing.expect(!_objects.of(_pipeline.Pipeline, plain.?).biased);

    // Three pipelines of the same draw: one lifted towards the eye by
    // three of the smallest differences the depth holds, one pushed away
    // by a tenth of the range, and the same held inside a twentieth.
    var state = base;
    state.raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = -3 };
    const nearer_result, const nearer = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, nearer_result);
    defer fb.DestroyPipeline(device, nearer);
    const made = _objects.of(_pipeline.Pipeline, nearer.?);
    try testing.expect(made.biased);
    try testing.expectEqual(@as(f32, -3), made.bias.?.constant);
    try testing.expectEqual(@as(f32, 0), made.bias.?.clamp);
    try testing.expectEqual(@as(f32, 0), made.bias.?.slope);

    state.raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 0.11 * 65535 };
    const further_result, const further = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, further_result);
    defer fb.DestroyPipeline(device, further);

    state.raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 0.11 * 65535, .depth_bias_clamp = 0.05 };
    const held_result, const held = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, held_result);
    defer fb.DestroyPipeline(device, held);

    // The numbers left to a command, and the two slopes.
    state.raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = 100 };
    state.dynamic = &.{.depth_bias};
    const dynamic_result, const dynamic = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, dynamic_result);
    defer fb.DestroyPipeline(device, dynamic);
    const dynamic_made = _objects.of(_pipeline.Pipeline, dynamic.?);
    try testing.expect(dynamic_made.biased);
    try testing.expect(dynamic_made.bias == null);

    state.dynamic = &.{};
    state.raster = .{ .depth_bias_enable = true, .depth_bias_slope_factor = -1 };
    const up_result, const up_slope = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, up_result);
    defer fb.DestroyPipeline(device, up_slope);
    state.raster = .{ .depth_bias_enable = true, .depth_bias_slope_factor = 1 };
    const down_result, const down_slope = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, down_result);
    defer fb.DestroyPipeline(device, down_slope);

    // A quad over the whole picture at one depth, another a tenth nearer,
    // and one sloped from 0.25 at the left to 0.75 at the right.
    const level = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 } };
    const closer = [6][3]f32{ .{ -1, -1, 0.4 }, .{ 1, -1, 0.4 }, .{ -1, 1, 0.4 }, .{ -1, 1, 0.4 }, .{ 1, -1, 0.4 }, .{ 1, 1, 0.4 } };
    const sloped = [6][3]f32{ .{ -1, -1, 0.25 }, .{ 1, -1, 0.75 }, .{ -1, 1, 0.25 }, .{ -1, 1, 0.25 }, .{ 1, -1, 0.75 }, .{ 1, 1, 0.75 } };
    const vertex_buffer, const vertex_bytes = try bench.buffer(2 * @sizeOf([6][3]f32), facet.BUFFER_USAGE_VERTEX_BUFFER);
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    var what = BiasFrame{
        .pass = pass,
        .frame = frame,
        .layout = layout,
        .buffer = vertex_buffer,
        .bytes = vertex_bytes,
        .plain = plain.?,
        .biased = plain.?,
        .first = &level,
        .second = &level,
    };

    // The same depth drawn twice, tested LESS: without a bias the second
    // draw is nowhere nearer, so the first still shows.
    try biasedFrame(&bench, what);
    try testing.expectEqual(green, picture.at(16, 16));
    try testing.expectEqual(green, picture.at(48, 48));

    // Lifted by three units it is nearer everywhere.
    what.biased = nearer.?;
    try biasedFrame(&bench, what);
    try testing.expectEqual(red, picture.at(16, 16));
    try testing.expectEqual(red, picture.at(48, 48));

    // A tenth of the range pushes a draw that was a tenth nearer behind
    // what is there; held inside a twentieth, it is still in front.
    what.second = &closer;
    what.biased = further.?;
    try biasedFrame(&bench, what);
    try testing.expectEqual(green, picture.at(16, 16));
    what.biased = held.?;
    try biasedFrame(&bench, what);
    try testing.expectEqual(red, picture.at(16, 16));

    // What the command sets is what a dynamic pipeline uses, and the
    // pipeline's own 100 units are not.
    what.second = &level;
    what.biased = dynamic.?;
    what.set = .{ .constant = -3 };
    try biasedFrame(&bench, what);
    try testing.expectEqual(red, picture.at(16, 16));
    what.set = .{ .constant = 3 };
    try biasedFrame(&bench, what);
    try testing.expectEqual(green, picture.at(16, 16));
    what.set = null;

    // The slope: the quad falls half the range over 64 pixels, so one of
    // its slope is 512 units - enough either way.
    what.first = &sloped;
    what.second = &sloped;
    what.biased = up_slope.?;
    try biasedFrame(&bench, what);
    try testing.expectEqual(red, picture.at(16, 16));
    try testing.expectEqual(red, picture.at(48, 48));
    what.biased = down_slope.?;
    try biasedFrame(&bench, what);
    try testing.expectEqual(green, picture.at(16, 16));
    try testing.expectEqual(green, picture.at(48, 48));
}

test "a device that moves no depth, as the V3D moves none: the pipeline that asks for a bias is refused" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    physical.features.depth_bias = false;
    defer physical.features.depth_bias = true;
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(!features.depth_bias);

    const pass = try renderPass(&bench, .clear, true);
    defer fb.DestroyRenderPass(device, pass);
    const flat = try module(&bench, &Flat.code);
    defer fb.DestroyShaderModule(device, flat);
    const layout = try pipelineLayout(&bench, &.{}, 4);
    defer fb.DestroyPipelineLayout(device, layout);
    var state = PipelineState{ .module = flat, .layout = layout, .pass = pass };
    state.raster = .{ .depth_bias_enable = true, .depth_bias_constant_factor = -3 };
    const refused, const none = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.error_feature_not_present, refused);
    try testing.expect(none == null);
    // Without the bias it is made, and a command that sets one is recorded
    // whatever the device: nothing of it reaches a pipeline that adds none.
    state.raster = .{};
    const result, const pipeline = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, pipeline);
    const commands = try bench.record();
    fb.CmdSetDepthBias(commands, -3, 0, 0);
    try bench.submit();
}

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

    // There is no geometry shader, so neither statistic of one is counted:
    // since 1.43 a pool may ask for them all the same, and they read 0, as
    // Vulkan has a statistic of a stage that never ran.
    try testing.expectEqual(facet.Result.success, fb.CreateQueryPool(device, &.{
        .query_type = .pipeline_statistics,
        .query_count = 1,
        .pipeline_statistics = facet.QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_VERTICES | facet.QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_INVOCATIONS | facet.QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_PRIMITIVES,
    }, &made));
    try testing.expect(made != null);
    {
        // Nothing drawn between the query's begin and its end, so every
        // one of the three is 0; the two of a geometry shader stay 0
        // whatever runs.
        const commands = try bench.record();
        fb.CmdResetQueryPool(commands, made.?, 0, 1);
        fb.CmdBeginQuery(commands, made.?, 0, 0);
        fb.CmdEndQuery(commands, made.?, 0);
        try bench.submit();
        var values: [3]u64 = @splat(0xDEAD);
        try testing.expectEqual(facet.Result.success, fb.GetQueryPoolResults(device, made.?, 0, 1, @sizeOf(@TypeOf(values)), &values, @sizeOf(@TypeOf(values)), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT));
        try testing.expectEqual([3]u64{ 0, 0, 0 }, values);
    }
    fb.DestroyQueryPool(device, made);
    made = null;
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

    // The depth wanted again after another subpass is kept in the
    // image's rows and read back (since 1.52), so the pass is made - but
    // this depth image is transient and has no rows to keep it in, which
    // the framebuffer says.
    const other_depth = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = both[0..1], .depth_stencil_attachment = &depth };
    const apart = [3]facet.SubpassDescription{ drawn_on, into_both, other_depth };
    var shared: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 3, .subpasses = &apart }, &shared));
    defer fb.DestroyRenderPass(device, shared);
    {
        const plan = _objects.of(_render.RenderPass, shared.?);
        // The first subpass's part keeps its depth; the last reads it in.
        try testing.expect(plan.parts[plan.subpasses[0].first_part].stores_depth);
        try testing.expect(plan.parts[plan.subpasses[2].first_part].loads_depth);
        var over: ?*facet.Framebuffer = null;
        try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateFramebuffer(device, &.{ .render_pass = shared.?, .attachment_count = 3, .attachments = &[3]*facet.ImageView{ first.view, second.view, depth_view }, .width = 64, .height = 64 }, &over));
    }
    // An attachment twice in a subpass.
    var none: ?*facet.RenderPass = null;
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

test "a depth attachment shared by two subpasses with another in between: kept in its rows and read back" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const first = try Picture.of(&bench, 64, 64);
    const second = try Picture.of(&bench, 64, 64);
    // Not transient: the depth has to have rows to be kept in.
    _, const depth_view = try bench.image(.{
        .format = .d16_unorm,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT,
    }, false);
    const attachments = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        // Neither op asks for anything: the sharing alone makes the pass
        // keep it between the subpasses.
        .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
    };
    const on_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const on_second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const depth = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
    const subpasses = [3]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &depth },
        // In between, in tiles of its own and with no depth at all.
        .{ .color_attachment_count = 1, .color_attachments = &on_second },
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &depth },
    };
    var pass_made: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 3, .subpasses = &subpasses }, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;
    const plan = _objects.of(_render.RenderPass, pass);
    // Three parts, none of them joined: the first keeps its depth and the
    // last reads it in, though the attachment's own ops ask for neither.
    try testing.expectEqual(@as(u32, 3), plan.part_count);
    try testing.expect(plan.parts[0].stores_depth);
    try testing.expect(!plan.parts[0].loads_depth);
    try testing.expect(plan.parts[2].loads_depth);
    try testing.expect(!plan.parts[2].stores_depth);
    try testing.expect(!plan.subpasses[1].joined and !plan.subpasses[2].joined);

    const frame = try framebuffer(&bench, pass, &.{ first.view, second.view, depth_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const shaders = try module(&bench, &SubpassScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    var result, const red = makePipeline(&bench, .{ .module = shaders, .name = "red", .layout = layout, .pass = pass, .depth = tested });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, red);
    result, const between = makePipeline(&bench, .{ .module = shaders, .name = "green", .layout = layout, .pass = pass, .subpass = 1 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, between);
    result, const last = makePipeline(&bench, .{ .module = shaders, .name = "green", .layout = layout, .pass = pass, .subpass = 2, .depth = tested });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, last);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(SubpassScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(SubpassScene.quad))], std.mem.asBytes(&SubpassScene.quad));
    const offset: u64 = 0;
    const values = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .depth_stencil = .{ .depth = 1 } },
    };
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };

    // The last subpass's quad, at `far` eighths: drawn only where the
    // depth the first subpass left lets it through. The first draws at a
    // quarter, two eighths.
    const frameOf = struct {
        fn run(on: *Bench, into: *facet.RenderPass, onto: *facet.Framebuffer, pipelines: [3]*facet.Pipeline, buffer: *facet.Buffer, where: *const u64, far: u32) !void {
            const commands = try on.record();
            const dl = on.rig.fb;
            dl.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = area, .clear_value_count = 3, .clear_values = &values }, .@"inline");
            dl.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(where));
            dl.CmdBindPipeline(commands, .graphics, pipelines[0]);
            dl.CmdDraw(commands, 6, 1, 0, 2);
            dl.CmdNextSubpass(commands, .@"inline");
            dl.CmdBindPipeline(commands, .graphics, pipelines[1]);
            dl.CmdDraw(commands, 6, 1, 0, 0);
            dl.CmdNextSubpass(commands, .@"inline");
            dl.CmdBindPipeline(commands, .graphics, pipelines[2]);
            dl.CmdDraw(commands, 6, 1, 0, far);
            dl.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.run;

    // Farther than the quarter the first subpass wrote: nothing of it is
    // drawn, so the first picture is still red. Were the depth not kept,
    // the last subpass would start from a cleared one and the green would
    // win everywhere.
    try frameOf(&bench, pass, frame, .{ red.?, between.?, last.? }, vertex_buffer, &offset, 6);
    try testing.expectEqual(SubpassScene.red, first.at(32, 32));
    try testing.expectEqual(SubpassScene.red, first.at(1, 62));
    // The subpass in between drew into the other picture all the same.
    try testing.expectEqual(SubpassScene.green, second.at(32, 32));

    // Nearer than it: drawn, so the depth read back is a depth and not
    // simply a wall.
    try frameOf(&bench, pass, frame, .{ red.?, between.?, last.? }, vertex_buffer, &offset, 1);
    try testing.expectEqual(SubpassScene.green, first.at(32, 32));
    try testing.expectEqual(SubpassScene.green, first.at(1, 62));
}

test "a stencil shared by two subpasses with another in between: marked in the first, tested in the last" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const physical = _objects.of(_instance.PhysicalDevice, bench.physical);
    const first = try Picture.of(&bench, 64, 64);
    const second = try Picture.of(&bench, 64, 64);
    _, const stencil_view = try bench.image(.{
        .format = .s8_uint,
        .extent = .{ .width = 64, .height = 64 },
        .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT,
    }, false);
    const attachments = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .s8_uint, .stencil_load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
    };
    const on_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .general }};
    const on_second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .general }};
    const stencil = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
    const subpasses = [3]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &stencil },
        .{ .color_attachment_count = 1, .color_attachments = &on_second },
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &stencil },
    };
    const info = facet.RenderPassCreateInfo{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 3, .subpasses = &subpasses };
    var pass_made: ?*facet.RenderPass = null;

    // A device that keeps no stencil in an image's rows cannot share one
    // between two subpasses of different tiles.
    physical.features.stored_stencil = false;
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &info, &pass_made));
    physical.features.stored_stencil = true;

    try testing.expectEqual(facet.Result.success, fb.CreateRenderPass(device, &info, &pass_made));
    defer fb.DestroyRenderPass(device, pass_made);
    const pass = pass_made.?;
    const plan = _objects.of(_render.RenderPass, pass);
    try testing.expect(plan.parts[0].stores_stencil and !plan.parts[0].loads_stencil);
    try testing.expect(plan.parts[2].loads_stencil and !plan.parts[2].stores_stencil);

    const frame = try framebuffer(&bench, pass, &.{ first.view, second.view, stencil_view }, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const shaders = try module(&bench, &SubpassScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const layout = try pipelineLayout(&bench, &.{}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    const marked: u32 = 3;
    const marks = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = marked };
    const only_marked = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = marked };
    var result, const mark = makePipeline(&bench, .{
        .module = shaders,
        .name = "red",
        .layout = layout,
        .pass = pass,
        .depth = .{ .stencil_test_enable = true, .front = marks, .back = marks },
        .dynamic = &.{.scissor},
    });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, mark);
    result, const between = makePipeline(&bench, .{ .module = shaders, .name = "green", .layout = layout, .pass = pass, .subpass = 1 });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, between);
    result, const last = makePipeline(&bench, .{
        .module = shaders,
        .name = "green",
        .layout = layout,
        .pass = pass,
        .subpass = 2,
        .depth = .{ .stencil_test_enable = true, .front = only_marked, .back = only_marked },
    });
    try testing.expectEqual(facet.Result.success, result);
    defer fb.DestroyPipeline(device, last);

    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(SubpassScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(SubpassScene.quad))], std.mem.asBytes(&SubpassScene.quad));
    const offset: u64 = 0;
    const values = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };
    const area = facet.Rect2D{ .extent = .{ .width = 64, .height = 64 } };
    const left_half = facet.Rect2D{ .extent = .{ .width = 32, .height = 64 } };

    // The first subpass marks and draws the left half; the last draws
    // over the whole picture but only where the mark is.
    const commands = try bench.record();
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 3, .clear_values = &values }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, mark.?);
    fb.CmdSetScissor(commands, 0, 1, @ptrCast(&left_half));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, between.?);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, last.?);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    try bench.submit();

    // Green where the mark the first subpass left is, red where it drew
    // nothing to mark - so the stencil came back through the subpass in
    // between.
    try testing.expectEqual(SubpassScene.green, first.at(16, 32));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), first.at(48, 32));
    try testing.expectEqual(SubpassScene.green, second.at(48, 32));
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

    /// Which cube as well: the instance is the face, and the cube every
    /// sixth of it.
    fn cubeArray(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const a = p[0];
            const b = p[1];
            const towards: [3]f32 = switch (vertices.instance % 6) {
                0 => .{ 1, -b, -a },
                1 => .{ -1, -b, a },
                2 => .{ a, 1, b },
                3 => .{ a, -1, -b },
                4 => .{ a, -b, 1 },
                else => .{ -a, -b, -1 },
            };
            vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], 0, 1, towards[0], towards[1], towards[2], @floatFromInt(vertices.instance / 6) };
        }
    }

    fn volume(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            out(vertices, k).* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2, (@as(f32, @floatFromInt(vertices.instance)) + 0.5) / 4 };
        }
    }

    /// The same quad, its coordinates running a quarter of the texture
    /// outside it either way: what a sampler's edges are seen by.
    fn wide(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2 * 1.5 - 0.25, (p[1] + 1) / 2 * 1.5 - 0.25 };
        }
    }

    const nearest = facet.texture.Sampling{ .filter = .nearest };
    const entries = [_]shader.Entry{
        shader.vertex("flat", &flat, 2),
        shader.fixedFragment("flat", .{ .kind = .texture, .sampling = nearest }),
        // The same shapes read through the sampler bound beside the
        // texture (since 1.49).
        shader.vertex("arrayby", &array, 3),
        shader.fixedFragment("arrayby", .{ .kind = .texture_array_sampled }),
        shader.vertex("cubeby", &cube, 3),
        shader.fixedFragment("cubeby", .{ .kind = .texture_cube_sampled }),
        shader.vertex("volumeby", &volume, 3),
        shader.fixedFragment("volumeby", .{ .kind = .texture_3d_sampled }),
        // An array of cubes read through the sampler too (since 1.53):
        // four varyings, the fourth which cube.
        shader.vertex("cubesby", &cubeArray, 4),
        shader.fixedFragment("cubesby", .{ .kind = .texture_cube_array_sampled }),
        shader.vertex("wideby", &wide, 2),
        shader.fixedFragment("wideby", .{ .kind = .texture_sampled }),
        shader.vertex("array", &array, 3),
        shader.fixedFragment("array", .{ .kind = .texture_array, .sampling = nearest }),
        shader.vertex("cube", &cube, 3),
        shader.fixedFragment("cube", .{ .kind = .texture_cube, .sampling = nearest }),
        shader.vertex("cubes", &cubeArray, 4),
        shader.fixedFragment("cubes", .{ .kind = .texture_cube_array, .sampling = nearest }),
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

test "textures of layers: arrays, cube maps, 3D, copied a layer at a time; compressed and float ones sampled through a form of another format" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;
    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const side16 = facet.Extent3D{ .width = 16, .height = 16 };

    const refused = [_]facet.ImageCreateInfo{
        .{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 2, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT },
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

    // A 3D image's depth may be any number since 1.46, and it may have
    // levels: each slice's own, with half the slices at each level.
    for ([_]facet.ImageCreateInfo{
        .{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 3 }, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 4 }, .mip_levels = 2, .usage = usage },
        .{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 6 }, .mip_levels = 5, .usage = usage },
    }) |info| {
        var made: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.success, fb.CreateImage(device, &info, &made));
        fb.DestroyImage(device, made);
    }

    const array_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 3, .usage = usage | facet.IMAGE_USAGE_TRANSFER_SRC }, false);
    const cube_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 6, .usage = usage }, false);
    const volume_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 4 }, .usage = usage }, false);
    const into_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 2, .usage = usage }, false);
    const cubes_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 12, .usage = usage }, false);
    const packed_image = try bench.bareImage(.{ .format = .bc1_rgba_unorm_block, .extent = side16, .usage = usage }, false);
    const etc_image = try bench.bareImage(.{ .format = .etc2_r8g8b8a8_unorm_block, .extent = .{ .width = 4, .height = 4 }, .usage = usage }, false);
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
        // An array of cubes wants an image of cubes, a multiple of six
        // layers of it, and a first layer that begins one.
        .{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array },
        .{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .layer_count = 4 } },
        .{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .base_array_layer = 2, .layer_count = 6 } },
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
    const cubes_view = try bench.viewOf(.{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array });
    const second_view = try bench.viewOf(.{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .base_array_layer = 6, .layer_count = 6 } });
    const packed_view = try bench.viewOf(.{ .image = packed_image, .format = .bc1_rgba_unorm_block });
    const etc_view = try bench.viewOf(.{ .image = etc_image, .format = .etc2_r8g8b8a8_unorm_block });
    const half_view = try bench.viewOf(.{ .image = half_image, .format = .r16g16b16a16_sfloat });

    // Six stacks of texels one after another, the most any image takes.
    const stack_bytes = 16 * 16 * 4;
    const staging, const staged = try bench.buffer(stack_bytes * 6 + 288, facet.BUFFER_USAGE_TRANSFER_SRC);
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
    // One ETC2 block with alpha: eight bytes of EAC alpha - a base of 255,
    // a multiplier of 1 and every index 7, which clamps to opaque - and
    // eight of colour in the individual mode, the first subblock red and
    // the second blue, every index 0, which is the +2 of table 0.
    const etc_at = halves_at + 128;
    staged[etc_at..][0..16].* = .{ 0xFF, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00 };

    const whole = facet.BufferImageCopy{ .image_subresource = .{ .layer_count = 3 }, .image_extent = side16 };
    const slices = facet.BufferImageCopy{ .image_extent = .{ .width = 16, .height = 16, .depth = 4 } };
    var faces: [6]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*face, k| face.* = .{ .buffer_offset = k * stack_bytes, .image_subresource = .{ .base_array_layer = @intCast(k) }, .image_extent = side16 };
    const blocks = facet.BufferImageCopy{ .buffer_offset = blocks_at, .image_extent = side16 };
    const etc = facet.BufferImageCopy{ .buffer_offset = etc_at, .image_extent = .{ .width = 4, .height = 4 } };
    // The twelve faces of two cubes: the second cube takes the stacks of
    // the first backwards, so that its faces are told apart from them.
    var cubes: [12]facet.BufferImageCopy = undefined;
    for (&cubes, 0..) |*face, k| face.* = .{
        .buffer_offset = (if (k < 6) k else 11 - k) * stack_bytes,
        .image_subresource = .{ .base_array_layer = @intCast(k) },
        .image_extent = side16,
    };
    const halves = facet.BufferImageCopy{ .buffer_offset = halves_at, .image_extent = .{ .width = 4, .height = 4 } };
    const layer_copy = facet.ImageCopy{ .src_subresource = .{ .base_array_layer = 2 }, .dst_subresource = .{ .base_array_layer = 1 }, .extent = side16 };
    const read_region = facet.BufferImageCopy{ .image_subresource = .{ .base_array_layer = 1, .layer_count = 2 }, .image_extent = side16 };
    _, const read_back = try bench.buffer(stack_bytes * 2, facet.BUFFER_USAGE_TRANSFER_DST);
    const read_buffer = bench.buffers[bench.buffer_count - 1];

    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, array_image, .transfer_dst_optimal, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, staging, cube_image, .transfer_dst_optimal, 6, &faces);
    fb.CmdCopyBufferToImage(commands, staging, volume_image, .transfer_dst_optimal, 1, @ptrCast(&slices));
    fb.CmdCopyBufferToImage(commands, staging, cubes_image, .transfer_dst_optimal, 12, &cubes);
    fb.CmdCopyBufferToImage(commands, staging, packed_image, .transfer_dst_optimal, 1, @ptrCast(&blocks));
    fb.CmdCopyBufferToImage(commands, staging, etc_image, .transfer_dst_optimal, 1, @ptrCast(&etc));
    fb.CmdCopyBufferToImage(commands, staging, half_image, .transfer_dst_optimal, 1, @ptrCast(&halves));
    fb.CmdCopyImage(commands, array_image, .general, into_image, .general, 1, @ptrCast(&layer_copy));
    fb.CmdCopyImageToBuffer(commands, array_image, .general, read_buffer, 1, @ptrCast(&read_region));
    try bench.submit();
    try testing.expectEqualSlices(u8, &LayerScene.texel(1, 8, 0), read_back[8 * 4 ..][0..4]);
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
        // An array of cubes: the instance is the face, and every sixth of
        // it the cube. The second cube's faces carry the first cube's
        // stacks backwards.
        .{ .run = .{ .view = cubes_view, .name = "cubes", .instance = 0 }, .layer = 0 },
        .{ .run = .{ .view = cubes_view, .name = "cubes", .instance = 4 }, .layer = 4 },
        .{ .run = .{ .view = cubes_view, .name = "cubes", .instance = 6 }, .layer = 5 },
        .{ .run = .{ .view = cubes_view, .name = "cubes", .instance = 9 }, .layer = 2 },
        // Past the last cube: the last.
        .{ .run = .{ .view = cubes_view, .name = "cubes", .instance = 12 }, .layer = 5 },
        // A view that begins at the second cube: its cube 0 is that one.
        .{ .run = .{ .view = second_view, .name = "cubes", .instance = 1 }, .layer = 4 },
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
    // An ETC2 block is unpacked as it is copied in, so an 8888 form reads
    // it: red on the left of the block and blue on the right.
    try draw(&bench, .{ .view = etc_view, .name = "flat", .instance = 0 }, layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0202), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF02_02FF), picture.at(56, 56));
}

test "the shapes past 2D read through a sampler, an array of cubes among them, and a sampler the set layout holds" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.samplers);
    try testing.expect(features.immutable_samplers);

    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const side16 = facet.Extent3D{ .width = 16, .height = 16 };
    const array_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .extent = side16, .array_layers = 3, .usage = usage }, false);
    const cube_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 6, .usage = usage }, false);
    const volume_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .image_type = .@"3d", .extent = .{ .width = 16, .height = 16, .depth = 4 }, .usage = usage }, false);
    // Two cubes, twelve layers (since 1.53).
    const cubes_image = try bench.bareImage(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = side16, .array_layers = 12, .usage = usage }, false);
    const array_view = try bench.viewOf(.{ .image = array_image, .format = .r8g8b8a8_unorm, .view_type = .@"2d_array" });
    const cube_view = try bench.viewOf(.{ .image = cube_image, .format = .r8g8b8a8_unorm, .view_type = .cube });
    const volume_view = try bench.viewOf(.{ .image = volume_image, .format = .r8g8b8a8_unorm, .view_type = .@"3d" });
    const cubes_view = try bench.viewOf(.{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array });
    const second_view = try bench.viewOf(.{ .image = cubes_image, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .base_array_layer = 6, .layer_count = 6 } });
    const flat_view = try bench.viewOf(.{ .image = array_image, .format = .r8g8b8a8_unorm, .subresource_range = .{ .base_array_layer = 0, .layer_count = 1 } });

    const stack_bytes = 16 * 16 * 4;
    const staging, const staged = try bench.buffer(stack_bytes * 6, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..6) |layer| for (0..16) |y| for (0..16) |x| {
        staged[layer * stack_bytes + (y * 16 + x) * 4 ..][0..4].* = LayerScene.texel(layer, x, y);
    };
    const whole = facet.BufferImageCopy{ .image_subresource = .{ .layer_count = 3 }, .image_extent = side16 };
    const slices = facet.BufferImageCopy{ .image_extent = .{ .width = 16, .height = 16, .depth = 4 } };
    var faces: [6]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*face, k| face.* = .{ .buffer_offset = k * stack_bytes, .image_subresource = .{ .base_array_layer = @intCast(k) }, .image_extent = side16 };
    // The twelve faces of two cubes, the second cube taking the first's
    // stacks backwards, so that its faces are told apart from them.
    var cubes: [12]facet.BufferImageCopy = undefined;
    for (&cubes, 0..) |*face, k| face.* = .{
        .buffer_offset = (if (k < 6) k else 11 - k) * stack_bytes,
        .image_subresource = .{ .base_array_layer = @intCast(k) },
        .image_extent = side16,
    };
    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, array_image, .transfer_dst_optimal, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, staging, cube_image, .transfer_dst_optimal, 6, &faces);
    fb.CmdCopyBufferToImage(commands, staging, volume_image, .transfer_dst_optimal, 1, @ptrCast(&slices));
    fb.CmdCopyBufferToImage(commands, staging, cubes_image, .transfer_dst_optimal, 12, &cubes);
    try bench.submit();

    // Two samplers that read the edges differently, and tell each other
    // apart past the texture: the border's white against the far side.
    var edged: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .border_color = .float_opaque_white,
    }, &edged));
    defer fb.DestroySampler(device, edged);
    var tiled: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{ .mag_filter = .nearest, .min_filter = .nearest }, &tiled));
    defer fb.DestroySampler(device, tiled);

    // One layout whose sampler is written with the set, and one that holds
    // the bordered sampler of its own (since 1.49).
    var written_layout: ?*facet.DescriptorSetLayout = null;
    const written = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&written) }, &written_layout));
    defer fb.DestroyDescriptorSetLayout(device, written_layout);
    var held_layout: ?*facet.DescriptorSetLayout = null;
    const held = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT, .immutable_samplers = @ptrCast(&edged) };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&held) }, &held_layout));
    defer fb.DestroyDescriptorSetLayout(device, held_layout);

    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var written_set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&written_layout) }, &written_set));
    var held_set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&held_layout) }, &held_set));

    const shaders = try module(&bench, &LayerScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const written_pipes = try pipelineLayout(&bench, &.{written_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, written_pipes);
    const held_pipes = try pipelineLayout(&bench, &.{held_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, held_pipes);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const picture = try Picture.of(&bench, 64, 64);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const vertex_buffer, const vertex_bytes = try bench.buffer(@sizeOf(@TypeOf(LayerScene.quad)), facet.BUFFER_USAGE_VERTEX_BUFFER);
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(LayerScene.quad))], std.mem.asBytes(&LayerScene.quad));
    const offset: u64 = 0;
    const black = clears(0xFF00_0000);

    const Run = struct {
        view: *facet.ImageView,
        sampler: ?*facet.Sampler,
        name: [*:0]const u8,
        instance: u32,
        set: *[1]?*facet.DescriptorSet,
        layout: *facet.PipelineLayout,
    };
    const draw = struct {
        fn draw(on: *Bench, run: Run, into: *facet.RenderPass, into_frame: *facet.Framebuffer, code_module: *facet.ShaderModule, vertices: *facet.Buffer, first: *const u64, clear_values: *const [2]facet.ClearValue) !void {
            const f = on.rig.fb;
            const image_info = facet.DescriptorImageInfo{ .sampler = run.sampler, .image_view = run.view };
            const write = facet.WriteDescriptorSet{ .dst_set = run.set[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&image_info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const result, const pipeline = makePipeline(on, .{ .module = code_module, .name = run.name, .layout = run.layout, .pass = into });
            try testing.expectEqual(facet.Result.success, result);
            defer f.DestroyPipeline(on.device, pipeline);
            const recording = try on.record();
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = into_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = clear_values }, .@"inline");
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdBindDescriptorSets(recording, .graphics, run.layout, 0, 1, @ptrCast(run.set), 0, null);
            f.CmdBindPipeline(recording, .graphics, pipeline.?);
            f.CmdDraw(recording, 6, 1, 0, run.instance);
            f.CmdEndRenderPass(recording);
            try on.submit();
        }
    }.draw;

    // The three shapes read through a sampler read what the forms built
    // for them read: the layer, the face or the slice the instance names.
    const shapes = [_]struct { run: Run, layer: u32 }{
        .{ .run = .{ .view = array_view, .sampler = tiled, .name = "arrayby", .instance = 0, .set = &written_set, .layout = written_pipes }, .layer = 0 },
        .{ .run = .{ .view = array_view, .sampler = tiled, .name = "arrayby", .instance = 2, .set = &written_set, .layout = written_pipes }, .layer = 2 },
        // Past the last layer: the last, as `texture_array` has it.
        .{ .run = .{ .view = array_view, .sampler = tiled, .name = "arrayby", .instance = 9, .set = &written_set, .layout = written_pipes }, .layer = 2 },
        .{ .run = .{ .view = cube_view, .sampler = tiled, .name = "cubeby", .instance = 0, .set = &written_set, .layout = written_pipes }, .layer = 0 },
        .{ .run = .{ .view = cube_view, .sampler = tiled, .name = "cubeby", .instance = 3, .set = &written_set, .layout = written_pipes }, .layer = 3 },
        .{ .run = .{ .view = cube_view, .sampler = tiled, .name = "cubeby", .instance = 5, .set = &written_set, .layout = written_pipes }, .layer = 5 },
        .{ .run = .{ .view = volume_view, .sampler = tiled, .name = "volumeby", .instance = 0, .set = &written_set, .layout = written_pipes }, .layer = 0 },
        .{ .run = .{ .view = volume_view, .sampler = tiled, .name = "volumeby", .instance = 3, .set = &written_set, .layout = written_pipes }, .layer = 3 },
        // An array of cubes through the sampler (since 1.53): the
        // instance is the face, and every sixth of it the cube.
        .{ .run = .{ .view = cubes_view, .sampler = tiled, .name = "cubesby", .instance = 0, .set = &written_set, .layout = written_pipes }, .layer = 0 },
        .{ .run = .{ .view = cubes_view, .sampler = tiled, .name = "cubesby", .instance = 4, .set = &written_set, .layout = written_pipes }, .layer = 4 },
        .{ .run = .{ .view = cubes_view, .sampler = tiled, .name = "cubesby", .instance = 6, .set = &written_set, .layout = written_pipes }, .layer = 5 },
        .{ .run = .{ .view = cubes_view, .sampler = tiled, .name = "cubesby", .instance = 9, .set = &written_set, .layout = written_pipes }, .layer = 2 },
        // Past the last cube: the last, as `texture_cube_array` has it.
        .{ .run = .{ .view = cubes_view, .sampler = tiled, .name = "cubesby", .instance = 12, .set = &written_set, .layout = written_pipes }, .layer = 5 },
        // A view that begins at the second cube: its cube 0 is that one.
        .{ .run = .{ .view = second_view, .sampler = tiled, .name = "cubesby", .instance = 1, .set = &written_set, .layout = written_pipes }, .layer = 4 },
    };
    for (shapes) |each| {
        try draw(&bench, each.run, pass, frame, shaders, vertex_buffer, &offset, &black);
        try testing.expectEqual(LayerScene.colorOf(each.layer, false, false), picture.at(8, 8));
        try testing.expectEqual(LayerScene.colorOf(each.layer, true, true), picture.at(56, 56));
    }

    // A form with no sampler beside the texture still says so.
    try draw(&bench, .{ .view = array_view, .sampler = null, .name = "arrayby", .instance = 0, .set = &written_set, .layout = written_pipes }, pass, frame, shaders, vertex_buffer, &offset, &black);
    try testing.expectEqual(shader.missing, picture.at(32, 32));

    // The quad whose coordinates run a quarter outside the texture, with
    // the tiling sampler written into the set: the far side of the
    // texture, which is the corner furthest from (0, 0).
    const far = LayerScene.colorOf(0, true, true);
    const white: u32 = 0xFFFF_FFFF;
    try draw(&bench, .{ .view = flat_view, .sampler = tiled, .name = "wideby", .instance = 0, .set = &written_set, .layout = written_pipes }, pass, frame, shaders, vertex_buffer, &offset, &black);
    try testing.expectEqual(far, picture.at(4, 4));
    // The same drawn through the layout that holds the bordered sampler,
    // written with the tiling one: the layout's wins, so the border is
    // read past the edge and the write changed nothing.
    try draw(&bench, .{ .view = flat_view, .sampler = tiled, .name = "wideby", .instance = 0, .set = &held_set, .layout = held_pipes }, pass, frame, shaders, vertex_buffer, &offset, &black);
    try testing.expectEqual(white, picture.at(4, 4));
    // And the texture the write did bring is read inside the edges: at a
    // sixteenth in, the coordinate is 0.125, the texture's first quarter.
    try testing.expectEqual(LayerScene.colorOf(0, false, false), picture.at(16, 16));
    // A write of a sampler alone into that binding changes nothing either.
    const only = facet.DescriptorImageInfo{ .sampler = tiled, .image_view = null };
    const write_sampler = facet.WriteDescriptorSet{ .dst_set = held_set[0].?, .dst_binding = 0, .descriptor_type = .sampler, .image_info = @ptrCast(&only) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write_sampler), 0, null);
    try draw(&bench, .{ .view = flat_view, .sampler = tiled, .name = "wideby", .instance = 0, .set = &held_set, .layout = held_pipes }, pass, frame, shaders, vertex_buffer, &offset, &black);
    try testing.expectEqual(white, picture.at(4, 4));
}

/// A cube sampled at the one direction every vertex carries, through the
/// sampler bound beside it and through the fixed form: what a sample on a
/// seam reads.
const SeamScene = struct {
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const towards = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], 0, 1, towards[0], towards[1], towards[2] };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("by", &vertex, 3),
        shader.fixedFragment("by", .{ .kind = .texture_cube_sampled }),
        shader.vertex("fixed", &vertex, 3),
        shader.fixedFragment("fixed", .{ .kind = .texture_cube, .sampling = .{ .filter = .bilinear } }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A quad over the whole picture, every vertex looking the one way:
    /// each pixel samples that direction, so the whole picture is the one
    /// colour and the quad's steps are 0 - level 0, with no derivative to
    /// read a coarser one by.
    fn quadTowards(towards: [3]f32) [6][6]f32 {
        return .{
            .{ -1, -1, 0, towards[0], towards[1], towards[2] },
            .{ 1, -1, 0, towards[0], towards[1], towards[2] },
            .{ -1, 1, 0, towards[0], towards[1], towards[2] },
            .{ -1, 1, 0, towards[0], towards[1], towards[2] },
            .{ 1, -1, 0, towards[0], towards[1], towards[2] },
            .{ 1, 1, 0, towards[0], towards[1], towards[2] },
        };
    }

    /// Face k's colour: red alone, 32 apart, so a mix of two faces is
    /// told from either of them.
    fn faceColor(face: u32) u32 {
        return 0xFF00_0000 | (32 + 32 * face) << 16;
    }
};

test "a cube read through a sampler reads over its seams: a bilinear sample at an edge mixes the face beside it" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    const across = 16;
    const face_bytes = across * across * 4;
    const cube = try bench.bareImage(.{
        .format = .b8g8r8a8_unorm,
        .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE,
        .extent = .{ .width = across, .height = across },
        .array_layers = 6,
        .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
    }, false);
    const view = try bench.viewOf(.{ .image = cube, .format = .b8g8r8a8_unorm, .view_type = .cube });
    const staging, const staged = try bench.buffer(face_bytes * 6, facet.BUFFER_USAGE_TRANSFER_SRC);
    var faces: [6]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*region, face| {
        const color = SeamScene.faceColor(@intCast(face));
        for (0..across * across) |texel| std.mem.writeInt(u32, staged[face * face_bytes + texel * 4 ..][0..4], color, .little);
        region.* = .{
            .buffer_offset = face * face_bytes,
            .image_subresource = .{ .base_array_layer = @intCast(face) },
            .image_extent = .{ .width = across, .height = across },
        };
    }
    const copying = try bench.record();
    fb.CmdCopyBufferToImage(copying, staging, cube, .transfer_dst_optimal, faces.len, &faces);
    try bench.submit();

    // Two samplers whose edges differ: a cube has no edge of its own to
    // hold at or to repeat, so since 1.60 the two read a seam alike.
    var held: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
    }, &held));
    defer fb.DestroySampler(device, held);
    var tiled: ?*facet.Sampler = null;
    try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{}, &tiled));
    defer fb.DestroySampler(device, tiled);

    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));

    const shaders = try module(&bench, &SeamScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const picture = try Picture.of(&bench, 64, 64);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const by_result, const by_sampler = makePipeline(&bench, .{ .module = shaders, .name = "by", .layout = layout, .pass = pass, .stride = 24, .attributes = &attributes });
    try testing.expectEqual(facet.Result.success, by_result);
    defer fb.DestroyPipeline(device, by_sampler);
    const form_result, const by_form = makePipeline(&bench, .{ .module = shaders, .name = "fixed", .layout = layout, .pass = pass, .stride = 24, .attributes = &attributes });
    try testing.expectEqual(facet.Result.success, form_result);
    defer fb.DestroyPipeline(device, by_form);
    const vertex_buffer, const vertex_bytes = try bench.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER);

    const looked = struct {
        fn at(on: *Bench, bytes: [*]u8, buffer: *facet.Buffer, with: ?*facet.Sampler, of_view: *facet.ImageView, set: *facet.DescriptorSet, into: *facet.RenderPass, onto: *facet.Framebuffer, by: *facet.PipelineLayout, drawn: ?*facet.Pipeline, towards: [3]f32) !void {
            const f = on.rig.fb;
            const info = facet.DescriptorImageInfo{ .sampler = with, .image_view = of_view };
            const write = facet.WriteDescriptorSet{ .dst_set = set, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const quad = SeamScene.quadTowards(towards);
            @memcpy(bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
            const first: u64 = 0;
            const green = clears(0xFF00_FF00);
            const commands = try on.record();
            f.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &green }, .@"inline");
            f.CmdBindPipeline(commands, .graphics, drawn.?);
            f.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&first));
            f.CmdBindDescriptorSets(commands, .graphics, by, 0, 1, @ptrCast(&set), 0, null);
            f.CmdDraw(commands, 6, 1, 0, 0);
            f.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.at;

    // Inside a face, where no tap is past an edge: that face's colour,
    // whatever the sampler's edges say.
    for ([2]?*facet.Sampler{ held, tiled }) |with| {
        try looked(&bench, vertex_bytes, vertex_buffer, with, view, sets[0].?, pass, frame, layout, by_sampler, .{ 1, 0, 0 });
        try testing.expectEqual(SeamScene.faceColor(0), picture.at(32, 32));
        try looked(&bench, vertex_bytes, vertex_buffer, with, view, sets[0].?, pass, frame, layout, by_sampler, .{ 0, 0, 1 });
        try testing.expectEqual(SeamScene.faceColor(4), picture.at(32, 32));
    }

    // On the seam between +X and +Z, half a texel either side of it: the
    // sample mixes the two faces half and half, so its red is halfway
    // between theirs. Before 1.60 the taps were held inside the one face
    // and it read face 0's own colour.
    const seam = [3]f32{ 1, 0, 1 };
    const low = SeamScene.faceColor(0) >> 16 & 0xFF;
    const high = SeamScene.faceColor(4) >> 16 & 0xFF;
    const middle = (low + high) / 2;
    for ([2]?*facet.Sampler{ held, tiled }) |with| {
        try looked(&bench, vertex_bytes, vertex_buffer, with, view, sets[0].?, pass, frame, layout, by_sampler, seam);
        const read = picture.at(32, 32);
        try testing.expect(read >> 16 & 0xFF >= middle - 4 and read >> 16 & 0xFF <= middle + 4);
        // The green and the blue are what both faces have: none.
        try testing.expectEqual(@as(u32, 0), read & 0xFFFF);
        try testing.expectEqual(@as(u32, 0xFF), read >> 24);
    }

    // And the fixed form, which has read over its seams since 1.46, now
    // answers the same place the same way: the two paths agree.
    try looked(&bench, vertex_bytes, vertex_buffer, held, view, sets[0].?, pass, frame, layout, by_form, seam);
    const form_read = picture.at(32, 32);
    try testing.expect(form_read >> 16 & 0xFF >= middle - 4 and form_read >> 16 & 0xFF <= middle + 4);
}

/// A 3D sample through the sampler bound beside the texture, the s, the t
/// and the r given as the vertices' second three floats: what a level of
/// its own does to the slice a coordinate falls on.
const SliceScene = struct {
    fn vertex(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uvr = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], 0, 1, uvr[0], uvr[1], uvr[2] };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("main", &vertex, 3),
        shader.fixedFragment("main", .{ .kind = .texture_3d_sampled }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A quad over the whole picture at (0.5, 0.5) of the texture, `r`
    /// through it: a slice read whole, whatever the filtering across it.
    fn quadAt(r: f32) [6][6]f32 {
        return .{
            .{ -1, -1, 0.5, 0.5, 0.5, r },
            .{ 1, -1, 0.5, 0.5, 0.5, r },
            .{ -1, 1, 0.5, 0.5, 0.5, r },
            .{ -1, 1, 0.5, 0.5, 0.5, r },
            .{ 1, -1, 0.5, 0.5, 0.5, r },
            .{ 1, 1, 0.5, 0.5, 0.5, r },
        };
    }
};

test "a 3D texture of levels read through a sampler: the slices of the level it reads, not of the whole depth" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // 16 x 16 x 4 with two levels: level 0 is four slices, level 1 two,
    // as halving the depth gives (`texture.Texture.slicesAt`).
    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const volume = try bench.bareImage(.{
        .format = .b8g8r8a8_unorm,
        .image_type = .@"3d",
        .extent = .{ .width = 16, .height = 16, .depth = 4 },
        .mip_levels = 2,
        .usage = usage,
    }, false);
    const view = try bench.viewOf(.{ .image = volume, .format = .b8g8r8a8_unorm, .view_type = .@"3d" });

    // Each slice of each level one colour of its own, so that a sample
    // says which slice of which level it read.
    const deep = [4]u32{ 0xFF11_4400, 0xFF11_5500, 0xFF11_6600, 0xFF11_7700 };
    const halved = [2]u32{ 0xFF22_AA00, 0xFF22_BB00 };
    const staging, const staged = try bench.buffer(16 * 16 * 4 * 4 + 8 * 8 * 4 * 2, facet.BUFFER_USAGE_TRANSFER_SRC);
    var regions: [6]facet.BufferImageCopy = undefined;
    var at: usize = 0;
    for (deep, 0..) |color, slice| {
        for (0..16 * 16) |texel| std.mem.writeInt(u32, staged[at + texel * 4 ..][0..4], color, .little);
        regions[slice] = .{
            .buffer_offset = at,
            .image_offset = .{ .z = @intCast(slice) },
            .image_extent = .{ .width = 16, .height = 16, .depth = 1 },
        };
        at += 16 * 16 * 4;
    }
    for (halved, 0..) |color, slice| {
        for (0..8 * 8) |texel| std.mem.writeInt(u32, staged[at + texel * 4 ..][0..4], color, .little);
        regions[4 + slice] = .{
            .buffer_offset = at,
            .image_subresource = .{ .mip_level = 1 },
            .image_offset = .{ .z = @intCast(slice) },
            .image_extent = .{ .width = 8, .height = 8, .depth = 1 },
        };
        at += 8 * 8 * 4;
    }
    const copying = try bench.record();
    fb.CmdCopyBufferToImage(copying, staging, volume, .transfer_dst_optimal, regions.len, &regions);
    try bench.submit();

    // A sampler of its own for each level, nearest either way: what is
    // read is the slice the coordinate falls on and nothing mixed.
    var samplers: [2]?*facet.Sampler = .{ null, null };
    for (&samplers, 0..) |*made, level| {
        const lod: f32 = @floatFromInt(level);
        try testing.expectEqual(facet.Result.success, fb.CreateSampler(device, &.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .min_lod = lod,
            .max_lod = lod,
        }, made));
    }
    defer for (samplers) |one| fb.DestroySampler(device, one);

    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    const layout = try pipelineLayout(&bench, &.{set_layout.?}, 0);
    defer fb.DestroyPipelineLayout(device, layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets));

    const shaders = try module(&bench, &SliceScene.code);
    defer fb.DestroyShaderModule(device, shaders);
    const pass = try renderPass(&bench, .clear, false);
    defer fb.DestroyRenderPass(device, pass);
    const picture = try Picture.of(&bench, 64, 64);
    const frame = try framebuffer(&bench, pass, &.{picture.view}, 64, 64);
    defer fb.DestroyFramebuffer(device, frame);
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const made, const pipeline = makePipeline(&bench, .{ .module = shaders, .layout = layout, .pass = pass, .stride = 24, .attributes = &attributes });
    try testing.expectEqual(facet.Result.success, made);
    defer fb.DestroyPipeline(device, pipeline);
    const vertex_buffer, const vertex_bytes = try bench.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER);

    const sampled = struct {
        fn of(on: *Bench, bytes: [*]u8, buffer: *facet.Buffer, with: ?*facet.Sampler, of_view: *facet.ImageView, set: *facet.DescriptorSet, into: *facet.RenderPass, onto: *facet.Framebuffer, by: *facet.PipelineLayout, drawn: ?*facet.Pipeline, r: f32) !void {
            const f = on.rig.fb;
            const info = facet.DescriptorImageInfo{ .sampler = with, .image_view = of_view };
            const write = facet.WriteDescriptorSet{ .dst_set = set, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const quad = SliceScene.quadAt(r);
            @memcpy(bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
            const first: u64 = 0;
            const black = clears(0xFF00_0000);
            const commands = try on.record();
            f.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = &black }, .@"inline");
            f.CmdBindPipeline(commands, .graphics, drawn.?);
            f.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&first));
            f.CmdBindDescriptorSets(commands, .graphics, by, 0, 1, @ptrCast(&set), 0, null);
            f.CmdDraw(commands, 6, 1, 0, 0);
            f.CmdEndRenderPass(commands);
            try on.submit();
        }
    }.of;

    // Level 0 has the whole depth: a quarter of the way through it for
    // each of the four slices.
    for ([4]f32{ 0.125, 0.375, 0.625, 0.875 }, deep) |r, wanted| {
        try sampled(&bench, vertex_bytes, vertex_buffer, samplers[0], view, sets[0].?, pass, frame, layout, pipeline, r);
        try testing.expectEqual(wanted, picture.at(16, 8));
        try testing.expectEqual(wanted, picture.at(48, 40));
    }

    // Level 1 has two: the coordinate falls on the level's own slices, so
    // the first half of the texture reads its first slice and the second
    // half its second. Before 1.59 the coordinate was taken over the
    // whole four, so a quarter of the way through read the second slice
    // and three quarters read a slice the level has not got.
    for ([4]f32{ 0.125, 0.375, 0.625, 0.875 }, [4]u32{ halved[0], halved[0], halved[1], halved[1] }) |r, wanted| {
        try sampled(&bench, vertex_bytes, vertex_buffer, samplers[1], view, sets[0].?, pass, frame, layout, pipeline, r);
        try testing.expectEqual(wanted, picture.at(16, 8));
    }

    // Past the end either way, as `repeat` has it: the first slice again.
    try sampled(&bench, vertex_bytes, vertex_buffer, samplers[1], view, sets[0].?, pass, frame, layout, pipeline, 1.125);
    try testing.expectEqual(halved[0], picture.at(16, 8));
}

/// A quad over a texture kept in its blocks, drawn through a form for each
/// kept format, and through one for 8888 - which is the wrong format for
/// such a texture and takes the run-time sampler.
const BlockScene = struct {
    fn flat(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2 };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("blocks", &flat, 2),
        shader.fixedFragment("blocks", .{ .kind = .texture, .sampling = .{ .format = .bc1, .filter = .nearest } }),
        shader.vertex("alpha", &flat, 2),
        shader.fixedFragment("alpha", .{ .kind = .texture, .sampling = .{ .format = .bc3, .filter = .nearest } }),
        shader.vertex("eight", &flat, 2),
        shader.fixedFragment("eight", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest } }),
        // 1.72: one channel and two, each the block BC3 keeps its alpha
        // in.
        shader.vertex("one", &flat, 2),
        shader.fixedFragment("one", .{ .kind = .texture, .sampling = .{ .format = .bc4, .filter = .nearest } }),
        shader.vertex("two", &flat, 2),
        shader.fixedFragment("two", .{ .kind = .texture, .sampling = .{ .format = .bc5, .filter = .nearest } }),
        // 1.73: four channels in the same sixteen bytes.
        shader.vertex("full", &flat, 2),
        shader.fixedFragment("full", .{ .kind = .texture, .sampling = .{ .format = .bc7, .filter = .nearest } }),
        // 1.74: BC6H's three channels of half float.
        shader.vertex("halves", &flat, 2),
        shader.fixedFragment("halves", .{ .kind = .texture, .sampling = .{ .format = .bc6hu, .filter = .nearest } }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A BC1 block of one colour: both endpoints it, every texel the first.
    fn block1(color: u16, into: *[8]u8) void {
        std.mem.writeInt(u16, into[0..2], color, .little);
        std.mem.writeInt(u16, into[2..4], color, .little);
        std.mem.writeInt(u32, into[4..8], 0, .little);
    }

    /// A BC4 block of one value: both endpoints it, so every texel takes
    /// it whatever the indices say. (Since 1.72.)
    fn block4(value: u8, into: *[8]u8) void {
        into[0] = value;
        into[1] = value;
        @memset(into[2..8], 0);
    }

    /// A BC5 block of one red and one green: the red's block, then the
    /// green's. (Since 1.72.)
    fn block5(red: u8, green: u8, into: *[16]u8) void {
        block4(red, into[0..8]);
        block4(green, into[8..16]);
    }

    /// A BC7 block of one colour: mode 6, both endpoints the colour, so
    /// every texel takes it whatever the indices say. Each channel must
    /// be even - one p-bit stands under all four channels of an endpoint,
    /// and it is 0 here. (Since 1.73.)
    fn block7(color: u32, into: *[16]u8) void {
        @memset(into, 0);
        // Mode 6 is six zeros and a 1, then 7 bits a channel for each
        // endpoint in turn, red first and the alpha last.
        into[0] = 0x40;
        var next: u32 = 7;
        for ([4]u32{ color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF, color >> 24 }) |channel| {
            for (0..2) |_| {
                for (0..7) |bit| {
                    const place = next + @as(u32, @intCast(bit));
                    if (channel >> 1 >> @intCast(bit) & 1 != 0) into[place >> 3] |= @as(u8, 1) << @intCast(place & 7);
                }
                next += 7;
            }
        }
    }

    /// A BC6H block of one colour: mode 3, which holds both endpoints as
    /// they are in 10 bits each and transforms neither, so every texel
    /// takes the first whatever the indices say. 495 of 1024 unquantizes
    /// and scales to the half float for 1, and 0 to 0. (Since 1.74.)
    fn block6(red: u32, green: u32, blue: u32, into: *[16]u8) void {
        @memset(into, 0);
        into[0] = 3;
        var next: u32 = 5;
        for ([6]u32{ red, green, blue, red, green, blue }) |value| {
            for (0..10) |bit| {
                const place = next + @as(u32, @intCast(bit));
                if (value >> @intCast(bit) & 1 != 0) into[place >> 3] |= @as(u8, 1) << @intCast(place & 7);
            }
            next += 10;
        }
    }

    /// A BC3 block of one colour at one alpha: the alpha endpoints both it,
    /// so every texel takes it whatever the bits say.
    fn block3(color: u16, alpha: u8, into: *[16]u8) void {
        into[0] = alpha;
        into[1] = alpha;
        @memset(into[2..8], 0);
        block1(color, into[8..16]);
    }
};

test "compressed textures kept in their blocks: copied as blocks, sampled out of them, one channel and two" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    // The cores keep the blocks, and so there are blocks of the format to
    // read back as well as to write.
    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.kept_compressed);
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .bc1_rgba_unorm_block, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_DST != 0);

    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const side16 = facet.Extent3D{ .width = 16, .height = 16 };
    const packed_image = try bench.bareImage(.{ .format = .bc1_rgba_unorm_block, .extent = side16, .usage = usage }, false);
    const copy_image = try bench.bareImage(.{ .format = .bc1_rgba_unorm_block, .extent = side16, .usage = usage }, false);
    const alpha_image = try bench.bareImage(.{ .format = .bc3_unorm_block, .extent = side16, .usage = usage }, false);

    // An eighth of the texels unpacked: sixteen blocks of 8 bytes, where
    // 16 x 16 of 8888 takes 1024.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, packed_image, &needs);
    try testing.expectEqual(@as(u64, 128), needs.size);
    fb.GetImageMemoryRequirements(device, alpha_image, &needs);
    try testing.expectEqual(@as(u64, 256), needs.size);

    const packed_view = try bench.viewOf(.{ .image = packed_image, .format = .bc1_rgba_unorm_block });
    const copy_view = try bench.viewOf(.{ .image = copy_image, .format = .bc1_rgba_unorm_block });
    const alpha_view = try bench.viewOf(.{ .image = alpha_image, .format = .bc3_unorm_block });

    // Red blocks on the left of the picture and blue on the right, and the
    // same colours at half alpha for BC3.
    const red: u16 = 0xF800;
    const blue: u16 = 0x001F;
    const staging, const staged = try bench.buffer(2048, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..16) |block| {
        const color: u16 = if (block % 4 < 2) red else blue;
        BlockScene.block1(color, staged[block * 8 ..][0..8]);
        BlockScene.block3(color, 0x80, staged[128 + block * 16 ..][0..16]);
    }
    const blocks = facet.BufferImageCopy{ .image_extent = side16 };
    const alphas = facet.BufferImageCopy{ .buffer_offset = 128, .image_extent = side16 };
    const whole_copy = facet.ImageCopy{ .extent = side16 };
    _, const read_back = try bench.buffer(512, facet.BUFFER_USAGE_TRANSFER_DST);
    const read_buffer = bench.buffers[bench.buffer_count - 1];
    const read_region = facet.BufferImageCopy{ .image_extent = side16 };

    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, packed_image, .transfer_dst_optimal, 1, @ptrCast(&blocks));
    fb.CmdCopyBufferToImage(commands, staging, alpha_image, .transfer_dst_optimal, 1, @ptrCast(&alphas));
    // Image to image, both keeping their blocks: the blocks go as they lie.
    fb.CmdCopyImage(commands, packed_image, .general, copy_image, .general, 1, @ptrCast(&whole_copy));
    fb.CmdCopyImageToBuffer(commands, copy_image, .general, read_buffer, 1, @ptrCast(&read_region));
    try bench.submit();
    // What came back is what went in, block for block: nothing was decoded
    // on the way.
    try testing.expectEqualSlices(u8, staged[0..128], read_back[0..128]);

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));

    const shaders = try module(&bench, &BlockScene.code);
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
    const offset: u64 = 0;
    const black = clears(0xFF00_0000);

    const drawn = struct {
        fn drawn(on: *Bench, view: *facet.ImageView, name: [*:0]const u8, made_layout: *facet.PipelineLayout, into: *facet.RenderPass, into_frame: *facet.Framebuffer, code_module: *facet.ShaderModule, sets: *[1]?*facet.DescriptorSet, vertices: *facet.Buffer, first: *const u64, clear_values: *const [2]facet.ClearValue) !void {
            const f = on.rig.fb;
            const image_info = facet.DescriptorImageInfo{ .image_view = view };
            const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const result, const pipeline = makePipeline(on, .{ .module = code_module, .name = name, .layout = made_layout, .pass = into });
            try testing.expectEqual(facet.Result.success, result);
            defer f.DestroyPipeline(on.device, pipeline);
            const recording = try on.record();
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = into_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = clear_values }, .@"inline");
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdBindDescriptorSets(recording, .graphics, made_layout, 0, 1, @ptrCast(sets), 0, null);
            f.CmdBindPipeline(recording, .graphics, pipeline.?);
            f.CmdDraw(recording, 6, 1, 0, 0);
            f.CmdEndRenderPass(recording);
            try on.submit();
        }
    }.drawn;

    // The form built for the kept format: the fast path, a block decoded
    // where the four texels a sample mixes share one.
    try drawn(&bench, packed_view, "blocks", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 8));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 56));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
    // The copy of it reads the same, the blocks having gone as they lay.
    try drawn(&bench, copy_view, "blocks", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
    // A form built for 8888 handed a texture of blocks: the run-time
    // sampler draws it, and reads the same colours (since 1.44).
    try drawn(&bench, packed_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
    // BC3: the colours the same and the alpha the block's own.
    try drawn(&bench, alpha_view, "alpha", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0x80FF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0x8000_00FF), picture.at(56, 56));

    // --- 1.72: BC4 and BC5, one channel and two ---
    // The block BC3 keeps its alpha in, over red alone and over red and
    // green: 8 bytes a block and 16, kept as they lie and read as
    // (red, 0, 0, 1) and (red, green, 0, 1).
    for ([2]facet.Format{ .bc4_unorm_block, .bc5_unorm_block }) |format| {
        fb.GetPhysicalDeviceFormatProperties(bench.physical, format, &properties);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT);
    }
    const one_image = try bench.bareImage(.{ .format = .bc4_unorm_block, .extent = side16, .usage = usage }, false);
    const two_image = try bench.bareImage(.{ .format = .bc5_unorm_block, .extent = side16, .usage = usage }, false);
    fb.GetImageMemoryRequirements(device, one_image, &needs);
    try testing.expectEqual(@as(u64, 128), needs.size);
    fb.GetImageMemoryRequirements(device, two_image, &needs);
    try testing.expectEqual(@as(u64, 256), needs.size);
    const one_view = try bench.viewOf(.{ .image = one_image, .format = .bc4_unorm_block });
    const two_view = try bench.viewOf(.{ .image = two_image, .format = .bc5_unorm_block });

    // A red of 200 on the left and 100 on the right; and beside it a
    // green of 10 and 250.
    const one_at = 256;
    const two_at = 384;
    for (0..16) |block| {
        const left = block % 4 < 2;
        BlockScene.block4(if (left) 200 else 100, staged[one_at + block * 8 ..][0..8]);
        BlockScene.block5(if (left) 200 else 100, if (left) 10 else 250, staged[two_at + block * 16 ..][0..16]);
    }
    const one_blocks = facet.BufferImageCopy{ .buffer_offset = one_at, .image_extent = side16 };
    const two_blocks = facet.BufferImageCopy{ .buffer_offset = two_at, .image_extent = side16 };
    @memset(read_back[0..256], 0);
    const channel_commands = try bench.record();
    fb.CmdCopyBufferToImage(channel_commands, staging, one_image, .transfer_dst_optimal, 1, @ptrCast(&one_blocks));
    fb.CmdCopyBufferToImage(channel_commands, staging, two_image, .transfer_dst_optimal, 1, @ptrCast(&two_blocks));
    fb.CmdCopyImageToBuffer(channel_commands, one_image, .general, read_buffer, 1, @ptrCast(&facet.BufferImageCopy{ .image_extent = side16 }));
    try bench.submit();
    // The blocks came back as they went in: nothing was decoded on the
    // way.
    try testing.expectEqualSlices(u8, staged[one_at..][0..128], read_back[0..128]);

    // Sampled through the form built for each: red alone, and red and
    // green with a blue of 0 and the alpha whole.
    try drawn(&bench, one_view, "one", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFC8_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF64_0000), picture.at(56, 8));
    try drawn(&bench, two_view, "two", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFC8_0A00), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF64_FA00), picture.at(56, 8));
    // And through a form built for 8888, which takes the run-time
    // sampler: the same colours.
    try drawn(&bench, one_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFC8_0000), picture.at(8, 8));
    try drawn(&bench, two_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFF64_FA00), picture.at(56, 8));

    // --- 1.73: BC7, four channels in the same sixteen bytes ---
    // Subsets, modes and indices: the one block of these to hold a
    // smooth alpha beside a sharp colour, and the only one whose texels
    // are not two endpoints of 565.
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .bc7_unorm_block, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
    try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT);
    const full_image = try bench.bareImage(.{ .format = .bc7_unorm_block, .extent = side16, .usage = usage }, false);
    fb.GetImageMemoryRequirements(device, full_image, &needs);
    try testing.expectEqual(@as(u64, 256), needs.size);
    const full_view = try bench.viewOf(.{ .image = full_image, .format = .bc7_unorm_block });

    // Red at half alpha on the left and blue at a quarter on the right,
    // each a mode-6 block of one colour.
    const full_at = 640;
    const half_red = 0x80FE_0000;
    const quarter_blue = 0x4000_00FE;
    for (0..16) |block| {
        const color: u32 = if (block % 4 < 2) half_red else quarter_blue;
        BlockScene.block7(color, staged[full_at + block * 16 ..][0..16]);
    }
    const full_blocks = facet.BufferImageCopy{ .buffer_offset = full_at, .image_extent = side16 };
    @memset(read_back[0..256], 0);
    const full_commands = try bench.record();
    fb.CmdCopyBufferToImage(full_commands, staging, full_image, .transfer_dst_optimal, 1, @ptrCast(&full_blocks));
    fb.CmdCopyImageToBuffer(full_commands, full_image, .general, read_buffer, 1, @ptrCast(&facet.BufferImageCopy{ .image_extent = side16 }));
    try bench.submit();
    // The blocks came back as they went in.
    try testing.expectEqualSlices(u8, staged[full_at..][0..256], read_back[0..256]);

    // Sampled through the form built for BC7, and through the one built
    // for 8888, which takes the run-time sampler: the colour and the
    // alpha the block holds.
    try drawn(&bench, full_view, "full", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, half_red), picture.at(8, 8));
    try testing.expectEqual(@as(u32, quarter_blue), picture.at(56, 8));
    try drawn(&bench, full_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, half_red), picture.at(8, 8));
    try testing.expectEqual(@as(u32, quarter_blue), picture.at(56, 56));

    // --- 1.74: BC6H, three channels of half float ---
    // The one block of these to hold floats, for a texture whose channels
    // run past 1: a sample reads them held between 0 and 1 and rounded to
    // 8 bits, the way a float texture's are read.
    for ([2]facet.Format{ .bc6h_ufloat_block, .bc6h_sfloat_block }) |format| {
        fb.GetPhysicalDeviceFormatProperties(bench.physical, format, &properties);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
        try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
        try testing.expectEqual(@as(u32, 0), properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT);
    }
    const halves_image = try bench.bareImage(.{ .format = .bc6h_ufloat_block, .extent = side16, .usage = usage }, false);
    fb.GetImageMemoryRequirements(device, halves_image, &needs);
    try testing.expectEqual(@as(u64, 256), needs.size);
    const halves_view = try bench.viewOf(.{ .image = halves_image, .format = .bc6h_ufloat_block });

    // Red on the left and blue on the right, each channel the half float
    // for 1 or for 0.
    const halves_at = 896;
    for (0..16) |block| {
        const left = block % 4 < 2;
        BlockScene.block6(if (left) 495 else 0, 0, if (left) 0 else 495, staged[halves_at + block * 16 ..][0..16]);
    }
    const halves_blocks = facet.BufferImageCopy{ .buffer_offset = halves_at, .image_extent = side16 };
    @memset(read_back[0..256], 0);
    const halves_commands = try bench.record();
    fb.CmdCopyBufferToImage(halves_commands, staging, halves_image, .transfer_dst_optimal, 1, @ptrCast(&halves_blocks));
    fb.CmdCopyImageToBuffer(halves_commands, halves_image, .general, read_buffer, 1, @ptrCast(&facet.BufferImageCopy{ .image_extent = side16 }));
    try bench.submit();
    try testing.expectEqualSlices(u8, staged[halves_at..][0..256], read_back[0..256]);

    // Sampled through the form built for BC6H and through the one built
    // for 8888: a half float of 1 is a channel at the full.
    try drawn(&bench, halves_view, "halves", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 8));
    try drawn(&bench, halves_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));

    // A copy whose offset is not on a block is left alone, as Vulkan asks
    // of one: the image keeps what it had.
    const off_block = facet.BufferImageCopy{ .buffer_offset = 128, .image_offset = .{ .x = 2, .y = 0 }, .image_extent = .{ .width = 8, .height = 8 } };
    const again = try bench.record();
    fb.CmdCopyBufferToImage(again, staging, packed_image, .transfer_dst_optimal, 1, @ptrCast(&off_block));
    try bench.submit();
    try drawn(&bench, packed_view, "blocks", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
}

/// A quad over a float texture, drawn through a form built for its floats
/// and through one built for 8888, which is the wrong format for such a
/// texture and takes the run-time sampler.
const FloatScene = struct {
    fn flat(vertices: *const shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], 0, 1, (p[0] + 1) / 2, (p[1] + 1) / 2 };
        }
    }

    const entries = [_]shader.Entry{
        shader.vertex("halves", &flat, 2),
        shader.fixedFragment("halves", .{ .kind = .texture, .sampling = .{ .format = .rgba16f, .filter = .nearest } }),
        shader.vertex("eight", &flat, 2),
        shader.fixedFragment("eight", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest } }),
        // 1.69: forms built for a texture whose channels are its own.
        shader.vertex("wide", &flat, 2),
        shader.fixedFragment("wide", .{ .kind = .texture, .sampling = .{ .format = .rgba16, .filter = .nearest } }),
        shader.vertex("two", &flat, 2),
        shader.fixedFragment("two", .{ .kind = .texture, .sampling = .{ .format = .rg8, .filter = .nearest } }),
        // 1.70: one built for a texture of whole numbers.
        shader.vertex("whole", &flat, 2),
        shader.fixedFragment("whole", .{ .kind = .texture, .sampling = .{ .format = .rgba8u, .filter = .nearest } }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// Four half floats, red first, as a texel of R16G16B16A16_SFLOAT holds
    /// them.
    fn texel(values: [4]f32, into: *[8]u8) void {
        for (values, 0..) |value, k| {
            const half: u16 = @bitCast(@as(f16, @floatCast(value)));
            std.mem.writeInt(u16, into[k * 2 ..][0..2], half, .little);
        }
    }
};

test "textures kept as they lie: floats, channels of their own and whole numbers, copied in and out and sampled rounded" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.kept_floats);
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .r16g16b16a16_sfloat, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .b10g11r11_ufloat_pack32, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0);

    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const side4 = facet.Extent3D{ .width = 4, .height = 4 };
    const half_image = try bench.bareImage(.{ .format = .r16g16b16a16_sfloat, .extent = side4, .usage = usage }, false);
    const copy_image = try bench.bareImage(.{ .format = .r16g16b16a16_sfloat, .extent = side4, .usage = usage }, false);
    const packed_image = try bench.bareImage(.{ .format = .b10g11r11_ufloat_pack32, .extent = side4, .usage = usage }, false);
    // A storage image is written texel by texel, which a kept float is
    // not: such an image is unpacked into 8888, as it always was.
    const written = try bench.bareImage(.{ .format = .r16g16b16a16_sfloat, .extent = side4, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_DST }, false);

    // The texels' own size: 8 bytes for four halves, 4 for the packed one,
    // and 8 for the 8888 an unpacked one is kept spread in.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, half_image, &needs);
    try testing.expectEqual(@as(u64, 4 * 4 * 8), needs.size);
    fb.GetImageMemoryRequirements(device, packed_image, &needs);
    try testing.expectEqual(@as(u64, 4 * 4 * 4), needs.size);
    fb.GetImageMemoryRequirements(device, written, &needs);
    try testing.expectEqual(@as(u64, 4 * 4 * 8), needs.size);

    const half_view = try bench.viewOf(.{ .image = half_image, .format = .r16g16b16a16_sfloat });
    const copy_view = try bench.viewOf(.{ .image = copy_image, .format = .r16g16b16a16_sfloat });
    const packed_view = try bench.viewOf(.{ .image = packed_image, .format = .b10g11r11_ufloat_pack32 });

    // Sixteen texels: red on the left and half-bright blue on the right,
    // one of them above 1 and one below 0, which a sample holds inside.
    const staging, const staged = try bench.buffer(256, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..16) |k| {
        const left = k % 4 < 2;
        FloatScene.texel(if (left) .{ 2, -1, 0, 1 } else .{ 0, 0, 0.5, 1 }, staged[k * 8 ..][0..8]);
    }
    const words_at = 128;
    for (0..16) |k| {
        const bits: u32 = if (k % 4 < 2) 15 << 6 else 13 << 27;
        std.mem.writeInt(u32, staged[words_at + k * 4 ..][0..4], bits, .little);
    }
    const halves = facet.BufferImageCopy{ .image_extent = side4 };
    const words = facet.BufferImageCopy{ .buffer_offset = words_at, .image_extent = side4 };
    const whole_copy = facet.ImageCopy{ .extent = side4 };
    _, const read_back = try bench.buffer(256, facet.BUFFER_USAGE_TRANSFER_DST);
    const read_buffer = bench.buffers[bench.buffer_count - 1];

    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, half_image, .transfer_dst_optimal, 1, @ptrCast(&halves));
    fb.CmdCopyBufferToImage(commands, staging, packed_image, .transfer_dst_optimal, 1, @ptrCast(&words));
    fb.CmdCopyImage(commands, half_image, .general, copy_image, .general, 1, @ptrCast(&whole_copy));
    fb.CmdCopyImageToBuffer(commands, copy_image, .general, read_buffer, 1, @ptrCast(&halves));
    try bench.submit();
    // What came back is what went in, half for half: nothing was rounded
    // to 8 bits on the way.
    try testing.expectEqualSlices(u8, staged[0..128], read_back[0..128]);

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));

    const shaders = try module(&bench, &FloatScene.code);
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
    const offset: u64 = 0;
    const black = clears(0xFF00_0000);

    const drawn = struct {
        fn drawn(on: *Bench, view: *facet.ImageView, name: [*:0]const u8, made_layout: *facet.PipelineLayout, into: *facet.RenderPass, into_frame: *facet.Framebuffer, code_module: *facet.ShaderModule, sets: *[1]?*facet.DescriptorSet, vertices: *facet.Buffer, first: *const u64, clear_values: *const [2]facet.ClearValue) !void {
            const f = on.rig.fb;
            const image_info = facet.DescriptorImageInfo{ .image_view = view };
            const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const result, const pipeline = makePipeline(on, .{ .module = code_module, .name = name, .layout = made_layout, .pass = into });
            try testing.expectEqual(facet.Result.success, result);
            defer f.DestroyPipeline(on.device, pipeline);
            const recording = try on.record();
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = into_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = clear_values }, .@"inline");
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdBindDescriptorSets(recording, .graphics, made_layout, 0, 1, @ptrCast(sets), 0, null);
            f.CmdBindPipeline(recording, .graphics, pipeline.?);
            f.CmdDraw(recording, 6, 1, 0, 0);
            f.CmdEndRenderPass(recording);
            try on.submit();
        }
    }.drawn;

    // 2 reads as 255 and -1 as 0; the right half is blue at 128.
    try drawn(&bench, half_view, "halves", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0080), picture.at(56, 56));
    // The copy of it reads the same, the floats having gone as they lay.
    try drawn(&bench, copy_view, "halves", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0080), picture.at(56, 56));
    // A form built for 8888 handed a texture of floats: the run-time
    // sampler draws it, and reads the same colours.
    try drawn(&bench, half_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0080), picture.at(56, 56));
    // The packed format through the run-time sampler as well: red at 1 on
    // the left, and on the right a blue of 2 to the -2.
    try drawn(&bench, packed_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0040), picture.at(56, 56));

    // --- 1.69: a texture whose channels are its own ---
    // 16 bits a channel and two bytes of red and green: copied in and out
    // as they lie, and sampled as the colour of their top 8 bits.
    const wide_image = try bench.bareImage(.{ .format = .r16g16b16a16_unorm, .extent = side4, .usage = usage }, false);
    const two_image = try bench.bareImage(.{ .format = .r8g8_unorm, .extent = side4, .usage = usage }, false);
    fb.GetImageMemoryRequirements(device, wide_image, &needs);
    try testing.expectEqual(@as(u64, 4 * 4 * 8), needs.size);
    fb.GetImageMemoryRequirements(device, two_image, &needs);
    // Two bytes a texel is 32 for the sixteen of them, which an image's
    // memory rounds up to the cache line it begins on.
    try testing.expectEqual(@as(u64, 64), needs.size);
    const wide_view = try bench.viewOf(.{ .image = wide_image, .format = .r16g16b16a16_unorm });
    const two_view = try bench.viewOf(.{ .image = two_image, .format = .r8g8_unorm });

    // Red on the left, half-bright blue on the right; and for the two
    // bytes, red on the left and half-bright green on the right.
    const wide_at = 0;
    const two_at = 128;
    for (0..16) |k| {
        const left = k % 4 < 2;
        const channels: [4]u16 = if (left) .{ 0xFFFF, 0, 0, 0xFFFF } else .{ 0, 0, 0x8080, 0xFFFF };
        for (channels, 0..) |one, c| std.mem.writeInt(u16, staged[wide_at + k * 8 + c * 2 ..][0..2], one, .little);
        staged[two_at + k * 2] = if (left) 255 else 0;
        staged[two_at + k * 2 + 1] = if (left) 0 else 128;
    }
    const wides = facet.BufferImageCopy{ .buffer_offset = wide_at, .image_extent = side4 };
    const twos = facet.BufferImageCopy{ .buffer_offset = two_at, .image_extent = side4 };
    @memset(read_back[0..256], 0);
    const wide_commands = try bench.record();
    fb.CmdCopyBufferToImage(wide_commands, staging, wide_image, .transfer_dst_optimal, 1, @ptrCast(&wides));
    fb.CmdCopyBufferToImage(wide_commands, staging, two_image, .transfer_dst_optimal, 1, @ptrCast(&twos));
    fb.CmdCopyImageToBuffer(wide_commands, wide_image, .general, read_buffer, 1, @ptrCast(&wides));
    fb.CmdCopyImageToBuffer(wide_commands, two_image, .general, read_buffer, 1, @ptrCast(&twos));
    try bench.submit();
    // What came back is what went in, channel for channel: nothing was
    // rounded to 8 bits on the way.
    try testing.expectEqualSlices(u8, staged[wide_at..][0..128], read_back[wide_at..][0..128]);
    try testing.expectEqualSlices(u8, staged[two_at..][0..32], read_back[two_at..][0..32]);

    // Sampled through a form built for the format: the top 8 bits of each
    // channel.
    try drawn(&bench, wide_view, "wide", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0080), picture.at(56, 56));
    // And through one built for 8888, which takes the run-time sampler:
    // the same colours.
    try drawn(&bench, wide_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_0080), picture.at(56, 56));
    // Two bytes read as (red, green, 0, 1), the alpha whole where the
    // format has none.
    try drawn(&bench, two_view, "two", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_8000), picture.at(56, 56));
    try drawn(&bench, two_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFF00_8000), picture.at(56, 56));

    // --- 1.70: a texture of whole numbers ---
    // Four bytes a texel, read as the numbers they are: copied in and out
    // as they lie, and sampled as the colour each number holds to - 0 or
    // the channel at the full, a whole number being no colour.
    const whole_image = try bench.bareImage(.{ .format = .r8g8b8a8_uint, .extent = side4, .usage = usage }, false);
    fb.GetImageMemoryRequirements(device, whole_image, &needs);
    try testing.expectEqual(@as(u64, 64), needs.size);
    const whole_view = try bench.viewOf(.{ .image = whole_image, .format = .r8g8b8a8_uint });
    const whole_at = 160;
    for (0..16) |k| {
        const left = k % 4 < 2;
        const numbers: [4]u8 = if (left) .{ 255, 0, 0, 255 } else .{ 0, 0, 128, 255 };
        @memcpy(staged[whole_at + k * 4 ..][0..4], &numbers);
    }
    const numbers_copy = facet.BufferImageCopy{ .buffer_offset = whole_at, .image_extent = side4 };
    @memset(read_back[whole_at..][0..64], 0);
    const number_commands = try bench.record();
    fb.CmdCopyBufferToImage(number_commands, staging, whole_image, .transfer_dst_optimal, 1, @ptrCast(&numbers_copy));
    fb.CmdCopyImageToBuffer(number_commands, whole_image, .general, read_buffer, 1, @ptrCast(&numbers_copy));
    try bench.submit();
    try testing.expectEqualSlices(u8, staged[whole_at..][0..64], read_back[whole_at..][0..64]);

    // Sampled through a form built for the format, and through one built
    // for 8888 by way of the run-time sampler: a red of 255 and a blue of
    // 128 are both their channel at the full.
    try drawn(&bench, whole_view, "whole", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
    try drawn(&bench, whole_view, "eight", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), picture.at(8, 8));
    try testing.expectEqual(@as(u32, 0xFF00_00FF), picture.at(56, 56));
}
test "a clear of a float image writes its floats: the channels as given, into each format's own texel" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;

    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const side4 = facet.Extent3D{ .width = 4, .height = 4 };
    // Two levels on the halves, to see that a clear writes both.
    const halves = try bench.bareImage(.{ .format = .r16g16b16a16_sfloat, .extent = side4, .mip_levels = 2, .usage = usage }, false);
    const words = try bench.bareImage(.{ .format = .r32g32b32a32_sfloat, .extent = side4, .usage = usage }, false);
    const packed_image = try bench.bareImage(.{ .format = .b10g11r11_ufloat_pack32, .extent = side4, .usage = usage }, false);
    const shared = try bench.bareImage(.{ .format = .e5b9g9r9_ufloat_pack32, .extent = side4, .usage = usage }, false);
    const reds = try bench.bareImage(.{ .format = .r32_sfloat, .extent = side4, .usage = usage }, false);

    // A colour no 8888 texel holds: red above 1, green below 0, blue at a
    // half. Before 1.61 the clear wrote nothing at all.
    const color = facet.ClearColorValue{ .float32 = .{ 2, -1, 0.5, 1 } };
    const whole = facet.ImageSubresourceRange{};
    const read_buffer, const read_back = try bench.buffer(1024, facet.BUFFER_USAGE_TRANSFER_DST);
    @memset(read_back[0..1024], 0xAA);
    const at_level1 = 128;
    const at_words = 160;
    const at_packed = 416;
    const at_shared = 480;
    const at_reds = 544;
    const level0 = facet.BufferImageCopy{ .image_extent = side4 };
    const level1 = facet.BufferImageCopy{ .buffer_offset = at_level1, .image_subresource = .{ .mip_level = 1 }, .image_extent = .{ .width = 2, .height = 2 } };
    const word_copy = facet.BufferImageCopy{ .buffer_offset = at_words, .image_extent = side4 };
    const packed_copy = facet.BufferImageCopy{ .buffer_offset = at_packed, .image_extent = side4 };
    const shared_copy = facet.BufferImageCopy{ .buffer_offset = at_shared, .image_extent = side4 };
    const red_copy = facet.BufferImageCopy{ .buffer_offset = at_reds, .image_extent = side4 };

    const commands = try bench.record();
    for ([_]*facet.Image{ halves, words, packed_image, shared, reds }) |one| {
        fb.CmdClearColorImage(commands, one, .transfer_dst_optimal, &color, 1, @ptrCast(&whole));
    }
    fb.CmdCopyImageToBuffer(commands, halves, .general, read_buffer, 1, @ptrCast(&level0));
    fb.CmdCopyImageToBuffer(commands, halves, .general, read_buffer, 1, @ptrCast(&level1));
    fb.CmdCopyImageToBuffer(commands, words, .general, read_buffer, 1, @ptrCast(&word_copy));
    fb.CmdCopyImageToBuffer(commands, packed_image, .general, read_buffer, 1, @ptrCast(&packed_copy));
    fb.CmdCopyImageToBuffer(commands, shared, .general, read_buffer, 1, @ptrCast(&shared_copy));
    fb.CmdCopyImageToBuffer(commands, reds, .general, read_buffer, 1, @ptrCast(&red_copy));
    try bench.submit();

    // Four halves and four whole floats, written out by hand: 2, -1, 0.5
    // and 1 as those formats hold them.
    var want_half: [8]u8 = undefined;
    inline for ([4]u16{ 0x4000, 0xBC00, 0x3800, 0x3C00 }, 0..) |bits, k| std.mem.writeInt(u16, want_half[k * 2 ..][0..2], bits, .little);
    var want_word: [16]u8 = undefined;
    inline for ([4]u32{ 0x4000_0000, 0xBF80_0000, 0x3F00_0000, 0x3F80_0000 }, 0..) |bits, k| std.mem.writeInt(u32, want_word[k * 4 ..][0..4], bits, .little);
    // Every texel of both levels, and of the whole floats beside them.
    for (0..16) |k| try testing.expectEqualSlices(u8, &want_half, read_back[k * 8 ..][0..8]);
    for (0..4) |k| try testing.expectEqualSlices(u8, &want_half, read_back[at_level1 + k * 8 ..][0..8]);
    for (0..16) |k| try testing.expectEqualSlices(u8, &want_word, read_back[at_words + k * 16 ..][0..16]);

    // The packed formats read back through the reader, not compared byte
    // for byte: each holds 2 and 0.5 exactly, has no green below 0 to
    // hold, and answers an alpha of 1 it has not got.
    for (0..16) |k| {
        try testing.expectEqual([4]f32{ 2, 0, 0.5, 1 }, texture_zig.floatParts(.rg11b10f, read_back + at_packed + k * 4));
        try testing.expectEqual([4]f32{ 2, 0, 0.5, 1 }, texture_zig.floatParts(.rgb9e5, read_back + at_shared + k * 4));
        try testing.expectEqual([4]f32{ 2, 0, 0, 1 }, texture_zig.floatParts(.r32f, read_back + at_reds + k * 4));
    }
    // Nothing was written past the last texel of the last image.
    try testing.expectEqual(@as(u8, 0xAA), read_back[at_reds + 64]);

    // --- 1.70: a clear of an image of whole numbers ---
    // Such an image reads `uint32` of the colour, or `int32` where its
    // format is signed, as Vulkan has it: `float32` could not say 70000
    // at all. Each number is held to what its channel holds.
    const at_numbers = 640;
    const numbers = try bench.bareImage(.{ .format = .r16g16b16a16_sint, .extent = side4, .usage = usage }, false);
    const number_color = facet.ClearColorValue{ .int32 = .{ 300, -5, 70000, 1 } };
    const number_copy = facet.BufferImageCopy{ .buffer_offset = at_numbers, .image_extent = side4 };
    const number_commands = try bench.record();
    fb.CmdClearColorImage(number_commands, numbers, .transfer_dst_optimal, &number_color, 1, @ptrCast(&whole));
    fb.CmdCopyImageToBuffer(number_commands, numbers, .general, read_buffer, 1, @ptrCast(&number_copy));
    try bench.submit();
    var want_numbers: [8]u8 = undefined;
    inline for ([4]i16{ 300, -5, 32767, 1 }, 0..) |one, k| std.mem.writeInt(i16, want_numbers[k * 2 ..][0..2], one, .little);
    for (0..16) |k| try testing.expectEqualSlices(u8, &want_numbers, read_back[at_numbers + k * 8 ..][0..8]);
    try testing.expectEqual(@as(u8, 0xAA), read_back[at_numbers + 128]);
}

/// A quad over the whole target, and the forms that sample a texture kept
/// a texel smaller: one word of 8888, one byte of red, and the spread form
/// handed either.
const SmallScene = struct {
    const entries = [_]shader.Entry{
        shader.vertex("word", &FloatScene.flat, 2),
        shader.fixedFragment("word", .{ .kind = .texture, .sampling = .{ .format = .argb8888, .filter = .nearest } }),
        shader.vertex("red", &FloatScene.flat, 2),
        shader.fixedFragment("red", .{ .kind = .texture, .sampling = .{ .format = .r8, .filter = .nearest } }),
        shader.vertex("spread", &FloatScene.flat, 2),
        shader.fixedFragment("spread", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest } }),
    };
    const code = shader.Code{ .entry_count = entries.len, .entries = &entries };
};

test "a texel kept smaller than its colour: 8888 in its word, and one byte of red" {
    var bench = try Bench.up();
    defer bench.down();
    const fb = bench.rig.fb;
    const device = bench.device;

    var features: facet.PhysicalDeviceFeatures = undefined;
    fb.GetPhysicalDeviceFeatures(bench.physical, &features);
    try testing.expect(features.small_texels);
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(bench.physical, .r8_unorm, &properties);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0);
    try testing.expect(properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT == 0);
    // A texel buffer of one byte a texel as well, since 1.54, and no
    // vertex attribute is read in it.
    try testing.expectEqual(facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER, properties.buffer_features);

    const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    // Eight by eight: a level of 64 texels, so that what each format
    // takes is above the alignment an image's memory is rounded up to.
    const side = facet.Extent3D{ .width = 8, .height = 8 };
    const spread_image = try bench.bareImage(.{ .format = .b8g8r8a8_unorm, .extent = side, .usage = usage }, false);
    const word_image = try bench.bareImage(.{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .b8g8r8a8_unorm, .extent = side, .usage = usage }, false);
    const red_image = try bench.bareImage(.{ .format = .r8_unorm, .extent = side, .usage = usage }, false);

    // What each takes: eight bytes a texel spread, four in a word, one for
    // the red alone.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, spread_image, &needs);
    try testing.expectEqual(@as(u64, 8 * 8 * 8), needs.size);
    fb.GetImageMemoryRequirements(device, word_image, &needs);
    try testing.expectEqual(@as(u64, 8 * 8 * 4), needs.size);
    fb.GetImageMemoryRequirements(device, red_image, &needs);
    try testing.expectEqual(@as(u64, 8 * 8 * 1), needs.size);

    // Refused: the flag where the format has no word of 8888 to keep, and
    // where nothing samples the image.
    var refused: ?*facet.Image = null;
    const packed565 = facet.ImageCreateInfo{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .r5g6b5_unorm_pack16, .extent = side, .usage = usage };
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &packed565, &refused));
    const packed_rows = facet.ImageCreateInfo{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .b8g8r8a8_unorm, .extent = side, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &packed_rows, &refused));
    const red_rows = facet.ImageCreateInfo{ .format = .r8_unorm, .extent = side, .usage = facet.IMAGE_USAGE_TRANSFER_DST };
    try testing.expectEqual(facet.Result.error_format_not_supported, fb.CreateImage(device, &red_rows, &refused));

    const spread_view = try bench.viewOf(.{ .image = spread_image, .format = .b8g8r8a8_unorm });
    const word_view = try bench.viewOf(.{ .image = word_image, .format = .b8g8r8a8_unorm });
    const red_view = try bench.viewOf(.{ .image = red_image, .format = .r8_unorm });

    // A colour of its own on the left and another on the right, and the
    // reds of those in the one-byte image.
    const left_color: u32 = 0xFF20_4080;
    const right_color: u32 = 0xFFC0_6010;
    const reds_at = 8 * 8 * 4;
    const staging, const staged = try bench.buffer(512, facet.BUFFER_USAGE_TRANSFER_SRC);
    for (0..64) |k| {
        const color = if (k % 8 < 4) left_color else right_color;
        std.mem.writeInt(u32, staged[k * 4 ..][0..4], color, .little);
        staged[reds_at + k] = @truncate(color >> 16);
    }
    const words = facet.BufferImageCopy{ .image_extent = side };
    const reds = facet.BufferImageCopy{ .buffer_offset = reds_at, .image_extent = side };
    _, const read_back = try bench.buffer(512, facet.BUFFER_USAGE_TRANSFER_DST);
    const read_buffer = bench.buffers[bench.buffer_count - 1];

    const commands = try bench.record();
    fb.CmdCopyBufferToImage(commands, staging, spread_image, .transfer_dst_optimal, 1, @ptrCast(&words));
    fb.CmdCopyBufferToImage(commands, staging, word_image, .transfer_dst_optimal, 1, @ptrCast(&words));
    fb.CmdCopyBufferToImage(commands, staging, red_image, .transfer_dst_optimal, 1, @ptrCast(&reds));
    fb.CmdCopyImageToBuffer(commands, red_image, .general, read_buffer, 1, @ptrCast(&reds));
    try bench.submit();
    // One byte a texel came back, as it went in.
    try testing.expectEqualSlices(u8, staged[reds_at..][0..64], read_back[reds_at..][0..64]);

    var set_layout: ?*facet.DescriptorSetLayout = null;
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout));
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var pool: ?*facet.DescriptorPool = null;
    try testing.expectEqual(facet.Result.success, fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool));
    defer fb.DestroyDescriptorPool(device, pool);
    var set: [1]?*facet.DescriptorSet = undefined;
    try testing.expectEqual(facet.Result.success, fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &set));

    const shaders = try module(&bench, &SmallScene.code);
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
    const offset: u64 = 0;
    const black = clears(0xFF00_0000);

    const drawn = struct {
        fn drawn(on: *Bench, view: *facet.ImageView, name: [*:0]const u8, made_layout: *facet.PipelineLayout, into: *facet.RenderPass, into_frame: *facet.Framebuffer, code_module: *facet.ShaderModule, sets: *[1]?*facet.DescriptorSet, vertices: *facet.Buffer, first: *const u64, clear_values: *const [2]facet.ClearValue) !void {
            const f = on.rig.fb;
            const image_info = facet.DescriptorImageInfo{ .image_view = view };
            const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            f.UpdateDescriptorSets(on.device, 1, @ptrCast(&write), 0, null);
            const result, const pipeline = makePipeline(on, .{ .module = code_module, .name = name, .layout = made_layout, .pass = into });
            try testing.expectEqual(facet.Result.success, result);
            defer f.DestroyPipeline(on.device, pipeline);
            const recording = try on.record();
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = into_frame, .render_area = .{ .extent = .{ .width = 64, .height = 64 } }, .clear_value_count = 1, .clear_values = clear_values }, .@"inline");
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdBindDescriptorSets(recording, .graphics, made_layout, 0, 1, @ptrCast(sets), 0, null);
            f.CmdBindPipeline(recording, .graphics, pipeline.?);
            f.CmdDraw(recording, 6, 1, 0, 0);
            f.CmdEndRenderPass(recording);
            try on.submit();
        }
    }.drawn;

    // The word a texel reads what the spread one reads.
    try drawn(&bench, spread_view, "spread", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(left_color, picture.at(8, 8));
    try testing.expectEqual(right_color, picture.at(56, 56));
    try drawn(&bench, word_view, "word", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(left_color, picture.at(8, 8));
    try testing.expectEqual(right_color, picture.at(56, 56));
    // The one-byte one reads red alone, the green and blue 0.
    try drawn(&bench, red_view, "red", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(0xFF00_0000 | (left_color & 0x00FF_0000), picture.at(8, 8));
    try testing.expectEqual(0xFF00_0000 | (right_color & 0x00FF_0000), picture.at(56, 56));
    // A form built for the spread 8888 handed either: the run-time
    // sampler draws it, and reads the same colours.
    try drawn(&bench, word_view, "spread", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(left_color, picture.at(8, 8));
    try drawn(&bench, red_view, "spread", layout, pass, frame, shaders, &set, vertex_buffer, &offset, &black);
    try testing.expectEqual(0xFF00_0000 | (right_color & 0x00FF_0000), picture.at(56, 56));
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
