// SPDX-License-Identifier: MIT
//! The first driver: the machine's cores, drawing through the rasterizer
//! (raster/). It is part of the library and always there, the device every
//! machine has.
//!
//! Its physical device is described as an instance is made - its cores
//! counted, its memory types made from the regions exec has then - and its
//! work is done on the queue's task, a frame's tiles shared between the
//! cores (_play.zig, _draw.zig).
//!
//! **A heap is a set of attributes.** The regions exec has are walked in
//! the order it prefers them, and each new set of the attributes that say
//! where memory is and who reaches it - MEMF_INTERNAL, MEMF_EXTERNAL,
//! MEMF_DMA - is a heap, as large as its regions are together, with one
//! memory type of its own. Memory of a type is allocated with its heap's
//! attributes, so it comes from regions that have them all. Every type is
//! local to the device, visible to the program and coherent with it: the
//! device is the processor. After them comes one type with nothing
//! behind it, for attachments whose pixels live only in the tiles.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const raster = @import("raster");
const ExecBase = sdk.interface.exec.ExecBase;
const facet_version = @import("../../facet_version.zig");
const _objects = @import("../../_objects.zig");
const _format = @import("../_format.zig");
const _render = @import("../../render/_render.zig");
const _instance = @import("../../instance/_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;
const Device = @import("../../device/_device.zig").Device;
const _memory = @import("../../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;
const _pipeline = @import("../../pipeline/_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const Queue = @import("../../queue/_queue.zig").Queue;
const CommandBuffer = @import("../../command/_command.zig").CommandBuffer;
const Ops = @import("../_driver.zig").Ops;
const _play = @import("_play.zig");
const _draw = @import("_draw.zig");

pub const ops = Ops{
    .describe = &describe,
    .format_properties = &_format.keptProperties,
    .allocate_memory = &allocateMemory,
    .free_memory = &freeMemory,
    .make_pipeline = &makePipeline,
    .unmake_pipeline = &unmakePipeline,
    .open_queue = &_play.open,
    .close_queue = &_play.close,
    .execute = &execute,
};

/// The one queue family: drawing and copying, one queue.
const queue_family: facet.QueueFamilyProperties = .{
    .queue_flags = facet.QUEUE_GRAPHICS | facet.QUEUE_COMPUTE | facet.QUEUE_TRANSFER,
    .queue_count = 1,
    // A timestamp is the E-clock in microseconds, which is 64 bits of it
    // (facet_base.now); without timer.device the instance clears this.
    .timestamp_valid_bits = 64,
    .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
};

fn describe(sys: *ExecBase, physical: *PhysicalDevice) callconv(.c) bool {
    const cores = runningCores(sys);
    physical.properties = .{
        .api_version = facet.API_VERSION_1_0,
        .driver_version = facet.makeVersion(facet_version.LIBRARY_VERSION, facet_version.LIBRARY_REVISION),
        .vendor_id = 0,
        .device_id = 0,
        .device_type = .cpu,
        .device_name = @splat(0),
        .limits = .{
            .max_image_dimension_2d = _instance.max_image_dimension,
            .max_framebuffer_width = _instance.max_image_dimension,
            .max_framebuffer_height = _instance.max_image_dimension,
            .max_image_dimension_3d = _instance.max_image_dimension_3d,
            .max_image_array_layers = _instance.max_image_array_layers,
            .max_color_attachments = _render.most_colors,
            .max_vertex_input_bindings = _instance.max_vertex_input_bindings,
            .max_vertex_input_attributes = _instance.max_vertex_input_attributes,
            .max_vertex_input_binding_stride = 2048,
            .max_vertex_output_components = _instance.max_vertex_output_components,
            .max_push_constants_size = _instance.max_push_constants_size,
            .max_bound_descriptor_sets = _instance.max_bound_descriptor_sets,
            .max_per_stage_descriptor_sampled_images = 16,
            .max_per_stage_descriptor_uniform_buffers = 12,
            .max_descriptor_set_dynamic_buffers = facet.shader.MAX_DYNAMIC_OFFSETS,
            // A compute function runs on the cores for either device.
            .max_compute_work_group_size = _instance.max_compute_work_group_size,
            .max_compute_work_group_invocations = _instance.max_compute_work_group_invocations,
            .max_compute_shared_memory_size = _instance.max_compute_shared_memory_size,
            .min_memory_map_alignment = _memory.alignment,
            .tile_size = raster.tile_size,
            .cores = @min(cores, raster.most_parts),
            .max_sampler_anisotropy = _instance.max_sampler_anisotropy,
            .timestamp_period_ns = _instance.timestamp_period_ns,
        },
    };
    const shared = physical.properties.limits.cores;
    _ = std.fmt.bufPrint(physical.properties.device_name[0 .. facet.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1], "facet.library rasterizer, {d} core{s}", .{ shared, if (shared == 1) "" else "s" }) catch {};
    physical.features = .{
        // The rasterizer calls whatever function the pipeline carries.
        .own_fragment_functions = true,
        .sampling_format = true,
        // This device is the cores, which is where both of these run.
        .compute_on_device = true,
        .tessellation_on_device = true,
        // The rasterizer holds a dropping form's depths back until it has run.
        .discarding_fragment_forms = true,
        // The sampling itself is here (sdk.facet.texture.sampleBy), so the
        // forms that read a sampler run, with everything one may ask for.
        .samplers = true,
        .sampler_anisotropy = true,
        // The samples that passed are counted by the tiles as they are
        // drawn, and what each stage was given as the draw is played
        // (driver/cpu/_draw.zig, driver/cpu/raster/batched.zig).
        .occlusion_queries = true,
        .pipeline_statistics_queries = true,
        .timestamp_queries = true,
        // The tiles hold the depth, so they can write it into the image's
        // rows as they are drawn and read it back (raster/target.zig).
        .stored_depth = true,
        // The tiles hold a byte of stencil a pixel, written into the
        // image's rows as each tile is drawn, as the depth is.
        .stored_stencil = true,
        // A depth image's rows are sampled where they lie: the one texel
        // decoder reads a depth as well (`texture.Format.d16`).
        .sampled_depth = true,
        // A compressed image is sampled out of its blocks: the one texel
        // decoder reads a BC block as well (`texture.Format.blockOf`).
        .kept_compressed = true,
        // A float image likewise, its texels read and rounded where they
        // lie (`texture.floatTexel`).
        .kept_floats = true,
        // One cube of an array, the fourth coordinate saying which
        // (`texture.Texture.sampleCubeIn`).
        .cube_arrays = true,
        // ETC2 and EAC, unpacked as they are copied in (image/_decode.zig).
        .etc2_textures = true,
        // A texel kept smaller than its colour: one byte of red, or an
        // 8888 word unspread, which the one sampler reads either way
        // (`texture.Format.r8`, `argb8888`).
        .small_texels = true,
        // A pixel's depth and its stencil are written where they lie in
        // its four bytes, so a format of both keeps either (since 1.47).
        .stored_both = true,
        // Both go by the pixel at a time way the stencil test goes by:
        // the clamp holds a pixel's depth inside the viewport's range,
        // and the bounds test reads the depth already there.
        .depth_clamp = true,
        .depth_bounds = true,
        // A function of the program's runs here, and the texels it writes
        // lie where the library keeps them (`shader.Resources.written`).
        .storage_images = true,
        // A texel buffer is a buffer's bytes and a format: nothing of a
        // device's own layout is in it, so every device takes one. What
        // reads it is a function of the program's, which on a device
        // without them is its compute functions, run on the cores.
        .texel_buffers = true,
        // An input attachment is read by a fragment function of the
        // program's, out of the image's rows (`shader.Attachment`).
        .input_attachments = true,
        // A dynamic buffer descriptor is a pointer and a range, shifted
        // by what the bind gave: the function that reads it is the
        // program's, so every device takes one.
        .dynamic_descriptors = true,
        // A colour attachment is drawn as a pass of its own, so each
        // takes the mixing asked for it as it is drawn.
        .independent_blend = true,
        // The depth is a plane the triangle's set-up works out, so a bias
        // is an offset on it and costs nothing a pixel (raster/setup.zig).
        .depth_bias = true,
        .depth_prepass = true,
        .points_and_lines = true,
        .depth_test = true,
        .stencil_test = true,
        .blending = true,
        .indirect_draws = true,
        .secondary_command_buffers = true,
        .several_subpasses = true,
        .several_color_attachments = true,
        .texture_arrays = true,
        .cube_maps = true,
        .textures_3d = true,
        .compressed_textures = true,
        .float_textures = true,
    };
    physical.queue_family = queue_family;
    describeMemory(sys, &physical.memory);
    return true;
}

/// The cores running now: those whose times exec can read.
fn runningCores(sys: *ExecBase) u32 {
    var times: exec.CoreTimes = undefined;
    var count: u32 = 0;
    while (count < 32 and sys.ReadCoreTimes(count, &times)) count += 1;
    return @max(count, 1);
}

/// The attributes that make a heap.
const heap_attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | exec.MEMF_DMA;

/// The device's memory types and heaps, from the regions exec has now.
fn describeMemory(sys: *ExecBase, into: *facet.PhysicalDeviceMemoryProperties) void {
    into.* = std.mem.zeroes(facet.PhysicalDeviceMemoryProperties);
    // The last type, the lazily allocated one, takes no heap of its own.
    const most_heaps = @min(facet.MAX_MEMORY_HEAPS, facet.MAX_MEMORY_TYPES - 1);
    var count: u32 = 0;
    if (sys.LockExecList(exec.EXECLIST_MEMORY)) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const region: *const exec.MemHeader = @fieldParentPtr("node", node);
            const attributes = region.attributes & heap_attributes;
            const size = @intFromPtr(region.upper) - @intFromPtr(region.lower);
            const heap = for (into.memory_heaps[0..count]) |*heap| {
                if (heap.attributes == attributes) break heap;
            } else if (count < most_heaps) heap: {
                count += 1;
                into.memory_heaps[count - 1] = .{ .size = 0, .flags = facet.MEMORY_HEAP_DEVICE_LOCAL, .attributes = attributes };
                break :heap &into.memory_heaps[count - 1];
            } else continue;
            heap.size += size;
        }
        sys.UnlockExecList(exec.EXECLIST_MEMORY);
    }
    for (into.memory_heaps[0..count], into.memory_types[0..count], 0..) |heap, *memory_type, index| {
        memory_type.* = .{ .property_flags = memoryPropertiesOf(heap.attributes), .heap_index = @intCast(index) };
    }
    into.memory_types[count] = .{ .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, .heap_index = 0 };
    into.memory_heap_count = count;
    into.memory_type_count = count + 1;
}

/// What memory with these attributes is.
fn memoryPropertiesOf(attributes: u32) u32 {
    var flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_HOST_VISIBLE | facet.MEMORY_PROPERTY_HOST_COHERENT;
    if (attributes & exec.MEMF_EXTERNAL != 0) flags |= facet.MEMORY_PROPERTY_HOST_CACHED;
    if (attributes & exec.MEMF_DMA != 0) flags |= facet.MEMORY_PROPERTY_DMA;
    return flags;
}

fn allocateMemory(device: *Device, memory: *DeviceMemory) callconv(.c) facet.Result {
    const properties = &device.physical.memory;
    // Room to move the block up to a cache line: AllocMem's are aligned to
    // its chunks.
    const extra = _memory.alignment - exec.MEM_BLOCKSIZE;
    const bytes = std.math.cast(usize, memory.size) orelse 0;
    const attributes = properties.memory_heaps[properties.memory_types[memory.type_index].heap_index].attributes;
    const block = if (bytes != 0 and bytes <= std.math.maxInt(usize) - extra) device.sys.AllocMem(bytes + extra, attributes) else null;
    const taken: [*]u8 = @ptrCast(block orelse return .error_out_of_device_memory);
    memory.block = taken;
    memory.block_bytes = bytes + extra;
    memory.data = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(taken), _memory.alignment));
    return .success;
}

