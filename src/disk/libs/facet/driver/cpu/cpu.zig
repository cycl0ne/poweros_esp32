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
    .format_properties = &_format.properties,
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
    .timestamp_valid_bits = 0,
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
            .min_memory_map_alignment = _memory.alignment,
            .tile_size = raster.tile_size,
            .cores = @min(cores, raster.most_parts),
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
        .blend = _draw.blendOf(&pipeline.mixing),
        .mixing = _draw.mixingOf(&pipeline.mixing),
    };
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
