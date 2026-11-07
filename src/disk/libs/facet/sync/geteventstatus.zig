// SPDX-License-Identifier: MIT
//! GetEventStatus: whether an event is set.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Event = @import("_sync.zig").Event;

/// Whether an event is set, without waiting: `event_set` or `event_reset`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetEventStatus(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result
/// ```
///
/// SINCE: 1.129. LVO -556.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `event` - the event.
///
/// RESULT:
/// `event_set` for a set event, `event_reset` for one that is not;
/// `error_device_lost` once the device is lost, as v3dv answers
/// (`v3dv_GetEventStatus`, v3dv_event.c:451-459).
///
/// BEHAVIOR:
/// Nothing changes: the event stays as it is. What a command buffer still
/// being played sets or resets may change it as soon as this returns.
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
/// Vulkan has no call that waits on the host for an event: a program
/// that has to asks this until it is set, or waits for a fence.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetEvent`, `ResetEvent`, `CmdSetEvent`
///
/// EXAMPLES:
/// ```zig
/// const done = fb.GetEventStatus(device, uploaded.?) == .event_set;
/// ```
pub fn GetEventStatus(base: *FacetBase, device: *facet.Device, event: *facet.Event) facet.Result {
    _ = base;
    if (_objects.of(Device, device).isLost()) return .error_device_lost;
    const made = _objects.of(Event, event);
    return if (@atomicLoad(u32, &made.waitable.signalled, .acquire) != 0) .event_set else .event_reset;
}
