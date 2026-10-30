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
const _pipeline = @import("../pipeline/_pipeline.zig");
const testing = std.testing;

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
    images: [8]*facet.Image = undefined,
    image_count: u32 = 0,
    views: [8]*facet.ImageView = undefined,
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
        const fb = bench.rig.fb;
        var made: ?*facet.Image = null;
        try testing.expectEqual(facet.Result.success, fb.CreateImage(bench.device, &info, &made));
        bench.images[bench.image_count] = made.?;
        bench.image_count += 1;
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(bench.device, made.?, &needs);
        const block = try bench.memory(needs.size, if (lazy) 2 else 0);
        try testing.expectEqual(facet.Result.success, fb.BindImageMemory(bench.device, made.?, block, 0));
        var view: ?*facet.ImageView = null;
        const aspect = if (info.format == .d16_unorm) facet.IMAGE_ASPECT_DEPTH else facet.IMAGE_ASPECT_COLOR;
        try testing.expectEqual(facet.Result.success, fb.CreateImageView(bench.device, &.{ .image = made.?, .format = info.format, .subresource_range = .{ .aspect_mask = aspect } }, &view));
        bench.views[bench.view_count] = view.?;
        bench.view_count += 1;
        return .{ made.?, view.? };
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

    fn allocateMemory(device: *Device, memory: *DeviceMemory) facet.Result {
        allocated += 1;
        return cpu.ops.allocate_memory(device, memory);
    }

    fn freeMemory(device: *Device, memory: *DeviceMemory) void {
        freed += 1;
        cpu.ops.free_memory(device, memory);
    }

    fn makeOne(pipeline: *_pipeline.Pipeline) facet.Result {
        made += 1;
        return cpu.ops.make_pipeline(pipeline);
    }

    fn unmakePipeline(pipeline: *_pipeline.Pipeline) void {
        unmade += 1;
        cpu.ops.unmake_pipeline(pipeline);
    }

    fn openQueue(queue: *Queue) bool {
        opened += 1;
        return cpu.ops.open_queue(queue);
    }

    fn closeQueue(queue: *Queue) void {
        closed += 1;
        cpu.ops.close_queue(queue);
    }

    fn execute(queue: *Queue, buffer: *CommandBuffer, done: *sdk.exec.Waitable) void {
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
    const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&state.blend) };
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
    try testing.expectEqual(@as(u32, 0), made.color);
    try testing.expectEqual(@as(?u32, 1), made.depth);
    try testing.expectEqual(.keep, made.color_load);
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
    // A reference past the attachments; two subpasses; none of colour.
    const fine = [2]facet.AttachmentDescription{ .{ .format = .b8g8r8a8_unorm, .final_layout = .general }, .{ .format = .d16_unorm, .final_layout = .general } };
    var none: ?*facet.RenderPass = null;
    try testing.expectEqual(facet.Result.error_initialization_failed, fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = &fine, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &none));
    const two = [2]facet.SubpassDescription{ subpass, subpass };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &fine, .subpass_count = 2, .subpasses = &two }, &none));
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
    try testing.expect(made.depth != null);
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
    const compute = [1]shader.Entry{.{ .name = "main", .stage = 0x20, .function = &Flat.vertex, .varyings = 0 }};
    try testing.expectEqual(facet.Result.error_invalid_shader_nv, fb.CreateShaderModule(device, &.{ .code = &shader.Code{ .entry_count = 1, .entries = &compute } }, &none));
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
    const sampler = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler };
    try testing.expectEqual(facet.Result.error_feature_not_present, fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&sampler) }, &none));
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
    try testing.expectEqual(.alpha, made.blend);
    try testing.expectEqual(@as(f32, 64), made.viewport.?.width);
    try testing.expect(made.scissor == null);
    try testing.expectEqual(@as(u32, 1), made.locations);
    fb.DestroyPipeline(device, pipeline);
    fb.DestroyPipeline(device, null);

    // The rasterizer discarding, or both faces culled: made, draws nothing.
    state = base;
    state.raster = .{ .cull_mode = facet.CULL_MODE_FRONT_AND_BACK };
    const culled_result, const culled = makePipeline(&bench, state);
    try testing.expectEqual(facet.Result.success, culled_result);
    try testing.expect(_objects.of(_pipeline.Pipeline, culled.?).draws_nothing);
    fb.DestroyPipeline(device, culled);

    const Change = struct { facet.Result, PipelineState };
    var changes: [9]Change = @splat(.{ .success, base });
    changes[0][0] = .error_feature_not_present;
    changes[0][1].topology = .line_list;
    changes[1][0] = .error_feature_not_present;
    changes[1][1].depth = .{ .stencil_test_enable = true };
    changes[2][0] = .error_feature_not_present;
    changes[2][1].blend = .{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one };
    changes[3][0] = .error_feature_not_present;
    changes[3][1].blend = .{ .color_write_mask = facet.COLOR_COMPONENT_R };
    changes[4][0] = .error_feature_not_present;
    changes[4][1].raster = .{ .polygon_mode = .line };
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

    fn execute(queue: *Queue, buffer: *CommandBuffer, done: *sdk.exec.Waitable) void {
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
