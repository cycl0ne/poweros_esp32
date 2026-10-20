// SPDX-License-Identifier: MIT
//! CreateFence: what a queue signals when work is done.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Fence = @import("_sync.zig").Fence;

/// A fence: signalled by a queue when the submission it came with is done.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateFence(base: *FacetBase, device: *facet.Device, info: *const facet.FenceCreateInfo, fence: *?*facet.Fence) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - FENCE_CREATE_SIGNALED for one that starts signalled.
/// - `fence` - where the fence is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A fence is an exec waitable (exec.Waitable): signalled, it stays so
/// until ResetFences.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The fence is the caller's, until DestroyFence.
///
/// NOTES:
/// A fence made signalled lets a frame loop wait for the frame before
/// from its very first frame on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitForFences`, `ResetFences`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// var frame_done: ?*facet.Fence = null;
/// if (fb.CreateFence(device, &.{ .flags = facet.FENCE_CREATE_SIGNALED }, &frame_done) != .success) return error.NoFence;
/// ```
pub fn CreateFence(base: *FacetBase, device: *facet.Device, info: *const facet.FenceCreateInfo, fence: *?*facet.Fence) facet.Result {
    _ = device;
    fence.* = null;
    const sys = base.sys_base;
    const made = _objects.create(sys, Fence) orelse return .error_out_of_host_memory;
    made.* = .{};
    if (info.flags & facet.FENCE_CREATE_SIGNALED != 0) sys.SignalWaitable(&made.waitable);
    fence.* = _objects.handle(facet.Fence, made);
    return .success;
}