fn freeMemory(device: *Device, memory: *DeviceMemory) callconv(.c) void {
    device.sys.FreeMem(memory.block.?, memory.block_bytes);
}

fn makePipeline(pipeline: *Pipeline) callconv(.c) facet.Result {
    const made = _objects.create(pipeline.device.sys, _draw.RasterState) orelse return .error_out_of_host_memory;
    made.* = .{
        .cull = switch (pipeline.cull) {
            .none => .none,
            .back => .back,
            .front => .front,
        },
        .front = if (pipeline.front == .clockwise) .clockwise else .counter_clockwise,
        // The rasterizer's compares are numbered as facet.library's are.
        .depth_test = if (pipeline.depth_test) |compare| @enumFromInt(@intFromEnum(compare)) else null,
        .blend = undefined,
        .mixing = undefined,
    };
    // One translated state for each colour attachment of the subpass.
    for (&pipeline.mixings, &made.blend, &made.mixing) |*mixing, *blend, *translated| {
        blend.* = _draw.blendOf(mixing);
        translated.* = _draw.mixingOf(mixing);
    }
    pipeline.driver = made;
    return .success;
}

fn unmakePipeline(pipeline: *Pipeline) callconv(.c) void {
    _objects.destroy(pipeline.device.sys, pipeline.driver);
}

fn execute(queue: *Queue, buffer: *CommandBuffer, done: *exec.Waitable) callconv(.c) void {
    _play.play(queue, buffer);
    queue.device.sys.SignalWaitable(done);
}
