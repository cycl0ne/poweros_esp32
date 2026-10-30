// SPDX-License-Identifier: MIT
//! The second driver: the BCM2712's V3D 7.1, the 3D core of its VideoCore
//! VII. What knows the hardware is the module `v3d` (v3d.zig), compiled into
//! the library as the rasterizer is; this is its table, and `_play.zig` a
//! command buffer made into its control lists.
//!
//! The board part is what finds it: where the machine has no such part the
//! instance lists no device of it. It is switched on when a device first
//! wants it, and what that makes - the MMU's table, the interrupts, the
//! programs - stays while any queue or block of memory is left, in the one
//! `Hardware` all the instances of the library share. It goes back to
//! nothing but stays powered: a second power-up after a power-down halted
//! the machine.
//!
//! Vertex functions stay the program's, and run on the cores; pixels are the
//! V3D's, and it has a program for each fixed form of fragment function
//! (shader.Fixed), so a pipeline with another fragment function is refused.
//!
//! **Its memory is one heap**, what DMA reaches, each block mapped for the
//! V3D as it is allocated. Only what the V3D reads has to reach it: vertices
//! and uniforms go out as a frame is sent (`_play.zig`), texels as they are
//! copied in, and an image drawn into is written back before and dropped
//! from the caches after, so that for a program the type is coherent.
//! Textures lie in the V3D's own layout (`tiling.zig`).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const v3d = @import("v3d");
const ExecBase = sdk.interface.exec.ExecBase;
const facet_init = @import("../../facet_init.zig");
const FacetBase = @import("../../facet_base.zig").FacetBase;
const _objects = @import("../../_objects.zig");
const _instance = @import("../../instance/_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;
const Device = @import("../../device/_device.zig").Device;
const _memory = @import("../../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;
const Pipeline = @import("../../pipeline/_pipeline.zig").Pipeline;
const Queue = @import("../../queue/_queue.zig").Queue;
const CommandBuffer = @import("../../command/_command.zig").CommandBuffer;
const _driver = @import("../_driver.zig");
const cpu = @import("../cpu/cpu.zig");
const _play = @import("_play.zig");
const qpu = v3d.qpu;
const tiling = v3d.tiling;
const Block = v3d.Block;

pub const ops = _driver.Ops{
    .describe = &describe,
    .format_properties = cpu.ops.format_properties,
    .allocate_memory = &allocateMemory,
    .free_memory = &freeMemory,
    .make_pipeline = &makePipeline,
    .unmake_pipeline = &unmakePipeline,
    .open_queue = &_play.open,
    .close_queue = &_play.close,
    .execute = &execute,
    .texture_memory = &textureMemory,
    .picture_memory = exec.MEMF_DMA,
};

/// Where the programs are on the V3D.
pub const Programs = struct {
    coordinate: u32,
    vertex: [qpu.most_varyings + 1]u32,
    color: u32,
    texture: u32,
    texture_color: u32,
};

/// What the V3D has while anything uses it. Its job, and its table, are
/// one at a time: both are taken under `FacetBase.v3d_lock`.
pub const Hardware = struct {
    gpu: v3d.Gpu,
    space: v3d.Space,
    engine: v3d.Engine,
    /// The queues and the blocks of memory that hold it.
    users: u32,
    programs_block: Block,
    programs: Programs,
    /// The table has changed since the MMU last read it.
    stale: bool = false,
    /// A job faulted or never ended. Nothing more is sent: what comes after
    /// it would be drawn over what it left.
    broken: bool = false,
};

fn describe(sys: *ExecBase, physical: *PhysicalDevice) bool {
    if (v3d.Gpu.find(sys) == null) return false;
    physical.properties = .{
        .api_version = facet.API_VERSION_1_0,
        .driver_version = facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION),
        .vendor_id = 0x14E4,
        .device_id = 0x2712,
        .device_type = .integrated_gpu,
        .device_name = @splat(0),
        .limits = .{
            .max_image_dimension_2d = _instance.max_image_dimension,
            .max_framebuffer_width = _instance.max_image_dimension,
            .max_framebuffer_height = _instance.max_image_dimension,
            .max_color_attachments = 1,
            .max_vertex_input_bindings = _instance.max_vertex_input_bindings,
            .max_vertex_input_attributes = _instance.max_vertex_input_attributes,
            .max_vertex_input_binding_stride = 2048,
            .max_vertex_output_components = _instance.max_vertex_output_components,
            .max_push_constants_size = _instance.max_push_constants_size,
            .max_bound_descriptor_sets = _instance.max_bound_descriptor_sets,
            .max_per_stage_descriptor_sampled_images = 1,
            .max_per_stage_descriptor_uniform_buffers = 12,
            .min_memory_map_alignment = _memory.alignment,
            .tile_size = v3d.frame.tile_pixels,
            .cores = 1,
        },
    };
    const name = "VideoCore VII V3D 7.1";
    @memcpy(physical.properties.device_name[0..name.len], name);
    physical.queue_family = .{
        .queue_flags = facet.QUEUE_GRAPHICS | facet.QUEUE_TRANSFER,
        .queue_count = 1,
        .timestamp_valid_bits = 0,
        .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
    };
    describeMemory(sys, &physical.memory);
    return true;
}

/// The one heap and its type, and the type with nothing behind it.
fn describeMemory(sys: *ExecBase, into: *facet.PhysicalDeviceMemoryProperties) void {
    into.* = std.mem.zeroes(facet.PhysicalDeviceMemoryProperties);
    var size: u64 = 0;
    if (sys.LockExecList(exec.EXECLIST_MEMORY)) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const region: *const exec.MemHeader = @fieldParentPtr("node", node);
            if (region.attributes & exec.MEMF_DMA != 0) size += @intFromPtr(region.upper) - @intFromPtr(region.lower);
        }
        sys.UnlockExecList(exec.EXECLIST_MEMORY);
    }
    into.memory_heaps[0] = .{ .size = size, .flags = facet.MEMORY_HEAP_DEVICE_LOCAL, .attributes = exec.MEMF_DMA };
    into.memory_types[0] = .{
        .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_HOST_VISIBLE | facet.MEMORY_PROPERTY_HOST_COHERENT | facet.MEMORY_PROPERTY_HOST_CACHED | facet.MEMORY_PROPERTY_DMA,
        .heap_index = 0,
    };
    into.memory_types[1] = .{ .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, .heap_index = 0 };
    into.memory_heap_count = 1;
    into.memory_type_count = 2;
}

