// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceSurfaceSupport: whether a queue family can present to a surface.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;

/// Whether queue family `family` can present to the surface, into `supported`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceSurfaceSupport(base: *FacetBase, physical: *facet.PhysicalDevice, family: u32, surface: *facet.Surface, supported: *bool) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -328.
///
/// INPUTS:
/// - `physical` - the physical device.
/// - `family` - a queue family of it.
/// - `surface` - the surface.
/// - `supported` - true where the family's queues can present to it.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// The one queue family can present to a surface whose pixels
/// facet.library draws in: 32 bits, in either order of red and blue.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetPhysicalDeviceSurfaceFormats`, `QueuePresent`
///
/// EXAMPLES:
/// ```zig
/// var supported = false;
/// _ = fb.GetPhysicalDeviceSurfaceSupport(physical, 0, surface.?, &supported);
/// if (!supported) return error.CannotShow;
/// ```
pub fn GetPhysicalDeviceSurfaceSupport(base: *FacetBase, physical: *facet.PhysicalDevice, family: u32, surface: *facet.Surface, supported: *bool) facet.Result {
    _ = base;
    _ = physical;
    const made = _objects.of(Surface, surface);
    supported.* = family == 0 and _surface.drawable(made.ops.shape(made).format);
    return .success;
}
