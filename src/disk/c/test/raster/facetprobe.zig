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
const VERSION_STRING = "\x00$VER: FacetProbe 1.42 (07.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CORES/S,V3D/S,QUIET/S";

/// The side of the pictures drawn into: two tiles across, so that what is
/// written back tile by tile is seen as well.
const side = 64;

/// What one device can do, as the probe works it out for itself.
///
/// Until 1.82 these were fields of `facet.PhysicalDeviceFeatures` and the
/// probe read them straight out of GetPhysicalDeviceFeatures. That call
/// answers Vulkan's 55 features now, and most of these are not among them:
/// they were facet's own record of what a device refuses, which is the
/// library's and not a program's.
///
/// So the probe asks the way a Vulkan program would have to, and that is
/// an improvement rather than a loss - it is now held to what the public
/// surface *says*, not to a private field, and a device whose limits or
/// format properties disagreed with its own refusals would be caught here
/// instead of agreeing with itself.
///
/// Two have no counterpart on Vulkan's surface at all, `samplers` and
/// `unnormalized_coordinates`, because Vulkan requires both of every
/// implementation and so has no feature bit to turn off. They are taken
/// from `sampler_anisotropy`, which on both of this library's devices is
/// true exactly where they are; a device that broke that would need a
/// trial of its own here.
const Can = struct {
    stored_depth: bool,
    stored_stencil: bool,
    sampled_depth: bool,
    storage_images: bool,
    texel_buffers: bool,
    input_attachments: bool,
    dynamic_descriptors: bool,
    depth_bias: bool,
    independent_blend: bool,
    occlusion_queries: bool,
    pipeline_statistics_queries: bool,
    cube_arrays: bool,
    several_outputs: bool,
    samplers: bool,
    unnormalized_coordinates: bool,
    kept_compressed: bool,
    kept_floats: bool,
    wide_channels: bool,
    whole_textures: bool,
    small_texels: bool,
    depth_bounds: bool,
    depth_clamp: bool,
    stored_both: bool,
    etc2_textures: bool,
    /// Whether a generated shader may sample at a constant texel offset:
    /// SPIR-V's `ConstOffset`. Read off `max_texel_offset`, which Vulkan
    /// requires of every implementation and no feature gates, so a 0
    /// there is a device saying it cannot. The cores can since 1.87 and
    /// the V3D refuses the operand (item 28).
    texel_offsets: bool,

    fn formatOf(fb: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format) facet.FormatProperties {
        var said: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(physical, format, &said);
        return said;
    }

    /// Worked out from this device's features, limits and format
    /// properties: every line says which public answer it reads.
    fn of(fb: *FacetBase, physical: *facet.PhysicalDevice) Can {
        var features: facet.PhysicalDeviceFeatures = undefined;
        fb.GetPhysicalDeviceFeatures(physical, &features);
        var properties: facet.PhysicalDeviceProperties = undefined;
        fb.GetPhysicalDeviceProperties(physical, &properties);
        const limits = &properties.limits;
        // A format's own features say what may be done with an image of it,
        // which is where the four depth and stencil answers live.
        const depth = formatOf(fb, physical, .d16_unorm).optimal_tiling_features;
        const stencil = formatOf(fb, physical, .s8_uint).optimal_tiling_features;
        const blocks = formatOf(fb, physical, .bc1_rgb_unorm_block).optimal_tiling_features;
        const halves = formatOf(fb, physical, .r16g16b16a16_sfloat).optimal_tiling_features;
        const wide = formatOf(fb, physical, .r16g16_unorm).optimal_tiling_features;
        const whole = formatOf(fb, physical, .r16g16_uint).optimal_tiling_features;
        const small = formatOf(fb, physical, .r8_unorm).optimal_tiling_features;
        const texels = formatOf(fb, physical, .r8g8b8a8_unorm).buffer_features;
        return .{
            .stored_depth = depth & facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT != 0,
            .stored_stencil = stencil & facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT != 0,
            .sampled_depth = depth & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0,
            // A device that takes no storage image a stage has none.
            .storage_images = limits.max_per_stage_descriptor_storage_images != 0,
            .texel_buffers = texels & facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER != 0,
            .input_attachments = limits.max_per_stage_descriptor_input_attachments != 0,
            .dynamic_descriptors = limits.max_descriptor_set_uniform_buffers_dynamic != 0,
            // Vulkan's `depthBiasClamp` comes with the bias here: the depth
            // offset packet takes its three numbers together.
            .depth_bias = features.depth_bias_clamp == facet.TRUE,
            .independent_blend = features.independent_blend == facet.TRUE,
            // An occlusion query counts its samples exactly where it has
            // one at all, so the precise bit is the query's.
            .occlusion_queries = features.occlusion_query_precise == facet.TRUE,
            .pipeline_statistics_queries = features.pipeline_statistics_query == facet.TRUE,
            .cube_arrays = features.image_cube_array == facet.TRUE,
            // What one fragment function may write.
            .several_outputs = limits.max_fragment_output_attachments > 1,
            .samplers = features.sampler_anisotropy == facet.TRUE,
            .unnormalized_coordinates = features.sampler_anisotropy == facet.TRUE,
            // A device that keeps a format's bytes as it was given them can
            // copy them back out, which is the transfer bit on a format it
            // cannot otherwise do anything with.
            .kept_compressed = blocks & facet.FORMAT_FEATURE_TRANSFER_SRC != 0,
            .kept_floats = halves & facet.FORMAT_FEATURE_TRANSFER_SRC != 0,
            .wide_channels = wide != 0,
            .whole_textures = whole != 0,
            .small_texels = small != 0,
            .depth_bounds = features.depth_bounds == facet.TRUE,
            .depth_clamp = features.depth_clamp == facet.TRUE,
            // One image holding depth and stencil together, kept past the
            // pass that drew it.
            .stored_both = formatOf(fb, physical, .d16_unorm_s8_uint).optimal_tiling_features &
                facet.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT != 0,
            // `texture_compression_etc2` is false on both devices, Vulkan
            // asking for the whole ten-format family behind that bit where
            // five are here, so what a device really does with ETC2 is
            // read off the format itself.
            .etc2_textures = formatOf(fb, physical, .etc2_r8g8b8_unorm_block).optimal_tiling_features != 0,
            .texel_offsets = limits.max_texel_offset != 0,
        };
    }
};

/// Everything made through facet.library on one device, given back by
/// `down` in the order it goes.
const Probe = struct {
    fb: *FacetBase,
    dl: *DosBase,
    quiet: bool,
    instance: *facet.Instance,
    physical: *facet.PhysicalDevice,
    features: facet.PhysicalDeviceFeatures = undefined,
    can: Can = undefined,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    pool: ?*facet.CommandPool = null,
    commands: *facet.CommandBuffer = undefined,
    fence: ?*facet.Fence = null,
    /// What a check made and `give` gives back, newest first.
    memories: [20]?*facet.DeviceMemory = @splat(null),
    images: [16]?*facet.Image = @splat(null),
    views: [16]?*facet.ImageView = @splat(null),
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
        probe.can = Can.of(fb, physical);
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

    /// An image as `info` says, bound into memory with `wanted`, and no
    /// view of it: what a shape takes a view of more ways than one.
    fn bound(probe: *Probe, info: facet.ImageCreateInfo, wanted: u32) ?*facet.Image {
        const fb = probe.fb;
        const device = probe.device.?;
        var made: ?*facet.Image = null;
        if (fb.CreateImage(device, &info, &made) != .success) return null;
        const held = keep(&probe.images, made) orelse return null;
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, held, &needs);
        const memory = probe.block(needs, wanted) orelse return null;
        if (fb.BindImageMemory(device, held, memory, 0) != .success) return null;
        return held;
    }

    /// A view as `info` says, kept; null where the call refused it.
    fn viewed(probe: *Probe, info: facet.ImageViewCreateInfo) ?*facet.ImageView {
        var made: ?*facet.ImageView = null;
        if (probe.fb.CreateImageView(probe.device.?, &info, &made) != .success) return null;
        return keep(&probe.views, made);
    }

    /// An image as `info` says, bound into memory with `wanted`, and a view
    /// of it; `null` for either where the call refused.
    fn image(probe: *Probe, info: facet.ImageCreateInfo, wanted: u32) ?struct { *facet.Image, *facet.ImageView } {
        const held = probe.bound(info, wanted) orelse return null;
        const aspect: u32 = if (info.format == .d16_unorm) facet.IMAGE_ASPECT_DEPTH else facet.IMAGE_ASPECT_COLOR;
        const view = probe.viewed(.{ .image = held, .format = info.format, .subresource_range = .{ .aspect_mask = aspect } }) orelse return null;
        return .{ held, view };
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
        return probe.layeredFramebuffer(pass, views, 1);
    }

    /// A framebuffer of `layers` layers, kept; null where the call refused
    /// it (since 1.91, a framebuffer has more than one).
    fn layeredFramebuffer(probe: *Probe, pass: *facet.RenderPass, views: []const *facet.ImageView, layers: u32) ?*facet.Framebuffer {
        var made: ?*facet.Framebuffer = null;
        if (probe.fb.CreateFramebuffer(probe.device.?, &.{ .render_pass = pass, .attachment_count = @intCast(views.len), .attachments = views.ptr, .width = side, .height = side, .layers = layers }, &made) != .success) return null;
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

/// The colour each vertex carries, read from the vertices themselves: a
/// fixed form of `shader.FixedKind.color` again, so that a device which
/// runs none of the program's fragment functions draws it too - and the
/// colour is the draw's own without a push constant, which such a device
/// has no function to read.
const Painted = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        const full = facet.shader.channel(1);
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const rgb = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..8].* = .{
                p[0],                           p[1],
                p[2],                           1,
                facet.shader.channel(rgb[0]),   facet.shader.channel(rgb[1]),
                facet.shader.channel(rgb[2]),   full,
            };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 4),
        facet.shader.fixedFragment("main", .{ .kind = .color }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// Where it is and the colour it carries: six floats a vertex.
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = 12 },
    };
    const stride: u32 = 24;

    fn at(x: f32, y: f32, z: f32, rgb: [3]f32) [6]f32 {
        return .{ x, y, z, rgb[0], rgb[1], rgb[2] };
    }
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
    /// What it draws: triangles unless it says otherwise (since 1.70).
    topology: facet.PrimitiveTopology = .triangle_list,
    /// The whole depth state, where `depth_tested` is not enough.
    depth_state: ?facet.PipelineDepthStencilStateCreateInfo = null,
    /// Where z = 0 and z = 1 land in the depth.
    min_depth: f32 = 0,
    max_depth: f32 = 1,
    /// One set of blend constants for each colour attachment, facet's own
    /// where Vulkan shares the one set (since 1.51); null, and they all
    /// blend by the shared one.
    constants: ?[*]const [4]f32 = null,
};

/// A copy of `shape` with the fields of `change` put over it: the probe
/// builds several pipelines of one shape that differ in a field each.
fn shapeWith(shape: Shape, change: anytype) Shape {
    var made = shape;
    inline for (@typeInfo(@TypeOf(change)).@"struct".fields) |field| {
        @field(made, field.name) = @field(change, field.name);
    }
    return made;
}

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
    const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = shape.topology };
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
    const blend = facet.PipelineColorBlendStateCreateInfo{
        .attachment_count = @intCast(blends.len),
        .attachments = blends.ptr,
        .attachment_constants = shape.constants,
    };
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

/// A depth stored, allowing the one unit of 65535 the devices may differ
/// by: the cores write round(z x 65535) and the V3D the top 16 bits of its
/// own deeper number, which is z x 65536 held at 65535 - the same for a
/// depth that falls on a 65535th and one more for the rest (since 1.47).
fn checkDepth(probe: *Probe, wanted: u16, found: u16, name: [*:0]const u8) void {
    const apart = if (found > wanted) found - wanted else wanted - found;
    if (apart <= 1) probe.check(true, name) else probe.checkEqual(wanted, found, name);
}

