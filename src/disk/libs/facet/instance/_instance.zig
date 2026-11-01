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
const cpu = @import("../driver/cpu/cpu.zig");

pub const Instance = struct {
    base: *FacetBase,
    /// The physical devices listed, the first `physical_count` of these.
    physicals: [1 + _driver.most_modules]PhysicalDevice,
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
/// The vertices of a tessellated patch.
pub const max_patch_points = 32;
pub const max_push_constants_size = 128;
pub const max_bound_descriptor_sets = 4;
pub const max_image_dimension = 8192;
pub const max_image_dimension_3d = 256;
pub const max_image_array_layers = 256;

/// The most vertices a draw works, the lowest it reads to the highest. Both
/// drivers hold to it: a draw of more is left out of the frame and said to be,
/// and a CmdDraw whose own count is over it is refused as it is recorded.
pub const max_draw_vertices = 1 << 20;

/// The physical devices of `instance` described: the cores' first, then each
/// module's that finds its hardware.
pub fn describe(base: *FacetBase, instance: *Instance) void {
    const sys = base.sys_base;
    _driver.lookForModules(base);
    describeOne(sys, instance, &cpu.ops);
    for (base.module_ops[0..base.module_count]) |ops| describeOne(sys, instance, @ptrCast(@alignCast(ops.?)));
}

fn describeOne(sys: *ExecBase, instance: *Instance, ops: *const _driver.Ops) void {
    const physical = &instance.physicals[instance.physical_count];
    physical.instance = instance;
    physical.ops = ops;
    if (ops.describe(sys, physical)) instance.physical_count += 1;
}
