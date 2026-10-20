// SPDX-License-Identifier: MIT
//! An instance and the one physical device it lists: the machine's cores,
//! drawing through the rasterizer. The device is described as the
//! instance is made - its cores counted, its memory types made from the
//! regions exec has then - and keeps what it found for as long as the
//! instance lasts.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const raster = @import("raster");
const ExecBase = sdk.interface.exec.ExecBase;
const FacetBase = @import("../facet_base.zig").FacetBase;
const facet_init = @import("../facet_init.zig");
const _memory = @import("../memory/_memory.zig");

pub const Instance = struct {
    base: *FacetBase,
    physical: PhysicalDevice,
    /// The devices and the surfaces made from it and not yet destroyed.
    devices: u32 = 0,
    surfaces: u32 = 0,
};

pub const PhysicalDevice = struct {
    instance: *Instance,
    properties: facet.PhysicalDeviceProperties,
    memory: facet.PhysicalDeviceMemoryProperties,
};

/// The most vertex buffers, attributes and floats a vertex function hands
/// on, and what the rest of the limits are.
pub const max_vertex_input_bindings = 4;
pub const max_vertex_input_attributes = 8;
pub const max_vertex_output_components = 8;
pub const max_push_constants_size = 128;
pub const max_bound_descriptor_sets = 4;
pub const max_image_dimension = 8192;

/// The one queue family: drawing and copying, one queue.
pub const queue_family: facet.QueueFamilyProperties = .{
    .queue_flags = facet.QUEUE_GRAPHICS | facet.QUEUE_TRANSFER,
    .queue_count = 1,
    .timestamp_valid_bits = 0,
    .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
};

/// The physical device of `instance` described.
pub fn describe(sys: *ExecBase, instance: *Instance) void {
    const physical = &instance.physical;
    const cores = runningCores(sys);
    physical.* = .{
        .instance = instance,
        .properties = .{
            .api_version = facet.API_VERSION_1_0,
            .driver_version = facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION),
            .vendor_id = 0,
            .device_id = 0,
            .device_type = .cpu,
            .device_name = @splat(0),
            .limits = .{
                .max_image_dimension_2d = max_image_dimension,
                .max_framebuffer_width = max_image_dimension,
                .max_framebuffer_height = max_image_dimension,
                .max_color_attachments = 1,
                .max_vertex_input_bindings = max_vertex_input_bindings,
                .max_vertex_input_attributes = max_vertex_input_attributes,
                .max_vertex_input_binding_stride = 2048,
                .max_vertex_output_components = max_vertex_output_components,
                .max_push_constants_size = max_push_constants_size,
                .max_bound_descriptor_sets = max_bound_descriptor_sets,
                .max_per_stage_descriptor_sampled_images = 16,
                .max_per_stage_descriptor_uniform_buffers = 12,
                .min_memory_map_alignment = _memory.alignment,
                .tile_size = raster.tile_size,
                .cores = @min(cores, raster.most_parts),
            },
        },
        .memory = undefined,
    };
    const shared = physical.properties.limits.cores;
    _ = std.fmt.bufPrint(physical.properties.device_name[0 .. facet.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1], "facet.library rasterizer, {d} core{s}", .{ shared, if (shared == 1) "" else "s" }) catch {};
    _memory.describe(sys, &physical.memory);
}

/// The cores running now: those whose times exec can read.
fn runningCores(sys: *ExecBase) u32 {
    var times: exec.CoreTimes = undefined;
    var count: u32 = 0;
    while (count < 32 and sys.ReadCoreTimes(count, &times)) count += 1;
    return @max(count, 1);
}
