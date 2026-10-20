// SPDX-License-Identifier: MIT
//! The controller's root ports as a hub: the device answers its root
//! hub's control transfers itself - a high-speed hub's descriptors, each
//! port's status, the ports' features set and cleared - and holds an
//! interrupt transfer on endpoint 1 until a port changes. usb.library
//! drives it with the same hub code as any hub plugged in.
//!
//! **Its ports** are every root port the controller has, the USB 2 ones
//! first, then the USB 3 ones (`Host.port_map`). A connector has one of
//! each: a USB 3 device trains its link on the USB 3 port and runs at
//! SuperSpeed, anything else is on the USB 2 port.
//!
//! **A port's status** is its PORTSC as a hub's wPortStatus, a device at
//! SuperSpeed with USB_PORT_STAT_SUPER_SPEED, and its changes are PORTSC's
//! change bits, cleared as the hub's are: a USB 3 link's change as
//! C_SUSPEND, a link that could not be set up (CEC) as C_ENABLE. A Port
//! Status Change Event wakes the held transfer.
//!
//! **U1 and U2** are a USB 3 port's as a SuperSpeed hub's: the root hub
//! answers a BOS whose SuperSpeed capability has the ports' exit
//! latencies (HCSPARAMS3), and takes PORT_U1_TIMEOUT and PORT_U2_TIMEOUT
//! into the port's PORTPMSC. They are sticky, and the controller's start
//! sets every one back to 0 (`clearTimeouts`).
//!
//! **A reset** is the controller's: PR is written and the port resets
//! itself, saying so in PRC; the bus asks the port's status until it has.
//! A USB 3 link that failed - SS.Inactive, compliance mode - takes a warm
//! reset (WPR) instead, when it is asked to reset and when its status is
//! asked. The port is noted as where the next device at address 0 is,
//! and what was there let go (slots.zig). A port that shows its device
//! gone has its slot let go when the bus asks its status.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const d = sdk.usb.descriptors;
const regs = @import("regs.zig");
const _xhci = @import("_xhci.zig");
const Host = _xhci.Host;
const op = _xhci.op;
const slots = @import("slots.zig");

/// The root hub's device descriptor: a high-speed hub, of a USB version
/// with a BOS.
const device_descriptor = d.DeviceDescriptor{
    .bcd_usb = 0x0210,
    .device_class = d.USB_CLASS_HUB,
    .device_protocol = 1,
    .max_packet_size0 = 64,
    .bcd_device = 0x0100,
    .product_string = 1,
    .num_configurations = 1,
};

/// Its configuration: one interface, the hub's, with its status-change
/// endpoint.
const config_descriptor = extern struct {
    config: d.ConfigDescriptor,
    interface: d.InterfaceDescriptor,
    endpoint: d.EndpointDescriptor,
}{
    .config = .{
        .total_length = 9 + 9 + 7,
        .num_interfaces = 1,
        .configuration_value = 1,
        .attributes = d.USB_CONFIG_ONE | d.USB_CONFIG_SELF_POWERED,
    },
    .interface = .{ .num_endpoints = 1, .interface_class = d.USB_CLASS_HUB },
    .endpoint = .{
        .endpoint_address = d.USB_DIR_IN | 1,
        .attributes = d.USB_ENDPOINT_XFER_INT,
        .max_packet_size = 2,
        .interval = 12,
    },
};

/// Its BOS: the SuperSpeed capability alone.
const Bos = extern struct {
    header: d.BosDescriptor,
    superspeed: d.SSUsbCapability,
};

/// Its strings: the language list (US English), and its name.
const languages = [_]u8{ 4, d.USB_DT_STRING, 0x09, 0x04 };
const product_name = "xHCI root hub";

comptime {
    if (@sizeOf(@TypeOf(config_descriptor)) != 25) @compileError("the root hub's configuration is not 25 bytes");
    if (@sizeOf(Bos) != 15) @compileError("the root hub's BOS is not 15 bytes");
}

/// A request to the root hub: a control transfer answered, an interrupt
/// transfer held until a port changes.
pub fn handle(host: *Host, req: *usbhc.IOUsbHC) void {
    switch (req.std.req.command) {
        usbhc.UHCMD_CONTROLXFER => control(host, req),
        usbhc.UHCMD_INTXFER => {
            if (host.root.waiting != null) return _xhci.reply(host, req, exec.IOERR_UNITBUSY);
            host.root.waiting = req;
            answerStatus(host);
        },
        else => _xhci.reply(host, req, usbhc.UHIOERR_STALL),
    }
}

