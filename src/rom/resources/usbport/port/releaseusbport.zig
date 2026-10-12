// SPDX-License-Identifier: MPL-2.0
//! ReleaseUSBPort: a port let go of, or a bid withdrawn.

const sdk = @import("sdk");
const usbport = sdk.resources.usbport;
const USBPortHandle = usbport.USBPortHandle;
const UsbPortBase = @import("../usbport_base.zig").UsbPortBase;
const _port = @import("_port.zig");

/// Let go of the port `handle` holds, or of its bid.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseUSBPort(pb: *UsbPortBase, handle: *usbport.USBPortHandle, flags: u32) void
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `handle` - a bid made with OwnUSBPort.
/// - `flags` - USBPORTF_REMOVE: leave the bidders too.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A holder lets go: the port goes to the highest bidder left - switched
/// to its controller, its `state` USBPORT_HELD and its signals sent - or,
/// with no bidder left, back to the controller the chip starts with.
/// Without USBPORTF_REMOVE the caller stays a bidder (`state`
/// USBPORT_WAITING) and has the port again, told by its signals, once
/// everyone above it has let go; a caller nobody outranks keeps the port
/// (`state` USBPORT_HELD, no signal). With USBPORTF_REMOVE it leaves
/// (`state` USBPORT_IDLE). A bidder that does not hold the port withdraws
/// with USBPORTF_REMOVE; its holder is no longer wanted if nobody else
/// above it waits. A handle that is no bidder is left alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes the resource's spinlock for the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// After USBPORTF_REMOVE the handle is the caller's alone again.
///
/// NOTES:
/// A holder lets go only between two pieces of its work: the port is
/// switched at once, under whatever it was sending.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OwnUSBPort`, `USBPortOwner`
///
/// EXAMPLES:
/// ```zig
/// if (handle.state == usbport.USBPORT_WANTED) pb.ReleaseUSBPort(handle, 0);
/// pb.ReleaseUSBPort(handle, usbport.USBPORTF_REMOVE);
/// ```
pub fn ReleaseUSBPort(pb: *UsbPortBase, handle: *USBPortHandle, flags: u32) void {
    const sys = pb.sys_base;
    const port = _port.portOf(handle) orelse return;
    var tell: _port.Tell = .{};
    sys.AcquireLock(&pb.lock);
    if (handle.state != usbport.USBPORT_IDLE) {
        const was_holder = pb.holder[port] == handle;
        if (flags & usbport.USBPORTF_REMOVE != 0) {
            sys.Remove(&handle.node);
            handle.state = usbport.USBPORT_IDLE;
        } else if (was_holder) {
            handle.state = usbport.USBPORT_WAITING;
        }
        if (was_holder) {
            pb.holder[port] = null;
            if (pb.bidders[port].first()) |node| {
                const next = _port.handleOf(node);
                _port.give(pb, port, next);
                if (next != handle) tell = .of(next);
            } else {
                _port.chip.route(port, null, 0);
            }
        } else if (pb.holder[port]) |holder| {
            if (holder.state == usbport.USBPORT_WANTED and !_port.outranked(pb, port, holder)) {
                holder.state = usbport.USBPORT_HELD;
            }
        }
    }
    sys.ReleaseLock(&pb.lock);
    tell.send(pb);
}
