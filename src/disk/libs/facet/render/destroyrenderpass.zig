// SPDX-License-Identifier: MIT
//! DestroyRenderPass: a render pass given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _render = @import("_render.zig");

/// The render pass given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyRenderPass(base: *FacetBase, device: *facet.Device, render_pass: ?*facet.RenderPass) void
/// ```
///
/// SINCE: 1.0. LVO -208.
///
/// INPUTS:
/// - `device` - the device.
/// - `render_pass` - a render pass CreateRenderPass made, or null, which does
///   nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No command buffer still pending may have recorded it. The framebuffers
/// and pipelines made for it stay.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The render pass is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateRenderPass`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyRenderPass(device, pass);
/// ```
pub fn DestroyRenderPass(base: *FacetBase, device: *facet.Device, render_pass: ?*facet.RenderPass) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(_render.RenderPass, render_pass orelse return));
}