/// `bytes` into the request's data, as much as it asked for.
fn give(req: *usbhc.IOUsbHC, bytes: []const u8) void {
    const room: usize = @intCast(req.std.length);
    const count = @min(room, bytes.len);
    if (count != 0) {
        const into: [*]u8 = @ptrCast(req.std.data.?);
        @memcpy(into[0..count], bytes[0..count]);
    }
    req.std.actual = count;
}

fn asBytes(pointer: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(pointer)).pointer.child;
    return @as([*]const u8, @ptrCast(pointer))[0..@sizeOf(T)];
}

/// The hub's port `port` (from 1) as the controller numbers it.
fn portsc(host: *Host, port: u32) *volatile u32 {
    return op(host, regs.portsc(host.port_map[port - 1]));
}

/// Whether the hub's port `port` is a USB 3 one.
fn isSuper(host: *const Host, port: u32) bool {
    return host.super_ports & (@as(u32, 1) << @intCast(port)) != 0;
}

/// A USB 3 port whose link failed: only a warm reset brings it back.
fn needsWarmReset(value: u32) bool {
    const state = (value & regs.PORT_PLS_MASK) >> regs.PORT_PLS_SHIFT;
    return state == regs.PLS_INACTIVE or state == regs.PLS_COMPLIANCE;
}

fn control(host: *Host, req: *usbhc.IOUsbHC) void {
    const setup = req.setup;
    const value = setup.value;
    var err: i8 = 0;
    switch (setup.request_type) {
        d.USB_DIR_IN | d.USB_TYPE_STANDARD | d.USB_RECIP_DEVICE => switch (setup.request) {
            d.USB_REQ_GET_DESCRIPTOR => switch (@as(u8, @truncate(value >> 8))) {
                d.USB_DT_DEVICE => give(req, asBytes(&device_descriptor)),
                d.USB_DT_CONFIG => give(req, asBytes(&config_descriptor)),
                d.USB_DT_BOS => {
                    const bos = bosOf(host);
                    give(req, asBytes(&bos));
                },
                d.USB_DT_STRING => {
                    if (value & 0xFF == 0) {
                        give(req, &languages);
                    } else {
                        var string: [2 + 2 * product_name.len]u8 = undefined;
                        string[0] = string.len;
                        string[1] = d.USB_DT_STRING;
                        for (product_name, 0..) |c, i| {
                            string[2 + 2 * i] = c;
                            string[3 + 2 * i] = 0;
                        }
                        give(req, &string);
                    }
                },
                else => err = usbhc.UHIOERR_STALL,
            },
            d.USB_REQ_GET_STATUS => give(req, &[_]u8{ 1, 0 }),
            d.USB_REQ_GET_CONFIGURATION => give(req, &[_]u8{host.root.configuration}),
            else => err = usbhc.UHIOERR_STALL,
        },
        d.USB_DIR_OUT | d.USB_TYPE_STANDARD | d.USB_RECIP_DEVICE => switch (setup.request) {
            d.USB_REQ_SET_ADDRESS => host.root.address = @truncate(value & 0x7F),
            d.USB_REQ_SET_CONFIGURATION => host.root.configuration = @truncate(value),
            else => err = usbhc.UHIOERR_STALL,
        },
        d.USB_DIR_IN | d.USB_RT_HUB => switch (setup.request) {
            d.USB_REQ_GET_DESCRIPTOR => {
                const descriptor = d.HubDescriptor{
                    .num_ports = @intCast(host.ports),
                    .characteristics = d.USB_HUB_CHAR_INDIVIDUAL_POWER | d.USB_HUB_CHAR_INDIVIDUAL_OVERCURRENT,
                    .power_on_to_good = 10,
                };
                give(req, asBytes(&descriptor));
            },
            d.USB_REQ_GET_STATUS => give(req, &[_]u8{ 0, 0, 0, 0 }),
            else => err = usbhc.UHIOERR_STALL,
        },
        d.USB_DIR_OUT | d.USB_RT_HUB => {},
        d.USB_DIR_IN | d.USB_RT_PORT => {
            const port = setup.index;
            if (setup.request != d.USB_REQ_GET_STATUS or port == 0 or port > host.ports) {
                err = usbhc.UHIOERR_STALL;
            } else {
                const port_value = portsc(host, port).*;
                if (isSuper(host, port) and needsWarmReset(port_value) and port_value & regs.PORT_PR == 0) {
                    portWrite(host, port, regs.PORT_WPR, 0);
                }
                const status = statusOf(port_value);
                // A device gone: its slot with it.
                if (status.status & d.USB_PORT_STAT_CONNECTION == 0 or status.change & d.USB_PORT_STAT_C_CONNECTION != 0) {
                    slots.portGone(host, 0, @intCast(port));
                }
                give(req, asBytes(&status));
            }
        },
        d.USB_DIR_OUT | d.USB_RT_PORT => {
            // The port in wIndex's low byte, a timeout in its high one.
            const port = setup.index & 0xFF;
            if (port == 0 or port > host.ports) {
                err = usbhc.UHIOERR_STALL;
            } else if (setup.request == d.USB_REQ_SET_FEATURE) {
                err = setFeature(host, port, value, @truncate(setup.index >> 8));
            } else if (setup.request == d.USB_REQ_CLEAR_FEATURE) {
                err = clearFeature(host, port, value);
            } else {
                err = usbhc.UHIOERR_STALL;
            }
        },
        else => err = usbhc.UHIOERR_STALL,
    }
    _xhci.reply(host, req, err);
}

