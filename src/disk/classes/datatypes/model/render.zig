// SPDX-License-Identifier: MIT
//! model.datatype's process: everything made through facet.library, and
//! the frames drawn with it.
//!
//! The object starts it when it is first laid out, and it lives as long
//! as the object. It opens facet.library, makes a device, copies the
//! model in - the vertices and indices into buffers, each material's
//! picture into a texture - and gives back what the object held of them.
//! Then it waits. A change of the camera or the room, or a picture put
//! up, wakes it (`SIGBREAKF_CTRL_F`); it draws from what the camera is
//! when it begins, into a picture of the room's size in the screen's
//! pixels, makes it ready and asks for the object to be drawn again, and
//! goes on while what it drew is behind what is wanted. While nothing
//! changes it draws nothing. Turning by itself, it draws a frame once the
//! one before is on show and `turn_frame_us` has gone by since it began,
//! timer.device waking it for that: without the wait it would draw as
//! fast as frames can be drawn and put up, and take every core for a
//! model turning no faster.
//!
//! What it makes is its own: no other task uses the device. The pictures
//! are memory the program can see, so `GM_RENDER` reads one where it is.
//! When something cannot be had - facet.library, a device, memory, a
//! screen it draws on - it says so in the object's room and waits to be
//! told to go; what it made is given back only then, when the object has
//! been taken out of its window and nothing reads a picture any more.

const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const timer = sdk.devices.timer;
const mdt = sdk.datatypes.modelclass;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;
const ExecBase = sdk.interface.exec.ExecBase;
const FacetBase = sdk.interface.facet.FacetBase;
const TimerBase = sdk.interface.timer.TimerBase;
const state = @import("state.zig");
const camera = @import("camera.zig");
const shading = @import("shading.zig");
const levels = @import("levels.zig");
const Data = state.Data;

pub const stack_bytes = 32768;

/// How fast it turns by itself, in radians a second.
const turn_speed: f32 = 0.6;
/// A longer gap between two frames while it turns counts as this much.
const most_step_us = 100_000;
/// The least time from one frame turning by itself to the next: as often
/// as a display of 60 frames a second shows one.
const turn_frame_us = 16_667;

const Failure = error{ NoMemory, NoDevice, Refused, Undrawable, OtherScreen };

/// What each failure says in the object's room.
fn words(err: Failure) [*:0]const u8 {
    return switch (err) {
        error.NoMemory => "Not enough memory to draw the model",
        error.NoDevice => "facet.library has no device to draw with",
        error.Refused => "facet.library would not draw the model",
        error.Undrawable => "facet.library does not draw on this screen's pixels",
        error.OtherScreen => "On a screen of other pixels now: open the model again",
    };
}

fn expect(result: facet.Result, failure: Failure) Failure!void {
    if (result != .success) return failure;
}

/// The facet.library format of a screen's pixels, if it draws in them.
fn formatOf(pixels: u32) ?facet.Format {
    if (pixels > 0xFF) return null;
    return switch (@as(PixelFormat, @enumFromInt(@as(u8, @intCast(pixels))))) {
        .bgra32 => .b8g8r8a8_unorm,
        .rgba32 => .r8g8b8a8_unorm,
        .rgb565 => .r5g6b5_unorm_pack16,
        else => null,
    };
}

/// A picture a frame is drawn into, with the depth it is drawn with.
const Target = struct {
    image: ?*facet.Image = null,
    memory: ?*facet.DeviceMemory = null,
    view: ?*facet.ImageView = null,
    depth: ?*facet.Image = null,
    depth_memory: ?*facet.DeviceMemory = null,
    depth_view: ?*facet.ImageView = null,
    framebuffer: ?*facet.Framebuffer = null,
    width: u32 = 0,
    height: u32 = 0,
};

/// A material's picture, as a texture, and the set that binds it.
const Texture = struct {
    image: ?*facet.Image = null,
    memory: ?*facet.DeviceMemory = null,
    view: ?*facet.ImageView = null,
    set: ?*facet.DescriptorSet = null,
};

/// What a frame is drawn from: the shared numbers as they were when it
/// began.
const Wanted = struct {
    camera: camera.Camera,
    width: u32,
    height: u32,
    format: u32,
    ground: u32,
    changes: u32,
};