fn depthChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    if (!probe.can.stored_depth) {
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

    // The colour comes from the vertices, so these checks run on a device
    // that runs none of the program's fragment functions as well
    // (since 1.47).
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Painted.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const painted = Shape{ .attributes = &Painted.attributes, .stride = Painted.stride, .depth_tested = true };
    const first = pipelineOf(probe, storing, module.?, layout.?, painted) orelse return probe.check(false, "a pipeline over the storing pass");
    const second = pipelineOf(probe, loading, module.?, layout.?, painted) orelse return probe.check(false, "a pipeline over the loading pass");

    // A near corner at 0.25 and a far one at 0.75, with a band between
    // them that neither covers and the clear's depth stays in: the near
    // one reaches to x + y = 48 of the 64, the far one starts past 64.
    const paint_green = [3]f32{ 0, 1, 0 };
    const paint_red = [3]f32{ 1, 0, 0 };
    const vertices = [_][6]f32{
        Painted.at(-1, -1, 0.25, paint_green), Painted.at(0.5, -1, 0.25, paint_green), Painted.at(-1, 0.5, 0.25, paint_green),
        Painted.at(1, 1, 0.75, paint_green),   Painted.at(-1, 1, 0.75, paint_green),   Painted.at(1, -1, 0.75, paint_green),
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
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the frame submitted");

    const near: u16 = @intFromFloat(@round(0.25 * 65535));
    const far: u16 = @intFromFloat(@round(0.75 * 65535));
    checkDepth(probe, near, depthAt(back_bytes, 4, 4), "the near triangle's depth stored");
    checkDepth(probe, far, depthAt(back_bytes, 40, 40), "the far triangle's depth stored");
    // Past the first tile across, and down a row: the tiles are written
    // back one at a time, so a pixel in another one is worth asking about.
    checkDepth(probe, near, depthAt(back_bytes, 34, 2), "the depth of a pixel in another tile");
    checkDepth(probe, 0xFFFF, depthAt(back_bytes, 56, 2), "the clear's depth where neither triangle is");

    // The same depth loaded: a triangle at 0.5 wins only over the far half.
    const across = [_][6]f32{ Painted.at(-1, -1, 0.5, paint_red), Painted.at(3, -1, 0.5, paint_red), Painted.at(-1, 3, 0.5, paint_red) };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(across))], std.mem.asBytes(&across));
    commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = loading, .framebuffer = after, .render_area = area }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, second);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
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
    checkDepth(probe, near, depthAt(back_bytes, 4, 4), "the loaded depth kept where it was nearer");
    checkDepth(probe, half, depthAt(back_bytes, 40, 40), "the loaded depth written where it was further");
    checkDepth(probe, half, depthAt(back_bytes, 56, 2), "the loaded clear gave way to the new triangle");

    // Cleared without a pass over it.
    const value = facet.ClearDepthStencilValue{ .depth = 1 };
    const subresource = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
    commands = probe.record() orelse return probe.check(false, "a third recording");
    fb.CmdClearDepthStencilImage(commands, depth[0], .undefined, &value, 1, @ptrCast(&subresource));
    fb.CmdCopyImageToBuffer(commands, depth[0], .general, read_back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the clear submitted");
    checkDepth(probe, 0xFFFF, depthAt(back_bytes, 4, 4), "CmdClearDepthStencilImage set the whole image");
    checkDepth(probe, 0xFFFF, depthAt(back_bytes, 40, 40), "and its other corner");
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

    /// Group (x, y) writes texel (x, y) of the level and the layer the
    /// push constants name: the level in red and the layer in green, so
    /// what is written says where it went (since 1.55).
    fn named(groups: *const facet.shader.Groups) callconv(.c) void {
        const image = groups.resources.written(0, 0, 0) orelse return;
        const where = groups.resources.constants([2]u32).*;
        const color = 0xFF00_0000 | (10 + 40 * where[0]) << 16 | (10 + 40 * where[1]) << 8 | groups.group[0];
        image.setColor(where[1], where[0], groups.group[0], groups.group[1], color);
    }

    /// What ran, and whether it found an image to write through: the test
    /// reads it out of a buffer.
    fn told(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 1) orelse return;
        out[0] = if (groups.resources.written(0, 0, 0) == null) 0xA11_600D else 0xBAD;
    }

    /// Group (x, y) writes texel (x, y) from four floats the push
    /// constants carry, and the first group reads texel (0, 0) back into
    /// the buffer: what the format kept of them, which is the point of
    /// keeping floats (since 1.57).
    fn floats(groups: *const facet.shader.Groups) callconv(.c) void {
        const image = groups.resources.written(0, 0, 0) orelse return;
        const out = groups.resources.storage(f32, 0, 1) orelse return;
        const parts = groups.resources.constants([4]f32).*;
        const x = groups.group[0];
        const y = groups.group[1];
        image.setParts(0, 0, x, y, parts);
        if (x != 0 or y != 0) return;
        const read = image.partsAt(0, 0, 0, 0);
        for (read, 0..) |part, k| out[k] = part;
        out[4] = @bitCast(image.colorAt(0, 0, 0, 0));
        const none = image.partsAt(0, 0, image.width(0), 0);
        for (none, 0..) |part, k| out[5 + k] = part;
    }

    /// The shape the function sees, and what it reads back: the levels and
    /// the layers, the first two levels' widths, the texel the push
    /// constants name, and a level, a layer and a place the view has not
    /// got, each of which reads transparent black (since 1.55).
    fn shape(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 1) orelse return;
        const image = groups.resources.written(0, 0, 0) orelse {
            out[0] = 0xFFFF_FFFF;
            return;
        };
        const where = groups.resources.constants([2]u32).*;
        out[0] = image.levels;
        out[1] = image.layer_count;
        out[2] = image.width(0);
        out[3] = image.width(1);
        out[4] = image.colorAt(where[1], where[0], 0, 0);
        out[5] = image.colorAt(0, image.levels, 0, 0);
        out[6] = image.colorAt(image.layer_count, 0, 0, 0);
        out[7] = image.colorAt(0, 0, image.width(0), 0);
        out[8] = @intFromBool(image.holds(image.layer_count - 1, image.levels - 1, 0, 0));
        out[9] = @intFromBool(image.holds(0, image.levels, 0, 0));
    }

    /// The same with whole numbers (1.70): group (x, y) writes texel
    /// (x, y) from four of them the push constants carry as i32, and the
    /// first group reads texel (0, 0) back with `wholesAt` - the numbers
    /// themselves, which neither a colour nor a float carries.
    fn numbers(groups: *const facet.shader.Groups) callconv(.c) void {
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
        out[4] = image.colorAt(0, 0, 0, 0);
        // A place past the level reads all zero, as any storage image has
        // it: the four together, for the one slot.
        const none = image.wholesAt(0, 0, image.width(0), 0);
        out[5] = none[0] | none[1] | none[2] | none[3];
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.compute("main", &run),
        facet.shader.compute("told", &told),
        facet.shader.compute("named", &named),
        facet.shader.compute("shape", &shape),
        facet.shader.compute("floats", &floats),
        facet.shader.compute("numbers", &numbers),
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
    if (!probe.can.storage_images) {
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
    const range = facet.PushConstantRange{ .size = 16 };
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
    const told_buffer, const told_bytes = probe.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    @memset(told_bytes[0..64], 0);

    const image_info = facet.DescriptorImageInfo{ .image_view = image[1] };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = told_buffer, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);

    const infos = [6]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "told" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "named" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "shape" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "floats" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "numbers" }, .layout = layout.? },
    };
    var pipelines: [6]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 6, &infos, &pipelines) != .success) return probe.check(false, "the compute pipelines");
    for (pipelines) |one| _ = Probe.keep(&probe.pipelines, one);

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

    // --- 1.55: the level and the layer the function names ---
    // Three levels and three layers, written through and never sampled:
    // an image of layers needed SAMPLED beside STORAGE before 1.55.
    const stack = probe.bound(.{
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 8, .height = 8 },
        .mip_levels = 3,
        .array_layers = 3,
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_SRC,
    }, 0) orelse return probe.check(false, "an image of layers written through and never sampled");
    probe.check(true, "an image of layers written through and never sampled");
    const stack_view = probe.viewed(.{ .image = stack, .format = .r8g8b8a8_unorm, .view_type = .@"2d_array", .subresource_range = .{ .layer_count = 3 } }) orelse
        return probe.check(false, "a view of all of its levels and layers");
    const to_stack = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = stack_view }) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_stack), 0, null);

    const Where = struct { level: u32, layer: u32, side: u32 };
    const places = [_]Where{
        .{ .level = 0, .layer = 0, .side = 8 },
        .{ .level = 1, .layer = 2, .side = 4 },
        .{ .level = 2, .layer = 1, .side = 2 },
        .{ .level = 0, .layer = 1, .side = 8 },
        // A level the view has not got, and then a layer it has not got:
        // nothing is written either time.
        .{ .level = 3, .layer = 0, .side = 1 },
        .{ .level = 0, .layer = 3, .side = 1 },
    };
    for (places) |place| {
        const named = [2]u32{ place.level, place.layer };
        commands = probe.record() orelse return probe.check(false, "a recording of a named write");
        fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 8, &named);
        fb.CmdDispatch(commands, place.side, place.side, 1);
        if (!probe.submit()) return probe.check(false, "the named write submitted");
    }

    // Each of the four written places read back: the colour says which
    // level and which layer wrote it, so none of them went anywhere else.
    // r8g8b8a8 in the buffer, so the word reads 0xAABBGGRR.
    var all_placed = true;
    for (places[0..4]) |place| {
        @memset(back_bytes[0 .. 8 * 8 * 4], 0);
        const region = facet.BufferImageCopy{
            .image_subresource = .{ .mip_level = place.level, .base_array_layer = place.layer },
            .image_extent = .{ .width = place.side, .height = place.side },
        };
        commands = probe.record() orelse return probe.check(false, "a recording of the read-back");
        fb.CmdCopyImageToBuffer(commands, stack, .general, back, 1, @ptrCast(&region));
        if (!probe.submit()) return probe.check(false, "the read-back submitted");
        const want = 0xFF00_0000 | (place.side - 1) << 16 | (10 + 40 * place.layer) << 8 | (10 + 40 * place.level);
        const last_at = ((place.side - 1) * place.side + place.side - 1) * 4;
        if (std.mem.readInt(u32, back_bytes[last_at..][0..4], .little) != want) all_placed = false;
    }
    probe.check(all_placed, "each level and layer the function named written where it said");

    // What the function sees of the shape, and of what it reads back.
    const asked = [2]u32{ 1, 2 };
    @memset(told_bytes[0..64], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the shape");
    fb.CmdBindPipeline(commands, .compute, pipelines[3].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 8, &asked);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the shape submitted");
    const seen: [*]const u32 = @ptrCast(@alignCast(told_bytes));
    probe.checkEqual(3, seen[0], "the levels the function sees of the view");
    probe.checkEqual(3, seen[1], "the layers it sees");
    probe.checkEqual(8, seen[2], "the first level's width");
    probe.checkEqual(4, seen[3], "and the second level's");
    probe.checkEqual(0xFF32_5A00, seen[4], "a texel of a named level and layer read back");
    probe.checkEqual(0, seen[5], "a level the view has not got reads transparent black");
    probe.checkEqual(0, seen[6], "a layer it has not got as well");
    probe.checkEqual(0, seen[7], "and a place past the level's width");
    probe.checkEqual(1, seen[8], "the last level of the last layer is held");
    probe.checkEqual(0, seen[9], "and one past the last is not");

    // --- 1.56: a colour attachment written through as a storage image ---
    // The linear features say whose rows may be written through: a
    // texture of 8888 is 0xAARRGGBB, as b8g8r8a8's rows are, and the one
    // that reads a word with red in its low byte is fetched from, not
    // written through (since 1.110).
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .b8g8r8a8_unorm, &properties);
    probe.check(properties.linear_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0, "rows of b8g8r8a8 say they may be written through");
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r8g8b8a8_unorm, &properties);
    probe.check(properties.linear_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE == 0, "and rows of r8g8b8a8 say they may not");

    const both_usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_SRC;
    // As wide as the probe's pictures, a framebuffer being made of it:
    // the function writes its first 8 x 8 texels, which is what is read
    // back.
    const both = probe.bound(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .usage = both_usage }, 0) orelse
        return probe.check(false, "an image drawn into and written through at once");
    probe.check(true, "an image drawn into and written through at once");
    var denied: ?*facet.Image = null;
    // Sampled as well it is refused on both devices: the cores sample an
    // image they draw into where it lies only if nothing writes it
    // through (docs/facet-vulkan10.md item 48), and the V3D does neither.
    probe.check(fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .usage = both_usage | facet.IMAGE_USAGE_SAMPLED }, &denied) != .success, "sampled, drawn into and written through at once refused");
    probe.check(fb.CreateImage(device, &.{ .format = .r8g8b8a8_unorm, .extent = .{ .width = side, .height = side }, .usage = both_usage }, &denied) != .success, "and r8g8b8a8 rows written through refused");
    probe.check(denied == null, "and nothing given back for either");
    const both_view = probe.viewed(.{ .image = both, .format = .b8g8r8a8_unorm }) orelse return probe.check(false, "a view of it");
    const to_both = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = both_view }) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_both), 0, null);

    // Written through: the rows take the colour at once, and the function
    // reads its own rows back.
    commands = probe.record() orelse return probe.check(false, "a recording of the seeding write");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 4, &four);
    fb.CmdDispatch(commands, 8, 8, 1);
    if (!probe.submit()) return probe.check(false, "the seeding write submitted");
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the rows read back");
    fb.CmdCopyImageToBuffer(commands, both, .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the rows read back");
    // b8g8r8a8 in the buffer: the word is 0xAARRGGBB as it was written.
    probe.checkEqual(0xFF00_0004, std.mem.readInt(u32, back_bytes[0..4], .little), "the attachment's rows written through by a function");
    probe.checkEqual(0xFF05_0704, std.mem.readInt(u32, back_bytes[(7 * 8 + 5) * 4 ..][0..4], .little), "another of its rows");

    // Then drawn into: a pass that clears it. What a subpass draws
    // reaches the rows when it stores, so the clear is what is left.
    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass over the same image");
    const onto = probe.framebuffer(pass, &.{both_view}) orelse return probe.check(false, "a framebuffer of it");
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the pass");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = .{ .extent = .{ .width = side, .height = side } }, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, both, .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the pass submitted");
    probe.checkEqual(0xFF00_00FF, std.mem.readInt(u32, back_bytes[0..4], .little), "what the pass drew reaches the rows when it stores");

    // And written through again after it: over what the pass left.
    @memset(back_bytes[0 .. 8 * 8 * 4], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the write after the pass");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 4, &four);
    fb.CmdDispatch(commands, 8, 8, 1);
    fb.CmdCopyImageToBuffer(commands, both, .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the write after the pass submitted");
    probe.checkEqual(0xFF00_0004, std.mem.readInt(u32, back_bytes[0..4], .little), "and a write after the pass goes over what it left");

    // --- 1.57: a storage image of floats, and one float a texel ---
    // Every float format says it may be written through, and R32_SFLOAT
    // is an image format of its own.
    const float_formats = [5]facet.Format{ .r16g16b16a16_sfloat, .r32g32b32a32_sfloat, .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32, .r32_sfloat };
    var all_storage = true;
    for (float_formats) |format| {
        fb.GetPhysicalDeviceFormatProperties(probe.physical, format, &properties);
        if (properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE == 0) all_storage = false;
    }
    probe.check(all_storage, "every float format says it may be written through");

    // Each written with the same four floats and read back: what the
    // format keeps of them. A whole number above 1 is what a colour could
    // never have carried.
    const Kind = struct { format: facet.Format, want: [4]f32, mercy: f32, says: [*:0]const u8 };
    const kinds = [_]Kind{
        .{ .format = .r16g16b16a16_sfloat, .want = .{ 1.5, 2.5, 0.25, 0.5 }, .mercy = 0, .says = "four halves kept and read as floats" },
        .{ .format = .r32g32b32a32_sfloat, .want = .{ 1.5, 2.5, 0.25, 0.5 }, .mercy = 0, .says = "four floats kept as they were given" },
        .{ .format = .b10g11r11_ufloat_pack32, .want = .{ 1.5, 2.5, 0.25, 1 }, .mercy = 0.02, .says = "packed floats of 11, 11 and 10 bits" },
        .{ .format = .e5b9g9r9_ufloat_pack32, .want = .{ 1.5, 2.5, 0.25, 1 }, .mercy = 0.02, .says = "three mantissas over a shared exponent" },
        .{ .format = .r32_sfloat, .want = .{ 1.5, 0, 0, 1 }, .mercy = 0, .says = "one float a texel, read as red alone" },
    };
    const given = [4]f32{ 1.5, 2.5, 0.25, 0.5 };
    const floats_out: [*]const f32 = @ptrCast(@alignCast(told_bytes));
    for (kinds) |kind| {
        const held = probe.bound(.{
            .format = kind.format,
            .extent = .{ .width = 8, .height = 8 },
            .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
        }, 0) orelse {
            probe.check(false, kind.says);
            continue;
        };
        const held_view = probe.viewed(.{ .image = held, .format = kind.format }) orelse {
            probe.check(false, kind.says);
            continue;
        };
        const to_held = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = held_view }) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_held), 0, null);
        @memset(told_bytes[0..64], 0);
        commands = probe.record() orelse return probe.check(false, "a recording of the float write");
        fb.CmdBindPipeline(commands, .compute, pipelines[4].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 16, &given);
        fb.CmdDispatch(commands, 8, 8, 1);
        if (!probe.submit()) return probe.check(false, "the float write submitted");
        var alike = true;
        for (kind.want, 0..) |want, k| {
            const found = floats_out[k];
            if (kind.mercy == 0) {
                if (found != want) alike = false;
            } else if (@abs(found - want) > kind.mercy) alike = false;
        }
        // The colour the same texel reads as: red held to 1 and rounded
        // to 8 bits, which is all the tiles hold.
        const as_color: u32 = @bitCast(floats_out[4]);
        if (as_color >> 16 & 0xFF != 0xFF) alike = false;
        // And a place past the level: all zero.
        for (0..4) |k| if (floats_out[5 + k] != 0) {
            alike = false;
        };
        probe.check(alike, kind.says);
    }

    // 1.70: the whole numbers a function writes and reads back, each held
    // to what its channel holds. 300 is above a byte, -5 below what an
    // unsigned channel holds, and 70000 above 16 bits: nothing is scaled
    // on the way, so each comes back as itself or at its channel's end.
    if (probe.can.whole_textures) {
        const numbers_out: [*]const i64 = @ptrCast(@alignCast(told_bytes));
        const given_numbers = [4]i32{ 300, -5, 70000, 1 };
        const Whole = struct { format: facet.Format, want: [4]i64, says: [*:0]const u8 };
        for ([3]Whole{
            .{ .format = .r8g8b8a8_uint, .want = .{ 255, 0, 255, 1 }, .says = "four bytes of whole number, 300 and 70000 held to 255 and -5 to 0" },
            .{ .format = .r16g16b16a16_sint, .want = .{ 300, -5, 32767, 1 }, .says = "16 bits a channel, signed: 300 and -5 as they are, 70000 held to 32767" },
            .{ .format = .r32g32b32a32_uint, .want = .{ 300, 0, 70000, 1 }, .says = "32 bits a channel: 70000 as it is, and -5 held to 0" },
        }) |kind| {
            const held = probe.image(.{
                .format = kind.format,
                .extent = .{ .width = 8, .height = 8 },
                .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_SRC,
            }, 0) orelse {
                probe.check(false, kind.says);
                continue;
            };
            const to_held = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = held[1] }) };
            fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_held), 0, null);
            @memset(told_bytes[0..64], 0);
            commands = probe.record() orelse return probe.check(false, "a recording of the whole-number write");
            fb.CmdBindPipeline(commands, .compute, pipelines[5].?);
            fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
            fb.CmdPushConstants(commands, layout.?, facet.SHADER_STAGE_COMPUTE, 0, 16, &given_numbers);
            fb.CmdDispatch(commands, 8, 8, 1);
            if (!probe.submit()) return probe.check(false, "the whole-number write submitted");
            var alike = true;
            for (kind.want, 0..) |want, k| if (numbers_out[k] != want) {
                alike = false;
            };
            // The colour such a texel reads as: each number held to 0 to
            // 1 and over 255, so a red of 300 is a red at the full and a
            // green of 0 or -5 nothing.
            const as_color: u32 = @truncate(@as(u64, @bitCast(numbers_out[4])));
            if (as_color >> 16 & 0xFF != 0xFF or as_color >> 8 & 0xFF != 0) alike = false;
            // And a place past the level reads all zero.
            if (numbers_out[5] != 0) alike = false;
            probe.check(alike, kind.says);
        }
    }

    // A compressed image asked for as a storage image is still unpacked
    // into 8888: nothing writes one texel of a block, so it wants SAMPLED
    // beside it, being unpacked to be sampled.
    var blocked: ?*facet.Image = null;
    probe.check(fb.CreateImage(device, &.{
        .format = .bc1_rgba_unorm_block,
        .extent = .{ .width = 8, .height = 8 },
        .usage = facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSFER_DST,
    }, &blocked) != .success, "a compressed storage image with no sampling refused");
    probe.check(blocked == null, "and nothing given back for it");
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

    /// Texel k copied as it lies, by floats (since 1.54).
    fn copies(groups: *const facet.shader.Groups) callconv(.c) void {
        const from = groups.resources.texels(0, 0, 0) orelse return;
        var into = groups.resources.texels(0, 1, 0) orelse return;
        const k = groups.group[0];
        into.set(k, from.at(k));
    }

    /// The same by whole numbers, which is what a 32-bit integer format
    /// wants: `at`'s float carries 24 bits exactly (since 1.54).
    fn wholes(groups: *const facet.shader.Groups) callconv(.c) void {
        const from = groups.resources.texels(0, 0, 0) orelse return;
        var into = groups.resources.texels(0, 1, 0) orelse return;
        const k = groups.group[0];
        into.setInt(k, from.intAt(k));
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
        // Its first texel as four floats and as four whole numbers, the
        // two ways a texel is read since 1.54.
        if (from) |one| {
            const parts = one.at(0);
            for (parts, 0..) |part, k| out[5 + k] = @bitCast(part);
            const numbers = one.intAt(0);
            for (numbers, 0..) |number, k| out[9 + k] = @truncate(@as(u64, @bitCast(number)));
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.compute("main", &run),
        facet.shader.compute("told", &told),
        facet.shader.compute("copies", &copies),
        facet.shader.compute("wholes", &wholes),
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
    if (!probe.can.texel_buffers) {
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
    const told_buffer, const told_bytes = probe.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    @memset(told_bytes[0..64], 0);
    const told_info = facet.DescriptorBufferInfo{ .buffer = told_buffer, .range = facet.WHOLE_SIZE };
    const writes = [3]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&reading) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&writing) },
        .{ .dst_set = sets[0].?, .dst_binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&told_info) },
    };
    fb.UpdateDescriptorSets(device, 3, &writes, 0, null);

    const infos = [4]facet.ComputePipelineCreateInfo{
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "told" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "copies" }, .layout = layout.? },
        .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "wholes" }, .layout = layout.? },
    };
    var pipelines: [4]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 4, &infos, &pipelines) != .success) return probe.check(false, "the compute pipelines");
    for (pipelines) |one| _ = Probe.keep(&probe.pipelines, one);

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

    // --- 1.54: the grid of formats a view takes ---
    // Each of them over the 64-byte buffer: the texels it counts are 64
    // divided by the format's own size, which is what the library made of
    // the format.
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
        // 1.68: `_snorm`, `_srgb`, the words whose channels are packed
        // into them, and three channels of 32 bits.
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
        // 1.127: the A8B8G8R8 words of the rest.
        .{ .format = .a8b8g8r8_snorm_pack32, .size = 4 },
        .{ .format = .a8b8g8r8_uint_pack32, .size = 4 },
        .{ .format = .a8b8g8r8_sint_pack32, .size = 4 },
    };
    var all_made = true;
    var all_counted = true;
    var all_told = true;
    var all_bare = true;
    const texel_features = facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER | facet.FORMAT_FEATURE_STORAGE_TEXEL_BUFFER;
    for (grid) |grain| {
        var properties: facet.FormatProperties = undefined;
        fb.GetPhysicalDeviceFormatProperties(probe.physical, grain.format, &properties);
        if (properties.buffer_features & texel_features != texel_features) all_told = false;
        if (properties.buffer_features & facet.FORMAT_FEATURE_VERTEX_BUFFER != 0) all_bare = false;
        var view: ?*facet.BufferView = null;
        if (fb.CreateBufferView(device, &.{ .buffer = floats, .format = grain.format }, &view) != .success) {
            all_made = false;
            continue;
        }
        const one = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&view) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&one), 0, null);
        @memset(told_bytes[0..64], 0);
        commands = probe.record() orelse return probe.check(false, "a recording of the count");
        fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
        fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdDispatch(commands, 1, 1, 1);
        if (!probe.submit()) return probe.check(false, "the count submitted");
        if (out[0] != 64 / grain.size) all_counted = false;
        fb.DestroyBufferView(device, view);
    }
    probe.check(all_made, "a view of every format a texel buffer takes, 1.68's among them");
    probe.check(all_counted, "each counting its texels by its own size");
    probe.check(all_told, "and each saying UNIFORM_TEXEL_BUFFER and STORAGE_TEXEL_BUFFER");
    probe.check(all_bare, "and none of them a vertex format");

    // A whole number read as itself: 7 and 200 of r8_uint, copied into
    // r16_uint, where they are the same numbers in two bytes each.
    float_bytes[0] = 7;
    float_bytes[1] = 200;
    @memset(color_bytes[0..16], 0);
    var from_u8: ?*facet.BufferView = null;
    var into_u16: ?*facet.BufferView = null;
    if (fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r8_uint }, &from_u8) != .success) return probe.check(false, "a view of whole bytes");
    defer fb.DestroyBufferView(device, from_u8);
    if (fb.CreateBufferView(device, &.{ .buffer = colors, .format = .r16_uint }, &into_u16) != .success) return probe.check(false, "a view of whole words written through");
    defer fb.DestroyBufferView(device, into_u16);
    const pair = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&from_u8) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&into_u16) },
    };
    fb.UpdateDescriptorSets(device, 2, &pair, 0, null);
    commands = probe.record() orelse return probe.check(false, "a recording of the copy");
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 2, 1, 1);
    if (!probe.submit()) return probe.check(false, "the copy submitted");
    probe.checkEqual(7, std.mem.readInt(u16, color_bytes[0..2], .little), "a whole byte read as itself and written as a word");
    probe.checkEqual(200, std.mem.readInt(u16, color_bytes[2..4], .little), "and the next of them");

    // What the function saw of the first: 7 as a float and as a whole
    // number, the parts the format has not got 0, and alpha 1.
    @memset(told_bytes[0..64], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of what it saw");
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "that dispatch submitted");
    probe.check(@as(f32, @bitCast(out[5])) == 7, "a whole byte read as the float 7");
    probe.check(@as(f32, @bitCast(out[6])) == 0, "its green, which the format has not got, as 0");
    probe.check(@as(f32, @bitCast(out[8])) == 1, "and its alpha as 1");
    probe.checkEqual(7, out[9], "the same as a whole number");
    probe.checkEqual(1, out[12], "and its alpha as the whole number 1");

    // Half-floats read as they lie: 1.5 and -0.25 of r16g16b16a16_sfloat.
    const halves = [4]f16{ 1.5, -0.25, 3, 0.5 };
    for (halves, 0..) |half, k| std.mem.writeInt(u16, float_bytes[k * 2 ..][0..2], @bitCast(half), .little);
    var from_f16: ?*facet.BufferView = null;
    if (fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r16g16b16a16_sfloat }, &from_f16) != .success) return probe.check(false, "a view of half-floats");
    defer fb.DestroyBufferView(device, from_f16);
    const to_halves = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&from_f16) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_halves), 0, null);
    @memset(told_bytes[0..64], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the half-floats");
    fb.CmdBindPipeline(commands, .compute, pipelines[1].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the half-floats submitted");
    probe.check(@as(f32, @bitCast(out[5])) == 1.5, "a half-float read as 1.5");
    probe.check(@as(f32, @bitCast(out[6])) == -0.25, "and a negative one as -0.25");
    probe.check(@as(f32, @bitCast(out[8])) == 0.5, "and its alpha as the half it holds");

    // A 32-bit whole number past 2^24: `intAt` reads it as it lies, where
    // the float of `at` cannot carry it.
    const big: u32 = 4_000_000_001;
    std.mem.writeInt(u32, float_bytes[0..4], big, .little);
    @memset(color_bytes[0..16], 0);
    var from_u32: ?*facet.BufferView = null;
    var into_u32: ?*facet.BufferView = null;
    if (fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32_uint }, &from_u32) != .success) return probe.check(false, "a view of whole words");
    defer fb.DestroyBufferView(device, from_u32);
    if (fb.CreateBufferView(device, &.{ .buffer = colors, .format = .r32_uint }, &into_u32) != .success) return probe.check(false, "and one written through");
    defer fb.DestroyBufferView(device, into_u32);
    const wide = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&from_u32) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&into_u32) },
    };
    fb.UpdateDescriptorSets(device, 2, &wide, 0, null);
    commands = probe.record() orelse return probe.check(false, "a recording of the wide copy");
    fb.CmdBindPipeline(commands, .compute, pipelines[3].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the wide copy submitted");
    probe.checkEqual(big, std.mem.readInt(u32, color_bytes[0..4], .little), "a whole number past 2^24 copied by whole numbers");
    // The same copied by floats instead loses its low bits.
    @memset(color_bytes[0..16], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of the float copy");
    fb.CmdBindPipeline(commands, .compute, pipelines[2].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the float copy submitted");
    probe.check(std.mem.readInt(u32, color_bytes[0..4], .little) != big, "and changed where the float carried it");

    // --- 1.68: `_snorm`, `_srgb` and the packed words ---
    // What the function sees of texel 0 of binding 0, for each format in
    // turn: four floats at out[5] and four whole numbers at out[9].
    const sees = struct {
        fn sees(on: *Probe, pipeline: *facet.Pipeline, set: *[1]?*facet.DescriptorSet, where: *facet.PipelineLayout, buffer: *facet.Buffer, format: facet.Format, told: [*]u8) bool {
            var view: ?*facet.BufferView = null;
            if (on.fb.CreateBufferView(on.device.?, &.{ .buffer = buffer, .format = format }, &view) != .success) return false;
            defer on.fb.DestroyBufferView(on.device.?, view);
            const one = facet.WriteDescriptorSet{ .dst_set = set[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&view) };
            on.fb.UpdateDescriptorSets(on.device.?, 1, @ptrCast(&one), 0, null);
            @memset(told[0..64], 0);
            const recorded = on.record() orelse return false;
            on.fb.CmdBindPipeline(recorded, .compute, pipeline);
            on.fb.CmdBindDescriptorSets(recorded, .compute, where, 0, 1, @ptrCast(set), 0, null);
            on.fb.CmdDispatch(recorded, 1, 1, 1);
            return on.submit();
        }
    }.sees;

    // `_snorm`: the lowest value a channel holds and the one above it are
    // both -1, and the largest is 1.
    float_bytes[0] = 0x80;
    float_bytes[1] = 0x81;
    float_bytes[2] = 0;
    float_bytes[3] = 127;
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .r8g8b8a8_snorm, told_bytes)) return probe.check(false, "what the function saw of a snorm texel");
    probe.check(@as(f32, @bitCast(out[5])) == -1, "the lowest a snorm channel holds read as -1");
    probe.check(@as(f32, @bitCast(out[6])) == -1, "and the one above it as -1 as well");
    probe.check(@as(f32, @bitCast(out[7])) == 0, "and its zero as 0");
    probe.check(@as(f32, @bitCast(out[8])) == 1, "and the largest as 1");
    probe.checkEqual(@as(u32, @bitCast(@as(i32, -128))), out[9], "its whole number signed, as it lies");

    // `_srgb`: 188 of 255 is about half the light, and the alpha is
    // straight whatever the colour channels do.
    float_bytes[0] = 188;
    float_bytes[1] = 188;
    float_bytes[2] = 188;
    float_bytes[3] = 128;
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .r8g8b8a8_srgb, told_bytes)) return probe.check(false, "what the function saw of an srgb texel");
    const lit: f32 = @bitCast(out[5]);
    probe.check(lit > 0.495 and lit < 0.505, "an srgb byte of 188 read as about half the light");
    const straight: f32 = @bitCast(out[8]);
    probe.check(straight > 0.5 and straight < 0.505, "and its alpha straight, not through the function");
    probe.checkEqual(188, out[9], "and its whole number the byte it keeps");
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .r8g8b8a8_unorm, told_bytes)) return probe.check(false, "the same bytes as unorm");
    const plain: f32 = @bitCast(out[5]);
    probe.check(plain > 0.73 and plain < 0.74, "the same byte as unorm read as 188 of 255");

    // Three channels of 10 bits and an alpha of 2, in one word: red
    // whole, green half, blue nothing. a2b10g10r10 keeps red in the low
    // bits and a2r10g10b10 keeps blue there.
    const packed_word: u32 = 3 << 30 | 0 << 20 | 512 << 10 | 1023;
    std.mem.writeInt(u32, float_bytes[0..4], packed_word, .little);
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .a2b10g10r10_unorm_pack32, told_bytes)) return probe.check(false, "what it saw of a packed word");
    probe.check(@as(f32, @bitCast(out[5])) == 1, "the packed word's red channel whole");
    const half: f32 = @bitCast(out[6]);
    probe.check(half > 0.5 and half < 0.502, "its green half of what the channel holds");
    probe.check(@as(f32, @bitCast(out[7])) == 0, "its blue nothing");
    probe.check(@as(f32, @bitCast(out[8])) == 1, "and its alpha of two bits whole");
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .a2r10g10b10_unorm_pack32, told_bytes)) return probe.check(false, "the same word the other way round");
    probe.check(@as(f32, @bitCast(out[5])) == 0, "the same word with blue in the low bits reads red as 0");
    probe.check(@as(f32, @bitCast(out[7])) == 1, "and blue as 1");
    if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, .a2b10g10r10_uint_pack32, told_bytes)) return probe.check(false, "and as whole numbers");
    probe.check(@as(f32, @bitCast(out[5])) == 1023, "the uint pair gives the numbers themselves");
    probe.checkEqual(512, out[10], "its green among them");
    probe.checkEqual(3, out[12], "and the alpha's 3");

    // The floats of one word, written by the SDK's own `set` and read
    // back: 2, a half and a quarter, with an alpha of 1 neither holds.
    for ([2]facet.Format{ .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 }) |one| {
        @memset(float_bytes[0..16], 0);
        const kept: facet.shader.TexelFormat = if (one == .b10g11r11_ufloat_pack32) .rg11b10f else .rgb9e5;
        var writing_floats = facet.shader.Texels{ .bytes = float_bytes, .count = 4, .format = kept, .writable = true };
        writing_floats.set(0, .{ 2, 0.5, 0.25, 1 });
        if (!sees(probe, pipelines[1].?, &sets, layout.?, floats, one, told_bytes)) return probe.check(false, "what it saw of a word of floats");
        const red: f32 = @bitCast(out[5]);
        const green: f32 = @bitCast(out[6]);
        const blue: f32 = @bitCast(out[7]);
        probe.check(red > 1.96 and red < 2.04, "a word of floats read as the 2 it was given");
        probe.check(green > 0.49 and green < 0.51, "its half as a half");
        probe.check(blue > 0.24 and blue < 0.26, "and its quarter as a quarter");
        probe.check(@as(f32, @bitCast(out[8])) == 1, "and an alpha of 1 where it holds none");
    }

    // Three channels of 32 bits, whole: a number past 2^24 in each, read
    // and written as it lies.
    const three: u32 = 3_000_000_007;
    for (0..3) |k| std.mem.writeInt(u32, float_bytes[k * 4 ..][0..4], three, .little);
    @memset(color_bytes[0..16], 0);
    var from_three: ?*facet.BufferView = null;
    var into_three: ?*facet.BufferView = null;
    if (fb.CreateBufferView(device, &.{ .buffer = floats, .format = .r32g32b32_uint }, &from_three) != .success) return probe.check(false, "a view of three whole words");
    defer fb.DestroyBufferView(device, from_three);
    if (fb.CreateBufferView(device, &.{ .buffer = colors, .format = .r32g32b32_uint }, &into_three) != .success) return probe.check(false, "and one written through");
    defer fb.DestroyBufferView(device, into_three);
    const threes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&from_three) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_texel_buffer, .descriptor_count = 1, .texel_buffer_view = @ptrCast(&into_three) },
    };
    fb.UpdateDescriptorSets(device, 2, &threes, 0, null);
    commands = probe.record() orelse return probe.check(false, "a recording of the three-channel copy");
    fb.CmdBindPipeline(commands, .compute, pipelines[3].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the three-channel copy submitted");
    var all_three = true;
    for (0..3) |k| if (std.mem.readInt(u32, color_bytes[k * 4 ..][0..4], .little) != three) {
        all_three = false;
    };
    probe.check(all_three, "three channels of 32 bits copied by whole numbers");
    probe.checkEqual(0, std.mem.readInt(u32, color_bytes[12..16], .little), "and nothing written past them");
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
    if (!probe.can.independent_blend) {
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
    if (!probe.can.depth_bias) {
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
    if (!probe.can.dynamic_descriptors) {
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
    // Vulkan counts the two dynamic kinds apart, where facet folded them
    // into one number until 1.82. The library's cap is per set layout, so
    // each kind carries the whole of it.
    const most = properties.limits.max_descriptor_set_uniform_buffers_dynamic;
    probe.checkEqual(most, properties.limits.max_descriptor_set_storage_buffers_dynamic, "the two dynamic kinds are capped alike");
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
    probe.checkEqual(limits.sampled_image_color_sample_counts, shape.sample_counts, "the samples a pixel its limit says");
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
    probe.check(shape.max_mip_levels > 1, "and has the levels its slices have");

    // 1.66: a depth attachment has the levels 1.63 gave it, and the
    // layers 1.58 gave one that is read back; since 1.91 one that is not
    // read back has them as well, a framebuffer's layers being drawn into.
    if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .d16_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0, &shape) != .success) {
        return probe.check(false, "the largest depth attachment");
    }
    probe.check(shape.max_mip_levels > 1, "a depth attachment has levels of its own");
    probe.checkEqual(limits.max_image_array_layers, shape.max_array_layers, "and its layers, read back or not");
    if (probe.can.sampled_depth) {
        const read_back = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED;
        if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .d16_unorm, .@"2d", .optimal, read_back, 0, &shape) != .success) {
            return probe.check(false, "the largest sampled depth attachment");
        }
        probe.checkEqual(limits.max_image_array_layers, shape.max_array_layers, "a sampled depth attachment has its layers");
    }

    // 1.66: `max_resource_size` is the bytes of the image the rest of the
    // answer describes - that image made, and its memory asked for.
    // CreateImage lays an image out and binds nothing, so the largest
    // costs an object and no memory at all.
    if (fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"2d", .optimal, sampled, 0, &shape) != .success) {
        return probe.check(false, "the largest sampled image again");
    }
    var biggest: ?*facet.Image = null;
    const laid = fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = shape.max_extent, .mip_levels = shape.max_mip_levels, .array_layers = shape.max_array_layers, .usage = sampled }, &biggest);
    probe.check(laid == .success, "the largest image of that answer made");
    if (laid == .success) {
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, biggest.?, &needs);
        probe.checkEqual(shape.max_resource_size, needs.size, "its memory is what max_resource_size said");
        probe.check(needs.size > @as(u64, shape.max_extent.width) * shape.max_extent.height * 4, "which is more than one level of one layer");
    }
    fb.DestroyImage(device, biggest);

    // Shapes there is no image of at all.
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .d16_unorm, .@"2d", .linear, facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT, 0, &shape) == .error_format_not_supported, "a depth image in rows refused");
    probe.checkEqual(0, shape.max_mip_levels, "and nothing written for it");

    // A 1D image, which is an image since 1.86: a texture of one row, as
    // wide as a 2D image, and its levels halve that width alone - which
    // is Vulkan's own rule for one. The 1D view types are its own and the
    // 2D ones are not, a 2D image a row high being a different image.
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"1d", .optimal, sampled, 0, &shape) == .success, "a 1D image is a shape");
    probe.checkEqual(limits.max_image_dimension_1d, shape.max_extent.width, "as wide as the limit says");
    probe.checkEqual(1, shape.max_extent.height, "one row high");
    probe.checkEqual(1, shape.max_extent.depth, "and one deep");
    var row: ?*facet.Image = null;
    if (fb.CreateImage(device, &.{ .image_type = .@"1d", .format = .b8g8r8a8_unorm, .extent = .{ .width = 256, .height = 1 }, .usage = sampled }, &row) == .success) {
        var row_view: ?*facet.ImageView = null;
        probe.check(fb.CreateImageView(device, &.{ .image = row.?, .view_type = .@"1d", .format = .b8g8r8a8_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR } }, &row_view) == .success, "a 1D view of it made");
        fb.DestroyImageView(device, row_view);
        var flat_view: ?*facet.ImageView = null;
        probe.check(fb.CreateImageView(device, &.{ .image = row.?, .view_type = .@"2d", .format = .b8g8r8a8_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR } }, &flat_view) == .error_format_not_supported, "and a 2D view of it refused");
        fb.DestroyImage(device, row);
    } else probe.check(false, "a 1D image made");
    probe.check(fb.CreateImage(device, &.{ .image_type = .@"1d", .format = .b8g8r8a8_unorm, .extent = .{ .width = 256, .height = 2 }, .usage = sampled }, &row) == .error_format_not_supported, "a 1D image two rows high refused");

    // A constant texel offset on a sample (item 28, since 1.87). Vulkan
    // asks -8 and 7 of every implementation and no feature gates it, so a
    // device either reaches the pair or reports neither - and the thing
    // that must never happen is a device advertising a range it refuses
    // every use of, which is what the V3D would do if it inherited the
    // cores' numbers. Only this board can see that: the host count in
    // tests/vulkan_limits.zig is the cores' alone.
    if (probe.can.texel_offsets) {
        probe.check(limits.min_texel_offset <= -8, "a device that offsets reaches -8");
        probe.check(limits.max_texel_offset >= 7, "and reaches 7");
    } else {
        probe.check(limits.min_texel_offset == 0, "a device that does not offset says 0");
        probe.check(limits.max_texel_offset == 0, "at both ends");
    }
    // The gather pair rides on `shader_image_gather_extended`, which this
    // library reports false, so 0 is their mandatory value rather than a
    // shortfall of either device.
    probe.check(limits.min_texel_gather_offset == 0, "and no gather offset");
    probe.check(limits.max_texel_gather_offset == 0, "at either end");

    // 1.119: an attachment that is sampled too is made where the device
    // keeps it in rows and samples it where it lies - the cores, and not
    // the V3D yet (docs/facet-vulkan10.md item 48). Whichever the device
    // is, the query and CreateImage say the same.
    const drawn_and_sampled = sampled | facet.IMAGE_USAGE_COLOR_ATTACHMENT;
    const answered = fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .b8g8r8a8_unorm, .@"2d", .optimal, drawn_and_sampled, 0, &shape);
    var drawn: ?*facet.Image = null;
    const drawn_made = fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 64, .height = 64 }, .usage = drawn_and_sampled }, &drawn);
    probe.check((answered == .success) == (drawn_made == .success), if (answered == .success) "an attachment that is sampled too made, as the query says" else "an attachment that is sampled too refused, as the query says");
    fb.DestroyImage(device, drawn);

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
    // `limits.tile_size` left PhysicalDeviceLimits at 1.82, Vulkan having
    // no member for it, so this call is the only way to ask - and there is
    // nothing beside it to check it against. What must hold of it: it is
    // square, a power of two, and no larger than the framebuffer.
    probe.checkEqual(granularity.width, granularity.height, "the render area's granularity is square");
    probe.check(granularity.width != 0 and granularity.width & (granularity.width - 1) == 0, "and a power of two");
    probe.check(granularity.width <= limits.max_framebuffer_width, "and no wider than a framebuffer");

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

    /// The depth of the attachment read, 0 to 1, as a grey of its red
    /// (since 1.62).
    fn readDepth(fragments: *const facet.shader.Fragments) callconv(.c) void {
        const from = fragments.resources.input(0, 0, 0) orelse return facet.shader.fill(fragments, missing);
        for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |spot, *out| {
            inline for (0..4) |i| {
                const x = fragments.x + @as(u32, spot.x) + @as(u32, i & 1);
                const y = fragments.y + @as(u32, spot.y) + @as(u32, i >> 1);
                const byte: u32 = @intFromFloat(from.at(x, y)[0] * 255 + 0.5);
                out[i] = 0xFF00_0000 | byte << 16;
            }
        }
    }

    /// What the attachment being drawn into already holds at this very
    /// pixel, its green and blue the other way round: read through the
    /// input attachment descriptor, which for the one being drawn is the
    /// tile (since 1.64, this way since 1.65).
    fn own(fragments: *const facet.shader.Fragments) callconv(.c) void {
        const from = fragments.input(0, 0, 0) orelse return facet.shader.fill(fragments, missing);
        for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
            inline for (0..4) |i| {
                const x = fragments.x + @as(u32, quad.x) + @as(u32, i & 1);
                const y = fragments.y + @as(u32, quad.y) + @as(u32, i >> 1);
                const color = from.colorAt(x, y);
                out[i] = (color & 0xFFFF_0000) | (color & 0xFF) << 8 | (color >> 8 & 0xFF);
            }
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 0),
        facet.shader.fragment("main", &write, 0),
        facet.shader.vertex("read", &vertex, 0),
        facet.shader.fragment("read", &read, 0),
        facet.shader.vertex("depth", &vertex, 0),
        facet.shader.fragment("depth", &readDepth, 0),
        facet.shader.vertex("own", &vertex, 0),
        facet.shader.fragment("own", &own, 0),
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

    if (!probe.can.input_attachments) {
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
    // 1.62: a depth attachment is read as an input attachment, where
    // the device keeps a depth to be read at all.
    const depth_pass = probe.renderPass(.{ .attachment_count = 2, .attachments = &with_depth, .subpass_count = 1, .subpasses = @ptrCast(&reads_depth) });
    probe.check((depth_pass != null) == probe.can.sampled_depth, if (probe.can.sampled_depth) "a depth attachment read as an input attachment" else "a depth attachment read as an input attachment refused where none is kept");

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

    // An input attachment is kept in rows, so it is sampled as well only
    // on a device that samples rows where they lie: the cores since 1.119
    // and not the V3D yet (docs/facet-vulkan10.md item 48). The query and
    // CreateImage say the same either way.
    var read_and_sampled: ?*facet.Image = null;
    const both = facet.ImageCreateInfo{ .format = .b8g8r8a8_unorm, .extent = .{ .width = 8, .height = 8 }, .usage = facet.IMAGE_USAGE_INPUT_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED };
    var both_shape: facet.ImageFormatProperties = undefined;
    const both_said = fb.GetPhysicalDeviceImageFormatProperties(probe.physical, both.format, .@"2d", .optimal, both.usage, 0, &both_shape);
    const both_made = fb.CreateImage(device, &both, &read_and_sampled);
    probe.check((both_said == .success) == (both_made == .success), if (both_said == .success) "an image both read and sampled made, as the query says" else "an image both read and sampled refused, as the query says");
    probe.check((both_made == .success) == (read_and_sampled != null), "and given back exactly where it is made");
    fb.DestroyImage(device, read_and_sampled);

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

    // 1.62: the depth the first subpass drew, read pixel by pixel by the
    // next - the plane the view's aspect names, out of the image's rows.
    if (!probe.can.sampled_depth or !probe.can.stored_depth) return;
    const deep = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT }, 0) orelse
        return probe.check(false, "a depth attachment made to be read");
    var transient: ?*facet.Image = null;
    probe.check(fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, &transient) != .success, "a transient depth refused as an input attachment, having nothing behind it");
    if (transient) |each| fb.DestroyImage(device, each);
    const both_kinds = [2]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .d16_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const two = [2]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &to_first, .depth_stencil_attachment = &to_second[0] },
        .{ .input_attachment_count = 1, .input_attachments = &to_second, .color_attachment_count = 1, .color_attachments = &to_first },
    };
    const deep_pass = probe.renderPass(.{ .attachment_count = 2, .attachments = &both_kinds, .subpass_count = 2, .subpasses = &two }) orelse
        return probe.check(false, "a pass that draws a depth and then reads it");
    probe.check(true, "a pass that draws a depth and then reads it");
    const deep_frame = probe.framebuffer(deep_pass, &.{ second[1], deep[1] }) orelse return probe.check(false, "a framebuffer over the colour and the depth");

    var deep_pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &deep_pool) != .success) return probe.check(false, "a pool for the depth's set");
    defer fb.DestroyDescriptorPool(device, deep_pool);
    var deep_sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = deep_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &deep_sets) != .success) return probe.check(false, "a set for the depth");
    const deep_info = facet.DescriptorImageInfo{ .image_view = deep[1], .image_layout = .general };
    const deep_write = facet.WriteDescriptorSet{ .dst_set = deep_sets[0].?, .dst_binding = 0, .descriptor_type = .input_attachment, .descriptor_count = 1, .image_info = @ptrCast(&deep_info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&deep_write), 0, null);

    const writing = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    const draws = pipelineOf(probe, deep_pass, module.?, layout.?, .{ .depth_state = writing }) orelse
        return probe.check(false, "the pipeline that draws the depth");
    const takes = pipelineOf(probe, deep_pass, module.?, layout.?, .{ .subpass = 1, .name = "depth" }) orelse
        return probe.check(false, "the pipeline that reads it");

    // The left half nearer than the clear, so the two halves hold two
    // depths; the second subpass draws them as greys.
    const half = [6][3]f32{ .{ -1, -1, 0.25 }, .{ 0, -1, 0.25 }, .{ -1, 1, 0.25 }, .{ -1, 1, 0.25 }, .{ 0, -1, 0.25 }, .{ 0, 1, 0.25 } };
    const half_buffer, const half_bytes = probe.buffer(@sizeOf(@TypeOf(half)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer for the half quad");
    @memcpy(half_bytes[0..@sizeOf(@TypeOf(half))], std.mem.asBytes(&half));
    const deep_clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } } };
    const commands = probe.record() orelse return probe.check(false, "a recording of the two subpasses");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = deep_pass, .framebuffer = deep_frame, .render_area = area, .clear_value_count = 2, .clear_values = &deep_clears }, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&half_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, draws);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdNextSubpass(commands, .@"inline");
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(commands, .graphics, takes);
    fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&deep_sets), 0, null);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the two subpasses submitted");
    checkNearColor(probe, 0xFF40_0000, pixelAt(second_pixels, second_pitch, 8, 8), "the depth the subpass before drew, read where the quad covered it");
    checkNearColor(probe, 0xFFFF_0000, pixelAt(second_pixels, second_pitch, 40, 52), "and the depth the clear left, where it did not");

    // 1.64: a subpass that reads the colour attachment it draws into -
    // the pixel as the tile holds it - where a dependency of the subpass
    // on itself by region says so.
    const reads_itself = facet.SubpassDescription{ .input_attachment_count = 1, .input_attachments = &to_first, .color_attachment_count = 1, .color_attachments = &to_first };
    const by_region = facet.SubpassDependency{ .src_subpass = 0, .dst_subpass = 0, .src_stage_mask = 0, .dst_stage_mask = 0, .dependency_flags = facet.DEPENDENCY_BY_REGION };
    const one_attachment = [1]facet.AttachmentDescription{.{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general }};
    const own_pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = &one_attachment,
        .subpass_count = 1,
        .subpasses = @ptrCast(&reads_itself),
        .dependency_count = 1,
        .dependencies = @ptrCast(&by_region),
    }) orelse return probe.check(false, "a subpass that reads what it draws, by region");
    probe.check(true, "a subpass that reads what it draws, by region");
    const own_frame = probe.framebuffer(own_pass, &.{first[1]}) orelse return probe.check(false, "a framebuffer for it");
    const fills = pipelineOf(probe, own_pass, module.?, layout.?, .{}) orelse return probe.check(false, "the pipeline that writes the colour");
    const mixes = pipelineOf(probe, own_pass, module.?, layout.?, .{ .name = "own" }) orelse return probe.check(false, "the pipeline that reads it back");
    const own_clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    const own_commands = probe.record() orelse return probe.check(false, "a recording of the two draws");
    fb.CmdBeginRenderPass(own_commands, &.{ .render_pass = own_pass, .framebuffer = own_frame, .render_area = area, .clear_value_count = 1, .clear_values = &own_clear }, .@"inline");
    fb.CmdBindVertexBuffers(own_commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBindPipeline(own_commands, .graphics, fills);
    fb.CmdDraw(own_commands, 6, 1, 0, 0);
    fb.CmdBindPipeline(own_commands, .graphics, mixes);
    // The set written with a view of the very attachment being drawn:
    // what the descriptor names is the tile, and what the function reads
    // is the fragment's own pixel.
    fb.CmdBindDescriptorSets(own_commands, .graphics, layout.?, 0, 1, @ptrCast(&sets[0]), 0, null);
    fb.CmdDraw(own_commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(own_commands);
    if (!probe.submit()) return probe.check(false, "the two draws submitted");
    probe.checkEqual(Deferred.swapped, pixelAt(first_pixels, first_pitch, 8, 8), "what the draw before it left at the pixel, read through the descriptor of it");
    probe.checkEqual(Deferred.swapped, pixelAt(first_pixels, first_pitch, 40, 52), "the same in another tile");
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
    if (!probe.can.stored_stencil) {
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
    const blue: u32 = 0xFF00_00FF;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const marks = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = marked };
    const equal = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = marked };

    // The colour comes from the vertices, so these checks run on a device
    // that runs none of the program's fragment functions as well
    // (since 1.47).
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Painted.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const painted = Shape{ .attributes = &Painted.attributes, .stride = Painted.stride };

    // All of the picture in green, then its left half in red.
    const paint_green = [3]f32{ 0, 1, 0 };
    const paint_red = [3]f32{ 1, 0, 0 };
    const vertices = [_][6]f32{
        Painted.at(-1, -1, 0.5, paint_green), Painted.at(1, -1, 0.5, paint_green), Painted.at(-1, 1, 0.5, paint_green),
        Painted.at(-1, 1, 0.5, paint_green),  Painted.at(1, -1, 0.5, paint_green), Painted.at(1, 1, 0.5, paint_green),
        Painted.at(-1, -1, 0.5, paint_red),   Painted.at(0, -1, 0.5, paint_red),   Painted.at(-1, 1, 0.5, paint_red),
        Painted.at(-1, 1, 0.5, paint_red),    Painted.at(0, -1, 0.5, paint_red),   Painted.at(0, 1, 0.5, paint_red),
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;

    // A format that holds a depth beside the stencil keeps either only
    // where the device writes a pixel's planes where they lie in it
    // (`stored_both`, since 1.47); a device that stores a tile buffer
    // whole - the V3D - takes the format of a stencil alone.
    if (!probe.can.stored_both) {
        probe.check(passStenciling(probe, .d16_unorm_s8_uint, "cdcs") == null, "a stored stencil refused for a format that holds a depth too");
        probe.check(passStenciling(probe, .d16_unorm_s8_uint, "cdcd") != null, "one that stays in the tiles is still taken");
    }

    // One format of stencil alone, and one that holds a depth beside it
    // where the device keeps either of the two.
    const formats: []const facet.Format = if (probe.can.stored_both) &.{ .s8_uint, .d16_unorm_s8_uint } else &.{.s8_uint};
    for (formats) |format| {
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

        const mark = pipelineOf(probe, storing, module.?, layout.?, shapeWith(painted, .{ .stencil = [2]facet.StencilOpState{ marks, marks } })) orelse return probe.check(false, "a pipeline that marks");
        const draw = pipelineOf(probe, loading, module.?, layout.?, shapeWith(painted, .{ .stencil = [2]facet.StencilOpState{ equal, equal } })) orelse return probe.check(false, "a pipeline that draws where marked");

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
        fb.CmdClearDepthStencilImage(commands, stencil[0], .undefined, &value, 1, @ptrCast(&only_stencil));
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
    if (!probe.can.sampled_depth) {
        probe.check(asked != .success and made == null, "a sampled depth image refused where the device samples none");
        return;
    }
    if (asked != .success or made == null) return probe.check(false, "a depth image that is sampled as well");
    fb.DestroyImage(device, made);
    probe.check(true, "a depth image that is sampled as well");
    // Levels of its own since 1.63, as many as halving the longer side
    // gives; a volume it is never, what a pass draws into being rows.
    var none: ?*facet.Image = null;
    probe.check(fb.CreateImage(device, &.{ .format = .d16_unorm, .extent = extent, .mip_levels = 9, .usage = usage }, &none) != .success, "more levels than halving its longer side gives refused");
    probe.check(fb.CreateImage(device, &.{ .format = .d16_unorm, .image_type = .@"3d", .extent = .{ .width = side, .height = side, .depth = 2 }, .usage = usage }, &none) != .success, "and a volume refused");
    probe.check(none == null, "and nothing given back for either");

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

    // What passed reads (1, 0, 0, 1) and what failed (0, 0, 0, 1): a
    // depth reads (D, 0, 0, 1), as Vulkan converts one, and what a
    // comparison gave stands in its D (since 1.121).
    const white: u32 = 0xFFFF_0000;
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

    // --- 1.58: the planes a view names, and layers ---
    // A format that holds a stencil is sampled as well: a view takes one
    // of its planes, and both at once is no texture.
    const with_stencil = probe.bound(.{ .format = .d16_unorm_s8_uint, .extent = extent, .usage = usage | facet.IMAGE_USAGE_TRANSFER_DST }, 0);
    probe.check(with_stencil != null, "a sampled depth image of a format that holds a stencil");
    if (with_stencil) |held| {
        const depth_plane = probe.viewed(.{ .image = held, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } });
        const stencil_plane = probe.viewed(.{ .image = held, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_STENCIL } });
        probe.check(depth_plane != null and stencil_plane != null, "a view of each of its planes");
        var two: ?*facet.ImageView = null;
        probe.check(fb.CreateImageView(device, &.{ .image = held, .format = .d16_unorm_s8_uint, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL } }, &two) != .success and two == null, "and both planes at once no view at all");

        // Its depth plane cleared and sampled, the stencil beside it left
        // whole: the plane is read two bytes of every four, so a sample
        // that read the four would not answer the reference.
        if (depth_plane) |plane| {
            const filled = facet.ClearDepthStencilValue{ .depth = 0.75, .stencil = 0xFF };
            const planes = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL };
            commands = probe.record() orelse return probe.check(false, "a recording of the plane cleared");
            fb.CmdClearDepthStencilImage(commands, held, .undefined, &filled, 1, @ptrCast(&planes));
            if (!probe.submit()) return probe.check(false, "the plane cleared");
            probe.checkEqual(white, sampledWith(probe, plane, sampler.?, sets[0].?, layout.?, reading, onto, shade, vertex_buffer, vertex_bytes, pixels, pitch, 0.5), "the depth plane of such an image sampled at 16 bits");
        }
    }

    // Layers since 1.58: a layer's rows after the one before, which a
    // pass draws into one of and a sample reads any of.
    const layered = probe.bound(.{ .format = .d16_unorm, .extent = extent, .array_layers = 3, .usage = usage }, 0);
    probe.check(layered != null, "a sampled depth image of three layers");
    if (layered) |held| {
        var layer_views: [2]?*facet.ImageView = .{ null, null };
        for (&layer_views, [2]u32{ 0, 2 }) |*view, layer| {
            view.* = probe.viewed(.{ .image = held, .format = .d16_unorm, .subresource_range = .{
                .aspect_mask = facet.IMAGE_ASPECT_DEPTH,
                .base_array_layer = layer,
                .layer_count = 1,
            } });
        }
        probe.check(layer_views[0] != null and layer_views[1] != null, "a view of one layer of it, and of another");
        if (layer_views[0] != null and layer_views[1] != null) {
            // The first layer drawn at 0.25 and the third at 0.75, each
            // through a framebuffer with that layer's view.
            var drawn = true;
            for (layer_views, [2]f32{ 0.25, 0.75 }) |view, how_near| {
                const frame_of = probe.framebuffer(storing, &.{ color[1], view.? }) orelse {
                    drawn = false;
                    continue;
                };
                const quad = quadAt(how_near);
                @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
                commands = probe.record() orelse return probe.check(false, "a recording of a layer drawn into");
                fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame_of, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
                fb.CmdBindPipeline(commands, .graphics, list);
                fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
                fb.CmdPushConstants(commands, flat_layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
                fb.CmdDraw(commands, 6, 1, 0, 0);
                fb.CmdEndRenderPass(commands);
                if (!probe.submit()) return probe.check(false, "a layer drawn into");
            }
            probe.check(drawn, "a pass over each of two layers of it");
            // A reference halfway: nearer than the third layer's 0.75 and
            // further than the first's 0.25, so each layer answers for
            // itself.
            probe.checkEqual(black, sampledWith(probe, layer_views[0].?, sampler.?, sets[0].?, layout.?, reading, onto, shade, vertex_buffer, vertex_bytes, pixels, pitch, 0.5), "the layer a view names sampled, the nearer one");
            probe.checkEqual(white, sampledWith(probe, layer_views[1].?, sampler.?, sets[0].?, layout.?, reading, onto, shade, vertex_buffer, vertex_bytes, pixels, pitch, 0.5), "and the further one, its own rows a layer on");
        }
    }

    // Levels since 1.63: a level's rows after the level before it inside
    // the layer, each as wide as that level is, which a pass draws into
    // one of and a sample reads the one its sampler holds it to.
    const mipped = probe.bound(.{ .format = .d16_unorm, .extent = extent, .mip_levels = 2, .usage = usage }, 0);
    probe.check(mipped != null, "a sampled depth image of two levels");
    if (mipped) |held| {
        // Its memory is the pyramid: the first level's rows, 2 bytes a
        // pixel, and the second's, half as wide and half as high.
        const first_bytes = @as(u64, side) * 2 * side;
        const second_bytes = @as(u64, side / 2) * 2 * (side / 2);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(device, held, &needs);
        probe.checkEqual(first_bytes + second_bytes, needs.size, "its memory is both levels' rows");
        var level_layout: facet.SubresourceLayout = undefined;
        fb.GetImageSubresourceLayout(device, held, &.{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .mip_level = 1 }, &level_layout);
        probe.checkEqual(first_bytes, level_layout.offset, "the second level begins after the first level's rows");
        probe.checkEqual(@as(u64, side / 2) * 2, level_layout.row_pitch, "and its rows are as wide as that level is");

        const first_view = probe.viewed(.{ .image = held, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .level_count = 1 } });
        const deeper_view = probe.viewed(.{ .image = held, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } });
        probe.check(first_view != null and deeper_view != null, "a view of its first level, and one of both");
        var at_first: ?*facet.Sampler = null;
        var at_second: ?*facet.Sampler = null;
        var held_to = facet.SamplerCreateInfo{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .compare_enable = true,
            .compare_op = .less,
        };
        const asked_first = fb.CreateSampler(device, &held_to, &at_first);
        held_to.min_lod = 1;
        held_to.max_lod = 1;
        const asked_second = fb.CreateSampler(device, &held_to, &at_second);
        defer fb.DestroySampler(device, at_first);
        defer fb.DestroySampler(device, at_second);
        probe.check(asked_first == .success and asked_second == .success, "a sampler held to each of the two levels");
        if (first_view != null and deeper_view != null and at_first != null and at_second != null) {
            // Both levels cleared further than the quad, then the first
            // drawn into: the second keeps what the clear left there.
            const far = facet.ClearDepthStencilValue{ .depth = 0.75 };
            const every_level = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
            commands = probe.record() orelse return probe.check(false, "a recording of both levels cleared");
            fb.CmdClearDepthStencilImage(commands, held, .undefined, &far, 1, @ptrCast(&every_level));
            if (!probe.submit()) return probe.check(false, "both its levels cleared");
            if (probe.framebuffer(storing, &.{ color[1], first_view.? })) |frame_of| {
                const quad = quadAt(0.25);
                @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
                commands = probe.record() orelse return probe.check(false, "a recording of its first level drawn into");
                fb.CmdBeginRenderPass(commands, &.{ .render_pass = storing, .framebuffer = frame_of, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
                fb.CmdBindPipeline(commands, .graphics, list);
                fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
                fb.CmdPushConstants(commands, flat_layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 4, &red);
                fb.CmdDraw(commands, 6, 1, 0, 0);
                fb.CmdEndRenderPass(commands);
                if (!probe.submit()) return probe.check(false, "its first level drawn into");
                probe.check(true, "a pass into the level its view names");
                // A reference halfway: nearer than the clear's 0.75 and
                // further than the quad's 0.25, so each level answers for
                // itself.
                probe.checkEqual(black, sampledWith(probe, deeper_view.?, at_first.?, sets[0].?, layout.?, reading, onto, shade, vertex_buffer, vertex_bytes, pixels, pitch, 0.5), "the level a sampler holds it to sampled, the first");
                probe.checkEqual(white, sampledWith(probe, deeper_view.?, at_second.?, sets[0].?, layout.?, reading, onto, shade, vertex_buffer, vertex_bytes, pixels, pitch, 0.5), "and the second, its own rows a level on");
            } else probe.check(false, "a framebuffer with its first level");
        }
    }
}

