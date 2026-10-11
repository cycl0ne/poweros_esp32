// SPDX-License-Identifier: MIT
//! StopUSB: a bus stopped, and everything on it let go.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const Bus = @import("_bus.zig").Bus;

/// Stops a bus: every device on it let go, its controller closed.
///
/// SYNOPSIS:
/// ```zig
/// fn StopUSB(base: *UsbBase, bus: u32) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `bus` - which bus, as StartUSB took it. One that does not run is
///   left as it is.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The bus's process lets go of every device from the root down: a hub's
/// children before the hub, each interface's driver told with
/// USBClassUnbind, each device off the list. Then it closes the
/// controller - which stops it and unpowers its port - and ends.
///
/// CONTEXT:
/// - Waits: yes, until the bus's process has ended.
/// - Interrupts: no.
/// - Locks: takes the library's bus lock; none may be held - nor the
///   device list, which the process takes to change it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The USBDevices of the bus are gone when this returns: nothing of them
/// may be kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartUSB`
///
/// EXAMPLES:
/// ```zig
/// ub.StopUSB(0);
/// ```
pub fn StopUSB(base: *UsbBase, bus: u32) void {
    const sys = base.sys_base;
    if (bus >= usb.USB_MAX_BUSES) return;
    sys.ObtainSemaphore(&base.bus_lock);
    defer sys.ReleaseSemaphore(&base.bus_lock);
    const found = base.buses[bus] orelse return;
    const record: *Bus = @ptrCast(@alignCast(found));
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    defer sys.FreeSignal(signal);
    record.waiter = sys.FindTask(null);
    record.waiter_signal = signal;
    sys.Signal(record.process.?, record.stop_signal);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    base.buses[bus] = null;
    sys.FreeMem(record, @sizeOf(Bus));
}
