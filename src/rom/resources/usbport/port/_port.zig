// SPDX-License-Identifier: MPL-2.0
//! What the calls share: which port a handle is for, the port given to a
//! bidder, and a task told once the lock is let go.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbport = sdk.resources.usbport;
const USBPortHandle = usbport.USBPortHandle;
const UsbPortBase = @import("../usbport_base.zig").UsbPortBase;

/// The chip's ports; in the host tests the chip's numbering with nothing
/// switched.
pub const chip = if (builtin.is_test) no_switch else real;

const real = switch (sdk.hardware.chip) {
    .esp32s3 => @import("../esp32s3/ports.zig"),
    .esp32p4 => @import("../esp32p4/ports.zig"),
    .rv64sbi => @compileError("usbport.resource: no USB ports for this chip yet"),
};

const no_switch = struct {
    pub const count = real.count;
    pub const portOf = real.portOf;
    pub fn route(port: u32, controller: ?u8, role: u8) void {
        _ = port;
        _ = controller;
        _ = role;
    }
};

comptime {
    if (chip.count != usbport.USBPORT_PORTS) @compileError("the SDK's USBPORT_PORTS isn't the chip's");
}

/// The port `handle`'s controller is on, or null.
pub fn portOf(handle: *const USBPortHandle) ?u32 {
    return chip.portOf(handle.controller, handle.unit);
}

pub fn handleOf(node: *exec.Node) *USBPortHandle {
    return @fieldParentPtr("node", node);
}

/// A task to signal, once the lock is let go.
pub const Tell = struct {
    task: ?*exec.Task = null,
    signals: u32 = 0,

    pub fn of(handle: *const USBPortHandle) Tell {
        return .{ .task = handle.task, .signals = handle.signals };
    }

    pub fn send(tell: Tell, pb: *UsbPortBase) void {
        const task = tell.task orelse return;
        if (tell.signals != 0) pb.sys_base.Signal(task, tell.signals);
    }
};

/// `port` given to `handle`, which is a bidder for it: switched to its
/// controller, and it the holder. Under the lock.
pub fn give(pb: *UsbPortBase, port: u32, handle: *USBPortHandle) void {
    chip.route(port, handle.controller, handle.role);
    pb.holder[port] = handle;
    handle.state = usbport.USBPORT_HELD;
}

/// Whether a bidder for `port` outranks its holder `holder`. Under the
/// lock.
pub fn outranked(pb: *UsbPortBase, port: u32, holder: *const USBPortHandle) bool {
    const first = pb.bidders[port].first() orelse return false;
    return first.pri > holder.node.pri;
}