/// PORTSC written: what it keeps, `set` set, `clear` cleared among what
/// it keeps.
fn portWrite(host: *Host, port: u32, set: u32, clear: u32) void {
    const at = portsc(host, port);
    at.* = (at.* & regs.PORT_NEUTRAL & ~clear) | set;
}

/// The BOS's SuperSpeed capability: every speed, and the root ports'
/// exit latencies.
pub fn bosOf(host: *const Host) Bos {
    return .{
        .header = .{ .total_length = @sizeOf(Bos), .num_capabilities = 1 },
        .superspeed = .{ .speeds = 0x000F, .u1_exit = host.u1_exit, .u2_exit = host.u2_exit },
    };
}

/// A USB 3 port's PORTPMSC: its U1 or U2 timeout set to `timeout`.
fn setTimeout(host: *Host, port: u32, shift: u5, timeout: u8) void {
    const at = op(host, regs.portpmsc(host.port_map[port - 1]));
    at.* = (at.* & ~(@as(u32, 0xFF) << shift)) | @as(u32, timeout) << shift;
}

/// Every USB 3 port's U1 and U2 timeouts back to 0.
pub fn clearTimeouts(host: *Host) void {
    var port: u32 = 1;
    while (port <= host.ports) : (port += 1) {
        if (!isSuper(host, port)) continue;
        const at = op(host, regs.portpmsc(host.port_map[port - 1]));
        at.* &= ~regs.PMSC_TIMEOUTS;
    }
}

fn setFeature(host: *Host, port: u32, feature: u16, timeout: u8) i8 {
    switch (feature) {
        d.USB_PORT_FEAT_POWER => portWrite(host, port, regs.PORT_PP, 0),
        d.USB_PORT_FEAT_RESET => {
            slots.noteReset(host, 0, @intCast(port));
            const warm = isSuper(host, port) and needsWarmReset(portsc(host, port).*);
            portWrite(host, port, if (warm) regs.PORT_WPR else regs.PORT_PR, 0);
        },
        // Suspend is left to a hub that needs it.
        d.USB_PORT_FEAT_SUSPEND => {},
        d.USB_PORT_FEAT_U1_TIMEOUT, d.USB_PORT_FEAT_U2_TIMEOUT => {
            if (!isSuper(host, port)) return usbhc.UHIOERR_STALL;
            const shift: u5 = if (feature == d.USB_PORT_FEAT_U1_TIMEOUT) regs.PMSC_U1_TIMEOUT_SHIFT else regs.PMSC_U2_TIMEOUT_SHIFT;
            setTimeout(host, port, shift, timeout);
        },
        else => return usbhc.UHIOERR_STALL,
    }
    return 0;
}

