// SPDX-License-Identifier: MIT
//! ResetFences: fences back to unsignalled.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Fence = @import("_sync.zig").Fence;

/// Fences back to unsignalled.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -184.
///
/// INPUTS:
/// - `device` - the device they were made on.
/// - `count`, `fences` - the fences.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// None of them may be waiting for a submission still to be done.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitForFences`, `CreateFence`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.WaitForFences(device, 1, @ptrCast(&frame_done), true, facet.WAIT_FOREVER_NS);
/// _ = fb.ResetFences(device, 1, @ptrCast(&frame_done));
/// ```
pub fn ResetFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence) facet.Result {
    _ = device;
    const sys = base.sys_base;
    for (fences[0..count]) |fence| sys.ResetWaitable(&_objects.of(Fence, fence).waitable);
    return .success;
}
