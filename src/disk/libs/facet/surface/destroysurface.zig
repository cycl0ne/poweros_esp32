// SPDX-License-Identifier: MIT
//! DestroySurface: a surface given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;

/// The surface given back: every swapchain made on it destroyed first.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroySurface(base: *FacetBase, instance: *facet.Instance, surface: ?*facet.Surface) void
/// ```
///
/// SINCE: 1.0. LVO -324.
///
/// INPUTS:
/// - `instance` - the instance it was made from.
/// - `surface` - the surface; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The libraries it opened are closed. A surface with a swapchain left is
/// kept as it is, and said so on the debug output.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The screen or window it was over stays open: it is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateScreenSurface`, `CreateWindowSurface`, `DestroySwapchain`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroySurface(instance, surface);
/// ```
pub fn DestroySurface(base: *FacetBase, instance: *facet.Instance, surface: ?*facet.Surface) void {
    _ = instance;
    const made = _objects.of(Surface, surface orelse return);
    const sys = base.sys_base;
    if (made.swapchains != 0) {
        sdk.exec.kprintf(sys, "facet.library: a surface destroyed with %ld swapchains left, kept\n", .{@as(i64, made.swapchains)});
        return;
    }
    made.ops.close(made);
    made.instance.surfaces -= 1;
    _objects.destroy(sys, made);
}