const Renderer = struct {
    sys: *ExecBase,
    own: *Data,
    fb: *FacetBase = undefined,
    timer_base: ?*TimerBase = null,
    /// What wakes the process when the next frame turning by itself is due.
    clock: ?*timer.TimeRequest = null,
    ticking: bool = false,
    /// How long until then, when `frames` came back to wait for it; 0
    /// otherwise.
    due_us: u64 = 0,
    instance: ?*facet.Instance = null,
    physical: *facet.PhysicalDevice = undefined,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    /// The targets', fixed by the first room it draws in.
    format: facet.Format = .undefined,
    pass: ?*facet.RenderPass = null,
    set_layout: ?*facet.DescriptorSetLayout = null,
    descriptor_pool: ?*facet.DescriptorPool = null,
    layout: ?*facet.PipelineLayout = null,
    module: ?*facet.ShaderModule = null,
    coloured: ?*facet.Pipeline = null,
    textured: ?*facet.Pipeline = null,
    vertices: ?*facet.Buffer = null,
    vertex_memory: ?*facet.DeviceMemory = null,
    indices: ?*facet.Buffer = null,
    index_memory: ?*facet.DeviceMemory = null,
    textures: ?[*]Texture = null,
    texture_count: u32 = 0,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    targets: [state.slot_count]Target = @splat(.{}),
    /// What the frame last made ready was drawn from.
    drawn: u32 = 0,
    drawn_any: bool = false,
    /// When the last frame turning by itself began; 0 while it does not.
    turned_us: u64 = 0,

    /// The process woken in `us`, unless it is to be already.
    fn wakeIn(r: *Renderer, us: u64) void {
        const clock = r.clock orelse return;
        if (r.ticking) return;
        clock.node.command = timer.TR_ADDREQUEST;
        clock.time = timer.TimeVal.fromMicros(us);
        r.sys.SendIO(&clock.node);
        r.ticking = true;
    }

    /// The wake-up taken back, if it has come.
    fn woken(r: *Renderer) void {
        const clock = r.clock orelse return;
        if (!r.ticking or r.sys.CheckIO(&clock.node) == null) return;
        _ = r.sys.WaitIO(&clock.node);
        r.ticking = false;
    }

    fn clockSignal(r: *const Renderer) u32 {
        const clock = r.clock orelse return 0;
        return clock.node.message.reply_port.?.sigMask();
    }

    /// Microseconds of the E-clock.
    fn now(r: *const Renderer) u64 {
        const tb = r.timer_base orelse return 0;
        var value: timer.EClockVal = .{};
        const rate = tb.ReadEClock(&value);
        const count = @as(u64, value.hi) << 32 | value.lo;
        return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
    }

    // --- making and giving back ---------------------------------------------

    /// The instance, the device and its queue, and what does not hang on
    /// the screen's pixels.
    fn up(r: *Renderer) Failure!void {
        const fb = r.fb;
        try expect(fb.CreateInstance(&.{ .application_name = "model.datatype" }, &r.instance), error.NoDevice);
        var count: u32 = 1;
        var physical: [1]*facet.PhysicalDevice = undefined;
        if (fb.EnumeratePhysicalDevices(r.instance.?, &count, &physical) != .success or count == 0) return error.NoDevice;
        r.physical = physical[0];
        fb.GetPhysicalDeviceMemoryProperties(r.physical, &r.memory);
        const queue_info = facet.DeviceQueueCreateInfo{};
        try expect(fb.CreateDevice(r.physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &r.device), error.NoDevice);
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(r.device.?, 0, 0, &queue);
        r.queue = queue.?;
        const device = r.device.?;

        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &r.set_layout), error.Refused);
        const range = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = @sizeOf(shading.Constants) };
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&r.set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&range) }, &r.layout), error.Refused);
        try expect(fb.CreateShaderModule(device, &.{ .code = &shading.code }, &r.module), error.Refused);
        try expect(fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &r.command_pool), error.Refused);
        var commands: [1]?*facet.CommandBuffer = undefined;
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = r.command_pool.?, .command_buffer_count = 1 }, &commands), error.Refused);
        r.commands = commands[0];
        try expect(fb.CreateFence(device, &.{}, &r.fence), error.Refused);
    }

    /// Everything made, given back.
    fn down(r: *Renderer) void {
        const fb = r.fb;
        if (r.device) |device| {
            _ = fb.DeviceWaitIdle(device);
            for (&r.targets) |*target| r.unmake(target);
            if (r.textures) |textures| {
                for (textures[0..r.texture_count]) |texture| {
                    fb.DestroyImageView(device, texture.view);
                    fb.DestroyImage(device, texture.image);
                    fb.FreeMemory(device, texture.memory);
                }
                r.sys.FreeVec(textures);
            }
            fb.DestroyFence(device, r.fence);
            fb.DestroyCommandPool(device, r.command_pool);
            fb.DestroyPipeline(device, r.textured);
            fb.DestroyPipeline(device, r.coloured);
            fb.DestroyRenderPass(device, r.pass);
            fb.DestroyShaderModule(device, r.module);
            fb.DestroyPipelineLayout(device, r.layout);
            fb.DestroyDescriptorPool(device, r.descriptor_pool);
            fb.DestroyDescriptorSetLayout(device, r.set_layout);
            fb.DestroyBuffer(device, r.vertices);
            fb.DestroyBuffer(device, r.indices);
            fb.FreeMemory(device, r.vertex_memory);
            fb.FreeMemory(device, r.index_memory);
            fb.DestroyDevice(device);
        }
        if (r.instance) |instance| fb.DestroyInstance(instance);
    }

    /// The first memory type `needs` allows with `wanted`.
    fn typeFor(r: *const Renderer, needs: facet.MemoryRequirements, wanted: u32) Failure!u32 {
        for (r.memory.memory_types[0..r.memory.memory_type_count], 0..) |kind, k| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(k) != 0 and kind.property_flags & wanted == wanted) return @intCast(k);
        }
        return error.NoMemory;
    }

    /// An image as `info` says, in memory of its own of a type with
    /// `wanted`, put in `image` and `memory` as they are made.
    fn image(r: *Renderer, info: facet.ImageCreateInfo, wanted: u32, made: *?*facet.Image, memory: *?*facet.DeviceMemory) Failure!void {
        const fb = r.fb;
        const device = r.device.?;
        try expect(fb.CreateImage(device, &info, made), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, made.*.?, &needs);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = try r.typeFor(needs, wanted) }, memory), error.NoMemory);
        try expect(fb.BindImageMemory(device, made.*.?, memory.*.?, 0), error.Refused);
    }

    fn view(r: *Renderer, of: *facet.Image, format: facet.Format, aspect: u32, level_count: u32, made: *?*facet.ImageView) Failure!void {
        try expect(r.fb.CreateImageView(r.device.?, &.{ .image = of, .format = format, .subresource_range = .{ .aspect_mask = aspect, .level_count = level_count } }, made), error.Refused);
    }

    /// A buffer of `bytes` in memory the process sees, and its bytes.
    fn buffer(r: *Renderer, bytes: u64, usage: u32, made: *?*facet.Buffer, memory: *?*facet.DeviceMemory) Failure![*]u8 {
        const fb = r.fb;
        const device = r.device.?;
        try expect(fb.CreateBuffer(device, &.{ .size = @max(bytes, 4), .usage = usage }, made), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(device, made.*.?, &needs);
        try expect(fb.AllocateMemory(device, &.{ .allocation_size = needs.size, .memory_type_index = try r.typeFor(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE) }, memory), error.NoMemory);
        try expect(fb.BindBufferMemory(device, made.*.?, memory.*.?, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(device, memory.*.?, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        return @ptrCast(data.?);
    }

    fn begin(r: *Renderer) Failure!*facet.CommandBuffer {
        try expect(r.fb.BeginCommandBuffer(r.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        return r.commands.?;
    }

    /// The command buffer ended, submitted and waited for.
    fn submitAndWait(r: *Renderer) Failure!void {
        const fb = r.fb;
        try expect(fb.EndCommandBuffer(r.commands.?), error.Refused);
        const submit = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&r.commands) };
        try expect(fb.QueueSubmit(r.queue, 1, @ptrCast(&submit), r.fence), error.Refused);
        try expect(fb.WaitForFences(r.device.?, 1, @ptrCast(&r.fence), true, facet.WAIT_FOREVER_NS), error.Refused);
        try expect(fb.ResetFences(r.device.?, 1, @ptrCast(&r.fence)), error.Refused);
    }

    // --- the model ---------------------------------------------------------------

    /// The model copied in: the vertices and the indices into buffers, each
    /// picture into a texture with the set that binds it. What the object
    /// held of them is given back.
    fn load(r: *Renderer) Failure!void {
        const own = r.own;
        const sys = r.sys;
        const fb = r.fb;
        const device = r.device.?;
        const header = own.header;
        if (!own.held) return;
        if (own.vertices) |vertices| {
            const bytes = @as(usize, header.vertices) * @sizeOf(mdt.ModelVertex);
            const into = try r.buffer(bytes, facet.BUFFER_USAGE_VERTEX_BUFFER, &r.vertices, &r.vertex_memory);
            @memcpy(into[0..bytes], @as([*]const u8, @ptrCast(vertices))[0..bytes]);
        }
        if (own.indices) |indices| {
            const bytes = @as(usize, header.indices) * 4;
            const into = try r.buffer(bytes, facet.BUFFER_USAGE_INDEX_BUFFER, &r.indices, &r.index_memory);
            @memcpy(into[0..bytes], @as([*]const u8, @ptrCast(indices))[0..bytes]);
        }

        // The pictures, through one staging buffer as large as the largest.
        const materials = own.materials;
        var pictures: u32 = 0;
        var largest: usize = 0;
        if (materials) |all| for (all[0..header.materials]) |material| {
            if (material.texture == null) continue;
            pictures += 1;
            largest = @max(largest, shapeOf(material).bytes());
        };
        if (pictures != 0) {
            r.textures = @ptrCast(@alignCast(sys.AllocVec(header.materials * @sizeOf(Texture), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return error.NoMemory));
            r.texture_count = header.materials;
            try expect(fb.CreateDescriptorPool(device, &.{ .max_sets = pictures }, &r.descriptor_pool), error.Refused);
            var staging: ?*facet.Buffer = null;
            var staging_memory: ?*facet.DeviceMemory = null;
            defer {
                fb.DestroyBuffer(device, staging);
                fb.FreeMemory(device, staging_memory);
            }
            const staged = try r.buffer(largest, facet.BUFFER_USAGE_TRANSFER_SRC, &staging, &staging_memory);
            for (materials.?[0..header.materials], r.textures.?[0..header.materials]) |material, *texture| {
                const levels_of = material.texture orelse continue;
                const shape = shapeOf(material);
                try r.image(.{
                    .format = .b8g8r8a8_unorm,
                    .extent = .{ .width = shape.width, .height = shape.height },
                    .mip_levels = shape.levels,
                    .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
                }, 0, &texture.image, &texture.memory);
                try r.view(texture.image.?, .b8g8r8a8_unorm, facet.IMAGE_ASPECT_COLOR, shape.levels, &texture.view);
                var sets: [1]?*facet.DescriptorSet = undefined;
                try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = r.descriptor_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&r.set_layout) }, &sets), error.Refused);
                texture.set = sets[0];
                const image_info = facet.DescriptorImageInfo{ .image_view = texture.view };
                const write = facet.WriteDescriptorSet{ .dst_set = texture.set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
                fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
                @memcpy(staged[0..shape.bytes()], levels_of[0..shape.bytes()]);
                const regions = levels.regions(shape);
                const recording = try r.begin();
                fb.CmdCopyBufferToImage(recording, staging.?, texture.image.?, .transfer_dst_optimal, shape.levels, &regions);
                try r.submitAndWait();
            }
        }

        // What the object held is in facet.library's memory now.
        sys.AcquireLock(&own.lock);
        const vertices = own.vertices;
        const indices = own.indices;
        own.vertices = null;
        own.indices = null;
        sys.ReleaseLock(&own.lock);
        sys.FreeVec(vertices);
        sys.FreeVec(indices);
        if (materials) |all| for (all[0..header.materials]) |*material| {
            sys.FreeVec(material.texture);
            material.texture = null;
        };
    }

    fn shapeOf(material: state.Material) levels.Shape {
        return .{ .width = material.texture_width, .height = material.texture_height, .levels = material.texture_levels };
    }

    // --- the screen's pixels -------------------------------------------------------

    /// The render pass and the pipelines for targets of `format`: made for
    /// the first room drawn in, and the same for every frame after.
    fn passFor(r: *Renderer, format: facet.Format) Failure!void {
        if (r.pass != null) {
            if (format != r.format) return error.OtherScreen;
            return;
        }
        const fb = r.fb;
        const device = r.device.?;
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = format, .load_op = .clear, .store_op = .store, .final_layout = .general },
            .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &r.pass), error.Refused);
        r.format = format;
        r.coloured = try r.pipeline("coloured");
        r.textured = try r.pipeline("textured");
    }

    /// A pipeline of the shader functions named `name`: nearer kept, both
    /// sides drawn - a model's file need not wind its faces one way - into
    /// the viewport and scissor each frame sets.
    fn pipeline(r: *Renderer, name: [*:0]const u8) Failure!*facet.Pipeline {
        const stages = [2]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = r.module.?, .name = name },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = r.module.?, .name = name },
        };
        const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(mdt.ModelVertex) };
        const input = facet.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = shading.attributes.len,
            .vertex_attribute_descriptions = &shading.attributes,
        };
        const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list };
        const viewports = facet.PipelineViewportStateCreateInfo{};
        const rasterization = facet.PipelineRasterizationStateCreateInfo{};
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
            .layout = r.layout.?,
            .render_pass = r.pass.?,
        };
        var made: [1]?*facet.Pipeline = undefined;
        try expect(r.fb.CreateGraphicsPipelines(r.device.?, null, 1, @ptrCast(&info), &made), error.Refused);
        return made[0].?;
    }

    /// Target `index` made `width` x `height`, unless it is already, and
    /// its slot told where its pixels are. Its slot is the process's while
    /// it draws (`state.DRAWING`), so nothing reads the old pixels.
    fn targetOf(r: *Renderer, index: usize, width: u32, height: u32, pixels: u32) Failure!*Target {
        const target = &r.targets[index];
        if (target.framebuffer != null and target.width == width and target.height == height) return target;
        r.unmake(target);
        const fb = r.fb;
        const device = r.device.?;
        const extent = facet.Extent3D{ .width = width, .height = height };
        try r.image(.{ .format = r.format, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE, &target.image, &target.memory);
        try r.view(target.image.?, r.format, facet.IMAGE_ASPECT_COLOR, 1, &target.view);
        // Depth lives in the tiles alone: memory with nothing behind it.
        try r.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, &target.depth, &target.depth_memory);
        try r.view(target.depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1, &target.depth_view);
        const views = [2]*facet.ImageView{ target.view.?, target.depth_view.? };
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = r.pass.?, .attachment_count = 2, .attachments = &views, .width = width, .height = height }, &target.framebuffer), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(device, target.memory.?, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        var layout: facet.SubresourceLayout = undefined;
        fb.GetImageSubresourceLayout(device, target.image.?, &.{}, &layout);
        target.width = width;
        target.height = height;

        const own = r.own;
        r.sys.AcquireLock(&own.lock);
        own.slots[index].pixels = @as([*]const u8, @ptrCast(data.?)) + @as(usize, @intCast(layout.offset));
        own.slots[index].pitch = @intCast(layout.row_pitch);
        own.slots[index].width = width;
        own.slots[index].height = height;
        own.slots[index].format = pixels;
        r.sys.ReleaseLock(&own.lock);
        return target;
    }

    fn unmake(r: *Renderer, target: *Target) void {
        const fb = r.fb;
        const device = r.device orelse return;
        fb.DestroyFramebuffer(device, target.framebuffer);
        fb.DestroyImageView(device, target.depth_view);
        fb.DestroyImage(device, target.depth);
        fb.FreeMemory(device, target.depth_memory);
        fb.DestroyImageView(device, target.view);
        fb.DestroyImage(device, target.image);
        fb.FreeMemory(device, target.memory);
        target.* = .{};
    }

    // --- a frame --------------------------------------------------------------------

    /// Frames drawn while what is wanted is ahead of what was drawn and
    /// there is a picture free to draw into.
    fn frames(r: *Renderer) Failure!void {
        const own = r.own;
        const sys = r.sys;
        while (!own.quitting) {
            const time = r.now();
            sys.AcquireLock(&own.lock);
            var waiting = false;
            var chosen: ?usize = null;
            for (&own.slots, 0..) |slot, index| {
                if (slot.state == state.READY) waiting = true;
                if (slot.state != state.FREE or slot.readers != 0) continue;
                // One of the room's size already, if there is one.
                if (chosen == null or (slot.width == own.width and slot.height == own.height)) chosen = index;
            }
            const behind = !r.drawn_any or own.changes != r.drawn;
            // Turning by itself, the next frame waits until the last is
            // on show; a turn by the pointer does not.
            const turn = own.turning and !waiting;
            if (!own.turning) r.turned_us = 0;
            // Turning by itself and nothing else to draw: not before its
            // time.
            if (turn and !behind and r.turned_us != 0 and time -% r.turned_us < turn_frame_us) {
                r.due_us = turn_frame_us - (time -% r.turned_us);
                sys.ReleaseLock(&own.lock);
                return;
            }
            if ((!behind and !turn) or chosen == null) {
                sys.ReleaseLock(&own.lock);
                return;
            }
            if (turn) {
                const step: u64 = if (r.turned_us == 0) 0 else @min(time -% r.turned_us, most_step_us);
                own.yaw += turn_speed * @as(f32, @floatFromInt(step)) / 1_000_000;
                own.changes +%= 1;
                r.turned_us = time;
            }
            const index = chosen.?;
            own.slots[index].state = state.DRAWING;
            const wanted = Wanted{
                .camera = .{ .yaw = own.yaw, .pitch = own.pitch, .zoom = own.zoom },
                .width = own.width,
                .height = own.height,
                .format = own.format,
                .ground = own.ground,
                .changes = own.changes,
            };
            sys.ReleaseLock(&own.lock);

            r.draw(index, wanted) catch |err| {
                sys.AcquireLock(&own.lock);
                own.slots[index].state = state.FREE;
                sys.ReleaseLock(&own.lock);
                return err;
            };
            sys.AcquireLock(&own.lock);
            // The last drawn is the one shown: one ready and not yet on
            // show is dropped.
            for (&own.slots) |*slot| {
                if (slot.state == state.READY) slot.state = state.FREE;
            }
            own.slots[index].state = state.READY;
            sys.ReleaseLock(&own.lock);
            r.drawn = wanted.changes;
            r.drawn_any = true;
            if (own.object) |object| own.base.?.intuition_base.QueueGadgetRefresh(object);
        }
    }

    /// One frame into target `index` as `wanted` says.
    fn draw(r: *Renderer, index: usize, wanted: Wanted) Failure!void {
        if (wanted.width == 0 or wanted.height == 0) return;
        const format = formatOf(wanted.format) orelse return error.Undrawable;
        try r.passFor(format);
        const target = try r.targetOf(index, wanted.width, wanted.height, wanted.format);
        const fb = r.fb;
        const own = r.own;
        const header = own.header;

        const aspect = @as(f32, @floatFromInt(wanted.width)) / @as(f32, @floatFromInt(wanted.height));
        const seen = camera.view(header.low, header.high, wanted.camera, aspect);
        var constants = shading.Constants{
            .transform = seen.transform,
            .light = .{ seen.light[0], seen.light[1], seen.light[2], camera.ambient },
            .color = .{ 1, 1, 1, 1 },
        };

        const recording = try r.begin();
        const ground = wanted.ground;
        const clears = [2]facet.ClearValue{
            .{ .color = .{ .float32 = .{ channelOf(ground >> 16), channelOf(ground >> 8), channelOf(ground), 1 } } },
            .{ .depth_stencil = .{ .depth = 1 } },
        };
        const area = facet.Rect2D{ .extent = .{ .width = wanted.width, .height = wanted.height } };
        fb.CmdBeginRenderPass(recording, &.{ .render_pass = r.pass.?, .framebuffer = target.framebuffer.?, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        if (r.vertices != null and r.indices != null and own.parts != null) {
            const viewport = facet.Viewport{ .width = @floatFromInt(wanted.width), .height = @floatFromInt(wanted.height) };
            fb.CmdSetViewport(recording, 0, 1, @ptrCast(&viewport));
            fb.CmdSetScissor(recording, 0, 1, @ptrCast(&area));
            const offset: u64 = 0;
            fb.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&r.vertices), @ptrCast(&offset));
            fb.CmdBindIndexBuffer(recording, r.indices.?, 0, .uint32);
            var bound: ?*facet.Pipeline = null;
            for (own.parts.?[0..header.parts]) |part| {
                if (part.count == 0) continue;
                const material: ?state.Material = if (part.material < header.materials and own.materials != null) own.materials.?[part.material] else null;
                const color = if (material) |m| m.color else 0xFFC0_C0C0;
                const texture: ?Texture = if (material != null and r.textures != null and r.textures.?[part.material].set != null) r.textures.?[part.material] else null;
                const wanted_pipeline = if (texture != null) r.textured.? else r.coloured.?;
                if (bound != wanted_pipeline) {
                    fb.CmdBindPipeline(recording, .graphics, wanted_pipeline);
                    bound = wanted_pipeline;
                }
                if (texture) |t| fb.CmdBindDescriptorSets(recording, .graphics, r.layout.?, 0, 1, @ptrCast(&t.set), 0, null);
                constants.color = .{ channelOf(color >> 16), channelOf(color >> 8), channelOf(color), 1 };
                fb.CmdPushConstants(recording, r.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf(shading.Constants), &constants);
                fb.CmdDrawIndexed(recording, part.count, 1, part.first, 0, 0);
            }
        }
        fb.CmdEndRenderPass(recording);
        try r.submitAndWait();
    }
};

