// SPDX-License-Identifier: MPL-2.0
//! RemRtgDevice: A device AddRtgDevice made is gone.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _device = @import("_device.zig");

/// Takes away a device `AddRtgDevice` made.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) void
/// ```
///
/// SINCE: 1.18. LVO -352.
///
/// INPUTS:
/// - `device` - the device, as `AddRtgDevice` answered it. Null does
///   nothing, and so does one of the machine's own: a panel part and a
///   function on PCI never go.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every board its driver made of it is marked as gone first
/// (`RTGBF_GONE`, `RTGBF_NO_DISPLAY`): taken off the display, passed over
/// by `NextBoard` from now on, and answering `RTGERR_NO_DISPLAY` to a
/// show - but still a handle, with its buffers, for whoever holds it.
/// Then the driver's `detach` is called, where it has one, to stop the
/// hardware, and the device leaves the list and is freed. The boards are
/// the driver's to delete (`DeleteBoard`) when it is removed itself.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the device list or a board's
///   lock, and if the driver does.
/// - Interrupts: no.
/// - Locks: takes the device list's lock, and inside it each board's. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is gone, and its tags are the caller's again. Its boards
/// stay the library's. The driver is one device less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgDevice`, `DeleteBoard`, `NextBoard`
///
/// EXAMPLES:
/// ```zig
/// rb.RemRtgDevice(device);
/// ```
pub fn RemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) void {
    const gone = device orelse return;
    const sys = rb.sys_base;
    const private = _device.privateOf(gone);
    if (!private.added) return;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);

    // Its boards say so before the hardware stops.
    while (private.boards.first()) |link| boards.retire(rb, boards.ofDeviceLink(link));
    if (gone.driver) |driver| {
        if (driver.spec.ops.detach) |detach| detach(driver, gone);
        if (driver.devices != 0) driver.devices -= 1;
    }
    sys.Remove(&gone.node);
    sys.FreeVec(private);
}
