// SPDX-License-Identifier: MPL-2.0
//! OwnUSBPort: a bid for a USB port.

const sdk = @import("sdk");
const usbport = sdk.resources.usbport;
const USBPortHandle = usbport.USBPortHandle;
const UsbPortBase = @import("../usbport_base.zig").UsbPortBase;
const _port = @import("_port.zig");

/// Bid for the port of `handle`'s controller.
///
/// SYNOPSIS:
/// ```zig
/// fn OwnUSBPort(pb: *UsbPortBase, handle: *usbport.USBPortHandle) bool
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `handle` - the bid, filled in by the caller: `node.pri` its
///   priority (USBPORTPRI_*) and `node.name` who bids; `task` and
///   `signals` what it is told by; `controller`, `unit` and `role` the
///   controller the port is to be given to and what it is on it. `state`
///   is the resource's.
///
/// RESULT:
/// True if the port is the caller's now, switched to its controller.
/// False if it waits for it - or if the chip has no such controller,
/// when `state` stays USBPORT_IDLE and nothing is ever sent.
///
/// BEHAVIOR:
/// The handle joins the port's bidders, by priority. A port nobody holds
/// is given to it at once. A holder of lower priority is told the port is
/// wanted: its `state` becomes USBPORT_WANTED and its signals are sent;
/// it lets go with ReleaseUSBPort when what it is doing is done. Whenever
/// the port then comes to this handle, its `state` becomes USBPORT_HELD
/// and its signals are sent. A holder of the same or higher priority
/// keeps the port until it lets go of its own accord. Bidding again with
/// a handle that is already a bidder changes nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes the resource's spinlock for the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle stays the caller's memory, kept by the resource until
/// ReleaseUSBPort with USBPORTF_REMOVE; it must not move or be freed
/// before. The signals stay the caller's.
///
/// NOTES:
/// The signals say only that `state` changed: the bidder reads it when
/// they come. A bidder that waits for the port waits for its signals, with
/// a time limit of its own if the holder may take long.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseUSBPort`, `USBPortOwner`
///
/// EXAMPLES:
/// ```zig
/// handle.* = .{
///     .node = .{ .pri = usbport.USBPORTPRI_HOST, .name = "usbotg.device" },
///     .task = sys.FindTask(null),
///     .signals = @as(u32, 1) << @intCast(bit),
///     .controller = usbport.USBCTL_OTG,
///     .role = st.USBROLE_HOST,
/// };
/// if (!pb.OwnUSBPort(handle)) _ = sys.Wait(handle.signals);
/// ```
pub fn OwnUSBPort(pb: *UsbPortBase, handle: *USBPortHandle) bool {
    const sys = pb.sys_base;
    const port = _port.portOf(handle) orelse return false;
    var tell: _port.Tell = .{};
    sys.AcquireLock(&pb.lock);
    if (handle.state == usbport.USBPORT_IDLE) {
        sys.Enqueue(&pb.bidders[port], &handle.node);
        handle.state = usbport.USBPORT_WAITING;
        if (pb.holder[port]) |holder| {
            if (holder.state == usbport.USBPORT_HELD and _port.outranked(pb, port, holder)) {
                holder.state = usbport.USBPORT_WANTED;
                tell = .of(holder);
            }
        } else {
            _port.give(pb, port, handle);
        }
    }
    const held = handle.state == usbport.USBPORT_HELD or handle.state == usbport.USBPORT_WANTED;
    sys.ReleaseLock(&pb.lock);
    tell.send(pb);
    return held;
}
