// SPDX-License-Identifier: MIT
//! SetEvent: an event set by the host.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _sync = @import("_sync.zig");

/// The event set by the host.
///
/// SYNOPSIS:
/// ```zig
/// fn SetEvent(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result
/// ```
///
/// SINCE: 1.129. LVO -560.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `event` - the event.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// The event is set at once, as lavapipe stores 1 (`lvp_SetEvent`,
/// lvp_device.c:2754-2762), and stays set until it is reset; one set
/// already stays as it is. A queue's task waiting for it in a
/// CmdWaitEvents is woken.
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
/// Vulkan has an event the host sets be set before the work that waits for
/// it is submitted (VUID-vkSetEvent-event-09543), and a CmdWaitEvents of
/// such an event have PIPELINE_STAGE_HOST in its source stages.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ResetEvent`, `GetEventStatus`, `CmdWaitEvents`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.SetEvent(device, uploaded.?);
/// ```
pub fn SetEvent(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result {
    _ = device;
    _sync.set(base.sys_base, _objects.of(_sync.Event, event));
    return .success;
}
