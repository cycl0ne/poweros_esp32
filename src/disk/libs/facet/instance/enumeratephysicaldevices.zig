// SPDX-License-Identifier: MIT
//! EnumeratePhysicalDevices: what an instance can draw with.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Instance = @import("_instance.zig").Instance;

/// The instance's physical devices.
///
/// SYNOPSIS:
/// ```zig
/// fn EnumeratePhysicalDevices(base: *FacetBase, instance: *facet.Instance, count: *u32, devices: ?[*]*facet.PhysicalDevice) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `instance` - the instance.
/// - `count` - with `devices`, how many it has room for; written with
///   how many there are, or with how many it was given.
/// - `devices` - where they go; null to count them alone.
///
/// RESULT:
/// `success`, or `incomplete` when `devices` was too short for them all.
///
/// BEHAVIOR:
/// There is one: the machine's cores, drawing through the rasterizer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A physical device is the instance's, and goes with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetPhysicalDeviceProperties`, `CreateDevice`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 1;
/// var physical: [1]*facet.PhysicalDevice = undefined;
/// _ = fb.EnumeratePhysicalDevices(instance, &count, &physical);
/// if (count == 0) return error.NoDevice;
/// ```
pub fn EnumeratePhysicalDevices(base: *FacetBase, instance: *facet.Instance, count: *u32, devices: ?[*]*facet.PhysicalDevice) facet.Result {
    _ = base;
    const made = _objects.of(Instance, instance);
    const listed = made.physicals[0..made.physical_count];
    const into = devices orelse {
        count.* = made.physical_count;
        return .success;
    };
    const given = @min(count.*, made.physical_count);
    for (into[0..given], listed[0..given]) |*device, *physical| device.* = _objects.handle(facet.PhysicalDevice, physical);
    count.* = given;
    return if (given < made.physical_count) .incomplete else .success;
}
