// SPDX-License-Identifier: MIT
//! CreateEvent: what the host or a queue's work sets, and a queue's work
//! waits for.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Event = @import("_sync.zig").Event;

/// An event, reset: set by the host or by a queue's work, and waited for by
/// a queue's work.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateEvent(base: *FacetBase, device: *facet.Device, info: *const facet.EventCreateInfo, event: *?*facet.Event) facet.Result
/// ```
///
/// SINCE: 1.129. LVO -548.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - 0 for its flags.
/// - `event` - where the event is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// An event is an exec waitable, unsignalled at first, as lavapipe's
/// starts at 0 (`lvp_CreateEvent`, lvp_device.c:2708-2727). It stays set
/// until it is reset: a wait does not take it, as one for a semaphore
/// does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The event is the caller's, until DestroyEvent.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyEvent`, `SetEvent`, `CmdSetEvent`, `CmdWaitEvents`
///
/// EXAMPLES:
/// ```zig
/// var uploaded: ?*facet.Event = null;
/// if (fb.CreateEvent(device, &.{}, &uploaded) != .success) return error.NoEvent;
/// ```
pub fn CreateEvent(base: *FacetBase, device: *facet.Device, info: *const facet.EventCreateInfo, event: *?*facet.Event) facet.Result {
    _ = info;
    _ = device;
    event.* = null;
    const made = _objects.create(base.sys_base, Event) orelse return .error_out_of_host_memory;
    made.* = .{};
    event.* = _objects.handle(facet.Event, made);
    return .success;
}
