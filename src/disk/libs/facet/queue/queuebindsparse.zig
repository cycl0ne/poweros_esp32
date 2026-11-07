// SPDX-License-Identifier: MIT
//! QueueBindSparse: memory bound to sparse buffers and images, by a queue.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// Memory bound to sparse buffers and images, in batches, by the queue:
/// refused, no queue family binding sparse memory.
///
/// SYNOPSIS:
/// ```zig
/// fn QueueBindSparse(base: *FacetBase, queue: *facet.Queue, count: u32, binds: ?[*]const facet.BindSparseInfo, fence: ?*facet.Fence) facet.Result
/// ```
///
/// SINCE: 1.124. LVO -544.
///
/// INPUTS:
/// - `queue` - the queue.
/// - `count`, `binds` - the batches: for each, the semaphores it waits
///   for, the ranges and blocks it binds and the semaphores it signals.
/// - `fence` - would be signalled when they are bound; may be null.
///
/// RESULT:
/// `error_feature_not_present`, and nothing bound, waited for or
/// signalled.
///
/// BEHAVIOR:
/// Vulkan has the queue be of a family with `QUEUE_SPARSE_BINDING`
/// (VUID-vkQueueBindSparse-queuetype), and no family of either device has
/// it, `sparse_binding` being false; so no call a program may make reaches
/// here, and one that does is answered as v3dv answers it
/// (`v3dv_QueueBindSparse`, v3dv_queue.c:1170-1178). That code is not
/// one of the call's own, a lost device and no memory, which are for calls
/// a program may make. Vulkan has the call carried all the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The batches and the fence stay the caller's, and are not read.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QueueSubmit`, `GetPhysicalDeviceQueueFamilyProperties`
///
/// EXAMPLES:
/// ```zig
/// const refused = fb.QueueBindSparse(queue, 0, null, null);
/// ```
pub fn QueueBindSparse(base: *FacetBase, queue: *facet.Queue, count: u32, binds: ?[*]const facet.BindSparseInfo, fence: ?*facet.Fence) facet.Result {
    _ = base;
    _ = queue;
    _ = count;
    _ = binds;
    _ = fence;
    return .error_feature_not_present;
}
