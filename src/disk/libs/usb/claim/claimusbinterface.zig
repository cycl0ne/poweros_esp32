// SPDX-License-Identifier: MIT
//! ClaimUSBInterface: an interface no driver took, taken by a program.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// Takes an interface of a device for a program that drives it itself.
///
/// SYNOPSIS:
/// ```zig
/// fn ClaimUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `device` - the device, from the list.
/// - `interface_number` - bInterfaceNumber, below `USB_MAX_INTERFACES`.
/// - `name` - who takes it, for a listing; must outlive the claim.
///
/// RESULT:
/// True if it is now the program's; false if a class driver or another
/// program has it.
///
/// BEHAVIOR:
/// A claim is a binding with a program instead of a driver: the program
/// opens pipes to the interface's endpoints and does what a driver would.
/// A microcontroller's own protocol, a device no driver is written for,
/// a test, need no device of their own.
///
/// CONTEXT:
/// - Waits: yes, for the device list.
/// - Interrupts: no.
/// - Locks: takes the device list's semaphore; it may not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The interface is the program's until ReleaseUSBInterface - or until
/// the device goes, which a program learns from its transfers' errors
/// or from AddUSBNotify; it then closes its pipes and releases nothing.
///
/// BUGS:
/// A device that goes while claimed takes the claim with it silently.
///
/// SEE ALSO:
/// `ReleaseUSBInterface`, `OpenUSBPipe`
///
/// EXAMPLES:
/// ```zig
/// if (!ub.ClaimUSBInterface(device, 0, "test/USB")) return fail("interface 0 is taken");
/// defer ub.ReleaseUSBInterface(device, 0);
/// ```
pub fn ClaimUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32, name: [*:0]const u8) bool {
    const sys = base.sys_base;
    if (interface_number >= usb.USB_MAX_INTERFACES) return false;
    sys.ObtainSemaphore(&base.devices_lock);
    defer sys.ReleaseSemaphore(&base.devices_lock);
    if (device.drivers[interface_number] != null) return false;
    device.drivers[interface_number] = name;
    return true;
}
