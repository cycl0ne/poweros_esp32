// SPDX-License-Identifier: MPL-2.0
//! AddRtgDevice: A device the library cannot find by itself, made from
//! tags and offered.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;
const _device = @import("_device.zig");

/// Makes a device from tags and offers it to the drivers.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice
/// ```
///
/// SINCE: 1.18. LVO -340.
///
/// INPUTS:
/// - `tag_list` - what the device is, in the tags a panel part of the
///   board's list has: `PART_Chip`, `PART_Bus`, `PART_ChipName`, and the
///   `RTGA_` tags its driver reads. Read for as long as the device lives.
///
/// RESULT:
/// The device, or null without memory. It is answered whether a driver
/// took it or not: `device.driver` says.
///
/// BEHAVIOR:
/// For hardware the library cannot find by itself - a display that is
/// neither a panel of the board's list nor a function on PCI, and the
/// tests' own. The device joins the list as one of the part kind, named
/// `panel.` and the next number, and is offered at once as
/// `BindRtgDrivers` offers one: to the drivers whose table names it, the
/// closest first. The boards its driver makes join the library's list.
///
/// CONTEXT:
/// - Waits: yes. A driver brings its hardware up in its `attach`.
/// - Interrupts: no.
/// - Locks: takes the device list's lock, and inside it the driver
///   list's and the board list's. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is the library's until `RemRtgDevice`. The tags stay the
/// caller's and are kept valid until then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgDevice`, `BindRtgDrivers`, `CreateBoard`
///
/// EXAMPLES:
/// ```zig
/// const device = rb.AddRtgDevice(&found_tags) orelse return error.NoMemory;
/// ```
pub fn AddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);
    const private = _device.addPart(rb, null, tag_list) orelse return null;
    private.added = true;
    _ = _device.offer(rb, &private.device);
    return &private.device;
}
