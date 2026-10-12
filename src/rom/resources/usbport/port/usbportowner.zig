// SPDX-License-Identifier: MPL-2.0
//! USBPortOwner: who holds a USB port.

const sdk = @import("sdk");
const usbport = sdk.resources.usbport;
const UsbPortBase = @import("../usbport_base.zig").UsbPortBase;

/// Who holds `port`.
///
/// SYNOPSIS:
/// ```zig
/// fn USBPortOwner(pb: *UsbPortBase, port: u32) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `port` - 0 to USBPORT_PORTS - 1.
///
/// RESULT:
/// The holder's name, as its handle's node gives it; null if nobody
/// holds the port, or there is no such port.
///
/// BEHAVIOR:
/// Reads who holds the port now; the answer may be out of date by the
/// time it is looked at.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes the resource's spinlock for the read.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is the holder's, valid while it holds the port: copy it, or
/// print it at once.
///
/// NOTES:
/// A port nobody holds is with the controller the chip starts with.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OwnUSBPort`, `ReleaseUSBPort`
///
/// EXAMPLES:
/// ```zig
/// var port: u32 = 0;
/// while (port < usbport.USBPORT_PORTS) : (port += 1) {
///     if (pb.USBPortOwner(port)) |name| _ = Printf(dl, "port %u: %s\n", .{ port, name });
/// }
/// ```
pub fn USBPortOwner(pb: *UsbPortBase, port: u32) ?[*:0]const u8 {
    if (port >= usbport.USBPORT_PORTS) return null;
    const sys = pb.sys_base;
    sys.AcquireLock(&pb.lock);
    defer sys.ReleaseLock(&pb.lock);
    const holder = pb.holder[port] orelse return null;
    return holder.node.name;
}
