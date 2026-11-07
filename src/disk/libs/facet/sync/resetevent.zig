// SPDX-License-Identifier: MIT
//! ResetEvent: an event reset by the host.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _sync = @import("_sync.zig");

/// The event reset by the host.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetEvent(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result
/// ```
///
/// SINCE: 1.129. LVO -564.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `event` - the event.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// The event is reset at once, as lavapipe stores 0 (`lvp_ResetEvent`,
/// lvp_device.c:2764-2772); one not set stays as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// No CmdWaitEvents of the event may still be waiting: Vulkan has the
/// program know that work is done first (VUID-vkResetEvent-event-03821).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetEvent`, `GetEventStatus`, `CmdResetEvent`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.ResetEvent(device, uploaded.?);
/// ```
pub fn ResetEvent(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result {
    _ = device;
    _sync.reset(base.sys_base, _objects.of(_sync.Event, event));
    return .success;
}
