// SPDX-License-Identifier: MIT
//! An instance and the physical devices it lists: one for each driver
//! whose hardware the machine has (driver/_driver.zig). Each is described
//! as the instance is made, and keeps what its driver found for as long as
//! the instance lasts.

const sdk = @import("sdk");
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _driver = @import("../driver/_driver.zig");

pub const Instance = struct {
    base: *FacetBase,
    /// The physical devices listed, the first `physical_count` of these.
    physicals: [_driver.drivers.len]PhysicalDevice,
    physical_count: u32 = 0,
    /// The devices and the surfaces made from it and not yet destroyed.
    devices: u32 = 0,
    surfaces: u32 = 0,
};

pub const PhysicalDevice = struct {
    instance: *Instance,
    /// Its driver, and what the driver said of it.
    ops: *const _driver.Ops,
    properties: facet.PhysicalDeviceProperties,
    queue_family: facet.QueueFamilyProperties,
    memory: facet.PhysicalDeviceMemoryProperties,
};

/// The most vertex buffers, attributes and floats a vertex function hands
/// on, and what the rest of the limits are: what the library's own objects
/// have room for, whatever the driver.
pub const max_vertex_input_bindings = 4;
pub const max_vertex_input_attributes = 8;
pub const max_vertex_output_components = 8;
pub const max_push_constants_size = 128;
pub const max_bound_descriptor_sets = 4;
pub const max_image_dimension = 8192;

/// The physical devices of `instance` described, each driver asked in turn.
pub fn describe(sys: *ExecBase, instance: *Instance) void {
    for (_driver.drivers) |ops| {
        const physical = &instance.physicals[instance.physical_count];
        physical.instance = instance;
        physical.ops = ops;
        if (ops.describe(sys, physical)) instance.physical_count += 1;
    }
}
