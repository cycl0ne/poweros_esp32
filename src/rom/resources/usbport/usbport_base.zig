// SPDX-License-Identifier: MPL-2.0
//! usbport.resource's base: each port's bidders and its holder.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbport = sdk.resources.usbport;
const ExecBase = sdk.interface.exec.ExecBase;

pub const UsbPortBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// Each port's bidders (USBPortHandle nodes), the highest priority
    /// first and the first come first among equals; the holder is one
    /// of them. Empty exactly when the port has no holder.
    bidders: [usbport.USBPORT_PORTS]exec.List,
    holder: [usbport.USBPORT_PORTS]?*usbport.USBPortHandle,
    /// The lists, the holders, the handles' states and the switch: a
    /// spinlock, held while they change. Nobody waits under it.
    lock: exec.Lock,
};
