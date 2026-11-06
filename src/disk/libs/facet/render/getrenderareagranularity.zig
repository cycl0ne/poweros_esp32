// SPDX-License-Identifier: MIT
//! GetRenderAreaGranularity: the render area the device draws whole.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;

/// The granularity of a render area on this device: the tile it draws in.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRenderAreaGranularity(base: *FacetBase, device: *facet.Device, pass: *facet.RenderPass, granularity: *facet.Extent2D) void
/// ```
///
/// SINCE: 1.36. LVO -508.
///
/// INPUTS:
/// - `device` - the device the pass is drawn on.
/// - `pass` - a render pass. Every pass of a device has the same answer.
/// - `granularity` - where the width and the height are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A render area whose offset is a multiple of this and whose extent is
/// too - or which reaches the framebuffer's edge - costs nothing that a
/// whole-framebuffer area would not: the device draws in tiles of this
/// size, and a tile the area touches at all is drawn. An area inside one
/// tile is as dear as that whole tile.
///
/// It is the device's tile, `PhysicalDeviceLimits.tile_size` square: the
/// cores' rasterizer and the V3D both draw a frame tile by tile. The
/// render pass makes no difference to it, and is asked for because
/// Vulkan asks for it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `granularity` is the caller's.
///
/// NOTES:
/// What a render area narrower than the framebuffer does save is the
/// pixels drawn, and the tiles it does not touch at all.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginRenderPass`, `GetPhysicalDeviceProperties`
///
/// EXAMPLES:
/// ```zig
/// var granularity: facet.Extent2D = undefined;
/// fb.GetRenderAreaGranularity(device, pass.?, &granularity);
/// // The area rounded out to whole tiles.
/// const left = x / granularity.width * granularity.width;
/// _ = left;
/// ```
pub fn GetRenderAreaGranularity(base: *FacetBase, device: *facet.Device, pass: *facet.RenderPass, granularity: *facet.Extent2D) void {
    _ = base;
    _ = pass;
    const tile = _objects.of(Device, device).physical.tile_size;
    granularity.* = .{ .width = tile, .height = tile };
}
