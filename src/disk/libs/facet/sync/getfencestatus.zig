// SPDX-License-Identifier: MIT
//! GetFenceStatus: whether a fence is signalled.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Fence = @import("_sync.zig").Fence;

/// Whether a fence is signalled, without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn GetFenceStatus(base: *FacetBase, device: *facet.Device, fence: *facet.Fence) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -188.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `fence` - the fence.
///
/// RESULT:
/// `success` for a signalled fence, `not_ready` for one not yet;
/// `error_device_lost` once the device is lost.
///
/// BEHAVIOR:
/// Nothing changes: the fence stays as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes: it only reads.
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
/// `WaitForFences`
///
/// EXAMPLES:
/// ```zig
/// const ready = fb.GetFenceStatus(device, frame_done.?) == .success;
/// ```
pub fn GetFenceStatus(base: *FacetBase, device: *facet.Device, fence: *facet.Fence) facet.Result {
    _ = base;
    if (_objects.of(Device, device).isLost()) return .error_device_lost;
    const made = _objects.of(Fence, fence);
    return if (@atomicLoad(u32, &made.waitable.signalled, .acquire) != 0) .success else .not_ready;
}
