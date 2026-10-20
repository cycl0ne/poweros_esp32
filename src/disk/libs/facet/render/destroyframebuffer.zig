// SPDX-License-Identifier: MIT
//! DestroyFramebuffer: a framebuffer given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _render = @import("_render.zig");

/// The framebuffer given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyFramebuffer(base: *FacetBase, device: *facet.Device, framebuffer: ?*facet.Framebuffer) void
/// ```
///
/// SINCE: 1.0. LVO -216.
///
/// INPUTS:
/// - `device` - the device.
/// - `framebuffer` - a framebuffer CreateFramebuffer made, or null, which
///   does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No command buffer still pending may draw into it. Its views stay.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The framebuffer is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateFramebuffer`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyFramebuffer(device, frame);
/// ```
pub fn DestroyFramebuffer(base: *FacetBase, device: *facet.Device, framebuffer: ?*facet.Framebuffer) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(_render.Framebuffer, framebuffer orelse return));
}