/// One shadow sample of `view` over the whole of a picture, `reference`
/// compared with every texel of it: the pixel at (16, 8) of what it drew.
/// (Since 1.58.)
fn sampledWith(
    probe: *Probe,
    view: *facet.ImageView,
    sampler: *facet.Sampler,
    set: *facet.DescriptorSet,
    layout: *facet.PipelineLayout,
    pass: *facet.RenderPass,
    frame: *facet.Framebuffer,
    pipeline: *facet.Pipeline,
    buffer: *facet.Buffer,
    bytes: [*]u8,
    pixels: [*]const u8,
    pitch: u32,
    reference: f32,
) u32 {
    const fb = probe.fb;
    const info = facet.DescriptorImageInfo{ .sampler = sampler, .image_view = view };
    const write = facet.WriteDescriptorSet{ .dst_set = set, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(probe.device.?, 1, @ptrCast(&write), 0, null);
    const quad = [6][6]f32{
        .{ -1, -1, 0.5, 0, 0, reference },
        .{ 1, -1, 0.5, 1, 0, reference },
        .{ -1, 1, 0.5, 0, 1, reference },
        .{ -1, 1, 0.5, 0, 1, reference },
        .{ 1, -1, 0.5, 1, 0, reference },
        .{ 1, 1, 0.5, 1, 1, reference },
    };
    @memcpy(bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const at: u64 = 0;
    const one_clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    const commands = probe.record() orelse return 0;
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = side, .height = side } }, .clear_value_count = 1, .clear_values = &one_clear }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, pipeline);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(&at));
    fb.CmdBindDescriptorSets(commands, .graphics, layout, 0, 1, @ptrCast(&set), 0, null);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return 0;
    return pixelAt(pixels, pitch, 16, 8);
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
    const stores = probe.can.stored_depth;
    const pass = passKeeping(probe, .clear, .clear, if (stores) .store else .dont_care) orelse
        return probe.check(false, "a pass of a colour and a depth");
    // The colour comes from the vertices, not from a push constant: these
    // checks run on a device that runs none of the program's fragment
    // functions as well (since 1.47).
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Painted.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const painted = Shape{ .attributes = &Painted.attributes, .stride = Painted.stride, .depth_tested = true };

    if (!probe.can.depth_bounds) {
        probe.check(pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .depth_state = bounded })) == null, "a depth bounds test refused where the device has none");
    }
    if (!probe.can.depth_clamp) {
        probe.check(pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .raster = clamping })) == null, "a depth clamp refused where the device has none");
    }
    if (!probe.can.depth_bounds and !probe.can.depth_clamp) return;

    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const color_memory = probe.memories[0].?;
    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC }, 0) orelse
        return probe.check(false, "a depth image with memory behind it");
    const frame = probe.framebuffer(pass, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");
    const read_back, const back_bytes = probe.buffer(side * side * 2, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer to read the depth into");
    const whole = facet.BufferImageCopy{ .image_extent = extent, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } };

    // The left half at 0.25 in red, then all of it in green where the
    // bounds allow, then all of it in red wholly behind the near plane.
    const paint_red = [3]f32{ 1, 0, 0 };
    const paint_green = [3]f32{ 0, 1, 0 };
    const vertices = [_][6]f32{
        Painted.at(-1, -1, 0.25, paint_red),  Painted.at(0, -1, 0.25, paint_red),  Painted.at(-1, 1, 0.25, paint_red),
        Painted.at(-1, 1, 0.25, paint_red),   Painted.at(0, -1, 0.25, paint_red),  Painted.at(0, 1, 0.25, paint_red),
        Painted.at(-1, -1, 0.5, paint_green), Painted.at(1, -1, 0.5, paint_green), Painted.at(-1, 1, 0.5, paint_green),
        Painted.at(-1, 1, 0.5, paint_green),  Painted.at(1, -1, 0.5, paint_green), Painted.at(1, 1, 0.5, paint_green),
        Painted.at(-1, -1, -0.5, paint_red),  Painted.at(1, -1, -0.5, paint_red),  Painted.at(-1, 1, -0.5, paint_red),
        Painted.at(-1, 1, -0.5, paint_red),   Painted.at(1, -1, -0.5, paint_red),  Painted.at(1, 1, -0.5, paint_red),
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

    if (probe.can.depth_bounds) {
        const marks = pipelineOf(probe, pass, module.?, layout.?, painted) orelse return probe.check(false, "a pipeline that writes the depth");
        const in_bounds = pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .depth_state = bounded })) orelse
            return probe.check(false, "a pipeline whose bounds are tested");
        probe.check(true, "a pipeline whose bounds are tested");
        const dynamic_states = [1]facet.DynamicState{.depth_bounds};
        const by_command = pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .depth_state = facet.PipelineDepthStencilStateCreateInfo{ .depth_bounds_test_enable = true }, .dynamic = &dynamic_states })) orelse
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
            fb.CmdDraw(commands, 6, 1, 0, 0);
            fb.CmdBindPipeline(commands, .graphics, pipeline.?);
            if (set) |asked| fb.CmdSetDepthBounds(commands, asked[0], asked[1]);
            fb.CmdDraw(commands, 6, 1, 6, 0);
            fb.CmdEndRenderPass(commands);
            if (!probe.submit()) return probe.check(false, "the frame submitted");
            probe.checkEqual(wanted_left, pixelAt(pixels, pitch, 16, 8), name);
            probe.checkEqual(wanted_right, pixelAt(pixels, pitch, 48, 40), "and the other half of it");
        }
    }

    if (probe.can.depth_clamp) {
        // The viewport's own range, so what a clamped depth is held at is
        // not the whole of it.
        const low: f32 = 0.25;
        const writes = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .always };
        const plain = pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .depth_state = writes, .min_depth = low, .max_depth = 0.75 })) orelse
            return probe.check(false, "a pipeline that cuts at the near plane");
        const clamped = pipelineOf(probe, pass, module.?, layout.?, shapeWith(painted, .{ .depth_state = writes, .raster = clamping, .min_depth = low, .max_depth = 0.75 })) orelse
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
                checkDepth(probe, wanted_depth, depthAt(back_bytes, 16, 8), "and the depth it left");
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

