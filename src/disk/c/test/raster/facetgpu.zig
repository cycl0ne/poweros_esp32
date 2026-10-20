// SPDX-License-Identifier: MIT
//! What C:test/FacetCube and C:test/FacetWindow make through
//! facet.library to draw C:test/Cube's textured cube in front of its
//! backdrop (facetscene.zig): the device and its queue, a surface over a
//! screen or a window, a swapchain on it and a framebuffer over each of
//! its images, and the pipelines, buffers and texture of the scene. The
//! pipelines take their viewport and scissor as each frame is recorded,
//! so that a new swapchain - a window made bigger - needs only new
//! framebuffers.

const sdk = @import("sdk");
const scenes = @import("scenes.zig");
const scene = @import("facetscene.zig");
const facet = sdk.facet;
const intuition = sdk.intuition;
const FacetBase = sdk.interface.facet.FacetBase;

pub const most_images = 4;

pub const Failure = error{ NoMemory, NoDevice, NoSurface, NotThirtyTwoBits, NoSwapchain, Refused };

/// Everything made through facet.library, given back by `down` in the
/// order it goes.
pub const Gpu = struct {
    fb: *FacetBase,
    instance: ?*facet.Instance = null,
    physical: *facet.PhysicalDevice = undefined,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    surface: ?*facet.Surface = null,
    swapchain: ?*facet.Swapchain = null,
    format: facet.Format = .undefined,
    width: u32 = 0,
    height: u32 = 0,
    image_count: u32 = 0,
    images: [most_images]*facet.Image = undefined,
    views: [most_images]?*facet.ImageView = @splat(null),
    framebuffers: [most_images]?*facet.Framebuffer = @splat(null),
    /// Each image is cleared black once, the first time it is drawn into.
    cleared: [most_images]bool = @splat(false),
    depth: ?*facet.Image = null,
    depth_view: ?*facet.ImageView = null,
    depth_memory: ?*facet.DeviceMemory = null,
    texture: ?*facet.Image = null,
    texture_view: ?*facet.ImageView = null,
    staging: ?*facet.Buffer = null,
    vertices: ?*facet.Buffer = null,
    indices: ?*facet.Buffer = null,
    memories: [8]?*facet.DeviceMemory = @splat(null),
    pass: ?*facet.RenderPass = null,
    set_layout: ?*facet.DescriptorSetLayout = null,
    descriptor_pool: ?*facet.DescriptorPool = null,
    set: ?*facet.DescriptorSet = null,
    layout: ?*facet.PipelineLayout = null,
    module: ?*facet.ShaderModule = null,
    backdrop: ?*facet.Pipeline = null,
    box: ?*facet.Pipeline = null,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    acquired: ?*facet.Semaphore = null,
    rendered: ?*facet.Semaphore = null,

    pub fn down(gpu: *Gpu) void {
        const fb = gpu.fb;
        if (gpu.device) |device| {
            _ = fb.DeviceWaitIdle(device);
            gpu.unchain();
            fb.DestroySwapchain(device, gpu.swapchain);
            fb.DestroySemaphore(device, gpu.rendered);
            fb.DestroySemaphore(device, gpu.acquired);
            fb.DestroyFence(device, gpu.fence);
            fb.DestroyCommandPool(device, gpu.command_pool);
            fb.DestroyPipeline(device, gpu.box);
            fb.DestroyPipeline(device, gpu.backdrop);
            fb.DestroyShaderModule(device, gpu.module);
            fb.DestroyPipelineLayout(device, gpu.layout);
            fb.DestroyDescriptorPool(device, gpu.descriptor_pool);
            fb.DestroyDescriptorSetLayout(device, gpu.set_layout);
            fb.DestroyRenderPass(device, gpu.pass);
            fb.DestroyImageView(device, gpu.texture_view);
            fb.DestroyImage(device, gpu.texture);
            fb.DestroyBuffer(device, gpu.staging);
            fb.DestroyBuffer(device, gpu.vertices);
            fb.DestroyBuffer(device, gpu.indices);
            for (gpu.memories) |each| fb.FreeMemory(device, each);
            fb.DestroyDevice(device);
        }
        if (gpu.instance) |instance| {
            fb.DestroySurface(instance, gpu.surface);
            fb.DestroyInstance(instance);
        }
    }

    /// The instance, and the device and its queue.
    pub fn up(gpu: *Gpu, name: [*:0]const u8) Failure!void {
        const fb = gpu.fb;
        try expect(fb.CreateInstance(&.{ .application_name = name }, &gpu.instance), error.NoDevice);
        var count: u32 = 1;
        var physical: [1]*facet.PhysicalDevice = undefined;
        if (fb.EnumeratePhysicalDevices(gpu.instance.?, &count, &physical) != .success or count == 0) return error.NoDevice;
        gpu.physical = physical[0];
        fb.GetPhysicalDeviceMemoryProperties(gpu.physical, &gpu.memory);
        const queue_info = facet.DeviceQueueCreateInfo{};
        try expect(fb.CreateDevice(gpu.physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &gpu.device), error.NoDevice);
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(gpu.device.?, 0, 0, &queue);
        gpu.queue = queue.?;
    }

    /// The surface over the whole of `screen`.
    pub fn onScreen(gpu: *Gpu, screen: *intuition.Screen) Failure!void {
        try expect(gpu.fb.CreateScreenSurface(gpu.instance.?, &.{ .screen = screen }, &gpu.surface), error.NoSurface);
        try gpu.formatOfSurface();
    }

    /// The surface over the inside of `window`.
    pub fn onWindow(gpu: *Gpu, window: *intuition.Window) Failure!void {
        try expect(gpu.fb.CreateWindowSurface(gpu.instance.?, &.{ .window = window }, &gpu.surface), error.NoSurface);
        try gpu.formatOfSurface();
    }

    fn formatOfSurface(gpu: *Gpu) Failure!void {
        const fb = gpu.fb;
        var supported = false;
        _ = fb.GetPhysicalDeviceSurfaceSupport(gpu.physical, 0, gpu.surface.?, &supported);
        var formats: [1]facet.SurfaceFormat = undefined;
        var count: u32 = 1;
        _ = fb.GetPhysicalDeviceSurfaceFormats(gpu.physical, gpu.surface.?, &count, &formats);
        if (!supported or count == 0) return error.NotThirtyTwoBits;
        gpu.format = formats[0].format;
    }

    /// A swapchain of `wanted` images on the surface at its size now - or
    /// of one, where there is no room for more - handed the one before,
    /// which then goes; and a framebuffer over each image, with a depth
    /// image of their size.
    pub fn chain(gpu: *Gpu, wanted: u32) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        var capabilities: facet.SurfaceCapabilities = undefined;
        _ = fb.GetPhysicalDeviceSurfaceCapabilities(gpu.physical, gpu.surface.?, &capabilities);
        const old = gpu.swapchain;
        if (old != null) {
            _ = fb.DeviceWaitIdle(device);
            gpu.unchain();
        }
        var info = facet.SwapchainCreateInfo{
            .surface = gpu.surface.?,
            .min_image_count = @min(wanted, capabilities.max_image_count),
            .image_format = gpu.format,
            .image_extent = capabilities.current_extent,
            .old_swapchain = old,
        };
        var made = fb.CreateSwapchain(device, &info, &gpu.swapchain);
        if (made == .error_out_of_device_memory) {
            info.min_image_count = 1;
            made = fb.CreateSwapchain(device, &info, &gpu.swapchain);
        }
        fb.DestroySwapchain(device, old);
        if (made != .success) {
            gpu.swapchain = null;
            return error.NoSwapchain;
        }
        gpu.width = capabilities.current_extent.width;
        gpu.height = capabilities.current_extent.height;
        gpu.image_count = most_images;
        _ = fb.GetSwapchainImages(device, gpu.swapchain.?, &gpu.image_count, &gpu.images);
        gpu.cleared = @splat(false);

        // Depth lives in the tiles alone: memory with nothing behind it.
        try expect(fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = .{ .width = gpu.width, .height = gpu.height }, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &gpu.depth), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, gpu.depth.?, &needs);
        const type_index = try gpu.typeFor(needs, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = type_index }, &gpu.depth_memory), error.NoMemory);
        try expect(fb.BindImageMemory(device, gpu.depth.?, gpu.depth_memory.?, 0), error.Refused);
        gpu.depth_view = try gpu.view(gpu.depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);
        for (gpu.images[0..gpu.image_count], 0..) |each, k| {
            gpu.views[k] = try gpu.view(each, gpu.format, facet.IMAGE_ASPECT_COLOR, 1);
            const views = [2]*facet.ImageView{ gpu.views[k].?, gpu.depth_view.? };
            try expect(fb.CreateFramebuffer(device, &.{ .render_pass = gpu.pass.?, .attachment_count = 2, .attachments = &views, .width = gpu.width, .height = gpu.height }, &gpu.framebuffers[k]), error.Refused);
        }
    }

    /// What `chain` made over the swapchain's images given back, the
    /// swapchain kept.
    fn unchain(gpu: *Gpu) void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        for (&gpu.framebuffers) |*each| {
            fb.DestroyFramebuffer(device, each.*);
            each.* = null;
        }
        for (&gpu.views) |*each| {
            fb.DestroyImageView(device, each.*);
            each.* = null;
        }
        fb.DestroyImageView(device, gpu.depth_view);
        fb.DestroyImage(device, gpu.depth);
        fb.FreeMemory(device, gpu.depth_memory);
        gpu.depth_view = null;
        gpu.depth = null;
        gpu.depth_memory = null;
    }

    /// The render pass, the texture copied in, the buffers, the pipelines
    /// and what a frame is recorded and waited for with: everything but
    /// the swapchain.
    pub fn prepare(gpu: *Gpu, nearest: bool, pattern: *const facet.texture.Texture) Failure!void {
        const fb = gpu.fb;
        const device = gpu.device.?;
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = gpu.format, .load_op = .clear, .store_op = .store, .final_layout = .present_src },
            .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &gpu.pass), error.Refused);

        const levels = scenes.texture_levels;
        gpu.texture = try gpu.image(.{
            .format = .b8g8r8a8_unorm,
            .extent = .{ .width = scenes.texture_side, .height = scenes.texture_side },
            .mip_levels = levels,
            .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
        });
        gpu.texture_view = try gpu.view(gpu.texture.?, .b8g8r8a8_unorm, facet.IMAGE_ASPECT_COLOR, levels);
        gpu.staging, const staged = try gpu.buffer(scene.staged_bytes, facet.BUFFER_USAGE_TRANSFER_SRC);
        const regions = scene.stage(pattern, staged);

        const backdrop_vertices = scenes.backdrop(scene.Vertex);
        const cube_vertices = scenes.cube(scene.Vertex);
        const backdrop_bytes = @sizeOf(@TypeOf(backdrop_vertices));
        const cube_bytes = @sizeOf(@TypeOf(cube_vertices));
        gpu.vertices, const vertex_bytes = try gpu.buffer(backdrop_bytes + cube_bytes, facet.BUFFER_USAGE_VERTEX_BUFFER);
        @memcpy(vertex_bytes[0..backdrop_bytes], @as([*]const u8, @ptrCast(&backdrop_vertices)));
        @memcpy(vertex_bytes[backdrop_bytes..][0..cube_bytes], @as([*]const u8, @ptrCast(&cube_vertices)));
        const indices = scenes.quad_indices ++ scenes.cube_indices;
        gpu.indices, const index_bytes = try gpu.buffer(@sizeOf(@TypeOf(indices)), facet.BUFFER_USAGE_INDEX_BUFFER);
        @memcpy(index_bytes[0..@sizeOf(@TypeOf(indices))], @as([*]const u8, @ptrCast(&indices)));

        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &gpu.set_layout), error.Refused);
        try expect(fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &gpu.descriptor_pool), error.Refused);
        var sets: [1]?*facet.DescriptorSet = undefined;
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = gpu.descriptor_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&gpu.set_layout) }, &sets), error.Refused);
        gpu.set = sets[0];
        const image_info = facet.DescriptorImageInfo{ .image_view = gpu.texture_view };
        const write = facet.WriteDescriptorSet{ .dst_set = gpu.set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

        try expect(fb.CreateShaderModule(device, &.{ .code = &scene.code }, &gpu.module), error.Refused);
        const range = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = 64 };
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&gpu.set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &gpu.layout), error.Refused);
        gpu.backdrop = try gpu.pipeline("backdrop", "backdrop", .{});
        gpu.box = try gpu.pipeline("box", if (nearest) "box nearest" else "box", .{ .cull_mode = facet.CULL_MODE_BACK, .front_face = .clockwise });

        try expect(fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &gpu.command_pool), error.Refused);
        var commands: [1]?*facet.CommandBuffer = undefined;
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = gpu.command_pool.?, .command_buffer_count = 1 }, &commands), error.Refused);
        gpu.commands = commands[0];
        try expect(fb.CreateFence(device, &.{}, &gpu.fence), error.Refused);
        try expect(fb.CreateSemaphore(device, &.{}, &gpu.acquired), error.Refused);
        try expect(fb.CreateSemaphore(device, &.{}, &gpu.rendered), error.Refused);

        // The texture copied in, and waited for.
        const recording = try gpu.begin();
        fb.CmdCopyBufferToImage(recording, gpu.staging.?, gpu.texture.?, .transfer_dst_optimal, levels, &regions);
        try gpu.submitAndWait(null, null);
    }

    /// An image as `info` says, bound into memory of its own.
    fn image(gpu: *Gpu, info: facet.ImageCreateInfo) Failure!*facet.Image {
        const fb = gpu.fb;
        var made: ?*facet.Image = null;
        try expect(fb.CreateImage(gpu.device.?, &info, &made), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(gpu.device.?, made.?, &needs);
        const block = gpu.allocate(needs, 0) catch |err| {
            fb.DestroyImage(gpu.device.?, made);
            return err;
        };
        try expect(fb.BindImageMemory(gpu.device.?, made.?, block, 0), error.Refused);
        return made.?;
    }

    fn view(gpu: *Gpu, of: *facet.Image, format: facet.Format, aspect: u32, levels: u32) Failure!*facet.ImageView {
        var made: ?*facet.ImageView = null;
        try expect(gpu.fb.CreateImageView(gpu.device.?, &.{ .image = of, .format = format, .subresource_range = .{ .aspect_mask = aspect, .level_count = levels } }, &made), error.Refused);
        return made.?;
    }

    /// A buffer of `bytes`, bound into memory the program sees, and its
    /// bytes.
    fn buffer(gpu: *Gpu, bytes: u64, usage: u32) Failure!struct { *facet.Buffer, [*]u8 } {
        const fb = gpu.fb;
        var made: ?*facet.Buffer = null;
        try expect(fb.CreateBuffer(gpu.device.?, &.{ .size = bytes, .usage = usage }, &made), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(gpu.device.?, made.?, &needs);
        const block = gpu.allocate(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE) catch |err| {
            fb.DestroyBuffer(gpu.device.?, made);
            return err;
        };
        try expect(fb.BindBufferMemory(gpu.device.?, made.?, block, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(gpu.device.?, block, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        return .{ made.?, @ptrCast(data.?) };
    }

    /// A block of memory as `needs` says, of the first type with
    /// `wanted`, kept until `down`.
    fn allocate(gpu: *Gpu, needs: facet.MemoryRequirements, wanted: u32) Failure!*facet.DeviceMemory {
        const type_index = try gpu.typeFor(needs, wanted);
        const slot = for (&gpu.memories) |*slot| {
            if (slot.* == null) break slot;
        } else return error.NoMemory;
        try expect(gpu.fb.AllocateMemory(gpu.device.?, &.{ .allocation_size = needs.size, .memory_type_index = type_index }, slot), error.NoMemory);
        return slot.*.?;
    }

    /// The first memory type `needs` allows with `wanted`.
    fn typeFor(gpu: *const Gpu, needs: facet.MemoryRequirements, wanted: u32) Failure!u32 {
        for (gpu.memory.memory_types[0..gpu.memory.memory_type_count], 0..) |kind, k| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(k) != 0 and kind.property_flags & wanted == wanted) return @intCast(k);
        }
        return error.NoMemory;
    }

    /// A pipeline drawing the vertex function `vertex` and the fragment
    /// function `fragment` of the scene's, nearer kept, into the viewport
    /// and scissor each frame sets.
    fn pipeline(gpu: *Gpu, vertex: [*:0]const u8, fragment: [*:0]const u8, rasterization: facet.PipelineRasterizationStateCreateInfo) Failure!*facet.Pipeline {
        const stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = gpu.module.?, .name = vertex },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = gpu.module.?, .name = fragment },
        };
        const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(scene.Vertex) };
        const input = facet.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = scene.attributes.len,
            .vertex_attribute_descriptions = &scene.attributes,
        };
        const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list };
        const viewports = facet.PipelineViewportStateCreateInfo{};
        const dynamic_states = [2]facet.DynamicState{ .viewport, .scissor };
        const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = dynamic_states.len, .dynamic_states = &dynamic_states };
        const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true };
        const blend_attachment = facet.PipelineColorBlendAttachmentState{};
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
            .layout = gpu.layout.?,
            .render_pass = gpu.pass.?,
        };
        var made: [1]?*facet.Pipeline = undefined;
        try expect(gpu.fb.CreateGraphicsPipelines(gpu.device.?, null, 1, @ptrCast(&info), &made), error.Refused);
        return made[0].?;
    }

    /// The command buffer, begun anew.
    fn begin(gpu: *Gpu) Failure!*facet.CommandBuffer {
        try expect(gpu.fb.BeginCommandBuffer(gpu.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        return gpu.commands.?;
    }

    /// The command buffer ended and submitted, waiting for `wait` and
    /// signalling `signal`, and its fence waited for and reset.
    pub fn submitAndWait(gpu: *Gpu, wait: ?*facet.Semaphore, signal: ?*facet.Semaphore) Failure!void {
        const fb = gpu.fb;
        try expect(fb.EndCommandBuffer(gpu.commands.?), error.Refused);
        const stage: u32 = facet.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT;
        const submit = facet.SubmitInfo{
            .wait_semaphore_count = @intFromBool(wait != null),
            .wait_semaphores = @ptrCast(&wait),
            .wait_dst_stage_mask = @ptrCast(&stage),
            .command_buffer_count = 1,
            .command_buffers = @ptrCast(&gpu.commands),
            .signal_semaphore_count = @intFromBool(signal != null),
            .signal_semaphores = @ptrCast(&signal),
        };
        try expect(fb.QueueSubmit(gpu.queue, 1, @ptrCast(&submit), gpu.fence), error.Refused);
        try expect(fb.WaitForFences(gpu.device.?, 1, @ptrCast(&gpu.fence), true, facet.WAIT_FOREVER_NS), error.Refused);
        try expect(fb.ResetFences(gpu.device.?, 1, @ptrCast(&gpu.fence)), error.Refused);
    }

    /// Image `index` cleared black, all of it, waiting for the acquire.
    pub fn clear(gpu: *Gpu, index: u32) Failure!void {
        const fb = gpu.fb;
        const recording = try gpu.begin();
        const black = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
        fb.CmdBeginRenderPass(recording, &.{ .render_pass = gpu.pass.?, .framebuffer = gpu.framebuffers[index].?, .render_area = .{ .extent = .{ .width = gpu.width, .height = gpu.height } }, .clear_value_count = 2, .clear_values = &black }, .@"inline");
        fb.CmdEndRenderPass(recording);
        try gpu.submitAndWait(gpu.acquired, null);
        gpu.cleared[index] = true;
    }

    /// A frame recorded into `area` of image `index`: the area cleared,
    /// the backdrop over it and the box turned by `transform`.
    pub fn record(gpu: *Gpu, index: u32, area: facet.Rect2D, transform: *const [16]f32) Failure!void {
        const fb = gpu.fb;
        const recording = try gpu.begin();
        const black = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
        fb.CmdBeginRenderPass(recording, &.{ .render_pass = gpu.pass.?, .framebuffer = gpu.framebuffers[index].?, .render_area = area, .clear_value_count = 2, .clear_values = &black }, .@"inline");
        const viewport = facet.Viewport{
            .x = @floatFromInt(area.offset.x),
            .y = @floatFromInt(area.offset.y),
            .width = @floatFromInt(area.extent.width),
            .height = @floatFromInt(area.extent.height),
        };
        fb.CmdSetViewport(recording, 0, 1, @ptrCast(&viewport));
        fb.CmdSetScissor(recording, 0, 1, @ptrCast(&area));
        const offset: u64 = 0;
        fb.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&gpu.vertices), @ptrCast(&offset));
        fb.CmdBindIndexBuffer(recording, gpu.indices.?, 0, .uint16);
        fb.CmdBindDescriptorSets(recording, .graphics, gpu.layout.?, 0, 1, @ptrCast(&gpu.set), 0, null);
        fb.CmdBindPipeline(recording, .graphics, gpu.backdrop.?);
        fb.CmdDrawIndexed(recording, scenes.quad_indices.len, 1, 0, 0, 0);
        fb.CmdBindPipeline(recording, .graphics, gpu.box.?);
        fb.CmdPushConstants(recording, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf([16]f32), transform);
        fb.CmdDrawIndexed(recording, scenes.cube_indices.len, 1, scenes.quad_indices.len, 4, 0);
        fb.CmdEndRenderPass(recording);
    }

    /// Image `index` handed to the queue, shown once drawn.
    pub fn present(gpu: *Gpu, index: u32) facet.Result {
        return gpu.fb.QueuePresent(gpu.queue, &.{
            .wait_semaphore_count = 1,
            .wait_semaphores = @ptrCast(&gpu.rendered),
            .swapchains = @ptrCast(&gpu.swapchain),
            .image_indices = @ptrCast(&index),
        });
    }
};

pub fn expect(result: facet.Result, failure: Failure) Failure!void {
    if (result != .success) return failure;
}

/// What a failure says.
pub fn explain(err: Failure) [*:0]const u8 {
    return switch (err) {
        error.NoMemory => "Not enough memory",
        error.NoDevice => "No device of facet.library's",
        error.NoSurface => "No surface over it",
        error.NotThirtyTwoBits => "The display is not 32 bits a pixel",
        error.NoSwapchain => "No swapchain: no room for its images",
        error.Refused => "facet.library refused something",
    };
}
