// SPDX-License-Identifier: MIT
//! CreateSemaphore: what one submission signals and another waits for.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Semaphore = @import("_sync.zig").Semaphore;

/// A semaphore: signalled by one submission, waited for by another.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateSemaphore(base: *FacetBase, device: *facet.Device, info: *const facet.SemaphoreCreateInfo, semaphore: *?*facet.Semaphore) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -196.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - 0 for its flags.
/// - `semaphore` - where the semaphore is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A semaphore is an exec waitable, unsignalled at first. A submission
/// that waits for it takes the signal: each signal lets one go.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The semaphore is the caller's, until DestroySemaphore.
///
/// NOTES:
/// What a swapchain's image becoming free signals, and a frame's drawing
/// waits for before it starts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroySemaphore`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// var drawn: ?*facet.Semaphore = null;
/// if (fb.CreateSemaphore(device, &.{}, &drawn) != .success) return error.NoSemaphore;
/// ```
pub fn CreateSemaphore(base: *FacetBase, device: *facet.Device, info: *const facet.SemaphoreCreateInfo, semaphore: *?*facet.Semaphore) facet.Result {
    _ = info;
    _ = device;
    semaphore.* = null;
    const made = _objects.create(base.sys_base, Semaphore) orelse return .error_out_of_host_memory;
    made.* = .{};
    semaphore.* = _objects.handle(facet.Semaphore, made);
    return .success;
}