/// A pen's channel in its low byte, 0 to 1.
fn channelOf(value: u32) f32 {
    return @as(f32, @floatFromInt(value & 0xFF)) / 255;
}

/// Why nothing is drawn, put in the object's room.
fn trouble(own: *Data, sys: *ExecBase, text: [*:0]const u8) void {
    sys.AcquireLock(&own.lock);
    own.trouble = text;
    sys.ReleaseLock(&own.lock);
    if (own.object) |object| own.base.?.intuition_base.QueueGadgetRefresh(object);
}

/// The process: facet.library opened, the model copied in, and frames
/// drawn as they are wanted until the object goes.
pub fn main(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const own: *Data = @ptrCast(@alignCast(me.user_data orelse return));
    sys.ObtainSemaphore(&own.alive);
    if (own.starter) |starter| sys.Signal(starter, @as(u32, 1) << @intCast(own.start_signal));

    var r = Renderer{ .sys = sys, .own = own };
    const clock_port = sys.CreateMsgPort();
    if (clock_port) |port| {
        if (sys.CreateIORequest(port, @sizeOf(timer.TimeRequest))) |request| {
            const clock: *timer.TimeRequest = @ptrCast(@alignCast(request));
            if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, &clock.node, 0) == 0) {
                r.clock = clock;
                r.timer_base = @ptrCast(@alignCast(clock.node.device.?));
            } else sys.DeleteIORequest(&clock.node);
        }
    }
    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1);
    if (facet_lib) |lib| {
        r.fb = @ptrCast(lib);
        serve(&r);
    } else trouble(own, sys, "No facet.library on this machine to draw the model with");

    // Held until the object says go: it signals this task as it ends, and
    // what was made stays until nothing can read a picture of it.
    while (!own.quitting) _ = sys.Wait(exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_F);
    if (facet_lib) |lib| {
        r.down();
        sys.CloseLibrary(lib);
    }
    if (r.clock) |clock| {
        if (r.ticking) {
            _ = sys.AbortIO(&clock.node);
            _ = sys.WaitIO(&clock.node);
        }
        sys.CloseDevice(&clock.node);
        sys.DeleteIORequest(&clock.node);
    }
    if (clock_port) |port| sys.DeleteMsgPort(port);
    sys.ReleaseSemaphore(&own.alive);
}

/// The device made and the model copied in, then a frame drawn each time
/// one is wanted; back when the object goes or something fails, which is
/// put in its room.
fn serve(r: *Renderer) void {
    const own = r.own;
    const sys = r.sys;
    r.up() catch |err| return trouble(own, sys, words(err));
    r.load() catch |err| return trouble(own, sys, words(err));
    while (!own.quitting) {
        r.due_us = 0;
        r.frames() catch |err| return trouble(own, sys, words(err));
        if (own.quitting) return;
        if (r.due_us != 0) r.wakeIn(r.due_us);
        _ = sys.Wait(exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_F | r.clockSignal());
        r.woken();
    }
}