fn clearFeature(host: *Host, port: u32, feature: u16) i8 {
    switch (feature) {
        // Writing 1 to PED is what disables the port.
        d.USB_PORT_FEAT_ENABLE => portWrite(host, port, regs.PORT_PED, 0),
        d.USB_PORT_FEAT_POWER => portWrite(host, port, 0, regs.PORT_PP),
        d.USB_PORT_FEAT_SUSPEND => {},
        d.USB_PORT_FEAT_C_CONNECTION => portWrite(host, port, regs.PORT_CSC, 0),
        d.USB_PORT_FEAT_C_ENABLE => portWrite(host, port, regs.PORT_PEC | regs.PORT_CEC, 0),
        d.USB_PORT_FEAT_C_SUSPEND => portWrite(host, port, regs.PORT_PLC, 0),
        d.USB_PORT_FEAT_C_OVER_CURRENT => portWrite(host, port, regs.PORT_OCC, 0),
        d.USB_PORT_FEAT_C_RESET => portWrite(host, port, regs.PORT_PRC | regs.PORT_WRC, 0),
        else => return usbhc.UHIOERR_STALL,
    }
    return 0;
}

/// A port's PORTSC as a hub's wPortStatus and wPortChange.
pub fn statusOf(value: u32) d.PortStatus {
    var status: u16 = 0;
    if (value & regs.PORT_CCS != 0) status |= d.USB_PORT_STAT_CONNECTION;
    if (value & regs.PORT_PED != 0) status |= d.USB_PORT_STAT_ENABLE;
    if ((value & regs.PORT_PLS_MASK) >> regs.PORT_PLS_SHIFT == regs.PLS_U3) status |= d.USB_PORT_STAT_SUSPEND;
    if (value & regs.PORT_OCA != 0) status |= d.USB_PORT_STAT_OVERCURRENT;
    if (value & regs.PORT_PR != 0) status |= d.USB_PORT_STAT_RESET;
    if (value & regs.PORT_PP != 0) status |= d.USB_PORT_STAT_POWER;
    if (value & regs.PORT_CCS != 0) {
        const speed = (value & regs.PORT_SPEED_MASK) >> regs.PORT_SPEED_SHIFT;
        if (speed == regs.SPEED_LOW) status |= d.USB_PORT_STAT_LOW_SPEED;
        if (speed == regs.SPEED_HIGH) status |= d.USB_PORT_STAT_HIGH_SPEED;
        if (speed >= regs.SPEED_SUPER) status |= d.USB_PORT_STAT_SUPER_SPEED;
    }
    var change: u16 = 0;
    if (value & regs.PORT_CSC != 0) change |= d.USB_PORT_STAT_C_CONNECTION;
    if (value & (regs.PORT_PEC | regs.PORT_CEC) != 0) change |= d.USB_PORT_STAT_C_ENABLE;
    if (value & regs.PORT_PLC != 0) change |= d.USB_PORT_STAT_C_SUSPEND;
    if (value & regs.PORT_OCC != 0) change |= d.USB_PORT_STAT_C_OVERCURRENT;
    if (value & (regs.PORT_PRC | regs.PORT_WRC) != 0) change |= d.USB_PORT_STAT_C_RESET;
    return .{ .status = status, .change = change };
}

/// A Port Status Change Event: the held transfer answered if a port of
/// the root hub's has a change.
pub fn portChanged(host: *Host) void {
    answerStatus(host);
}

/// The held status-change transfer answered, if a port has changed: a
/// bit per port, from bit 1.
fn answerStatus(host: *Host) void {
    const req = host.root.waiting orelse return;
    var bitmap: u16 = 0;
    var port: u32 = 1;
    while (port <= host.ports) : (port += 1) {
        if (statusOf(portsc(host, port).*).change != 0) bitmap |= @as(u16, 1) << @intCast(port);
    }
    if (bitmap == 0) return;
    host.root.waiting = null;
    give(req, &[_]u8{ @truncate(bitmap), @truncate(bitmap >> 8) });
    _xhci.reply(host, req, 0);
}

/// The held transfer answered if AbortIO asked for it.
pub fn takeAbort(host: *Host) void {
    const req = host.root.waiting orelse return;
    if (req.hc_private[_xhci.PRIV_ABORT] == 0) return;
    host.root.waiting = null;
    _xhci.reply(host, req, exec.IOERR_ABORTED);
}

/// The held transfer answered as the controller stops.
pub fn stop(host: *Host) void {
    const req = host.root.waiting orelse return;
    host.root.waiting = null;
    _xhci.reply(host, req, exec.IOERR_ABORTED);
}
