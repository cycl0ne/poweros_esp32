// SPDX-License-Identifier: MIT
//! ReleaseUSBDeviceList: the list let go of.

const UsbBase = @import("../usb_base.zig").UsbBase;

/// Lets go of the list ObtainUSBDeviceList took.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseUSBDeviceList(base: *UsbBase) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Once every reader has let go, the buses' processes may change the
/// list again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: releases the list's semaphore, which the caller holds.
/// - Process: a Task will do; the same one that took it.
///
/// OWNERSHIP:
/// Nothing of the list may be used after it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainUSBDeviceList`
///
/// EXAMPLES:
/// ```zig
/// _ = ub.ObtainUSBDeviceList();
/// defer ub.ReleaseUSBDeviceList();
/// ```
pub fn ReleaseUSBDeviceList(base: *UsbBase) void {
    base.sys_base.ReleaseSemaphore(&base.devices_lock);
}
