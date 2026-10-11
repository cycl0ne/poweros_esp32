// SPDX-License-Identifier: MIT
//! ObtainUSBDeviceList: every device on every bus, held for reading.

const sdk = @import("sdk");
const exec = sdk.exec;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// Takes the list of every device on every bus, for reading.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainUSBDeviceList(base: *UsbBase) *exec.List
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The list: its nodes are `USBDevice`s, the root hubs among them, in
/// the order they were set up.
///
/// BEHAVIOR:
/// The list is held shared: other readers read it too, and no device is
/// added or removed - a bus's process that has one to add or remove
/// waits - until ReleaseUSBDeviceList.
///
/// CONTEXT:
/// - Waits: yes, while a bus's process changes the list.
/// - Interrupts: no.
/// - Locks: takes the list's semaphore, shared; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list and its devices stay the library's: read them, change
/// nothing, and keep nothing of them after ReleaseUSBDeviceList.
///
/// NOTES:
/// Hold it briefly: a device plugged in meanwhile is not set up until it
/// is let go. A program that prints the list copies what it wants and
/// prints after.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseUSBDeviceList`, `AddUSBNotify`
///
/// EXAMPLES:
/// ```zig
/// const list = ub.ObtainUSBDeviceList();
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const device: *usb.USBDevice = @fieldParentPtr("node", node);
///     count += 1;
///     _ = device;
/// }
/// ub.ReleaseUSBDeviceList();
/// ```
pub fn ObtainUSBDeviceList(base: *UsbBase) *exec.List {
    base.sys_base.ObtainSemaphoreShared(&base.devices_lock);
    return &base.devices;
}