// --- 1.42: a texture of any size ---------------------------------------------

/// A texture at the vertices' second two floats, sampled the nearest way:
/// one form that clamps past the edges and one that wraps, so that both
/// ways round a texture of an odd size are drawn.
const Odd = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1] };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 2),
        facet.shader.fixedFragment("main", .{ .kind = .texture, .sampling = .{ .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("wrapped", &vertex, 2),
        facet.shader.fixedFragment("wrapped", .{ .kind = .texture, .sampling = .{ .filter = .nearest, .address = .wrap } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// The grey texel (x, y) of the odd texture holds: its own, and the same
/// number whichever way round the channels of a format are.
fn greyOf(x: u32, y: u32) u32 {
    const value = 20 + (y * 6 + x) * 8;
    return 0xFF00_0000 | value << 16 | value << 8 | value;
}

fn sizeChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;

    // A texture of any size, since 1.42, with as many levels as halving
    // its longer side gives and no more.
    var made: ?*facet.Image = null;
    const odd = facet.Extent3D{ .width = 100, .height = 60 };
    probe.check(fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = odd, .mip_levels = 7, .usage = sampled }, &made) == .success, "a texture 100 by 60, of seven levels");
    if (made) |one| {
        var layout: facet.SubresourceLayout = undefined;
        fb.GetImageSubresourceLayout(device, one, &.{ .mip_level = 1 }, &layout);
        probe.check(layout.offset > 0 and layout.size > 0, "its second level lies past its first");
        fb.DestroyImage(device, one);
    }
    var none: ?*facet.Image = null;
    probe.check(fb.CreateImage(device, &.{ .format = .b8g8r8a8_unorm, .extent = odd, .mip_levels = 8, .usage = sampled }, &none) != .success, "one of more levels than that refused");
    probe.check(none == null, "and nothing given back for it");

    // Six by five texels, each its own grey, copied in from a buffer.
    const across = 6;
    const down = 5;
    const texture = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = across, .height = down }, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of six by five texels");
    // Which slot the picture's own memory lands in: the texture's took one.
    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw it into");
    const shown_memory = probe.memories[slot].?;
    const texels, const texel_bytes = probe.buffer(across * down * 4, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    for (0..down) |y| for (0..across) |x| {
        const value: u8 = @intCast(20 + (y * across + x) * 8);
        texel_bytes[(y * across + x) * 4 ..][0..4].* = .{ value, value, value, 0xFF };
    };
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = across, .height = down } };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, texture[0], .general, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy into the texture submitted");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Odd.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const info = facet.DescriptorImageInfo{ .image_view = texture[1] };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw it in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const clamps = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20 }) orelse
        return probe.check(false, "a pipeline that clamps past the edges");
    const wraps = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "wrapped" }) orelse
        return probe.check(false, "a pipeline that wraps round them");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    // Where each texel's middle lands in a picture of `side`: far enough
    // from the next texel that no slip in the interpolation reaches it.
    const columns = [6]u32{ 5, 16, 26, 37, 47, 58 };
    const rows = [5]u32{ 6, 19, 32, 44, 57 };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    for ([2]struct { *facet.Pipeline, f32, [*:0]const u8 }{
        .{ clamps, 0, "every texel of a texture of an odd size drawn where it belongs" },
        .{ wraps, -1, "and the same a whole texture back, which wraps by a division" },
    }) |one| {
        const pipeline, const shift, const name = one;
        // The texture over the whole picture: 0 to 1 across it, or a whole
        // texture before that, which comes round to the same texels.
        const quad = [6][5]f32{
            .{ -1, -1, 0.5, shift, shift },
            .{ 1, -1, 0.5, shift + 1, shift },
            .{ -1, 1, 0.5, shift, shift + 1 },
            .{ -1, 1, 0.5, shift, shift + 1 },
            .{ 1, -1, 0.5, shift + 1, shift },
            .{ 1, 1, 0.5, shift + 1, shift + 1 },
        };
        @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        var right = true;
        var wanted: u32 = 0;
        var found: u32 = 0;
        for (rows, 0..) |py, y| for (columns, 0..) |px, x| {
            const want = greyOf(@intCast(x), @intCast(y));
            const seen = pixelAt(pixels, pitch, px, py);
            if (seen != want and right) {
                wanted = want;
                found = seen;
                right = false;
            }
        };
        if (right) probe.check(true, name) else probe.checkEqual(wanted, found, name);
    }

    // 1.120: a view of the same texture that swizzles, drawn by the same
    // form - red 1, green 0, and the blue and the alpha the texel's own:
    // through the run-time sampler on the cores, and on the V3D by the
    // TMU, which takes the view's swizzle over the format's own
    // (docs/facet-vulkan10.md item 41).
    const swizzled = probe.viewed(.{ .image = texture[0], .format = .b8g8r8a8_unorm, .components = .{ .r = .one, .g = .zero } }) orelse
        return probe.check(false, "a view of the texture that swizzles");
    const to_swizzled = facet.DescriptorImageInfo{ .image_view = swizzled };
    const rewrite = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&to_swizzled) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&rewrite), 0, null);
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 }, .{ 1, -1, 0.5, 1, 0 }, .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },  .{ 1, -1, 0.5, 1, 0 }, .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    commands = probe.record() orelse return probe.check(false, "a recording of the swizzled draw");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, clamps);
    fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the swizzled frame submitted");
    for (rows, 0..) |py, y| for (columns, 0..) |px, x| {
        const want = 0xFFFF_0000 | (greyOf(@intCast(x), @intCast(y)) & 0xFF);
        const seen = pixelAt(pixels, pitch, px, py);
        if (seen != want) return probe.checkEqual(want, seen, "a view that swizzles: red 1, green 0, blue and alpha its own");
    };
    probe.check(true, "a view that swizzles: red 1, green 0, blue and alpha its own");
}

// --- 1.43: the smaller edges -------------------------------------------------

/// Every element of a binding that is an array of buffers, which
/// `bufferAt` and `storageAt` reach.
const Elements = struct {
    fn run(groups: *const facet.shader.Groups) callconv(.c) void {
        const out = groups.resources.storage(u32, 0, 1) orelse return;
        if (out.len < 8) return;
        inline for (0..3) |k| {
            const one = groups.resources.bufferAt(u32, 0, 0, k);
            out[k] = if (one) |value| value.* else 0xDEAD;
        }
        if (groups.resources.storageAt(u32, 0, 1, 1)) |second| {
            if (second.len > 0) second[0] = 0x5151;
            out[3] = @intCast(second.len);
        }
        out[4] = if (groups.resources.bufferAt(u32, 0, 0, 3) == null) 1 else 0;
    }

    const entries = [_]facet.shader.Entry{facet.shader.compute("main", &run)};
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

fn edgeChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    // Both statistics of a geometry shader may be asked for, since 1.43,
    // and read 0: there is no such stage to count. A device that counts no
    // statistics at all refuses the pool, as it always did.
    const wanted = facet.QUERY_PIPELINE_STATISTIC_INPUT_ASSEMBLY_VERTICES |
        facet.QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_INVOCATIONS |
        facet.QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_PRIMITIVES;
    var pool: ?*facet.QueryPool = null;
    const asked = fb.CreateQueryPool(device, &.{ .query_type = .pipeline_statistics, .query_count = 1, .pipeline_statistics = wanted }, &pool);
    if (!probe.can.pipeline_statistics_queries) {
        probe.check(asked != .success and pool == null, "a statistics pool refused where the device counts none");
    } else if (asked != .success or pool == null) {
        probe.check(false, "a statistics pool that counts a geometry shader's two");
    } else {
        probe.check(true, "a statistics pool that counts a geometry shader's two");
        const commands = probe.record() orelse return probe.check(false, "a recording");
        fb.CmdResetQueryPool(commands, pool.?, 0, 1);
        fb.CmdBeginQuery(commands, pool.?, 0, 0);
        fb.CmdEndQuery(commands, pool.?, 0);
        if (!probe.submit()) return probe.check(false, "the query submitted");
        var values: [3]u64 = @splat(0xDEAD);
        const read = fb.GetQueryPoolResults(device, pool.?, 0, 1, @sizeOf(@TypeOf(values)), &values, @sizeOf(@TypeOf(values)), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT);
        probe.check(read == .success, "its three values read");
        probe.checkEqual(0, values[0] + values[1] + values[2], "nothing drawn, and a geometry shader's two 0 whatever runs");
        fb.DestroyQueryPool(device, pool);
    }

    // A binding that is an array of buffers, read element by element.
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Elements.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 3, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 2, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .bindings = &bindings }, &set_layout) != .success) return probe.check(false, "a set layout of two arrays of buffers");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pools: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pools) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pools);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pools.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const uniform, const uniform_bytes = probe.buffer(256, facet.BUFFER_USAGE_UNIFORM_BUFFER) orelse return probe.check(false, "a uniform buffer");
    const storage, const storage_bytes = probe.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    const in: [*]u32 = @ptrCast(@alignCast(uniform_bytes));
    const out: [*]u32 = @ptrCast(@alignCast(storage_bytes));
    for (0..64) |k| in[k] = @intCast(k);
    @memset(out[0..64], 0);
    var uniforms: [3]facet.DescriptorBufferInfo = undefined;
    for (&uniforms, 0..) |*info, k| info.* = .{ .buffer = uniform, .offset = k * 16, .range = 16 };
    const storages = [2]facet.DescriptorBufferInfo{
        .{ .buffer = storage, .offset = 0, .range = 64 },
        .{ .buffer = storage, .offset = 128, .range = 32 },
    };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = uniforms.len, .buffer_info = &uniforms },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = storages.len, .buffer_info = &storages },
    };
    fb.UpdateDescriptorSets(device, writes.len, &writes, 0, null);

    const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? };
    var pipelines: [1]?*facet.Pipeline = undefined;
    if (fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipelines) != .success) return probe.check(false, "the compute pipeline");
    _ = Probe.keep(&probe.pipelines, pipelines[0]);
    const commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdBindPipeline(commands, .compute, pipelines[0].?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 1, 1, 1);
    if (!probe.submit()) return probe.check(false, "the dispatch submitted");
    var right = true;
    for (0..3) |k| right = right and out[k] == k * 4;
    probe.check(right, "every element of a binding of buffers read, not its first alone");
    probe.checkEqual(8, out[3], "an element written through, its own range long");
    probe.checkEqual(1, out[4], "and nothing past the binding's last");
    probe.checkEqual(0x5151, out[32], "what it wrote where its range says");
}

// --- 1.44: compressed textures kept compressed -------------------------------

/// A quad over a compressed texture, drawn through a form built for its
/// blocks and through one built for 8888, which on a device that keeps the
/// blocks is the wrong format and takes the run-time sampler.
const Blocks = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1] };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 2),
        facet.shader.fixedFragment("main", .{ .kind = .texture, .sampling = .{ .format = .bc1, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("eight", &vertex, 2),
        facet.shader.fixedFragment("eight", .{ .kind = .texture, .sampling = .{ .filter = .nearest, .address = .clamp } }),
        // 1.72: BC4 and BC5, one channel and two.
        facet.shader.vertex("one", &vertex, 2),
        facet.shader.fixedFragment("one", .{ .kind = .texture, .sampling = .{ .format = .bc4, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("two", &vertex, 2),
        facet.shader.fixedFragment("two", .{ .kind = .texture, .sampling = .{ .format = .bc5, .filter = .nearest, .address = .clamp } }),
        // 1.73: BC7, four channels in the same sixteen bytes.
        facet.shader.vertex("full", &vertex, 2),
        facet.shader.fixedFragment("full", .{ .kind = .texture, .sampling = .{ .format = .bc7, .filter = .nearest, .address = .clamp } }),
        // 1.74: BC6H's three channels of half float.
        facet.shader.vertex("halves", &vertex, 2),
        facet.shader.fixedFragment("halves", .{ .kind = .texture, .sampling = .{ .format = .bc6hu, .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A BC1 block of one colour: both endpoints it, every texel the first.
    fn block(color: u16, into: *[8]u8) void {
        into[0] = @truncate(color);
        into[1] = @truncate(color >> 8);
        into[2] = into[0];
        into[3] = into[1];
        @memset(into[4..8], 0);
    }

    /// A BC4 block of one value: both endpoints it, so every texel takes
    /// it whatever the indices say (since 1.72).
    fn channel(value: u8, into: *[8]u8) void {
        into[0] = value;
        into[1] = value;
        @memset(into[2..8], 0);
    }

    /// A BC5 block: the red's block, then the green's (since 1.72).
    fn channels(red: u8, green: u8, into: *[16]u8) void {
        channel(red, into[0..8]);
        channel(green, into[8..16]);
    }

    /// A BC6H block of one colour: mode 3, which holds both endpoints as
    /// they are in 10 bits each and transforms neither, so every texel
    /// takes the first whatever the indices say. 495 of 1024 unquantizes
    /// and scales to the half float for 1, and 0 to 0 (since 1.74).
    fn halves(red: u32, green: u32, blue: u32, into: *[16]u8) void {
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

    /// A BC7 block of one colour: mode 6, both endpoints the colour, so
    /// every texel takes it whatever the indices say. Each channel must
    /// be even - one p-bit stands under all four channels of an endpoint,
    /// and it is 0 here (since 1.73).
    fn full(color: u32, into: *[16]u8) void {
        @memset(into, 0);
        // Mode 6 is six zeros and a 1, then 7 bits a channel for each
        // endpoint in turn, red first and the alpha last.
        into[0] = 0x40;
        var next: u32 = 7;
        for ([4]u32{ color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF, color >> 24 }) |channel_value| {
            for (0..2) |_| {
                for (0..7) |bit| {
                    const place = next + @as(u32, @intCast(bit));
                    if (channel_value >> 1 >> @intCast(bit) & 1 != 0) into[place >> 3] |= @as(u8, 1) << @intCast(place & 7);
                }
                next += 7;
            }
        }
    }
};

/// A texture of 16 by 16 of BC1, its blocks red on the left and blue on the
/// right: kept as blocks where the device samples them, unpacked where it
/// does not, and the same colours sampled either way.
fn blockChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const kept = probe.can.kept_compressed;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const across = 16;

    // Read back as well as written where the blocks are kept: there is
    // something of the format to read.
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .bc1_rgba_unorm_block, &properties);
    const reads = properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0;
    probe.check(reads == kept, if (kept) "a compressed format may be copied out of, the blocks being kept" else "a compressed format may not be copied out of, being unpacked");

    const texture = probe.image(.{ .format = .bc1_rgba_unorm_block, .extent = .{ .width = across, .height = across }, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 16 by 16 of BC1");
    // An eighth of what the texels take unpacked: 16 blocks of 8 bytes.
    // Unpacked it is 1024 at least - a device with a layout of its own
    // takes more, the V3D 4096 for a tile it can read.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, texture[0], &needs);
    const sized = if (kept) needs.size == 128 else needs.size >= 1024;
    if (sized) probe.check(true, "its memory is its blocks' where they are kept, the texels' or more where they are not") else probe.checkEqual(if (kept) 128 else 1024, needs.size, "its memory is its blocks' where they are kept, the texels' or more where they are not");

    // Which slot the picture's own memory lands in: the texture's took one.
    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw it into");
    const shown_memory = probe.memories[slot].?;

    const blocks, const block_bytes = probe.buffer(2048, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the blocks come from");
    for (0..16) |k| Blocks.block(if (k % 4 < 2) 0xF800 else 0x001F, block_bytes[k * 8 ..][0..8]);
    // The BC4 and BC5 blocks of 1.72 beside them: a red of 200 on the
    // left and 100 on the right, with a green of 10 and 250.
    const one_at = 256;
    const two_at = 384;
    // And the BC7 blocks of 1.73: red at half alpha on the left and blue
    // at a quarter on the right, which is the alpha no other block of
    // these carries.
    const full_at = 640;
    // And the BC6H blocks of 1.74: red on the left and blue on the right,
    // each channel the half float for 1 or for 0.
    const halves_at = 896;
    for (0..16) |k| {
        const left = k % 4 < 2;
        Blocks.channel(if (left) 200 else 100, block_bytes[one_at + k * 8 ..][0..8]);
        Blocks.channels(if (left) 200 else 100, if (left) 10 else 250, block_bytes[two_at + k * 16 ..][0..16]);
        Blocks.full(if (left) 0x80FE_0000 else 0x4000_00FE, block_bytes[full_at + k * 16 ..][0..16]);
        Blocks.halves(if (left) 495 else 0, 0, if (left) 0 else 495, block_bytes[halves_at + k * 16 ..][0..16]);
    }
    const back, const back_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer they are read back into");
    @memset(back_bytes[0..128], 0);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = across, .height = across } };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, blocks, texture[0], .general, 1, @ptrCast(&whole));
    if (kept) fb.CmdCopyImageToBuffer(commands, texture[0], .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy into the texture submitted");
    if (kept) {
        var same = true;
        for (0..128) |k| if (block_bytes[k] != back_bytes[k]) {
            same = false;
            break;
        };
        probe.check(same, "the blocks read back are the ones copied in, nothing decoded on the way");
    }

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Blocks.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const info = facet.DescriptorImageInfo{ .image_view = texture[1] };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw it in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_blocks = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20 }) orelse
        return probe.check(false, "a pipeline whose form samples blocks");
    const of_eight = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "eight" }) orelse
        return probe.check(false, "a pipeline whose form samples 8888");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    // Both forms draw the texture: the one built for what it holds takes
    // the fast path, the other the run-time sampler. Either way the left
    // of the picture is the red blocks and the right the blue.
    for ([2]struct { *facet.Pipeline, [*:0]const u8 }{
        .{ of_blocks, "a form built for the kept format draws the texture's own colours" },
        .{ of_eight, "and one built for 8888 draws the same, through the run-time sampler" },
    }) |one| {
        const pipeline, const name = one;
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const left = pixelAt(pixels, pitch, quarter, quarter);
        const right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (left == 0xFFFF_0000 and right == 0xFF00_00FF) probe.check(true, name) else probe.checkEqual(0xFFFF_0000_FF00_00FF, @as(u64, left) << 32 | right, name);
    }

    // 1.72: BC4 and BC5, the block BC3 keeps its alpha in over one
    // channel and over two. 8 bytes a block and 16, read as
    // (red, 0, 0, 1) and (red, green, 0, 1).
    for ([5]facet.Format{ .bc4_unorm_block, .bc5_unorm_block, .bc7_unorm_block, .bc6h_ufloat_block, .bc6h_sfloat_block }) |format| {
        fb.GetPhysicalDeviceFormatProperties(probe.physical, format, &properties);
        probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0, "one channel of a BC block and two, BC7's four and BC6H's halves are formats a texture may be of");
        probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT == 0, "and never ones an image is drawn into");
    }
    for ([4]struct { facet.Format, u32, usize, u64, u64, [*:0]const u8 }{
        .{ .bc4_unorm_block, 8, one_at, 0xFFC8_0000, 0xFF64_0000, "BC4 reads red alone, the green and the blue 0 and the alpha whole" },
        .{ .bc5_unorm_block, 16, two_at, 0xFFC8_0A00, 0xFF64_FA00, "BC5 reads red and green, the blue 0 and the alpha whole" },
        // 1.73: the colour and the alpha both the block's own, where BC1
        // to BC5 hold a punched-through alpha, a coarse one or none.
        .{ .bc7_unorm_block, 16, full_at, 0x80FE_0000, 0x4000_00FE, "BC7 reads four channels out of its subsets, the alpha its own" },
        // 1.74: three channels of half float, read as a float texture's
        // are - held between 0 and 1 and rounded to 8 bits.
        .{ .bc6h_ufloat_block, 16, halves_at, 0xFFFF_0000, 0xFF00_00FF, "BC6H reads three channels of half float, the alpha whole" },
    }, [4][*:0]const u8{ "one", "two", "full", "halves" }) |one, name| {
        const format, const wide, const at, const want_left, const want_right, const says = one;
        const held = probe.image(.{ .format = format, .extent = .{ .width = across, .height = across }, .usage = sampled }, 0) orelse {
            probe.check(false, says);
            continue;
        };
        fb.GetImageMemoryRequirements(device, held[0], &needs);
        const asked: u64 = if (kept) 16 * wide else across * across * 4;
        if (needs.size >= asked) probe.check(true, "its memory is its blocks' where they are kept") else probe.checkEqual(asked, needs.size, "its memory is its blocks' where they are kept");
        const region = facet.BufferImageCopy{ .buffer_offset = at, .image_extent = .{ .width = across, .height = across } };
        const draws = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = name }) orelse {
            probe.check(false, says);
            continue;
        };
        const to_held = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&facet.DescriptorImageInfo{ .image_view = held[1] }) };
        commands = probe.record() orelse return probe.check(false, "a recording of the copy");
        fb.CmdCopyBufferToImage(commands, blocks, held[0], .general, 1, @ptrCast(&region));
        if (!probe.submit()) return probe.check(false, "the copy of the one-channel blocks submitted");
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&to_held), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, draws);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const left = pixelAt(pixels, pitch, quarter, quarter);
        const right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (left == want_left and right == want_right) probe.check(true, says) else probe.checkEqual(want_left << 32 | want_right, @as(u64, left) << 32 | right, says);
    }
}

// --- 1.45: float textures kept as their floats -------------------------------

