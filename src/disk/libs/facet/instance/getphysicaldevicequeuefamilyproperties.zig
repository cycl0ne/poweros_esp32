// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceQueueFamilyProperties: the queues a device can have.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

/// The physical device's queue families.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceQueueFamilyProperties(base: *FacetBase, physical: *facet.PhysicalDevice, count: *u32, properties: ?[*]facet.QueueFamilyProperties) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `count` - with `properties`, how many it has room for; written with
///   how many there are, or with how many it was given.
/// - `properties` - where they go; null to count them alone.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// There is one family, 0: QUEUE_GRAPHICS and QUEUE_TRANSFER, with one
/// queue. Its queue plays command buffers on a task of its own and
/// shares each frame's tiles between the cores.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `properties` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDevice`, `GetDeviceQueue`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 1;
/// var family: [1]facet.QueueFamilyProperties = undefined;
/// fb.GetPhysicalDeviceQueueFamilyProperties(physical, &count, &family);
/// ```
pub fn GetPhysicalDeviceQueueFamilyProperties(base: *FacetBase, physical: *facet.PhysicalDevice, count: *u32, properties: ?[*]facet.QueueFamilyProperties) void {
    _ = base;
    const into = properties orelse {
        count.* = 1;
        return;
    };
    if (count.* == 0) return;
    into[0] = _objects.of(PhysicalDevice, physical).queue_family;
    count.* = 1;
}
