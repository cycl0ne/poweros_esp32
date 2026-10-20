// SPDX-License-Identifier: MIT
//! DestroyFence: a fence given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Fence = @import("_sync.zig").Fence;

/// The fence given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyFence(base: *FacetBase, device: *facet.Device, fence: ?*facet.Fence) void
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `fence` - the fence, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No submission still to be done may signal it, and no task may be
/// waiting on it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The fence is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateFence`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyFence(device, frame_done);
/// ```
pub fn DestroyFence(base: *FacetBase, device: *facet.Device, fence: ?*facet.Fence) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Fence, fence orelse return));
}