/// A quad over a float texture, drawn through a form built for its floats
/// and through one built for 8888.
const Floats = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1] };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 2),
        facet.shader.fixedFragment("main", .{ .kind = .texture, .sampling = .{ .format = .rgba16f, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("eight", &vertex, 2),
        facet.shader.fixedFragment("eight", .{ .kind = .texture, .sampling = .{ .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// Four half floats, red first, as a texel holds them.
    fn texel(values: [4]f32, into: *[8]u8) void {
        for (values, 0..) |value, k| {
            const half: u16 = @bitCast(@as(f16, @floatCast(value)));
            into[k * 2] = @truncate(half);
            into[k * 2 + 1] = @truncate(half >> 8);
        }
    }
};

/// A texture of 4 by 4 of R16G16B16A16_SFLOAT, red on the left and
/// half-bright blue on the right: kept as its floats where the device
/// samples them, unpacked where it does not, and the same colours either
/// way.
fn floatChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const kept = probe.can.kept_floats;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const across = 4;

    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r16g16b16a16_sfloat, &properties);
    const reads = properties.optimal_tiling_features & facet.FORMAT_FEATURE_TRANSFER_SRC != 0;
    probe.check(reads == kept, if (kept) "a float format may be copied out of, the floats being kept" else "a float format may not be copied out of, being unpacked");

    const texture = probe.image(.{ .format = .r16g16b16a16_sfloat, .extent = .{ .width = across, .height = across }, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 4 by 4 of halves");
    // Four halves a texel where they are kept; where they are not, the
    // 8888 they unpack into, which a texture keeps spread in 8 bytes as
    // well - so a device with a layout of its own is the only one that
    // asks for more.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, texture[0], &needs);
    const sized = if (kept) needs.size == across * across * 8 else needs.size >= across * across * 4;
    if (sized) probe.check(true, "its memory is its texels' own") else probe.checkEqual(across * across * 8, needs.size, "its memory is its texels' own");

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw it into");
    const shown_memory = probe.memories[slot].?;

    const texels, const texel_bytes = probe.buffer(256, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    for (0..16) |k| Floats.texel(if (k % 4 < 2) .{ 2, -1, 0, 1 } else .{ 0, 0, 0.5, 1 }, texel_bytes[k * 8 ..][0..8]);
    const back, const back_bytes = probe.buffer(256, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer they are read back into");
    @memset(back_bytes[0..128], 0);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = across, .height = across } };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, texture[0], .general, 1, @ptrCast(&whole));
    if (kept) fb.CmdCopyImageToBuffer(commands, texture[0], .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy into the texture submitted");
    if (kept) {
        var same = true;
        for (0..128) |k| if (texel_bytes[k] != back_bytes[k]) {
            same = false;
            break;
        };
        probe.check(same, "the floats read back are the ones copied in, nothing rounded on the way");

        // 1.61: a clear of such an image writes the channels it was
        // given, 2 and 0.5 among them, where before it wrote nothing.
        const filled = probe.image(.{ .format = .r16g16b16a16_sfloat, .extent = .{ .width = across, .height = across }, .usage = sampled }, 0) orelse
            return probe.check(false, "a float texture to clear");
        var want: [8]u8 = undefined;
        Floats.texel(.{ 2, -1, 0.5, 1 }, &want);
        @memset(back_bytes[128..256], 0xAA);
        const cleared = facet.ClearColorValue{ .float32 = .{ 2, -1, 0.5, 1 } };
        const range = facet.ImageSubresourceRange{};
        const out = facet.BufferImageCopy{ .buffer_offset = 128, .image_extent = .{ .width = across, .height = across } };
        commands = probe.record() orelse return probe.check(false, "a recording of the clear");
        fb.CmdClearColorImage(commands, filled[0], .transfer_dst_optimal, &cleared, 1, @ptrCast(&range));
        fb.CmdCopyImageToBuffer(commands, filled[0], .general, back, 1, @ptrCast(&out));
        if (!probe.submit()) return probe.check(false, "the clear of a float image submitted");
        var every = true;
        for (0..16) |k| if (!std.mem.eql(u8, &want, back_bytes[128 + k * 8 ..][0..8])) {
            every = false;
            break;
        };
        probe.check(every, "a clear of a float image writes the channels as they were given, 2 and 0.5 among them");
    }

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Floats.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");
    const info = facet.DescriptorImageInfo{ .image_view = texture[1] };
    const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
    fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw it in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_floats = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20 }) orelse
        return probe.check(false, "a pipeline whose form samples floats");
    const of_eight = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "eight" }) orelse
        return probe.check(false, "a pipeline whose form samples 8888");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    // 2 reads as 255 and -1 as 0, whichever form draws it: the left of the
    // picture is red and the right half-bright blue.
    for ([2]struct { *facet.Pipeline, [*:0]const u8 }{
        .{ of_floats, "a form built for the floats draws them held inside 0 to 1" },
        .{ of_eight, "and one built for 8888 draws the same, through the run-time sampler" },
    }) |one| {
        const pipeline, const name = one;
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const left = pixelAt(pixels, pitch, quarter, quarter);
        const right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (left == 0xFFFF_0000 and right == 0xFF00_0080) probe.check(true, name) else probe.checkEqual(0xFFFF_0000_FF00_0080, @as(u64, left) << 32 | right, name);
    }
}

// --- 1.46: the other texture shapes ------------------------------------------

/// A quad over a texture of layers: an array of cubes, whose instance is the
/// face and every sixth of it the cube, and a plain texture of 8888 - which
/// is what an ETC2 one is kept as, unpacked on the copy in.
const Shapes = struct {
    fn flat(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const uv = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, uv[0], uv[1] };
        }
    }

    fn cubes(vertices: *const facet.shader.Vertices) callconv(.c) void {
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
            vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], 1, towards[0], towards[1], towards[2], @floatFromInt(vertices.instance / 6) };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &flat, 2),
        facet.shader.fixedFragment("main", .{ .kind = .texture, .sampling = .{ .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("cubes", &cubes, 4),
        facet.shader.fixedFragment("cubes", .{ .kind = .texture_cube_array, .sampling = .{ .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A face's colour: sixteen apart in red, so that the faces of the two
    /// cubes are told apart.
    fn faceColor(layer: u32) u32 {
        return 0xFF00_0000 | (16 + layer * 16) << 16;
    }
};

/// The shapes of 1.46: a 3D texture with levels of its own and a depth that
/// is not a power of two, an array of cubes sampled one cube at a time, and
/// an ETC2 texture unpacked as it is copied in.
fn shapeChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const arrays = probe.can.cube_arrays;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const across = 4;
    const square = facet.Extent3D{ .width = across, .height = across };

    // ETC2 is taken on every device, sampled and copied into but never read
    // back: the blocks are gone once they are unpacked.
    probe.check(probe.can.etc2_textures, "ETC2 and EAC are taken, unpacked as they are copied in");
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .etc2_r8g8b8a8_unorm_block, &properties);
    const features = properties.optimal_tiling_features;
    probe.check(features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0 and features & facet.FORMAT_FEATURE_TRANSFER_DST != 0 and
        features & facet.FORMAT_FEATURE_TRANSFER_SRC == 0, "an ETC2 format is sampled and copied into, and not copied out of");

    // A 3D texture of six slices with five levels: each slice carries its
    // own pyramid, and a level has half the slices of the one before it.
    const volume = probe.bound(.{ .image_type = .@"3d", .format = .r8g8b8a8_unorm, .extent = .{ .width = across, .height = across, .depth = 6 }, .mip_levels = 3, .usage = sampled }, 0) orelse
        return probe.check(false, "a 3D texture of six slices with three levels");
    probe.check(probe.viewed(.{ .image = volume, .format = .r8g8b8a8_unorm, .view_type = .@"3d" }) != null, "a 3D texture may have levels of its own, and a view of the whole of it");
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, volume, &needs);
    probe.check(needs.size != 0, "its memory holds every slice's levels");
    // And a depth that is not a power of two.
    probe.check(probe.bound(.{ .image_type = .@"3d", .format = .r8g8b8a8_unorm, .extent = .{ .width = across, .height = across, .depth = 3 }, .usage = sampled }, 0) != null, "a 3D texture's depth need not be a power of two");

    // Two cubes one after another: twelve layers of a square image.
    const stack = probe.bound(.{ .format = .r8g8b8a8_unorm, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = square, .array_layers = 12, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of twelve layers, of cubes");
    const whole_cubes = facet.ImageViewCreateInfo{ .image = stack, .format = .r8g8b8a8_unorm, .view_type = .cube_array };
    const stack_view = probe.viewed(whole_cubes);
    probe.check((stack_view != null) == arrays, if (arrays) "a view of cubes one after another" else "a view of cubes one after another is refused here");
    // Whatever the device, a view of part of a cube is not one of cubes.
    probe.check(probe.viewed(.{ .image = stack, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .layer_count = 4 } }) == null, "layers that are not a multiple of six are refused");
    probe.check(probe.viewed(.{ .image = stack, .format = .r8g8b8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .base_array_layer = 2, .layer_count = 6 } }) == null, "and a first layer that does not begin a cube");

    const etc = probe.bound(.{ .format = .etc2_r8g8b8a8_unorm_block, .extent = square, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 4 by 4 of ETC2 with alpha");
    const etc_view = probe.viewed(.{ .image = etc, .format = .etc2_r8g8b8a8_unorm_block }) orelse
        return probe.check(false, "a view of it");
    fb.GetImageMemoryRequirements(device, etc, &needs);
    probe.check(needs.size >= across * across * 4, "its memory is the texels' it unpacks into, not the block's");

    // Which slot the picture's own memory lands in: the textures' took theirs.
    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw them into");
    const shown_memory = probe.memories[slot].?;

    // The twelve faces, each of one colour, and one ETC2 block after them:
    // eight bytes of EAC alpha that clamp to opaque, and eight of colour in
    // the individual mode - the first subblock red and the second blue.
    const texels, const texel_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    for (0..12) |layer| {
        const color = Shapes.faceColor(@intCast(layer));
        for (0..16) |k| texel_bytes[layer * 64 + k * 4 ..][0..4].* = .{ @truncate(color >> 16), @truncate(color >> 8), @truncate(color), 0xFF };
    }
    const block_at = 12 * 64;
    texel_bytes[block_at..][0..16].* = .{ 0xFF, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00 };

    var faces: [12]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*face, k| face.* = .{ .buffer_offset = k * 64, .image_subresource = .{ .base_array_layer = @intCast(k) }, .image_extent = square };
    const block = facet.BufferImageCopy{ .buffer_offset = block_at, .image_extent = square };
    const commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, stack, .general, 12, &faces);
    fb.CmdCopyBufferToImage(commands, texels, etc, .general, 1, @ptrCast(&block));
    if (!probe.submit()) return probe.check(false, "the copies into the textures submitted");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Shapes.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw them in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_eight = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20 }) orelse
        return probe.check(false, "a pipeline whose form samples 8888");
    const of_cubes = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "cubes" });
    probe.check((of_cubes != null) == arrays, if (arrays) "a pipeline whose form samples a cube of an array" else "a form that samples a cube of an array is refused here");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    const draw = struct {
        fn draw(on: *Probe, view: *facet.ImageView, pipeline: *facet.Pipeline, instance: u32, held: *facet.PipelineLayout, into: *facet.RenderPass, frame: *facet.Framebuffer, kept: *[1]?*facet.DescriptorSet, vertices: *facet.Buffer, first: *const u64, values: *const [1]facet.ClearValue, where: facet.Rect2D) bool {
            const f = on.fb;
            const info = facet.DescriptorImageInfo{ .image_view = view };
            const write = facet.WriteDescriptorSet{ .dst_set = kept[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
            f.UpdateDescriptorSets(on.device.?, 1, @ptrCast(&write), 0, null);
            const recording = on.record() orelse return false;
            f.CmdBeginRenderPass(recording, &.{ .render_pass = into, .framebuffer = frame, .render_area = where, .clear_value_count = 1, .clear_values = values }, .@"inline");
            f.CmdBindPipeline(recording, .graphics, pipeline);
            f.CmdBindDescriptorSets(recording, .graphics, held, 0, 1, @ptrCast(kept), 0, null);
            f.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&vertices), @ptrCast(first));
            f.CmdDraw(recording, 6, 1, 0, instance);
            f.CmdEndRenderPass(recording);
            return on.submit();
        }
    }.draw;

    // An ETC2 block decoded as it was copied in: red on the left of the
    // picture and blue on the right, each channel the +2 of table 0.
    if (!draw(probe, etc_view, of_eight, 0, layout.?, pass, onto, &sets, vertex_buffer, &offset, &clear, area)) return probe.check(false, "the ETC2 frame submitted");
    const quarter = side / 4;
    const left = pixelAt(pixels, pitch, quarter, quarter);
    const right = pixelAt(pixels, pitch, side - quarter, side - quarter);
    if (left == 0xFFFF_0202 and right == 0xFF02_02FF) probe.check(true, "an ETC2 block is unpacked as it is copied in, and sampled as 8888") else probe.checkEqual(0xFFFF_0202_FF02_02FF, @as(u64, left) << 32 | right, "an ETC2 block is unpacked as it is copied in, and sampled as 8888");

    // And each cube of the array, the fourth coordinate saying which: the
    // first face of the first cube, and of the second.
    if (arrays) {
        for ([3]struct { u32, u32 }{ .{ 0, 0 }, .{ 6, 6 }, .{ 12, 6 } }) |one| {
            const instance, const layer = one;
            if (!draw(probe, stack_view.?, of_cubes.?, instance, layout.?, pass, onto, &sets, vertex_buffer, &offset, &clear, area)) return probe.check(false, "the cube frame submitted");
            const middle = pixelAt(pixels, pitch, side / 2, side / 2);
            const name: [*:0]const u8 = if (instance == 0) "the first face of the first cube of the array" else if (instance == 6) "the first face of the second cube" else "a cube past the last reads as the last";
            if (middle == Shapes.faceColor(layer)) probe.check(true, name) else probe.checkEqual(Shapes.faceColor(layer), middle, name);
        }
    }
}

// --- 1.47: the samples an occlusion query counted --------------------------

/// What an occlusion query counts: the samples that passed the tests and
/// the fragment kept. A quad over the whole picture counts every pixel of
/// it, and one wholly behind it counts none.
fn samplesChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    var pool: ?*facet.QueryPool = null;
    const asked = fb.CreateQueryPool(device, &.{ .query_type = .occlusion, .query_count = 2 }, &pool);
    if (!probe.can.occlusion_queries) {
        return probe.check(asked != .success and pool == null, "an occlusion pool refused where the device counts no samples");
    }
    if (asked != .success or pool == null) return probe.check(false, "an occlusion pool of two queries");
    probe.check(true, "an occlusion pool of two queries");
    defer fb.DestroyQueryPool(device, pool);

    const pass = passKeeping(probe, .clear, .clear, .dont_care) orelse return probe.check(false, "a pass of a colour and a depth");
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Painted.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const draws = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &Painted.attributes, .stride = Painted.stride, .depth_tested = true }) orelse
        return probe.check(false, "a pipeline that tests its depth");

    const extent = facet.Extent3D{ .width = side, .height = side };
    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const depth = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT }, 0) orelse
        return probe.check(false, "a depth attachment");
    const frame = probe.framebuffer(pass, &.{ color[1], depth[1] }) orelse return probe.check(false, "a framebuffer over the two");

    // All of the picture in green at a half, then its left half in red
    // behind that: the first counts every pixel and the second none.
    const paint_green = [3]f32{ 0, 1, 0 };
    const paint_red = [3]f32{ 1, 0, 0 };
    const vertices = [_][6]f32{
        Painted.at(-1, -1, 0.5, paint_green), Painted.at(1, -1, 0.5, paint_green), Painted.at(-1, 1, 0.5, paint_green),
        Painted.at(-1, 1, 0.5, paint_green),  Painted.at(1, -1, 0.5, paint_green), Painted.at(1, 1, 0.5, paint_green),
        Painted.at(-1, -1, 0.75, paint_red),  Painted.at(0, -1, 0.75, paint_red),  Painted.at(-1, 1, 0.75, paint_red),
        Painted.at(-1, 1, 0.75, paint_red),   Painted.at(0, -1, 0.75, paint_red),  Painted.at(0, 1, 0.75, paint_red),
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };

    const commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdResetQueryPool(commands, pool.?, 0, 2);
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, draws);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdBeginQuery(commands, pool.?, 0, 0);
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndQuery(commands, pool.?, 0);
    fb.CmdBeginQuery(commands, pool.?, 1, 0);
    fb.CmdDraw(commands, 6, 1, 6, 0);
    fb.CmdEndQuery(commands, pool.?, 1);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the frame submitted");

    var counted: [2]u64 = @splat(0xDEAD);
    const read = fb.GetQueryPoolResults(device, pool.?, 0, 2, @sizeOf(@TypeOf(counted)), &counted, @sizeOf(u64), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT);
    probe.check(read == .success, "the two queries read");
    probe.checkEqual(side * side, counted[0], "every pixel of the picture counted");
    probe.checkEqual(0, counted[1], "and none at all for what was drawn behind it");
}

// --- 1.48: a texel kept smaller than its colour ------------------------------

/// A quad over a texture, and the three forms that read one: the 8888
/// texel kept in its word, the one byte of red, and the spread 8888 the
/// forms were always built for.
const Smalls = struct {
    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("word", &Shapes.flat, 2),
        facet.shader.fixedFragment("word", .{ .kind = .texture, .sampling = .{ .format = .argb8888, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("red", &Shapes.flat, 2),
        facet.shader.fixedFragment("red", .{ .kind = .texture, .sampling = .{ .format = .r8, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("spread", &Shapes.flat, 2),
        facet.shader.fixedFragment("spread", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    const left: u32 = 0xFF20_4080;
    const right: u32 = 0xFFC0_6010;
};

/// The smaller texels of 1.48: an image of one byte of red, and an 8888 one
/// kept in its word rather than spread over 64 bits.
fn smallChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const small = probe.can.small_texels;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    // Large enough that what each format asks for is above the page a
    // device with a layout of its own rounds an image up to.
    const across = 64;
    const extent = facet.Extent3D{ .width = across, .height = across };

    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r8_unorm, &properties);
    const reads = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
    probe.check(reads, "one byte of red is a format a texture may be of");
    probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT == 0, "and not one an image is drawn into");

    if (!small) {
        var refused: ?*facet.Image = null;
        const one_byte = facet.ImageCreateInfo{ .format = .r8_unorm, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &one_byte, &refused) != .success, "an image of one byte a texel refused where the device keeps no small texel");
        const in_word = facet.ImageCreateInfo{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .b8g8r8a8_unorm, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &in_word, &refused) != .success, "and the packed flag refused there too");
        return;
    }

    // Refused whatever the device: the flag on a format with no word of
    // 8888 to keep, and on an image nothing samples.
    var refused: ?*facet.Image = null;
    const packed565 = facet.ImageCreateInfo{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .r5g6b5_unorm_pack16, .extent = extent, .usage = sampled };
    probe.check(fb.CreateImage(device, &packed565, &refused) != .success, "the packed flag refused on a format with no 8888 word");
    const packed_rows = facet.ImageCreateInfo{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .b8g8r8a8_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    probe.check(fb.CreateImage(device, &packed_rows, &refused) != .success, "and on an image that is drawn into rather than sampled");

    const spread = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 64 by 64 spread over 64 bits a texel");
    const word = probe.image(.{ .flags = facet.IMAGE_CREATE_PACKED_TEXELS, .format = .b8g8r8a8_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "the same kept in its word");
    const red = probe.image(.{ .format = .r8_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "and one of a byte of red a texel");

    // What each asks for. A device with a layout of its own keeps an 8888
    // texel in its word already, so the flag changes nothing there; one
    // byte a texel is less than four on either.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, spread[0], &needs);
    const spread_bytes = needs.size;
    fb.GetImageMemoryRequirements(device, word[0], &needs);
    const word_bytes = needs.size;
    fb.GetImageMemoryRequirements(device, red[0], &needs);
    const red_bytes = needs.size;
    probe.check(word_bytes <= spread_bytes, "a texel in its word asks for no more memory than a spread one");
    probe.check(red_bytes < spread_bytes, "and a texel of one byte for less than either");

    const texels, const texel_bytes = probe.buffer(32768, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    const reds_at = across * across * 4;
    for (0..across * across) |k| {
        const color = if (k % across < across / 2) Smalls.left else Smalls.right;
        std.mem.writeInt(u32, texel_bytes[k * 4 ..][0..4], color, .little);
        texel_bytes[reds_at + k] = @truncate(color >> 16);
    }
    const back, const back_bytes = probe.buffer(32768, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer they are read back into");
    @memset(back_bytes[0 .. reds_at + across * across], 0);
    const whole = facet.BufferImageCopy{ .image_extent = extent };
    const whole_reds = facet.BufferImageCopy{ .buffer_offset = reds_at, .image_extent = extent };

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw them into");
    const shown_memory = probe.memories[slot].?;

    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, spread[0], .general, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, texels, word[0], .general, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, texels, red[0], .general, 1, @ptrCast(&whole_reds));
    fb.CmdCopyImageToBuffer(commands, red[0], .general, back, 1, @ptrCast(&whole_reds));
    if (!probe.submit()) return probe.check(false, "the copies into the textures submitted");
    var same = true;
    for (0..across * across) |k| if (texel_bytes[reds_at + k] != back_bytes[reds_at + k]) {
        same = false;
        break;
    };
    probe.check(same, "the bytes read back out of the one-byte texture are the ones copied in");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Smalls.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw them in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_word = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "word" }) orelse
        return probe.check(false, "a pipeline whose form samples a texel in its word");
    const of_red = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "red" }) orelse
        return probe.check(false, "a pipeline whose form samples one byte of red");
    const of_spread = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "spread" }) orelse
        return probe.check(false, "a pipeline whose form samples a spread texel");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    const only_red = struct {
        fn only_red(color: u32) u32 {
            return 0xFF00_0000 | (color & 0x00FF_0000);
        }
    }.only_red;

    for ([4]struct { *facet.Pipeline, *facet.ImageView, u32, u32, [*:0]const u8 }{
        .{ of_spread, spread[1], Smalls.left, Smalls.right, "a spread texel reads the colours copied in" },
        .{ of_word, word[1], Smalls.left, Smalls.right, "one kept in its word reads the same" },
        .{ of_red, red[1], only_red(Smalls.left), only_red(Smalls.right), "and one byte of red reads red alone, the green and the blue 0" },
        .{ of_spread, word[1], Smalls.left, Smalls.right, "a form built for the spread texel draws the packed one all the same" },
    }) |one| {
        const pipeline, const view, const want_left, const want_right, const name = one;
        const info = facet.DescriptorImageInfo{ .image_view = view };
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const drawn_left = pixelAt(pixels, pitch, quarter, quarter);
        const drawn_right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (drawn_left == want_left and drawn_right == want_right) probe.check(true, name) else probe.checkEqual(@as(u64, want_left) << 32 | want_right, @as(u64, drawn_left) << 32 | drawn_right, name);
    }
}

// --- 1.67: a sampler whose coordinates are the texture's own texels -------

/// A quad whose s and t are the texture's columns and rows, read through
/// the sampler bound beside it: what `unnormalized_coordinates` is for.
const ByTexel = struct {
    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("bytexel", &Shapes.flat, 2),
        facet.shader.fixedFragment("bytexel", .{ .kind = .texture_sampled }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// A sample placed in texels rather than 0 to 1 across the texture
/// (1.67): what CreateSampler asks of such a sampler, and the texel it
/// reads.
fn texelChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const across = 64;
    const extent = facet.Extent3D{ .width = across, .height = across };
    const in_texels = facet.SamplerCreateInfo{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .unnormalized_coordinates = true,
    };

    var by_texel: ?*facet.Sampler = null;
    const asked = fb.CreateSampler(device, &in_texels, &by_texel);
    if (!probe.can.unnormalized_coordinates) {
        probe.check(asked == .error_feature_not_present and by_texel == null, "a sampler in texels refused where the device reads none");
        return;
    }
    probe.check(asked == .success and by_texel != null, "a sampler whose coordinates are texels");
    if (asked != .success) return;
    defer fb.DestroySampler(device, by_texel);

    // What Vulkan allows beside it, and nothing else: one filter for
    // both, the first level alone, one sample, no comparison, and an edge
    // held or bordered.
    var refused: ?*facet.Sampler = null;
    var two_filters = in_texels;
    two_filters.min_filter = .linear;
    probe.check(fb.CreateSampler(device, &two_filters, &refused) == .error_initialization_failed, "two filters with it refused");
    var levelled = in_texels;
    levelled.max_lod = facet.texture.lod_unclamped;
    probe.check(fb.CreateSampler(device, &levelled, &refused) == .error_initialization_failed, "and a level past the first");
    var tapped = in_texels;
    tapped.anisotropy_enable = true;
    tapped.max_anisotropy = 4;
    probe.check(fb.CreateSampler(device, &tapped, &refused) == .error_initialization_failed, "and several samples along an axis");
    var tiled = in_texels;
    tiled.address_mode_u = .repeat;
    probe.check(fb.CreateSampler(device, &tiled, &refused) == .error_initialization_failed, "and an edge that is neither held nor bordered");
    probe.check(refused == null, "and nothing given back for any of them");

    // The texture of the small texels' two colours, its left half and its
    // right, and a picture to draw it into.
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
    const table = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 64 by 64 to read by texel");
    const texels, const texel_bytes = probe.buffer(across * across * 4, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer its texels come from");
    for (0..across * across) |k| {
        const color = if (k % across < across / 2) Smalls.left else Smalls.right;
        std.mem.writeInt(u32, texel_bytes[k * 4 ..][0..4], color, .little);
    }
    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw it into");
    const shown_memory = probe.memories[slot].?;
    const whole = facet.BufferImageCopy{ .image_extent = extent };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, table[0], .general, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the texels copied in");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &ByTexel.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a texture and a sampler");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw it in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const draws = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "bytexel" }) orelse
        return probe.check(false, "a pipeline whose form reads a texture through a sampler");

    // s and t are the texture's own texels, 0 to 64 over the quad.
    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, across, 0 },
        .{ -1, 1, 0.5, 0, across },
        .{ -1, 1, 0.5, 0, across },
        .{ 1, -1, 0.5, across, 0 },
        .{ 1, 1, 0.5, across, across },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    // The same quad through a sampler of 0 to 1: its coordinates are then
    // sixty-four times across the texture, held at the edge, so the whole
    // picture is the texture's last column - which is what says the other
    // read texels.
    var by_part: ?*facet.Sampler = null;
    var normalized = in_texels;
    normalized.unnormalized_coordinates = false;
    if (fb.CreateSampler(device, &normalized, &by_part) != .success) return probe.check(false, "a sampler of 0 to 1 to tell it from");
    defer fb.DestroySampler(device, by_part);

    const quarter = side / 4;
    for ([2]struct { ?*facet.Sampler, u32, u32, [*:0]const u8, [*:0]const u8 }{
        .{ by_texel, Smalls.left, Smalls.right, "the texel the coordinates name, on the texture's left half", "and on its right half" },
        .{ by_part, Smalls.right, Smalls.right, "the same coordinates as parts of the texture read its far edge", "there as well" },
    }) |one| {
        const with, const want_left, const want_right, const says_left, const says_right = one;
        const info = facet.DescriptorImageInfo{ .sampler = with, .image_view = table[1] };
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, draws);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        probe.checkEqual(want_left, pixelAt(pixels, pitch, quarter, quarter), says_left);
        probe.checkEqual(want_right, pixelAt(pixels, pitch, side - quarter, side - quarter), says_right);
    }
}

// --- 1.69: a texture whose channels are its own ----------------------------

/// A quad over a texture, and the three forms that read one of its own
/// channels: 16 bits a channel, two bytes of red and green, and the spread
/// 8888 every form was built for before.
const Wides = struct {
    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("wide", &Shapes.flat, 2),
        facet.shader.fixedFragment("wide", .{ .kind = .texture, .sampling = .{ .format = .rgba16, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("two", &Shapes.flat, 2),
        facet.shader.fixedFragment("two", .{ .kind = .texture, .sampling = .{ .format = .rg8, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("spread", &Shapes.flat, 2),
        facet.shader.fixedFragment("spread", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// The channels of 1.69: a texture of 16 bits a channel and one of two
/// bytes of red and green, copied in and out as they lie and sampled as
/// the colour of their top 8 bits.
fn wideChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const wide = probe.can.wide_channels;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const across = 8;
    const extent = facet.Extent3D{ .width = across, .height = across };

    // The format says what the device does with it: a texture and a
    // storage image where the channels are kept, nothing at all where
    // they are not. A texel buffer reads it on either, that being the
    // library's own doing (1.54).
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r16g16b16a16_unorm, &properties);
    const reads = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
    const written = properties.optimal_tiling_features & facet.FORMAT_FEATURE_STORAGE_IMAGE != 0;
    probe.check(reads == wide, if (wide) "16 bits a channel is a format a texture may be of" else "16 bits a channel is no texture here, the device keeping 8 bits a channel");
    probe.check(written == wide, "and one a function writes through where it is one at all");
    probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT == 0, "and never one an image is drawn into");
    probe.check(properties.buffer_features & facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER != 0, "a buffer reads it as texels whatever the device");

    // An image of such a format is for a function to read or to write:
    // one that is copied into and out of and nothing else is refused on
    // either device, and so is a colour attachment of it.
    var refused: ?*facet.Image = null;
    const copies = facet.ImageCreateInfo{ .format = .r16g16b16a16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC };
    probe.check(fb.CreateImage(device, &copies, &refused) != .success, "an image of them that nothing samples is refused");
    const drawn_into = facet.ImageCreateInfo{ .format = .r16g16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    probe.check(fb.CreateImage(device, &drawn_into, &refused) != .success, "and a colour attachment of them as well");

    if (!wide) {
        const texture = facet.ImageCreateInfo{ .format = .r16g16b16a16_unorm, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &texture, &refused) != .success, "a texture of 16 bits a channel refused where the device keeps 8");
        const two = facet.ImageCreateInfo{ .format = .r8g8_unorm, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &two, &refused) != .success, "and one of two bytes of red and green refused there too");
        return;
    }

    const wides = probe.image(.{ .format = .r16g16b16a16_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 8 by 8 of 16 bits a channel");
    const twos = probe.image(.{ .format = .r8g8_unorm, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "and one of two bytes of red and green");

    // Eight bytes a texel and two: the channels as they lie, not the
    // colour of 8 bits a channel a sample makes of them.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, wides[0], &needs);
    probe.check(needs.size >= across * across * 8, "its memory is its channels' own, eight bytes a texel");
    fb.GetImageMemoryRequirements(device, twos[0], &needs);
    probe.check(needs.size < across * across * 4, "and two bytes a texel asks for less than a colour would");

    const texels, const texel_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    const twos_at = across * across * 8;
    for (0..across * across) |k| {
        // Red on the left; on the right a blue of 0x8080, which is 128 in
        // its top 8 bits, and for the two bytes a green of 128.
        const left = k % across < across / 2;
        const channels: [4]u16 = if (left) .{ 0xFFFF, 0, 0, 0xFFFF } else .{ 0, 0, 0x8080, 0xFFFF };
        for (channels, 0..) |one, c| std.mem.writeInt(u16, texel_bytes[k * 8 + c * 2 ..][0..2], one, .little);
        texel_bytes[twos_at + k * 2] = if (left) 255 else 0;
        texel_bytes[twos_at + k * 2 + 1] = if (left) 0 else 128;
    }
    const back, const back_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer they are read back into");
    @memset(back_bytes[0 .. twos_at + across * across * 2], 0);
    const whole = facet.BufferImageCopy{ .image_extent = extent };
    const whole_twos = facet.BufferImageCopy{ .buffer_offset = twos_at, .image_extent = extent };

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw them into");
    const shown_memory = probe.memories[slot].?;

    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, wides[0], .general, 1, @ptrCast(&whole));
    fb.CmdCopyBufferToImage(commands, texels, twos[0], .general, 1, @ptrCast(&whole_twos));
    fb.CmdCopyImageToBuffer(commands, wides[0], .general, back, 1, @ptrCast(&whole));
    fb.CmdCopyImageToBuffer(commands, twos[0], .general, back, 1, @ptrCast(&whole_twos));
    if (!probe.submit()) return probe.check(false, "the copies into the textures submitted");
    var same = true;
    for (0..twos_at + across * across * 2) |k| if (texel_bytes[k] != back_bytes[k]) {
        same = false;
        break;
    };
    probe.check(same, "the channels read back are the ones copied in, nothing rounded to 8 bits on the way");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Wides.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw them in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_wide = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "wide" }) orelse
        return probe.check(false, "a pipeline whose form samples 16 bits a channel");
    const of_two = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "two" }) orelse
        return probe.check(false, "a pipeline whose form samples two bytes of red and green");
    const of_spread = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "spread" }) orelse
        return probe.check(false, "a pipeline whose form samples a spread 8888 texel");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    for ([4]struct { *facet.Pipeline, *facet.ImageView, u32, u32, [*:0]const u8 }{
        .{ of_wide, wides[1], 0xFFFF_0000, 0xFF00_0080, "16 bits a channel sample as the colour of their top 8 bits" },
        .{ of_spread, wides[1], 0xFFFF_0000, 0xFF00_0080, "and a form built for 8888 draws the same, through the run-time sampler" },
        .{ of_two, twos[1], 0xFFFF_0000, 0xFF00_8000, "two bytes read as red and green, the blue 0 and the alpha whole" },
        .{ of_spread, twos[1], 0xFFFF_0000, 0xFF00_8000, "and the run-time sampler reads them the same way" },
    }) |one| {
        const pipeline, const view, const want_left, const want_right, const name = one;
        const info = facet.DescriptorImageInfo{ .image_view = view };
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const drawn_left = pixelAt(pixels, pitch, quarter, quarter);
        const drawn_right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (drawn_left == want_left and drawn_right == want_right) probe.check(true, name) else probe.checkEqual(@as(u64, want_left) << 32 | want_right, @as(u64, drawn_left) << 32 | drawn_right, name);
    }
}

