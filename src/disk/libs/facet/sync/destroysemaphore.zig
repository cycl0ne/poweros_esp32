// SPDX-License-Identifier: MIT
//! DestroySemaphore: a semaphore given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Semaphore = @import("_sync.zig").Semaphore;

/// The semaphore given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroySemaphore(base: *FacetBase, device: *facet.Device, semaphore: ?*facet.Semaphore) void
/// ```
///
/// SINCE: 1.0. LVO -200.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `semaphore` - the semaphore, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No submission still to be done may wait for it or signal it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The semaphore is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSemaphore`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroySemaphore(device, drawn);
/// ```
pub fn DestroySemaphore(base: *FacetBase, device: *facet.Device, semaphore: ?*facet.Semaphore) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Semaphore, semaphore orelse return));
}
