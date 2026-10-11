// SPDX-License-Identifier: MIT
//! usb.library's base: exec's Library header, the list of every device on
//! every bus and its lock, the buses, the class drivers found in
//! `DEVS:usb/`, and who wants to be told of a change. One base, shared by
//! every opener.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const UsbBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// dos.library and utility.library, opened by the first StartUSB and
    /// closed at the expunge.
    dos: ?*DosBase = null,
    utility: ?*UtilityBase = null,
    /// Every device on every bus: USBDevices, each the start of a bus's
    /// `Device`. Read under `devices_lock` shared, changed under it
    /// exclusive, by the buses' processes alone.
    devices: exec.List = .{},
    devices_lock: exec.SignalSemaphore = .{},
    /// One StartUSB or StopUSB at a time.
    bus_lock: exec.SignalSemaphore = .{},
    /// Each started bus, by its number.
    buses: [usb.USB_MAX_BUSES]?*anyopaque = @splat(null),
    /// The class drivers: a `bind/_bind.zig` Drivers block, read from
    /// `DEVS:usb/` when the first bus starts; and its lock, since two
    /// buses' processes bind at once.
    drivers: ?*anyopaque = null,
    drivers_lock: exec.SignalSemaphore = .{},
    /// AddUSBNotify's records, and their lock.
    notify: exec.List = .{},
    notify_lock: exec.SignalSemaphore = .{},
};

pub fn usbBase(lib: *exec.Library) *UsbBase {
    return @fieldParentPtr("lib", lib);
}