// --- 1.70: a texture of whole numbers --------------------------------------

/// A quad over a texture of whole numbers, and the spread 8888 form
/// beside it: the one reads the format directly, the other through the
/// run-time sampler.
const Numbers = struct {
    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("whole", &Shapes.flat, 2),
        facet.shader.fixedFragment("whole", .{ .kind = .texture, .sampling = .{ .format = .rgba8u, .filter = .nearest, .address = .clamp } }),
        facet.shader.vertex("spread", &Shapes.flat, 2),
        facet.shader.fixedFragment("spread", .{ .kind = .texture, .sampling = .{ .format = .rgba8888, .filter = .nearest, .address = .clamp } }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// The whole numbers of 1.70 as a texture: copied in and out as they lie,
/// and sampled as the colour each number holds to.
fn wholeChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const wholes = probe.can.whole_textures;
    const sampled = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC;
    const across = 8;
    const extent = facet.Extent3D{ .width = across, .height = across };

    // What the device does with the format, and what no device does with
    // it: no linear filter, there being nothing to mix between two whole
    // numbers, and no attachment, nothing blending one.
    var properties: facet.FormatProperties = undefined;
    fb.GetPhysicalDeviceFormatProperties(probe.physical, .r8g8b8a8_uint, &properties);
    const reads = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
    probe.check(reads == wholes, if (wholes) "whole numbers are a format a texture may be of" else "whole numbers are no texture here, the device keeping a colour of 8 bits a channel");
    probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR == 0, "and never one a sample filters linearly");
    probe.check(properties.optimal_tiling_features & facet.FORMAT_FEATURE_COLOR_ATTACHMENT == 0, "nor one an image is drawn into");
    probe.check(properties.buffer_features & facet.FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER != 0, "a buffer reads them as texels whatever the device");

    // An image of whole numbers is for a function to read or to write, as
    // a wide channel is: one that is copied into and out of and nothing
    // else is refused on either device, and so is a colour attachment.
    var refused: ?*facet.Image = null;
    const copies = facet.ImageCreateInfo{ .format = .r8g8b8a8_uint, .extent = extent, .usage = facet.IMAGE_USAGE_TRANSFER_DST | facet.IMAGE_USAGE_TRANSFER_SRC };
    probe.check(fb.CreateImage(device, &copies, &refused) != .success, "an image of them that nothing samples is refused");
    const drawn_into = facet.ImageCreateInfo{ .format = .r32_uint, .extent = extent, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT };
    probe.check(fb.CreateImage(device, &drawn_into, &refused) != .success, "and a colour attachment of them as well");

    if (!wholes) {
        const texture_info = facet.ImageCreateInfo{ .format = .r8g8b8a8_uint, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &texture_info, &refused) != .success, "a texture of whole numbers refused where the device keeps a colour");
        const signed = facet.ImageCreateInfo{ .format = .r16g16b16a16_sint, .extent = extent, .usage = sampled };
        probe.check(fb.CreateImage(device, &signed, &refused) != .success, "and a signed one refused there too");
        return;
    }

    const numbers = probe.image(.{ .format = .r8g8b8a8_uint, .extent = extent, .usage = sampled }, 0) orelse
        return probe.check(false, "a texture of 8 by 8 of four bytes of whole number");

    // Four bytes a texel, as they lie: not the eight an unpacked 8888
    // colour is kept spread in.
    var needs: facet.MemoryRequirements = undefined;
    fb.GetImageMemoryRequirements(device, numbers[0], &needs);
    probe.check(needs.size >= across * across * 4 and needs.size < across * across * 8, "its memory is its numbers' own, four bytes a texel");

    const texels, const texel_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the texels come from");
    for (0..across * across) |k| {
        // Red at 255 on the left; on the right a blue of 128, which is a
        // blue at the full as a whole number, not half a blue.
        const left = k % across < across / 2;
        const four: [4]u8 = if (left) .{ 255, 0, 0, 255 } else .{ 0, 0, 128, 255 };
        @memcpy(texel_bytes[k * 4 ..][0..4], &four);
    }
    const back, const back_bytes = probe.buffer(1024, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer they are read back into");
    @memset(back_bytes[0 .. across * across * 4], 0);
    const whole = facet.BufferImageCopy{ .image_extent = extent };

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw them into");
    const shown_memory = probe.memories[slot].?;

    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, numbers[0], .general, 1, @ptrCast(&whole));
    fb.CmdCopyImageToBuffer(commands, numbers[0], .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy into the texture submitted");
    var same = true;
    for (0..across * across * 4) |k| if (texel_bytes[k] != back_bytes[k]) {
        same = false;
        break;
    };
    probe.check(same, "the numbers read back are the ones copied in, nothing scaled on the way");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Numbers.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout) != .success) return probe.check(false, "a set layout of a sampled image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success) return probe.check(false, "a descriptor set");

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw them in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = 12 },
    };
    const of_whole = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "whole" }) orelse
        return probe.check(false, "a pipeline whose form samples whole numbers");
    const of_spread = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &attributes, .stride = 20, .name = "spread" }) orelse
        return probe.check(false, "a pipeline whose form samples a spread 8888 texel");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][5]f32{
        .{ -1, -1, 0.5, 0, 0 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ -1, 1, 0.5, 0, 1 },
        .{ 1, -1, 0.5, 1, 0 },
        .{ 1, 1, 0.5, 1, 1 },
    };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    for ([2]struct { *facet.Pipeline, [*:0]const u8 }{
        .{ of_whole, "a number above 0 samples as its channel at the full: red on the left, blue on the right" },
        .{ of_spread, "and a form built for 8888 reads them the same, through the run-time sampler" },
    }) |one| {
        const pipeline, const name = one;
        const info = facet.DescriptorImageInfo{ .image_view = numbers[1] };
        const write = facet.WriteDescriptorSet{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, layout.?, 0, 1, @ptrCast(&sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        const quarter = side / 4;
        const drawn_left = pixelAt(pixels, pitch, quarter, quarter);
        const drawn_right = pixelAt(pixels, pitch, side - quarter, side - quarter);
        if (drawn_left == 0xFFFF_0000 and drawn_right == 0xFF00_00FF) probe.check(true, name) else probe.checkEqual(0xFFFF_0000_FF00_00FF, @as(u64, drawn_left) << 32 | drawn_right, name);
    }
}

// --- 1.70: a point as wide as its vertex says ------------------------------

/// Points of a size each vertex carries, drawn in the colour the vertices
/// carry: a fixed form of `shader.FixedKind.color`, so that every device
/// draws them.
const Points = struct {
    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        const full = facet.shader.channel(1);
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const size = vertices.input(@intCast(k), 1);
            vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], 0.5, 1, full, 0, 0, full };
            vertices.setPointSize(@intCast(k), size[0]);
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 4),
        facet.shader.fixedFragment("main", .{ .kind = .color }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    const attributes = [2]facet.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat },
        .{ .location = 1, .binding = 0, .format = .r32_sfloat, .offset = 12 },
    };
    const stride: u32 = 16;

    /// A vertex at the middle of pixel (x, y) of a `side` by `side`
    /// picture, asking for a point `size` pixels across and down.
    fn at(x: f32, y: f32, size: f32) [4]f32 {
        const half: f32 = side / 2;
        return .{ (x + 0.5) / half - 1, (y + 0.5) / half - 1, 0.5, size };
    }
};

/// The point sizes of 1.70: what the limits say, and the pixels a point of
/// each size covers.
fn pointChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    // The range the device gives: one pixel at the narrow end and wider
    // than one at the other, which is what Vulkan's `largePoints` says,
    // and every size between them drawn as it is.
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    const range = properties.limits.point_size_range;
    probe.check(range[0] == 1, "the narrowest point is one pixel");
    probe.check(range[1] > 1, "and the widest is wider than one, as largePoints says");
    probe.check(properties.limits.point_size_granularity == 0, "every size between them is drawn as it is");

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw the points into");
    const shown_memory = probe.memories[slot].?;

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Points.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw them in");
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");
    const draws = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &Points.attributes, .stride = Points.stride, .topology = .point_list }) orelse
        return probe.check(false, "a pipeline that draws points");

    // One pixel, eight pixels, no size at all, and far more than the
    // range holds.
    const vertices = [4][4]f32{
        Points.at(16, 16, 1),
        Points.at(48, 16, 8),
        Points.at(16, 48, 0),
        Points.at(48, 48, 1000),
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(vertices)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");
    const red: u32 = 0xFFFF_0000;
    const blue: u32 = 0xFF00_00FF;

    const Case = struct {
        first: u32,
        /// The pixel the point is at, pixels inside it and pixels past it.
        at: [2]u32,
        inside: []const [2]u32,
        outside: []const [2]u32,
        says: [*:0]const u8,
    };
    for ([4]Case{
        .{
            .first = 0,
            .at = .{ 16, 16 },
            .inside = &.{},
            .outside = &.{ .{ 15, 16 }, .{ 17, 16 }, .{ 16, 15 }, .{ 16, 17 } },
            .says = "a point of one pixel covers the one pixel, as every point did before 1.70",
        },
        .{
            .first = 1,
            .at = .{ 48, 16 },
            .inside = &.{ .{ 46, 16 }, .{ 50, 16 }, .{ 48, 14 }, .{ 48, 18 }, .{ 46, 14 } },
            .outside = &.{ .{ 42, 16 }, .{ 54, 16 }, .{ 48, 10 }, .{ 48, 22 } },
            .says = "a point of eight covers eight pixels across and down, about its vertex",
        },
        .{
            .first = 2,
            .at = .{ 16, 48 },
            .inside = &.{},
            .outside = &.{ .{ 15, 48 }, .{ 17, 48 }, .{ 16, 47 }, .{ 16, 49 } },
            .says = "a size of 0 comes to the one pixel, nothing dropped and nothing widened",
        },
        .{
            .first = 3,
            .at = .{ 48, 48 },
            .inside = &.{ .{ 2, 2 }, .{ side - 2, side - 2 } },
            .outside = &.{},
            .says = "and a size far above the range is held to the range's end",
        },
    }) |case| {
        const commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, draws);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 1, 1, case.first, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        var right = pixelAt(pixels, pitch, case.at[0], case.at[1]) == red;
        for (case.inside) |one| if (pixelAt(pixels, pitch, one[0], one[1]) != red) {
            right = false;
        };
        for (case.outside) |one| if (pixelAt(pixels, pitch, one[0], one[1]) != blue) {
            right = false;
        };
        probe.check(right, case.says);
    }

    // All four at once, each its own size: the one-pixel point stays one
    // pixel beside the eight-pixel one.
    const commands = probe.record() orelse return probe.check(false, "a recording of the last draw");
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, draws);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdDraw(commands, 3, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    if (!probe.submit()) return probe.check(false, "the frame of three points submitted");
    var apart = pixelAt(pixels, pitch, 16, 16) == red and pixelAt(pixels, pitch, 15, 16) == blue;
    if (pixelAt(pixels, pitch, 48, 18) != red) apart = false;
    if (pixelAt(pixels, pitch, 16, 48) != red or pixelAt(pixels, pitch, 17, 48) != blue) apart = false;
    probe.check(apart, "three points of three sizes in the one draw, each the size its own vertex asked for");
}

// --- 1.49: the shapes read through a sampler, and a sampler a layout holds -

/// A quad over a texture of layers read through the sampler bound beside
/// it: an array, a cube and a 3D texture, and a plain 2D one whose
/// coordinates run outside the texture, where the sampler's edges show.
const Held = struct {
    fn arrayed(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) / 2, (p[1] + 1) / 2, @floatFromInt(vertices.instance) };
        }
    }

    fn cubed(vertices: *const facet.shader.Vertices) callconv(.c) void {
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
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, towards[0], towards[1], towards[2] };
        }
    }

    /// A cube of an array: the instance is the face, and every sixth of
    /// it the cube - a fourth coordinate (since 1.53).
    fn cubedArray(vertices: *const facet.shader.Vertices) callconv(.c) void {
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
            vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], 1, towards[0], towards[1], towards[2], @floatFromInt(vertices.instance / 6) };
        }
    }

    fn sliced(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            const r = (@as(f32, @floatFromInt(vertices.instance)) + 0.5) / 4;
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) / 2, (p[1] + 1) / 2, r };
        }
    }

    /// Coordinates a quarter of the texture outside it either way.
    fn wide(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], 1, (p[0] + 1) / 2 * 1.5 - 0.25, (p[1] + 1) / 2 * 1.5 - 0.25 };
        }
    }

    /// The one direction every vertex looks: the seam between +x and +z,
    /// where face 0's u is 0 and a bilinear tap falls half on face 4
    /// (since 1.60).
    fn seamed(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], 1, 1, 0, 1 };
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("arrayby", &arrayed, 3),
        facet.shader.fixedFragment("arrayby", .{ .kind = .texture_array_sampled }),
        facet.shader.vertex("cubeby", &cubed, 3),
        facet.shader.fixedFragment("cubeby", .{ .kind = .texture_cube_sampled }),
        facet.shader.vertex("seamed", &seamed, 3),
        facet.shader.fixedFragment("seamed", .{ .kind = .texture_cube_sampled }),
        facet.shader.vertex("volumeby", &sliced, 3),
        facet.shader.fixedFragment("volumeby", .{ .kind = .texture_3d_sampled }),
        facet.shader.vertex("cubesby", &cubedArray, 4),
        facet.shader.fixedFragment("cubesby", .{ .kind = .texture_cube_array_sampled }),
        facet.shader.vertex("wideby", &wide, 2),
        facet.shader.fixedFragment("wideby", .{ .kind = .texture_sampled }),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// A layer's colour, each its own: forty apart in red.
    fn layerColor(layer: u32) u32 {
        return 0xFF00_0000 | (10 + 40 * layer) << 16;
    }
};

/// The sampler forms past 2D of 1.49, the array of cubes of 1.53, and a
/// sampler the set layout holds.
fn heldChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const across = 16;
    const layer_bytes = across * across * 4;

    // A sampler the set layout holds is the library's doing, so every
    // device takes one; the forms that read a sampler are the cores'.
    var kept: ?*facet.Sampler = null;
    if (fb.CreateSampler(device, &.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .border_color = .float_opaque_white,
    }, &kept) != .success) return probe.check(false, "a sampler with a white border");
    defer fb.DestroySampler(device, kept);
    var tiled: ?*facet.Sampler = null;
    if (fb.CreateSampler(device, &.{ .mag_filter = .nearest, .min_filter = .nearest }, &tiled) != .success)
        return probe.check(false, "a sampler that tiles");
    defer fb.DestroySampler(device, tiled);
    // All five of Vulkan's address modes, since 1.49.
    var mirrored: ?*facet.Sampler = null;
    const asked = fb.CreateSampler(device, &.{ .address_mode_u = .mirror_clamp_to_edge }, &mirrored);
    probe.check(asked == .success and mirrored != null, "a sampler that mirrors once and then holds at the edge");
    if (asked == .success) fb.DestroySampler(device, mirrored);
    var unknown: ?*facet.Sampler = null;
    probe.check(fb.CreateSampler(device, &.{ .address_mode_u = @enumFromInt(9) }, &unknown) != .success, "an address mode that is none of the five refused");

    var held_layout: ?*facet.DescriptorSetLayout = null;
    const held_binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT, .immutable_samplers = @ptrCast(&kept) };
    const made_layout = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&held_binding) }, &held_layout);
    probe.check(made_layout == .success and held_layout != null, "a set layout that holds a sampler of its own");
    if (made_layout != .success or held_layout == null) return;
    defer fb.DestroyDescriptorSetLayout(device, held_layout);
    var written_layout: ?*facet.DescriptorSetLayout = null;
    const written_binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&written_binding) }, &written_layout) != .success)
        return probe.check(false, "a set layout whose sampler is written");
    defer fb.DestroyDescriptorSetLayout(device, written_layout);

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Held.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var held_pipes: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&held_layout) }, &held_pipes) != .success) return probe.check(false, "a pipeline layout over it");
    _ = Probe.keep(&probe.layouts, held_pipes);
    var written_pipes: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&written_layout) }, &written_pipes) != .success) return probe.check(false, "and one over the other");
    _ = Probe.keep(&probe.layouts, written_pipes);

    const pass = probe.renderPass(.{
        .attachment_count = 1,
        .attachments = @ptrCast(&facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal }),
        .subpass_count = 1,
        .subpasses = @ptrCast(&facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal }) }),
    }) orelse return probe.check(false, "a pass to draw in");
    const attributes = [1]facet.VertexInputAttributeDescription{.{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat }};

    // Where the device runs no form that reads a sampler, every one of
    // them is refused there and the program draws on the cores instead.
    if (!probe.can.samplers) {
        var refused = false;
        for ([4][*:0]const u8{ "arrayby", "cubeby", "volumeby", "cubesby" }) |name| {
            if (pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = name }) == null) refused = true else refused = false;
            if (!refused) break;
        }
        return probe.check(refused, "a form past 2D that reads a sampler is refused where the device reads none");
    }

    // Bound without a view of their own: a plain 2D one is not what
    // either of these is read as.
    const cube_image = probe.bound(.{ .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .format = .b8g8r8a8_unorm, .extent = .{ .width = across, .height = across }, .array_layers = 6, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, 0) orelse
        return probe.check(false, "an image of six layers");
    const volume_image = probe.bound(.{ .format = .b8g8r8a8_unorm, .image_type = .@"3d", .extent = .{ .width = across, .height = across, .depth = 4 }, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, 0) orelse
        return probe.check(false, "a 3D image of four slices");
    const cubes_image = probe.bound(.{ .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .format = .b8g8r8a8_unorm, .extent = .{ .width = across, .height = across }, .array_layers = 12, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, 0) orelse
        return probe.check(false, "an image of two cubes");
    const array_view = probe.viewed(.{ .image = cube_image, .format = .b8g8r8a8_unorm, .view_type = .@"2d_array", .subresource_range = .{ .layer_count = 6 } }) orelse
        return probe.check(false, "a view of it as an array");
    const cube_view = probe.viewed(.{ .image = cube_image, .format = .b8g8r8a8_unorm, .view_type = .cube, .subresource_range = .{ .layer_count = 6 } }) orelse
        return probe.check(false, "and one as a cube");
    const volume_view = probe.viewed(.{ .image = volume_image, .format = .b8g8r8a8_unorm, .view_type = .@"3d" }) orelse
        return probe.check(false, "a view of the 3D image");
    const cubes_view = probe.viewed(.{ .image = cubes_image, .format = .b8g8r8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .layer_count = 12 } }) orelse
        return probe.check(false, "a view of the two cubes as an array of them");
    const second_view = probe.viewed(.{ .image = cubes_image, .format = .b8g8r8a8_unorm, .view_type = .cube_array, .subresource_range = .{ .base_array_layer = 6, .layer_count = 6 } }) orelse
        return probe.check(false, "and one that begins at the second cube");

    const texels, const texel_bytes = probe.buffer(layer_bytes * 6, facet.BUFFER_USAGE_TRANSFER_SRC) orelse
        return probe.check(false, "a buffer the layers come from");
    for (0..6) |layer| {
        const color = Held.layerColor(@intCast(layer));
        for (0..across * across) |k| std.mem.writeInt(u32, texel_bytes[layer * layer_bytes + k * 4 ..][0..4], color, .little);
    }
    var faces: [6]facet.BufferImageCopy = undefined;
    for (&faces, 0..) |*face, k| face.* = .{ .buffer_offset = k * layer_bytes, .image_subresource = .{ .base_array_layer = @intCast(k) }, .image_extent = .{ .width = across, .height = across } };
    const slices = facet.BufferImageCopy{ .image_extent = .{ .width = across, .height = across, .depth = 4 } };
    // The second cube takes the first's layers backwards, so that its
    // faces are told apart from them.
    var cubes: [12]facet.BufferImageCopy = undefined;
    for (&cubes, 0..) |*face, k| face.* = .{
        .buffer_offset = (if (k < 6) k else 11 - k) * layer_bytes,
        .image_subresource = .{ .base_array_layer = @intCast(k) },
        .image_extent = .{ .width = across, .height = across },
    };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, cube_image, .general, 6, &faces);
    fb.CmdCopyBufferToImage(commands, texels, volume_image, .general, 1, @ptrCast(&slices));
    fb.CmdCopyBufferToImage(commands, texels, cubes_image, .general, 12, &cubes);
    if (!probe.submit()) return probe.check(false, "the copies into them submitted");

    var slot: usize = 0;
    for (probe.memories, 0..) |each, k| if (each == null) {
        slot = k;
        break;
    };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw into");
    const shown_memory = probe.memories[slot].?;
    const onto = probe.framebuffer(pass, &.{shown[1]}) orelse return probe.check(false, "a framebuffer for it");

    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 2 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var written_set: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&written_layout) }, &written_set) != .success)
        return probe.check(false, "a set whose sampler is written");
    var held_set: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&held_layout) }, &held_set) != .success)
        return probe.check(false, "and one of the layout that holds its own");

    const vertex_buffer, const vertex_bytes = probe.buffer(256, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    const quad = [6][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ -1, 1, 0.5 }, .{ -1, 1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 } };
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    // One pipeline for each form, made once: the probe keeps only so many.
    const of_array = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "arrayby" }) orelse
        return probe.check(false, "a pipeline whose form reads an array through a sampler");
    const of_cube = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "cubeby" }) orelse
        return probe.check(false, "one whose form reads a cube through a sampler");
    const of_volume = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "volumeby" }) orelse
        return probe.check(false, "one whose form reads a 3D texture through a sampler");
    const of_cubes = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "cubesby" }) orelse
        return probe.check(false, "one whose form reads a cube of an array through a sampler");
    const of_wide = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "wideby" }) orelse
        return probe.check(false, "one that reads past the texture's edges");
    const of_held = pipelineOf(probe, pass, module.?, held_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "wideby" }) orelse
        return probe.check(false, "and the same over the layout that holds a sampler");

    const Case = struct {
        pipeline: *facet.Pipeline,
        view: *facet.ImageView,
        instance: u32,
        sets: *[1]?*facet.DescriptorSet,
        layout: *facet.PipelineLayout,
        want: u32,
        at: u32,
        says: [*:0]const u8,
    };
    const middle = side / 2;
    const corner = side / 16;
    for ([_]Case{
        .{ .pipeline = of_array, .view = array_view, .instance = 0, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(0), .at = middle, .says = "a layer of an array read through a sampler" },
        .{ .pipeline = of_array, .view = array_view, .instance = 4, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(4), .at = middle, .says = "and another layer of it" },
        .{ .pipeline = of_array, .view = array_view, .instance = 9, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(5), .at = middle, .says = "a layer past the last reads as the last" },
        .{ .pipeline = of_cube, .view = cube_view, .instance = 0, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(0), .at = middle, .says = "a face of a cube read through a sampler" },
        .{ .pipeline = of_cube, .view = cube_view, .instance = 3, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(3), .at = middle, .says = "and another face of it" },
        .{ .pipeline = of_volume, .view = volume_view, .instance = 0, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(0), .at = middle, .says = "a slice of a 3D texture read through a sampler" },
        .{ .pipeline = of_volume, .view = volume_view, .instance = 3, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(3), .at = middle, .says = "and another slice of it" },
        // An array of cubes through a sampler (since 1.53): the second
        // cube's faces carry the first cube's layers backwards.
        .{ .pipeline = of_cubes, .view = cubes_view, .instance = 0, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(0), .at = middle, .says = "a face of a cube of an array read through a sampler" },
        .{ .pipeline = of_cubes, .view = cubes_view, .instance = 4, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(4), .at = middle, .says = "and another face of that cube" },
        .{ .pipeline = of_cubes, .view = cubes_view, .instance = 6, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(5), .at = middle, .says = "the first face of the second cube" },
        .{ .pipeline = of_cubes, .view = cubes_view, .instance = 9, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(2), .at = middle, .says = "and another face of that one" },
        .{ .pipeline = of_cubes, .view = cubes_view, .instance = 12, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(5), .at = middle, .says = "a cube past the last reads as the last" },
        .{ .pipeline = of_cubes, .view = second_view, .instance = 1, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(4), .at = middle, .says = "a view that begins at the second cube reads it as cube 0" },
        // Past the edges, with the tiling sampler written into the set:
        // the texture again.
        .{ .pipeline = of_wide, .view = cube_view, .instance = 0, .sets = &written_set, .layout = written_pipes.?, .want = Held.layerColor(0), .at = corner, .says = "the written sampler tiles past the texture's edge" },
        // The same draw through the layout that holds the bordered
        // sampler: the layout's wins, so the border is read there.
        .{ .pipeline = of_held, .view = cube_view, .instance = 0, .sets = &held_set, .layout = held_pipes.?, .want = 0xFFFF_FFFF, .at = corner, .says = "the layout's own sampler is read instead of the one written" },
    }) |case| {
        const info = facet.DescriptorImageInfo{ .sampler = tiled, .image_view = case.view };
        const write = facet.WriteDescriptorSet{ .dst_set = case.sets[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, case.pipeline);
        fb.CmdBindDescriptorSets(commands, .graphics, case.layout, 0, 1, @ptrCast(case.sets), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, case.instance);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        probe.checkEqual(case.want, pixelAt(pixels, pitch, case.at, case.at), case.says);
    }

    // --- 1.59: a 3D texture of levels read through a sampler ---
    // A level has half the slices of the one before it, so the
    // coordinate through the texture falls on that level's own slices.
    // Before 1.59 it fell on the whole depth's, whatever the level.
    const deep = probe.bound(.{
        .format = .b8g8r8a8_unorm,
        .image_type = .@"3d",
        .extent = .{ .width = across, .height = across, .depth = 4 },
        .mip_levels = 2,
        .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
    }, 0);
    probe.check(deep != null, "a 3D image of four slices and two levels");
    const deep_view = if (deep) |image| probe.viewed(.{ .image = image, .format = .b8g8r8a8_unorm, .view_type = .@"3d" }) else null;
    var deeper: ?*facet.Sampler = null;
    const asked_deeper = fb.CreateSampler(device, &.{ .mag_filter = .nearest, .min_filter = .nearest, .min_lod = 1, .max_lod = 1 }, &deeper);
    probe.check(deep_view != null and asked_deeper == .success, "a view of it, and a sampler held to its second level");
    defer fb.DestroySampler(device, deeper);
    if (deep) |image| if (deep_view) |view| if (asked_deeper == .success) {
        // Level 0 takes the first four layer colours, a slice each;
        // level 1 the next two, 8 x 8 of the one colour being all a
        // slice of it holds.
        var levels: [6]facet.BufferImageCopy = undefined;
        for (0..4) |slice| levels[slice] = .{
            .buffer_offset = slice * layer_bytes,
            .image_offset = .{ .z = @intCast(slice) },
            .image_extent = .{ .width = across, .height = across, .depth = 1 },
        };
        for (0..2) |slice| levels[4 + slice] = .{
            .buffer_offset = (4 + slice) * layer_bytes,
            .image_subresource = .{ .mip_level = 1 },
            .image_offset = .{ .z = @intCast(slice) },
            .image_extent = .{ .width = across / 2, .height = across / 2, .depth = 1 },
        };
        commands = probe.record() orelse return probe.check(false, "a recording of its levels copied in");
        fb.CmdCopyBufferToImage(commands, texels, image, .general, levels.len, &levels);
        if (!probe.submit()) return probe.check(false, "its levels copied in");

        // The form's r is (instance + 0.5) / 4, so the four draws read an
        // eighth, three eighths, five eighths and seven eighths of the
        // way through. At level 1, whose slices are two, the first half
        // is its first slice and the second half its second.
        const info = facet.DescriptorImageInfo{ .sampler = deeper, .image_view = view };
        const write = facet.WriteDescriptorSet{ .dst_set = written_set[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        for ([4]u32{ 0, 1, 2, 3 }, [4]u32{ 4, 4, 5, 5 }, [4][*:0]const u8{
            "the second level's first slice, an eighth of the way through",
            "its first slice again, three eighths through",
            "its second slice, five eighths through",
            "and its second slice again, seven eighths through",
        }) |instance, layer, says| {
            commands = probe.record() orelse return probe.check(false, "a recording of the level's draw");
            fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
            fb.CmdBindPipeline(commands, .graphics, of_volume);
            fb.CmdBindDescriptorSets(commands, .graphics, written_pipes.?, 0, 1, @ptrCast(&written_set), 0, null);
            fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
            fb.CmdDraw(commands, 6, 1, 0, instance);
            fb.CmdEndRenderPass(commands);
            if (!probe.submit()) return probe.check(false, "the level's frame submitted");
            probe.checkEqual(Held.layerColor(layer), pixelAt(pixels, pitch, middle, middle), says);
        }
    };

    // --- 1.60: a cube read through a sampler reads over its seams ---
    // Every pixel looks the one way, at the seam between +x and +z: the
    // taps fall half on each face, so the red is halfway between theirs.
    // Before 1.60 the taps were held inside face 0 and read its own.
    var smooth: ?*facet.Sampler = null;
    const asked_smooth = fb.CreateSampler(device, &.{ .mag_filter = .linear, .min_filter = .linear }, &smooth);
    defer fb.DestroySampler(device, smooth);
    const of_seam = pipelineOf(probe, pass, module.?, written_pipes.?, .{ .attributes = &attributes, .stride = 12, .name = "seamed" });
    probe.check(asked_smooth == .success and of_seam != null, "a sampler that filters, and a form that looks at a seam");
    if (asked_smooth == .success) if (of_seam) |drawn| {
        const info = facet.DescriptorImageInfo{ .sampler = smooth, .image_view = cube_view };
        const write = facet.WriteDescriptorSet{ .dst_set = written_set[0].?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .image_info = @ptrCast(&info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        commands = probe.record() orelse return probe.check(false, "a recording of the seam's draw");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = onto, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, drawn);
        fb.CmdBindDescriptorSets(commands, .graphics, written_pipes.?, 0, 1, @ptrCast(&written_set), 0, null);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the seam's frame submitted");
        const read = pixelAt(pixels, pitch, middle, middle) >> 16 & 0xFF;
        const low = Held.layerColor(0) >> 16 & 0xFF;
        const high = Held.layerColor(4) >> 16 & 0xFF;
        const halfway = (low + high) / 2;
        if (read + 4 >= halfway and read <= halfway + 4) {
            probe.check(true, "a bilinear sample on a cube's seam mixes the face beside it");
        } else {
            probe.checkEqual(halfway, read, "a bilinear sample on a cube's seam mixes the face beside it");
        }
    };
}

// --- 1.50: the fraction of a level, and the floats a patch carries ----------

/// A patch cut into pieces. The control function works out the colour once
/// for the whole patch and carries it to the evaluation function
/// (`shader.Patch.ownValues`), which is all the colour the picture ever
/// gets; each evaluation entry spends the fraction of a level its own way
/// (`shader.Spacing`). Tessellation runs on the cores whichever device the
/// pipeline was made on, so these functions run on both.
const Cut = struct {
    /// The smallest coordinate above 0 the evaluation function was given:
    /// where the first cut of an edge fell.
    var smallest: f32 = 1;
    /// What came back through the patch's own floats, red first.
    var carried: [4]f32 = @splat(-1);
    /// How many floats the evaluation function found the patch carrying.
    var carried_count: u32 = 0;

    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    /// Every edge cut three and a half pieces' worth: the half piece is
    /// what a spacing has to do something with.
    fn control(patch: *const facet.shader.Patch, levels: *facet.shader.Levels) callconv(.c) void {
        levels.outer = .{ 3.5, 3.5, 3.5, 3.5 };
        levels.inner = .{ 3.5, 3.5 };
        const own = patch.ownValues();
        const full = facet.shader.channel(1);
        if (own.len >= 4) own[0..4].* = .{ full, 0, 0, full };
    }

    fn evaluate(evaluations: *const facet.shader.Evaluations) callconv(.c) void {
        const own = evaluations.patch.ownValues();
        carried_count = @intCast(own.len);
        if (own.len >= 4) carried = own[0..4].*;
        const a = evaluations.patch.point(0);
        const b = evaluations.patch.point(1);
        const c = evaluations.patch.point(2);
        const d = evaluations.patch.point(3);
        for (0..evaluations.count) |k| {
            const u = evaluations.coordinates[k][0];
            const v = evaluations.coordinates[k][1];
            if (u > 0 and u < smallest) smallest = u;
            const out = evaluations.output(@intCast(k));
            for (0..3) |axis| out[axis] = (a[axis] * (1 - u) + b[axis] * u) * (1 - v) + (d[axis] * (1 - u) + c[axis] * u) * v;
            out[3] = 1;
            // The colour the control function worked out, and nothing
            // else: a patch that carried none draws black.
            out[4..8].* = if (own.len >= 4) own[0..4].* else @splat(0);
        }
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("main", &vertex, 0),
        facet.shader.fixedFragment("main", .{ .kind = .color }),
        facet.shader.control("main", &control, 4),
        // More floats for the patch than any device of this library holds.
        facet.shader.control("hoard", &control, 17),
        facet.shader.evaluation("equally", &evaluate, 4, .{ .domain = .quads }),
        facet.shader.evaluation("evenly", &evaluate, 4, .{ .domain = .quads, .spacing = .fractional_even }),
        facet.shader.evaluation("oddly", &evaluate, 4, .{ .domain = .quads, .spacing = .fractional_odd }),
        // A spacing of a value the library has not: bits 11 and 12 both set.
        .{ .name = "nohow", .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION, .function = &evaluate, .varyings = 4 | 1 << 8 | 3 << 11 },
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };

    /// The whole picture as one patch of four corners.
    const corners = [4][3]f32{ .{ -1, -1, 0.5 }, .{ 1, -1, 0.5 }, .{ 1, 1, 0.5 }, .{ -1, 1, 0.5 } };
};

/// A pipeline of `Cut` over `pass`, of the control and evaluation entries
/// named; null where the call refused it.
fn cutPipeline(probe: *Probe, pass: *facet.RenderPass, module: *facet.ShaderModule, layout: *facet.PipelineLayout, control: [*:0]const u8, evaluation: [*:0]const u8) ?*facet.Pipeline {
    const stages = [4]facet.PipelineShaderStageCreateInfo{
        .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module },
        .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module },
        .{ .stage = facet.SHADER_STAGE_TESSELLATION_CONTROL, .module = module, .name = control },
        .{ .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION, .module = module, .name = evaluation },
    };
    const binding = facet.VertexInputBindingDescription{ .binding = 0, .stride = 12 };
    const attribute = facet.VertexInputAttributeDescription{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat };
    const input = facet.PipelineVertexInputStateCreateInfo{ .vertex_binding_description_count = 1, .vertex_binding_descriptions = @ptrCast(&binding), .vertex_attribute_description_count = 1, .vertex_attribute_descriptions = @ptrCast(&attribute) };
    const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = .patch_list };
    const tessellation = facet.PipelineTessellationStateCreateInfo{ .patch_control_points = 4 };
    const viewport = facet.Viewport{ .width = side, .height = side };
    const scissor = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const view = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
    const raster = facet.PipelineRasterizationStateCreateInfo{};
    const depth = facet.PipelineDepthStencilStateCreateInfo{};
    const attachment = facet.PipelineColorBlendAttachmentState{};
    const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = 1, .attachments = @ptrCast(&attachment) };
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
        .layout = layout,
        .render_pass = pass,
    };
    var made: [1]?*facet.Pipeline = undefined;
    if (probe.fb.CreateGraphicsPipelines(probe.device.?, null, 1, @ptrCast(&info), &made) != .success) return null;
    return Probe.keep(&probe.pipelines, made[0]);
}

