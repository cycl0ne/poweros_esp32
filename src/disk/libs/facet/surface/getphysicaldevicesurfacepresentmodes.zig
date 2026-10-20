// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceSurfacePresentModes: when a surface takes up what is presented.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// The present modes of the surface into `modes`, at most `count.*` of
/// them, and how many there are into `count`; null for `modes` counts
/// alone.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceSurfacePresentModes(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, modes: ?[*]facet.PresentMode) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -340.
///
/// INPUTS:
/// - `physical` - the physical device.
/// - `surface` - the surface.
/// - `count` - how many `modes` has room for; how many were written.
/// - `modes` - where they go, or null.
///
/// RESULT:
/// `success`, or `incomplete` when `modes` was too short.
///
/// BEHAVIOR:
/// Every surface has `fifo`, and only that: each image presented is shown
/// from the display's next frame on, in the order they were presented, and
/// none is left out. A program drawing faster than the display shows is
/// held to its rate.
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
/// `QueuePresent`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 1;
/// var mode: facet.PresentMode = undefined;
/// _ = fb.GetPhysicalDeviceSurfacePresentModes(physical, surface.?, &count, @ptrCast(&mode));
/// ```
pub fn GetPhysicalDeviceSurfacePresentModes(base: *FacetBase, physical: *facet.PhysicalDevice, surface: *facet.Surface, count: *u32, modes: ?[*]facet.PresentMode) facet.Result {
    _ = base;
    _ = physical;
    _ = surface;
    const into = modes orelse {
        count.* = 1;
        return .success;
    };
    if (count.* == 0) return .incomplete;
    into[0] = .fifo;
    count.* = 1;
    return .success;
}