/// The V3D held once more, switched on if this is the first; null when it
/// cannot be had.
pub fn hold(base: *FacetBase) ?*Hardware {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.v3d_lock);
    defer sys.ReleaseSemaphore(&base.v3d_lock);
    if (base.v3d) |made| {
        const hardware: *Hardware = @ptrCast(@alignCast(made));
        hardware.users += 1;
        return hardware;
    }
    const hardware = _objects.create(sys, Hardware) orelse return null;
    if (!bringUp(sys, hardware)) {
        _objects.destroy(sys, hardware);
        return null;
    }
    base.v3d = hardware;
    return hardware;
}

fn bringUp(sys: *ExecBase, hardware: *Hardware) bool {
    hardware.users = 1;
    hardware.stale = false;
    hardware.broken = false;
    hardware.gpu = v3d.Gpu.find(sys) orelse return false;
    hardware.gpu.powerUp() catch return false;
    const ident = hardware.gpu.identify();
    hardware.space = v3d.Space.open(&hardware.gpu) orelse return false;
    if (!hardware.engine.start(&hardware.gpu, &hardware.space, ident.virtual_bits)) {
        hardware.space.close();
        return false;
    }
    if (!loadPrograms(hardware)) {
        hardware.engine.stop();
        hardware.space.close();
        return false;
    }
    return true;
}