/// `wanted` and `found` within `apart` of each other, the two said where
/// they are not.
fn checkNear(probe: *Probe, wanted: f32, found: f32, apart: f32, name: [*:0]const u8) void {
    const off = if (found > wanted) found - wanted else wanted - found;
    if (off <= apart) return probe.check(true, name);
    probe.failed += 1;
    _ = Printf(probe.dl, "  FAILED  %s: wanted %d/10000, found %d/10000\n", .{ name, @as(i32, @intFromFloat(wanted * 10000)), @as(i32, @intFromFloat(found * 10000)) });
}

/// Vulkan's three spacings, and the floats a control function carries to
/// its evaluation function (1.50).
fn cutChecks(probe: *Probe) void {
    const fb = probe.fb;
    defer probe.give();
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    // The eight maxTessellation* limits read 0 since 1.82, because
    // `tessellation_shader` is false: a program bringing SPIR-V cannot
    // declare either tessellation stage (`spirv.facet_profile` leaves
    // `Profile.stages` at vertex and fragment), and Vulkan makes the
    // unsupported value mandatory once the feature says false. What the
    // library's own Zig surface tessellates is said by `shader.Patch`, and
    // the checks below exercise it through that surface.
    probe.check(probe.features.tessellation_shader == facet.FALSE, "the device says it runs no SPIR-V tessellation stage");
    probe.checkEqual(0, properties.limits.max_tessellation_patch_size, "so the patch limits read Vulkan's unsupported value");
    probe.checkEqual(0, properties.limits.max_tessellation_control_per_patch_output_components, "all of them");

    const color_attachment = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal };
    const reference = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&reference) };
    const pass = probe.renderPass(.{ .attachment_count = 1, .attachments = @ptrCast(&color_attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }) orelse
        return probe.check(false, "a pass to cut patches into");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(probe.device.?, &.{ .code = &Cut.code }, &module) != .success) return probe.check(false, "the shader module of a cut patch");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(probe.device.?, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    const color = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture to draw the patch into");
    const frame = probe.framebuffer(pass, &.{color[1]}) orelse return probe.check(false, "a framebuffer over it");
    const pixels, const pitch = probe.mapped(color[0], probe.memories[0].?) orelse return probe.check(false, "the picture read back");

    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(Cut.corners)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer of four corners");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(Cut.corners))], std.mem.asBytes(&Cut.corners));
    const offset: u64 = 0;
    const clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } }};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const red: u32 = 0xFFFF_0000;

    // A level of 3.5 along every edge: four pieces of one length; four
    // with the half piece split between the two ends of the edge; or five
    // the same way. Where the fraction goes is where the first cut falls.
    for ([_]struct { name: [*:0]const u8, first: f32, says: [*:0]const u8, drew: [*:0]const u8, got: [*:0]const u8 }{
        .{ .name = "equally", .first = 1.0 / 4.0, .says = "an equal spacing cuts the edge into four of one length", .drew = "the patch cut equally fills the picture", .got = "the floats the patch carries come back, cut equally" },
        .{ .name = "evenly", .first = 1.5 / 7.0, .says = "an even fractional spacing puts the half piece at the two ends", .drew = "the patch cut evenly fills the picture", .got = "the floats the patch carries come back, cut evenly" },
        .{ .name = "oddly", .first = 0.5 / 7.0, .says = "an odd fractional spacing cuts five, the short two at the ends", .drew = "the patch cut oddly fills the picture", .got = "the floats the patch carries come back, cut oddly" },
    }) |one| {
        const pipeline = cutPipeline(probe, pass, module.?, layout.?, "main", one.name) orelse
            return probe.check(false, "a pipeline of one of the three spacings");
        Cut.smallest = 1;
        Cut.carried = @splat(-1);
        Cut.carried_count = 0;
        const commands = probe.record() orelse return probe.check(false, "a recording of the cut patch");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 1, .clear_values = &clear }, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, pipeline);
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdDraw(commands, 4, 1, 0, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        checkNear(probe, one.first, Cut.smallest, 0.001, one.says);
        // The whole picture is covered whatever the cut, and the colour is
        // the control function's, carried over in the patch's own floats.
        probe.checkEqual(red, pixelAt(pixels, pitch, side / 2, side / 2), one.drew);
        probe.check(Cut.carried_count == 4 and Cut.carried[0] > 1 and Cut.carried[1] == 0, one.got);
    }

    // Refused: more floats for the patch than the device holds, and a
    // spacing of a value this library has not.
    probe.check(cutPipeline(probe, pass, module.?, layout.?, "hoard", "equally") == null, "a patch of more floats than the device holds refused");
    probe.check(cutPipeline(probe, pass, module.?, layout.?, "main", "nohow") == null, "a spacing of none of the three refused");
}

// --- 1.51: a subpass's colour attachments drawn together --------------------

/// Three colour attachments written in the one fragment call
/// (`shader.fragmentOutputs`, SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER), and
/// the same three written one at a time as they were before.
const Together = struct {
    /// How often a fragment function was called in the last draw.
    var calls: u32 = 0;
    /// What the last call was told it writes at once.
    var outputs: u32 = 0;
    const colors = [3]u32{ 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF };

    fn vertex(vertices: *const facet.shader.Vertices) callconv(.c) void {
        for (0..vertices.count) |k| {
            const p = vertices.input(@intCast(k), 0);
            vertices.output(@intCast(k))[0..4].* = .{ p[0], p[1], p[2], 1 };
        }
    }

    /// Red, green and blue, one for each attachment, in the one call.
    fn three(fragments: *const facet.shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        for (colors, 0..) |color, output| {
            const into = fragments.colorsOf(@intCast(output));
            for (into[0..fragments.count]) |*quad| quad.* = @splat(color);
        }
    }

    /// White into all of them: what differs is then the blending alone.
    fn white(fragments: *const facet.shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        for (0..fragments.output_count) |output| {
            const into = fragments.colorsOf(@intCast(output));
            for (into[0..fragments.count]) |*quad| quad.* = @splat(0xFFFF_FFFF);
        }
    }

    /// The one colour a replayed subpass writes, the attachment being
    /// drawn saying which.
    fn one(fragments: *const facet.shader.Fragments) callconv(.c) void {
        calls += 1;
        outputs = fragments.output_count;
        facet.shader.fill(fragments, colors[@min(fragments.resources.output, 2)]);
    }

    const entries = [_]facet.shader.Entry{
        facet.shader.vertex("three", &vertex, 0),
        facet.shader.fragmentOutputs("three", &three, 0, 3),
        facet.shader.vertex("white", &vertex, 0),
        facet.shader.fragmentOutputs("white", &white, 0, 3),
        facet.shader.vertex("one", &vertex, 0),
        facet.shader.fragment("one", &one, 0),
    };
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// A pass of three colour attachments, drawn together or one at a time.
fn togetherPass(probe: *Probe, together: bool) ?*facet.RenderPass {
    const descriptions = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .general },
    };
    const references = [3]facet.AttachmentReference{
        .{ .attachment = 0, .layout = .general },
        .{ .attachment = 1, .layout = .general },
        .{ .attachment = 2, .layout = .general },
    };
    const subpass = facet.SubpassDescription{
        .flags = if (together) facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER else 0,
        .color_attachment_count = 3,
        .color_attachments = &references,
    };
    return probe.renderPass(.{ .attachment_count = 3, .attachments = &descriptions, .subpass_count = 1, .subpasses = @ptrCast(&subpass) });
}

/// One fragment call for all the colour attachments of a subpass, and
/// blend constants of each attachment's own (1.51).
fn togetherChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Together.code }, &module) != .success) return probe.check(false, "the shader module of three colours at once");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const attributes = [1]facet.VertexInputAttributeDescription{.{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat }};

    // The flag is the cores': a device whose fragment programs each write
    // the one colour refuses the pass outright, and the subpass without
    // it is drawn once for each attachment as it always was.
    if (!probe.can.several_outputs) {
        probe.check(togetherPass(probe, true) == null, "a subpass drawn together refused where a fragment program writes the one colour");
        const apart = togetherPass(probe, false) orelse return probe.check(false, "the same subpass drawn once for each");
        probe.check(true, "the same subpass drawn once for each");
        // A fragment function of several colours is refused there as
        // well - and so is one of the program's own, every fragment
        // program of such a device being a fixed form.
        probe.check(pipelineOf(probe, apart, module.?, layout.?, .{ .name = "three", .attributes = &attributes, .blends = &@as([3]facet.PipelineColorBlendAttachmentState, @splat(.{})) }) == null, "a fragment function of three colours refused there");
        return;
    }

    const pass = togetherPass(probe, true) orelse return probe.check(false, "a subpass whose three colour attachments are drawn together");
    probe.check(true, "a subpass whose three colour attachments are drawn together");
    const apart = togetherPass(probe, false) orelse return probe.check(false, "the same three drawn once for each");

    var pictures: [3]struct { *facet.ImageView, [*]const u8, u32 } = undefined;
    for (&pictures) |*picture| {
        const made = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = .{ .width = side, .height = side }, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
            return probe.check(false, "a picture for each attachment");
        var slot: usize = 0;
        for (probe.memories, 0..) |each, k| if (each == null) {
            slot = k - 1;
            break;
        };
        const pixels, const pitch = probe.mapped(made[0], probe.memories[slot].?) orelse return probe.check(false, "the pictures read back");
        picture.* = .{ made[1], pixels, pitch };
    }
    const views = [3]*facet.ImageView{ pictures[0][0], pictures[1][0], pictures[2][0] };
    const frame = probe.framebuffer(pass, &views) orelse return probe.check(false, "a framebuffer over the three");
    const apart_frame = probe.framebuffer(apart, &views) orelse return probe.check(false, "and one for the pass that draws them apart");

    const quad = quadAt(0.5);
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(quad)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(quad))], std.mem.asBytes(&quad));
    const offset: u64 = 0;
    const clears = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
    };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const plain: [3]facet.PipelineColorBlendAttachmentState = @splat(.{});

    const draw = struct {
        fn run(on: *Probe, into: *facet.RenderPass, onto: *facet.Framebuffer, pipeline: *facet.Pipeline, buffer: *facet.Buffer, where: *const u64, at: ?u32) bool {
            const commands = on.record() orelse return false;
            on.fb.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = area, .clear_value_count = 3, .clear_values = &clears }, .@"inline");
            on.fb.CmdBindPipeline(commands, .graphics, pipeline);
            on.fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&buffer), @ptrCast(where));
            if (at) |which| {
                on.fb.CmdSetBlendConstants(commands, &.{ 1, 1, 1, 1 });
                on.fb.CmdSetBlendConstantsAt(commands, which, &.{ 0.25, 0.25, 0.25, 1 });
            }
            on.fb.CmdDraw(commands, 6, 1, 0, 0);
            on.fb.CmdEndRenderPass(commands);
            return on.submit();
        }
    }.run;

    // One call for all three: each attachment gets its own colour.
    const all = pipelineOf(probe, pass, module.?, layout.?, .{ .name = "three", .attributes = &attributes, .blends = &plain }) orelse
        return probe.check(false, "a pipeline whose fragment function writes all three");
    Together.calls = 0;
    Together.outputs = 0;
    if (!draw(probe, pass, frame, all, vertex_buffer, &offset, null)) return probe.check(false, "the frame drawn together submitted");
    probe.checkEqual(3, Together.outputs, "the fragment function is told it writes three colours");
    const together_calls = Together.calls;
    for (pictures, Together.colors, 0..) |picture, want, k| {
        _ = k;
        probe.checkEqual(want, pixelAt(picture[1], picture[2], side / 2, side / 2), "each attachment holds the colour the one call wrote it");
    }

    // The same three drawn once for each: three times the calls.
    const each = pipelineOf(probe, apart, module.?, layout.?, .{ .name = "one", .attributes = &attributes, .blends = &plain }) orelse
        return probe.check(false, "a pipeline of the one colour for the pass that draws them apart");
    Together.calls = 0;
    if (!draw(probe, apart, apart_frame, each, vertex_buffer, &offset, null)) return probe.check(false, "the frame drawn apart submitted");
    probe.checkEqual(1, Together.outputs, "a fragment function of one colour is told it writes one");
    probe.checkEqual(@as(u64, 3) * together_calls, Together.calls, "drawing them apart calls the fragment function three times over");

    // Each attachment cleared to its own colour, both ways round: the
    // clears belong to the subpass's attachments in order, whether one
    // part draws them all or a part draws each.
    const own_clears = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
    };
    for ([2]*facet.RenderPass{ pass, apart }, [2]*facet.Framebuffer{ frame, apart_frame }, [2][*:0]const u8{
        "a subpass drawn together clears each attachment to its own colour",
        "and so does one drawn once for each",
    }) |into, onto, says| {
        const commands = probe.record() orelse return probe.check(false, "a recording of the clears");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = into, .framebuffer = onto, .render_area = area, .clear_value_count = 3, .clear_values = &own_clears }, .@"inline");
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame of clears submitted");
        var right = true;
        for (pictures, Together.colors) |picture, want| {
            if (pixelAt(picture[1], picture[2], side / 2, side / 2) != want) right = false;
        }
        probe.check(right, says);
    }

    // Blend constants of each attachment's own, which Vulkan shares: the
    // pipeline's, and then what a command set for one of them.
    const by_constant = facet.PipelineColorBlendAttachmentState{
        .blend_enable = true,
        .src_color_blend_factor = .constant_color,
        .dst_color_blend_factor = .zero,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
    };
    const mixing: [3]facet.PipelineColorBlendAttachmentState = @splat(by_constant);
    const sets = [3][4]f32{ .{ 1, 1, 1, 1 }, .{ 0.5, 0.5, 0.5, 1 }, .{ 0.25, 0.25, 0.25, 1 } };
    const mixed = pipelineOf(probe, pass, module.?, layout.?, .{ .name = "white", .attributes = &attributes, .blends = &mixing, .constants = &sets }) orelse
        return probe.check(false, "a pipeline of one set of blend constants for each attachment");
    if (!draw(probe, pass, frame, mixed, vertex_buffer, &offset, null)) return probe.check(false, "the frame of its own constants submitted");
    probe.checkEqual(0xFFFF_FFFF, pixelAt(pictures[0][1], pictures[0][2], side / 2, side / 2), "the first attachment mixed by its whole constant");
    checkNearColor(probe, 0xFF80_8080, pixelAt(pictures[1][1], pictures[1][2], side / 2, side / 2), "the second by half of its own");
    checkNearColor(probe, 0xFF40_4040, pixelAt(pictures[2][1], pictures[2][2], side / 2, side / 2), "the third by a quarter of its own");

    const dynamic = pipelineOf(probe, pass, module.?, layout.?, .{ .name = "white", .attributes = &attributes, .blends = &mixing, .dynamic = &.{.blend_constants} }) orelse
        return probe.check(false, "a pipeline whose constants a command sets");
    if (!draw(probe, pass, frame, dynamic, vertex_buffer, &offset, 1)) return probe.check(false, "the frame of the command's constants submitted");
    probe.checkEqual(0xFFFF_FFFF, pixelAt(pictures[0][1], pictures[0][2], side / 2, side / 2), "the one set a command gave over all of them");
    checkNearColor(probe, 0xFF40_4040, pixelAt(pictures[1][1], pictures[1][2], side / 2, side / 2), "and one attachment's own over that");
    probe.checkEqual(0xFFFF_FFFF, pixelAt(pictures[2][1], pictures[2][2], side / 2, side / 2), "the others left with the shared set");

    // Refused: a fragment function that writes other than the subpass's
    // colour attachments, either way round.
    probe.check(pipelineOf(probe, pass, module.?, layout.?, .{ .name = "one", .attributes = &attributes, .blends = &plain }) == null, "a function of one colour refused a subpass drawn together");
    probe.check(pipelineOf(probe, apart, module.?, layout.?, .{ .name = "three", .attributes = &attributes, .blends = &plain }) == null, "a function of three refused a subpass drawn apart");
}

/// Two colours within `apart` of each other in every channel: what a
/// blend by a constant may differ by between one rounding and another.
fn checkNearColor(probe: *Probe, wanted: u32, found: u32, name: [*:0]const u8) void {
    inline for (0..4) |k| {
        const shift = k * 8;
        const a = (wanted >> shift) & 0xFF;
        const b = (found >> shift) & 0xFF;
        if ((if (a > b) a - b else b - a) > 2) return probe.checkEqual(wanted, found, name);
    }
    probe.check(true, name);
}

// --- 1.52: a depth attachment shared across a subpass -----------------------

