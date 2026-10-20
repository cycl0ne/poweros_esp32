// SPDX-License-Identifier: MIT
//! DestroyImageView: a view given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const ImageView = @import("_image.zig").ImageView;

/// The view given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyImageView(base: *FacetBase, device: *facet.Device, view: ?*facet.ImageView) void
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `device` - the device its image was made on.
/// - `view` - the view, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No work the queue has not finished may use it, nor a framebuffer or a
/// descriptor set still in use. The image stays as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The view is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImageView`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyImageView(device, view);
/// ```
pub fn DestroyImageView(base: *FacetBase, device: *facet.Device, view: ?*facet.ImageView) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(ImageView, view orelse return));
}
