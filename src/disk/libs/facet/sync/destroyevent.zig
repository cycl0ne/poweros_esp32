// SPDX-License-Identifier: MIT
//! DestroyEvent: an event given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Event = @import("_sync.zig").Event;

/// The event given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyEvent(base: *FacetBase, device: *facet.Device, event: ?*facet.Event) void
/// ```
///
/// SINCE: 1.129. LVO -552.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `event` - the event, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No work still to be done may set it, reset it or wait for it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The event is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateEvent`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyEvent(device, uploaded);
/// ```
pub fn DestroyEvent(base: *FacetBase, device: *facet.Device, event: ?*facet.Event) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Event, event orelse return));
}