/// A depth attachment the first and the last subpass share, with a
/// subpass of other tiles in between: the pass keeps it in the image's
/// rows between them, neither of the attachment's own ops asking for that
/// (1.52).
fn sharedDepthChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();

    const descriptions = [3]facet.AttachmentDescription{
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
        .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
    };
    const on_first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .color_attachment_optimal }};
    const on_second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .color_attachment_optimal }};
    const depth = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
    const subpasses = [3]facet.SubpassDescription{
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &depth },
        // In tiles of its own, and with no depth at all.
        .{ .color_attachment_count = 1, .color_attachments = &on_second },
        .{ .color_attachment_count = 1, .color_attachments = &on_first, .depth_stencil_attachment = &depth },
    };
    const pass = probe.renderPass(.{ .attachment_count = 3, .attachments = &descriptions, .subpass_count = 3, .subpasses = &subpasses }) orelse
        return probe.check(false, "a pass whose first and last subpass share a depth attachment");
    probe.check(true, "a pass whose first and last subpass share a depth attachment");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Smooth.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);

    const extent = facet.Extent3D{ .width = side, .height = side };
    const shown = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture the first and the last subpass draw into");
    const shown_memory = probe.memories[0].?;
    const other = probe.image(.{ .format = .b8g8r8a8_unorm, .extent = extent, .tiling = .linear, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT }, facet.MEMORY_PROPERTY_HOST_VISIBLE) orelse
        return probe.check(false, "a picture for the subpass in between");
    // A depth with memory something is behind: a kept one needs rows.
    const kept = probe.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT }, 0) orelse
        return probe.check(false, "a depth attachment with rows to keep it in");
    const frame = probe.framebuffer(pass, &.{ shown[1], other[1], kept[1] }) orelse
        return probe.check(false, "a framebuffer over the three");
    const pixels, const pitch = probe.mapped(shown[0], shown_memory) orelse return probe.check(false, "the picture read back");

    // A transient depth has nothing behind it to keep, so such a pass is
    // refused the framebuffer.
    if (probe.bound(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED)) |transient| {
        if (probe.viewed(.{ .image = transient, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH } })) |view| {
            probe.check(probe.framebuffer(pass, &.{ shown[1], other[1], view }) == null, "a transient depth refused the framebuffer of such a pass");
        }
    }

    // Three quads: the one the first subpass lays its depth down with,
    // and the farther and nearer ones the last subpass tries.
    const quads = [3][6][3]f32{ quadAt(0.5), quadAt(0.75), quadAt(0.25) };
    const quad_bytes = @sizeOf([6][3]f32);
    const vertex_buffer, const vertex_bytes = probe.buffer(quads.len * quad_bytes, facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer of the three quads");
    @memcpy(vertex_bytes[0 .. quads.len * quad_bytes], std.mem.asBytes(&quads));
    const offset: u64 = 0;
    const blue: u32 = 0xFF00_00FF;
    const white: u32 = 0xFFFF_FFFF;
    const clears = [3]facet.ClearValue{
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .color = .{ .float32 = .{ 0, 0, 1, 1 } } },
        .{ .depth_stencil = .{ .depth = 1 } },
    };
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };
    const tested = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true, .depth_compare_op = .less };
    // The first subpass writes its depth and no colour at all, so what
    // the picture holds at the end is the last subpass's doing alone.
    const depth_only = [1]facet.PipelineColorBlendAttachmentState{.{ .color_write_mask = 0 }};

    const lays = pipelineOf(probe, pass, module.?, layout.?, .{ .depth_state = tested, .blends = &depth_only }) orelse
        return probe.check(false, "a pipeline that writes the depth alone");
    const between = pipelineOf(probe, pass, module.?, layout.?, .{ .subpass = 1 }) orelse
        return probe.check(false, "a pipeline for the subpass in between");
    const against = pipelineOf(probe, pass, module.?, layout.?, .{ .subpass = 2, .depth_state = tested }) orelse
        return probe.check(false, "a pipeline for the last subpass");

    // Twice: the last subpass's quad farther than the half the first
    // wrote, then nearer. Were the depth not kept, the last subpass would
    // start from a cleared one and draw both.
    for ([2]struct { u32, u32, [*:0]const u8 }{
        .{ 6, blue, "the last subpass's farther quad is held off by the depth the first left" },
        .{ 12, white, "and its nearer one gets through, so what came back is a depth and not a wall" },
    }) |one| {
        const first_vertex, const want, const says = one;
        const commands = probe.record() orelse return probe.check(false, "a recording of the three subpasses");
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = frame, .render_area = area, .clear_value_count = 3, .clear_values = &clears }, .@"inline");
        fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
        fb.CmdBindPipeline(commands, .graphics, lays);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdNextSubpass(commands, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, between);
        fb.CmdDraw(commands, 6, 1, 0, 0);
        fb.CmdNextSubpass(commands, .@"inline");
        fb.CmdBindPipeline(commands, .graphics, against);
        fb.CmdDraw(commands, 6, 1, first_vertex, 0);
        fb.CmdEndRenderPass(commands);
        if (!probe.submit()) return probe.check(false, "the frame submitted");
        probe.checkEqual(want, pixelAt(pixels, pitch, side / 2, side / 2), says);
    }

    // The subpass in between drew into its own picture all the same.
    const between_pixels, const between_pitch = probe.mapped(other[0], probe.memories[1].?) orelse
        return probe.check(false, "the other picture read back");
    probe.checkEqual(white, pixelAt(between_pixels, between_pitch, side / 2, side / 2), "the subpass in between drew into its own picture");
}

// --- 1.91: framebuffers of layers --------------------------------------------

/// A pixel of one layer read back into a buffer, the layers one after
/// another and `side` pixels a row: 0xAARRGGBB, as `pixelAt` reads.
fn layerPixel(bytes: [*]const u8, layer: u32, x: u32, y: u32) u32 {
    return pixelAt(bytes + @as(usize, layer) * side * side * 4, side * 4, x, y);
}

/// A framebuffer of layers (since 1.91, which made them on the cores as
/// lavapipe makes them): as many as `max_framebuffer_layers` says and not
/// one more. A pass over a view of a later layer clears and draws there
/// and nowhere else - on the V3D, which has the one layer, that is where
/// its tiles are stored to and its depth is kept. And on a device with
/// layers to spare, a pass of two clears both, draws into the first, and
/// clears a rectangle of the second when CmdClearAttachments names it.
fn layerChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    const most = properties.limits.max_framebuffer_layers;

    const description = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal };
    const reference = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&reference) };
    const pass = probe.renderPass(.{ .attachment_count = 1, .attachments = @ptrCast(&description), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }) orelse
        return probe.check(false, "a pass that clears its colour");

    // An image of as many layers as a framebuffer may have, and three at
    // least: a layer past what a pass names is one to see left alone.
    const layers = @max(most, 3);
    const extent = facet.Extent3D{ .width = side, .height = side };
    const usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
    const stack = probe.bound(.{ .format = .b8g8r8a8_unorm, .extent = extent, .array_layers = layers, .usage = usage }, 0) orelse
        return probe.check(false, "a colour attachment of layers");
    probe.check(true, "a colour attachment of layers");
    const every = probe.viewed(.{ .image = stack, .format = .b8g8r8a8_unorm, .view_type = .@"2d_array", .subresource_range = .{ .layer_count = layers } }) orelse
        return probe.check(false, "a view of all its layers");
    const second = probe.viewed(.{ .image = stack, .format = .b8g8r8a8_unorm, .subresource_range = .{ .base_array_layer = 1, .layer_count = 1 } }) orelse
        return probe.check(false, "a view of its second layer");

    // As many layers as the device says, and one more refused: on the V3D
    // by its limit alone, the view having the layers.
    probe.check(probe.layeredFramebuffer(pass, &.{every}, most) != null, "a framebuffer of as many layers as the device says");
    probe.check(probe.layeredFramebuffer(pass, &.{every}, most + 1) == null, "and one of a layer more refused");
    const on_second = probe.framebuffer(pass, &.{second}) orelse return probe.check(false, "a framebuffer over the second layer");

    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Painted.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{}, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    const painted = pipelineOf(probe, pass, module.?, layout.?, .{ .attributes = &Painted.attributes, .stride = Painted.stride }) orelse
        return probe.check(false, "a pipeline over the pass");

    // A white quad over the left half: the right half is the clear's.
    const white_paint = [3]f32{ 1, 1, 1 };
    const left = [6][6]f32{
        Painted.at(-1, -1, 0.5, white_paint), Painted.at(0, -1, 0.5, white_paint), Painted.at(-1, 1, 0.5, white_paint),
        Painted.at(-1, 1, 0.5, white_paint),  Painted.at(0, -1, 0.5, white_paint), Painted.at(0, 1, 0.5, white_paint),
    };
    const vertex_buffer, const vertex_bytes = probe.buffer(@sizeOf(@TypeOf(left)), facet.BUFFER_USAGE_VERTEX_BUFFER) orelse
        return probe.check(false, "a vertex buffer");
    @memcpy(vertex_bytes[0..@sizeOf(@TypeOf(left))], std.mem.asBytes(&left));
    const layer_bytes = side * side * 4;
    const back, const back_bytes = probe.buffer(3 * layer_bytes, facet.BUFFER_USAGE_TRANSFER_DST) orelse
        return probe.check(false, "a buffer to read three layers into");
    var regions: [3]facet.BufferImageCopy = undefined;
    for (&regions, 0..) |*region, k| region.* = .{ .buffer_offset = k * layer_bytes, .image_extent = extent, .image_subresource = .{ .base_array_layer = @intCast(k) } };

    const offset: u64 = 0;
    const blue: u32 = 0xFF00_00FF;
    const green: u32 = 0xFF00_FF00;
    const red: u32 = 0xFFFF_0000;
    const yellow: u32 = 0xFFFF_FF00;
    const white: u32 = 0xFFFF_FFFF;
    const blue_value = facet.ClearColorValue{ .float32 = .{ 0, 0, 1, 1 } };
    const all = facet.ImageSubresourceRange{};
    const area = facet.Rect2D{ .extent = .{ .width = side, .height = side } };

    // The image blue, and a pass over the view of its second layer that
    // clears it green and draws the white half.
    @memset(back_bytes[0 .. 3 * layer_bytes], 0);
    const green_clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }};
    var commands = probe.record() orelse return probe.check(false, "a recording of a pass over the second layer");
    fb.CmdClearColorImage(commands, stack, .transfer_dst_optimal, &blue_value, 1, @ptrCast(&all));
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = on_second, .render_area = area, .clear_value_count = 1, .clear_values = &green_clear }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, painted);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, stack, .general, back, regions.len, &regions);
    if (!probe.submit()) return probe.check(false, "the pass over the second layer submitted");
    probe.checkEqual(white, layerPixel(back_bytes, 1, 8, 8), "a pass over a view of the second layer draws into it");
    probe.checkEqual(green, layerPixel(back_bytes, 1, 48, 40), "and clears it");
    // Past the first tile across and down: each tile is stored on its own.
    probe.checkEqual(green, layerPixel(back_bytes, 1, 40, 56), "and clears it in another tile");
    probe.checkEqual(blue, layerPixel(back_bytes, 0, 8, 8), "and leaves the first layer as it was");
    probe.checkEqual(blue, layerPixel(back_bytes, 0, 48, 40), "the whole of it");
    probe.checkEqual(blue, layerPixel(back_bytes, 2, 8, 8), "and the third");

    // A depth kept through a view of its second layer, where the device
    // keeps one.
    if (probe.can.stored_depth) depth: {
        const keeping = passKeeping(probe, .clear, .clear, .store) orelse break :depth probe.check(false, "a pass that keeps its depth");
        const depth_usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
        const depths = probe.bound(.{ .format = .d16_unorm, .extent = extent, .array_layers = 2, .usage = depth_usage }, 0) orelse
            break :depth probe.check(false, "a depth attachment of two layers");
        probe.check(true, "a depth attachment of two layers");
        const depth_second = probe.viewed(.{ .image = depths, .format = .d16_unorm, .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_array_layer = 1, .layer_count = 1 } }) orelse
            break :depth probe.check(false, "a view of the depth's second layer");
        const kept = probe.framebuffer(keeping, &.{ second, depth_second }) orelse break :depth probe.check(false, "a framebuffer keeping a depth in its second layer");
        const far = facet.ClearDepthStencilValue{ .depth = 1 };
        const depth_all = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
        const both_clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 1, 0, 1 } } }, .{ .depth_stencil = .{ .depth = 0.25 } } };
        var depth_regions: [2]facet.BufferImageCopy = undefined;
        for (&depth_regions, 0..) |*region, k| region.* = .{ .buffer_offset = k * side * side * 2, .image_extent = extent, .image_subresource = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .base_array_layer = @intCast(k) } };
        @memset(back_bytes[0 .. 2 * side * side * 2], 0xAA);
        commands = probe.record() orelse break :depth probe.check(false, "a recording of the kept depth");
        fb.CmdClearDepthStencilImage(commands, depths, .transfer_dst_optimal, &far, 1, @ptrCast(&depth_all));
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = keeping, .framebuffer = kept, .render_area = area, .clear_value_count = 2, .clear_values = &both_clears }, .@"inline");
        fb.CmdEndRenderPass(commands);
        fb.CmdCopyImageToBuffer(commands, depths, .general, back, depth_regions.len, &depth_regions);
        if (!probe.submit()) break :depth probe.check(false, "the kept depth submitted");
        const quarter: u16 = @intFromFloat(@round(0.25 * 65535));
        checkDepth(probe, quarter, depthAt(back_bytes + side * side * 2, 8, 8), "a depth kept through a view of the second layer kept there");
        checkDepth(probe, quarter, depthAt(back_bytes + side * side * 2, 40, 56), "in another tile as well");
        checkDepth(probe, 0xFFFF, depthAt(back_bytes, 8, 8), "and the first layer's depth left as it was");
    }

    // Two layers in one pass, where the device has them: both cleared
    // red, the first drawn into, and the right half of the second cleared
    // yellow by CmdClearAttachments. The third is not the framebuffer's.
    if (most < 2) return;
    const two = probe.layeredFramebuffer(pass, &.{every}, 2) orelse return probe.check(false, "a framebuffer of two layers");
    const red_clear = [1]facet.ClearValue{.{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } }};
    const yellow_attachment = facet.ClearAttachment{ .clear_value = .{ .color = .{ .float32 = .{ 1, 1, 0, 1 } } } };
    const right_of_second = facet.ClearRect{ .rect = .{ .offset = .{ .x = side / 2 }, .extent = .{ .width = side / 2, .height = side } }, .base_array_layer = 1 };
    @memset(back_bytes[0 .. 3 * layer_bytes], 0);
    commands = probe.record() orelse return probe.check(false, "a recording of a pass of two layers");
    fb.CmdClearColorImage(commands, stack, .transfer_dst_optimal, &blue_value, 1, @ptrCast(&all));
    fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = two, .render_area = area, .clear_value_count = 1, .clear_values = &red_clear }, .@"inline");
    fb.CmdBindPipeline(commands, .graphics, painted);
    fb.CmdBindVertexBuffers(commands, 0, 1, @ptrCast(&vertex_buffer), @ptrCast(&offset));
    fb.CmdDraw(commands, 6, 1, 0, 0);
    fb.CmdClearAttachments(commands, 1, @ptrCast(&yellow_attachment), 1, @ptrCast(&right_of_second));
    fb.CmdEndRenderPass(commands);
    fb.CmdCopyImageToBuffer(commands, stack, .general, back, regions.len, &regions);
    if (!probe.submit()) return probe.check(false, "the pass of two layers submitted");
    probe.checkEqual(white, layerPixel(back_bytes, 0, 8, 8), "a pass of two layers draws into the first");
    probe.checkEqual(red, layerPixel(back_bytes, 0, 48, 40), "and clears it");
    probe.checkEqual(red, layerPixel(back_bytes, 1, 8, 8), "and clears the second, which it does not draw into");
    probe.checkEqual(yellow, layerPixel(back_bytes, 1, 48, 40), "a rectangle of the second cleared where CmdClearAttachments names it");
    probe.checkEqual(red, layerPixel(back_bytes, 0, 56, 8), "and the first layer left red there");
    probe.checkEqual(blue, layerPixel(back_bytes, 2, 48, 40), "a layer past the framebuffer's left alone");
}

/// 1.129: events, set and reset by the queue's work, then waited for. The
/// wait is for one the host sets only once the work is submitted, which
/// Vulkan 1.0 had a program do: the queue's task holds the work after it
/// until then, which the host tests cannot show, the work being played
/// there by the task that submits it.
fn eventChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    var events: [2]?*facet.Event = @splat(null);
    // Given back once the queue is idle, which `give` waits for.
    defer for (events) |event| fb.DestroyEvent(device, event);
    defer probe.give();
    for (&events) |*event| {
        if (fb.CreateEvent(device, &.{}, event) != .success) return probe.check(false, "two events");
    }
    const by_queue, const by_host = .{ events[0].?, events[1].? };
    probe.check(fb.GetEventStatus(device, by_queue) == .event_reset, "an event is made reset");
    const target, const bytes = probe.buffer(16, facet.BUFFER_USAGE_TRANSFER_DST) orelse return probe.check(false, "a buffer to fill");
    @memset(bytes[0..16], 0);

    _ = fb.SetEvent(device, by_host);
    var commands = probe.record() orelse return probe.check(false, "the events set and reset");
    fb.CmdFillBuffer(commands, target, 0, 4, 0x1111_1111);
    fb.CmdSetEvent(commands, by_queue, facet.PIPELINE_STAGE_TRANSFER);
    fb.CmdResetEvent(commands, by_host, facet.PIPELINE_STAGE_TRANSFER);
    if (!probe.submit()) return probe.check(false, "the events set and reset");
    probe.check(fb.GetEventStatus(device, by_queue) == .event_set, "CmdSetEvent sets an event, the work before it done");
    probe.checkEqual(0x1111_1111, std.mem.readInt(u32, bytes[0..4], .little), "that work done");
    probe.check(fb.GetEventStatus(device, by_host) == .event_reset, "CmdResetEvent resets one");

    commands = probe.record() orelse return probe.check(false, "a wait for events");
    const awaited = [2]*facet.Event{ by_queue, by_host };
    fb.CmdWaitEvents(commands, 2, &awaited, facet.PIPELINE_STAGE_TRANSFER | facet.PIPELINE_STAGE_HOST, facet.PIPELINE_STAGE_TRANSFER, 0, null, 0, null, 0, null);
    fb.CmdFillBuffer(commands, target, 4, 4, 0x2222_2222);
    if (fb.EndCommandBuffer(commands) != .success) return probe.check(false, "a wait for events");
    if (fb.ResetFences(device, 1, @ptrCast(&probe.fence)) != .success) return probe.check(false, "a wait for events");
    const info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&probe.commands) };
    if (fb.QueueSubmit(probe.queue, 1, @ptrCast(&info), probe.fence) != .success) return probe.check(false, "a wait for events");
    // From here the host sets the event whatever is found, or the queue
    // would wait for ever.
    probe.check(fb.WaitForFences(device, 1, @ptrCast(&probe.fence), true, 50_000_000) == .timeout, "CmdWaitEvents holds the work after it while an event is reset");
    probe.checkEqual(0, std.mem.readInt(u32, bytes[4..8], .little), "none of that work done");
    _ = fb.SetEvent(device, by_host);
    probe.check(fb.WaitForFences(device, 1, @ptrCast(&probe.fence), true, 1_000_000_000) == .success, "SetEvent lets it go on");
    probe.checkEqual(0x2222_2222, std.mem.readInt(u32, bytes[4..8], .little), "and the work after it is done");
    probe.check(fb.GetEventStatus(device, by_host) == .event_set and fb.GetEventStatus(device, by_queue) == .event_set, "the events stay set");
}

/// 1.130: a pipeline cache hands out Vulkan's header, of the device's own
/// numbers: the cores' and the V3D's differ, which the host tests have
/// only one of.
fn cacheChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    var properties: facet.PhysicalDeviceProperties = undefined;
    fb.GetPhysicalDeviceProperties(probe.physical, &properties);
    var cache: ?*facet.PipelineCache = null;
    if (fb.CreatePipelineCache(device, &.{}, &cache) != .success) return probe.check(false, "a pipeline cache");
    defer fb.DestroyPipelineCache(device, cache);
    var bytes: [32]u8 = @splat(0);
    var size: usize = bytes.len;
    if (fb.GetPipelineCacheData(device, cache.?, &size, &bytes) != .success) return probe.check(false, "a pipeline cache's data");
    probe.checkEqual(32, size, "a pipeline cache's data is its header of 32 bytes");
    const header = std.mem.bytesToValue(facet.PipelineCacheHeaderVersionOne, &bytes);
    probe.checkEqual(properties.vendor_id, header.vendor_id, "of the device's vendor");
    probe.checkEqual(properties.device_id, header.device_id, "and the device's own number");
    probe.check(std.mem.eql(u8, &properties.pipeline_cache_uuid, &header.pipeline_cache_uuid), "and its pipeline cache UUID");
}

// --- 1.131: a view of another format (item 42) -------------------------------

/// Group (x, y) reads texel (x, y) of an R8G8B8A8 image through a view of
/// R32_UINT, which the image's four bytes are one number to, and writes
/// what it read into the buffer; the group at (1, 2) then writes a number
/// of its own over its texel. No group touches another's texel.
const Viewed = struct {
    fn words(groups: *const facet.shader.Groups) callconv(.c) void {
        const image = groups.resources.written(0, 0, 0) orelse return;
        const out = groups.resources.storage(u32, 0, 1) orelse return;
        const x = groups.group[0];
        const y = groups.group[1];
        out[y * 4 + x] = @truncate(@as(u64, @bitCast(image.wholesAt(0, 0, x, y)[0])));
        if (x == 1 and y == 2) image.setWholes(0, 0, x, y, .{ 0x88BB_AA99, 0, 0, 1 });
    }

    const entries = [_]facet.shader.Entry{facet.shader.compute("words", &words)};
    const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
};

/// 1.131: an image made IMAGE_CREATE_MUTABLE_FORMAT, which a view of
/// another format Vulkan has compatible with its own may be made of. The
/// cores keep such an image's texels as they lie, so that a view of
/// R32_UINT of an R8G8B8A8 image reads its four bytes as one number and
/// writes one where the copies find it again; a view of a format of
/// another size is refused. A device that cannot (the V3D, until the
/// half of item 42 that is v3dv's) says so in the format query, and then
/// CreateImage refuses the image the same way.
fn mutableChecks(probe: *Probe) void {
    const fb = probe.fb;
    const device = probe.device.?;
    defer probe.give();
    const mutable = facet.IMAGE_CREATE_MUTABLE_FORMAT;
    // Written through where the device writes through images at all.
    const written: u32 = if (probe.can.storage_images) facet.IMAGE_USAGE_STORAGE else 0;
    const usage = facet.IMAGE_USAGE_SAMPLED | written | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
    const info = facet.ImageCreateInfo{ .flags = mutable, .format = .r8g8b8a8_unorm, .extent = .{ .width = 4, .height = 4 }, .usage = usage };
    var shape: facet.ImageFormatProperties = undefined;
    const said = fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .r8g8b8a8_unorm, .@"2d", .optimal, usage, mutable, &shape);
    probe.check(fb.GetPhysicalDeviceImageFormatProperties(probe.physical, .r8g8b8a8_unorm, .@"2d", .optimal, usage, 0, &shape) == .success, "an R8G8B8A8 image to sample, write through where the device can, and copy");
    if (said != .success) {
        probe.check(said == .error_format_not_supported, "views of another format of it refused, as the format query says");
        var none: ?*facet.Image = null;
        probe.check(fb.CreateImage(device, &info, &none) == .error_format_not_supported and none == null, "and CreateImage refuses the image the same way");
        return;
    }
    probe.check(true, "views of another format of it, as the format query says");
    const made = probe.bound(info, 0) orelse return probe.check(false, "an image made for views of another format");
    probe.check(true, "an image made for views of another format");
    const words = probe.viewed(.{ .image = made, .format = .r32_uint }) orelse return probe.check(false, "a view of R32_UINT of it");
    probe.check(true, "a view of R32_UINT of it");
    probe.check(probe.viewed(.{ .image = made, .format = .r16_unorm }) == null, "and one of R16_UNORM, of another size, refused");
    probe.check(probe.viewed(.{ .image = made, .format = .d16_unorm_s8_uint }) == null, "and one of depth and stencil refused");

    // Bytes of the texel's place, copied in as they are.
    const texels, const texel_bytes = probe.buffer(64, facet.BUFFER_USAGE_TRANSFER_SRC) orelse return probe.check(false, "a buffer the texels come from");
    for (0..64) |k| texel_bytes[k] = @intCast(0x10 + k * 3);
    const whole = facet.BufferImageCopy{ .image_extent = .{ .width = 4, .height = 4 } };
    var commands = probe.record() orelse return probe.check(false, "a recording");
    fb.CmdCopyBufferToImage(commands, texels, made, .general, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy in submitted");

    if (!probe.can.storage_images) return;
    const bindings = [2]facet.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = facet.SHADER_STAGE_COMPUTE },
    };
    var set_layout: ?*facet.DescriptorSetLayout = null;
    if (fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &bindings }, &set_layout) != .success) return probe.check(false, "a set layout of a storage image");
    defer fb.DestroyDescriptorSetLayout(device, set_layout);
    var module: ?*facet.ShaderModule = null;
    if (fb.CreateShaderModule(device, &.{ .code = &Viewed.code }, &module) != .success) return probe.check(false, "the shader module");
    _ = Probe.keep(&probe.modules, module);
    var layout: ?*facet.PipelineLayout = null;
    if (fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout) }, &layout) != .success) return probe.check(false, "the pipeline layout");
    _ = Probe.keep(&probe.layouts, layout);
    var pool: ?*facet.DescriptorPool = null;
    if (fb.CreateDescriptorPool(device, &.{ .max_sets = 1 }, &pool) != .success) return probe.check(false, "a descriptor pool");
    defer fb.DestroyDescriptorPool(device, pool);
    var sets: [1]?*facet.DescriptorSet = undefined;
    if (fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) }, &sets) != .success)
        return probe.check(false, "a descriptor set");
    const read, const read_bytes = probe.buffer(64, facet.BUFFER_USAGE_STORAGE_BUFFER) orelse return probe.check(false, "a buffer the function writes");
    @memset(read_bytes[0..64], 0);
    const image_info = facet.DescriptorImageInfo{ .image_view = words };
    const buffer_info = facet.DescriptorBufferInfo{ .buffer = read, .range = facet.WHOLE_SIZE };
    const writes = [2]facet.WriteDescriptorSet{
        .{ .dst_set = sets[0].?, .dst_binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .image_info = @ptrCast(&image_info) },
        .{ .dst_set = sets[0].?, .dst_binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .buffer_info = @ptrCast(&buffer_info) },
    };
    fb.UpdateDescriptorSets(device, 2, &writes, 0, null);
    const pipeline_info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.?, .name = "words" }, .layout = layout.? };
    var pipeline: ?*facet.Pipeline = null;
    if (fb.CreateComputePipelines(device, null, 1, @ptrCast(&pipeline_info), @ptrCast(&pipeline)) != .success) return probe.check(false, "the compute pipeline");
    _ = Probe.keep(&probe.pipelines, pipeline);

    commands = probe.record() orelse return probe.check(false, "a second recording");
    fb.CmdBindPipeline(commands, .compute, pipeline.?);
    fb.CmdBindDescriptorSets(commands, .compute, layout.?, 0, 1, @ptrCast(&sets), 0, null);
    fb.CmdDispatch(commands, 4, 4, 1);
    if (!probe.submit()) return probe.check(false, "the dispatch submitted");
    // Each texel's four bytes, the first the lowest: R32_UINT's number.
    var as_words = true;
    for (0..16) |k| as_words = as_words and std.mem.readInt(u32, read_bytes[k * 4 ..][0..4], .little) == std.mem.readInt(u32, texel_bytes[k * 4 ..][0..4], .little);
    probe.check(as_words, "the view of R32_UINT reads each texel's four bytes as one number");

    const back, const back_bytes = probe.buffer(64, facet.BUFFER_USAGE_TRANSFER_DST) orelse return probe.check(false, "a buffer to read the image into");
    @memset(back_bytes[0..64], 0);
    commands = probe.record() orelse return probe.check(false, "a third recording");
    fb.CmdCopyImageToBuffer(commands, made, .general, back, 1, @ptrCast(&whole));
    if (!probe.submit()) return probe.check(false, "the copy out submitted");
    probe.checkEqual(0x88BB_AA99, std.mem.readInt(u32, back_bytes[36..40], .little), "and the number it writes is the four bytes the copy finds, the lowest first");
    var others = true;
    for (0..64) |k| others = others and (k / 4 == 9 or back_bytes[k] == texel_bytes[k]);
    probe.check(others, "beside the bytes copied in, where they lie");
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
    sizeChecks(&probe);
    edgeChecks(&probe);
    blockChecks(&probe);
    floatChecks(&probe);
    shapeChecks(&probe);
    samplesChecks(&probe);
    smallChecks(&probe);
    texelChecks(&probe);
    wideChecks(&probe);
    wholeChecks(&probe);
    pointChecks(&probe);
    heldChecks(&probe);
    cutChecks(&probe);
    togetherChecks(&probe);
    sharedDepthChecks(&probe);
    layerChecks(&probe);
    eventChecks(&probe);
    cacheChecks(&probe);
    mutableChecks(&probe);
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
