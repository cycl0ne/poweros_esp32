// SPDX-License-Identifier: MIT
//! ReleaseUSBInterface: a program's interface given back.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// Gives back an interface ClaimUSBInterface took.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32) void
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `device` - the device.
/// - `interface_number` - the interface the program claimed.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The interface is free again; it is not offered to the class drivers
/// until the device is plugged in again.
///
/// CONTEXT:
/// - Waits: yes, for the device list.
/// - Interrupts: no.
/// - Locks: takes the device list's semaphore; it may not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The program's pipes to it are closed first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClaimUSBInterface`
///
/// EXAMPLES:
/// ```zig
/// ub.ReleaseUSBInterface(device, 0);
/// ```
pub fn ReleaseUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32) void {
    const sys = base.sys_base;
    if (interface_number >= usb.USB_MAX_INTERFACES) return;
    sys.ObtainSemaphore(&base.devices_lock);
    defer sys.ReleaseSemaphore(&base.devices_lock);
    device.drivers[interface_number] = null;
}