/// Every program in one block of the V3D's.
fn loadPrograms(hardware: *Hardware) bool {
    const fragments = [_]*const qpu.Fragment{ &qpu.color_fragment, &qpu.texture_fragment, &qpu.texture_color_fragment };
    var words: usize = qpu.coordinate_program.len;
    for (0..qpu.most_varyings + 1) |varyings| words += qpu.vertexProgram(@intCast(varyings)).len;
    for (fragments) |fragment| words += fragment.code.len;
    const block = hardware.space.alloc(@intCast(words * 8)) orelse return false;
    if (!hardware.space.flush()) {
        var given_back = block;
        hardware.space.free(&given_back);
        return false;
    }
    var used: u32 = 0;
    const put = struct {
        fn program(at: Block, offset: *u32, code: []const u64) u32 {
            const into: [*]u64 = @ptrCast(@alignCast(at.cpu + offset.*));
            @memcpy(into[0..code.len], code);
            const address = at.address + offset.*;
            offset.* += @intCast(code.len * 8);
            return address;
        }
    }.program;
    hardware.programs.coordinate = put(block, &used, &qpu.coordinate_program);
    for (&hardware.programs.vertex, 0..) |*address, varyings| address.* = put(block, &used, qpu.vertexProgram(@intCast(varyings)));
    hardware.programs.color = put(block, &used, qpu.color_fragment.code);
    hardware.programs.texture = put(block, &used, qpu.texture_fragment.code);
    hardware.programs.texture_color = put(block, &used, qpu.texture_color_fragment.code);
    hardware.space.toGpu(&block);
    hardware.programs_block = block;
    return true;
}

/// The V3D let go of once, what it holds given back with the last. The core
/// stays powered and its clock running.
pub fn letGo(base: *FacetBase, hardware: *Hardware) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.v3d_lock);
    defer sys.ReleaseSemaphore(&base.v3d_lock);
    hardware.users -= 1;
    if (hardware.users != 0) return;
    hardware.space.free(&hardware.programs_block);
    hardware.engine.stop();
    hardware.space.close();
    base.v3d = null;
    _objects.destroy(sys, hardware);
}

fn allocateMemory(device: *Device, memory: *DeviceMemory) facet.Result {
    const bytes = std.math.cast(u32, memory.size) orelse return .error_out_of_device_memory;
    if (bytes == 0) return .error_out_of_device_memory;
    const base = device.base;
    const sys = device.sys;
    const kept = _objects.create(sys, Block) orelse return .error_out_of_host_memory;
    const hardware = hold(base) orelse {
        _objects.destroy(sys, kept);
        return .error_initialization_failed;
    };
    sys.ObtainSemaphore(&base.v3d_lock);
    const block = hardware.space.alloc(bytes);
    if (block != null) hardware.stale = true;
    sys.ReleaseSemaphore(&base.v3d_lock);
    kept.* = block orelse {
        letGo(base, hardware);
        _objects.destroy(sys, kept);
        return .error_out_of_device_memory;
    };
    memory.block = @ptrCast(kept);
    memory.block_bytes = 0;
    memory.data = kept.cpu;
    return .success;
}

fn freeMemory(device: *Device, memory: *DeviceMemory) void {
    const base = device.base;
    const sys = device.sys;
    const kept: *Block = @ptrCast(@alignCast(memory.block.?));
    const hardware: *Hardware = @ptrCast(@alignCast(base.v3d.?));
    sys.ObtainSemaphore(&base.v3d_lock);
    hardware.space.free(kept);
    hardware.stale = true;
    sys.ReleaseSemaphore(&base.v3d_lock);
    _objects.destroy(sys, kept);
    letGo(base, hardware);
}

fn makePipeline(pipeline: *Pipeline) facet.Result {
    const fixed = pipeline.fixed;
    if (fixed.kind == .none or pipeline.varyings != fixed.varyings()) return .error_feature_not_present;
    return .success;
}

fn unmakePipeline(pipeline: *Pipeline) void {
    _ = pipeline;
}

/// The queue's task blocks in the frame's jobs, on what the V3D's interrupts
/// signal, so the buffer's work is done by the time this signals.
fn execute(queue: *Queue, buffer: *CommandBuffer, done: *exec.Waitable) void {
    _play.play(queue, buffer);
    queue.device.sys.SignalWaitable(done);
}

fn textureMemory(format: facet.Format, width: u32, height: u32, levels: u32) _driver.TextureMemory {
    const layout = _play.layoutOf(format, width, height, levels);
    return .{ .bytes = layout.bytes, .alignment = tiling.alignment };
}
