// SPDX-License-Identifier: MIT
//! The root port as a hub: the controller answers its root hub's control
//! transfers itself - a hub's device, configuration and hub descriptors,
//! its port's status, the port's features set and cleared - and holds an
//! interrupt transfer on endpoint 1 until the port changes. usb.library
//! drives it with the same hub code as any hub plugged in.
//!
//! The port's status is HPRT's as a hub's wPortStatus, and its changes
//! are what the interrupt saw (`portChanged`) and what a reset left.
//! A reset is done here, on the task: the port held in reset for 50 ms,
//! let go, and given 20 ms to come up enabled.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const dwc = sdk.hardware.usb_dwc;
const d = sdk.usb.descriptors;
const _usbotg = @import("_usbotg.zig");
const Host = _usbotg.Host;
const reg = _usbotg.reg;
const host_ops = @import("host.zig");

/// The root hub's device descriptor: a full-speed hub.
const device_descriptor = d.DeviceDescriptor{
    .bcd_usb = 0x0110,
    .device_class = d.USB_CLASS_HUB,
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
        .max_packet_size = 1,
        .interval = 255,
    },
};

/// Its hub descriptor: one port, powered and watched on its own, 100 ms
/// from power to power good.
const hub_descriptor = d.HubDescriptor{
    .num_ports = 1,
    .characteristics = d.USB_HUB_CHAR_INDIVIDUAL_POWER | d.USB_HUB_CHAR_INDIVIDUAL_OVERCURRENT,
    .power_on_to_good = 50,
};

/// Its strings: the language list (US English), and its name.
const languages = [_]u8{ 4, d.USB_DT_STRING, 0x09, 0x04 };
const product_name = "DWC2 root hub";

comptime {
    if (@sizeOf(@TypeOf(config_descriptor)) != 25) @compileError("the root hub's configuration is not 25 bytes");
}

/// A request to the root hub: a control transfer answered, an interrupt
/// transfer held until the port changes.
pub fn handle(host: *Host, req: *usbhc.IOUsbHC) void {
    switch (req.std.req.command) {
        usbhc.UHCMD_CONTROLXFER => control(host, req),
        usbhc.UHCMD_INTXFER => {
            if (host.root.waiting != null) return _usbotg.reply(host, req, exec.IOERR_UNITBUSY);
            host.root.waiting = req;
            answerStatus(host);
        },
        else => _usbotg.reply(host, req, usbhc.UHIOERR_STALL),
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

fn control(host: *Host, req: *usbhc.IOUsbHC) void {
    const setup = req.setup;
    const value = setup.value;
    var err: i8 = 0;
    switch (setup.request_type) {
        d.USB_DIR_IN | d.USB_TYPE_STANDARD | d.USB_RECIP_DEVICE => switch (setup.request) {
            d.USB_REQ_GET_DESCRIPTOR => switch (@as(u8, @truncate(value >> 8))) {
                d.USB_DT_DEVICE => give(req, asBytes(&device_descriptor)),
                d.USB_DT_CONFIG => give(req, asBytes(&config_descriptor)),
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
            d.USB_REQ_GET_DESCRIPTOR => give(req, asBytes(&hub_descriptor)),
            d.USB_REQ_GET_STATUS => give(req, &[_]u8{ 0, 0, 0, 0 }),
            else => err = usbhc.UHIOERR_STALL,
        },
        d.USB_DIR_OUT | d.USB_RT_HUB => {},
        d.USB_DIR_IN | d.USB_RT_PORT => {
            if (setup.request != d.USB_REQ_GET_STATUS or setup.index != 1) {
                err = usbhc.UHIOERR_STALL;
            } else {
                refreshStatus(host);
                const status = d.PortStatus{ .status = host.root.status, .change = host.root.change };
                give(req, asBytes(&status));
            }
        },
        d.USB_DIR_OUT | d.USB_RT_PORT => {
            if (setup.index != 1) {
                err = usbhc.UHIOERR_STALL;
            } else if (setup.request == d.USB_REQ_SET_FEATURE) {
                err = setFeature(host, value);
            } else if (setup.request == d.USB_REQ_CLEAR_FEATURE) {
                err = clearFeature(host, value);
            } else {
                err = usbhc.UHIOERR_STALL;
            }
        },
        else => err = usbhc.UHIOERR_STALL,
    }
    _usbotg.reply(host, req, err);
}

fn setFeature(host: *Host, feature: u16) i8 {
    switch (feature) {
        d.USB_PORT_FEAT_POWER => host_ops.portWrite(host, dwc.HPRT_PRTPWR, 0),
        d.USB_PORT_FEAT_RESET => reset(host),
        d.USB_PORT_FEAT_SUSPEND => host_ops.portWrite(host, dwc.HPRT_PRTSUSP, 0),
        else => return usbhc.UHIOERR_STALL,
    }
    return 0;
}

fn clearFeature(host: *Host, feature: u16) i8 {
    switch (feature) {
        // Writing 1 to PRTENA is what disables the port.
        d.USB_PORT_FEAT_ENABLE => reg(host, dwc.HPRT).* = (reg(host, dwc.HPRT).* & ~dwc.HPRT_W1C_MASK) | dwc.HPRT_PRTENA,
        d.USB_PORT_FEAT_POWER => host_ops.portWrite(host, 0, dwc.HPRT_PRTPWR),
        d.USB_PORT_FEAT_SUSPEND => host_ops.portWrite(host, dwc.HPRT_PRTRES, dwc.HPRT_PRTSUSP),
        d.USB_PORT_FEAT_C_CONNECTION => host.root.change &= ~d.USB_PORT_STAT_C_CONNECTION,
        d.USB_PORT_FEAT_C_ENABLE => host.root.change &= ~d.USB_PORT_STAT_C_ENABLE,
        d.USB_PORT_FEAT_C_SUSPEND => host.root.change &= ~d.USB_PORT_STAT_C_SUSPEND,
        d.USB_PORT_FEAT_C_OVER_CURRENT => host.root.change &= ~d.USB_PORT_STAT_C_OVERCURRENT,
        d.USB_PORT_FEAT_C_RESET => host.root.change &= ~d.USB_PORT_STAT_C_RESET,
        else => return usbhc.UHIOERR_STALL,
    }
    return 0;
}

/// The port reset, and what it found: its speed, the PHY's clock for it.
fn reset(host: *Host) void {
    host_ops.portWrite(host, dwc.HPRT_PRTRST, 0);
    _usbotg.delay(host, 50);
    host_ops.portWrite(host, 0, dwc.HPRT_PRTRST);
    var waited: u32 = 0;
    while (reg(host, dwc.HPRT).* & dwc.HPRT_PRTENA == 0 and waited < 20) : (waited += 1) _usbotg.delay(host, 1);
    host_ops.setPortClock(host);
    // Time for the device to recover from its reset.
    _usbotg.delay(host, 10);
    refreshStatus(host);
    host.root.change |= d.USB_PORT_STAT_C_RESET;
    answerStatus(host);
}

/// wPortStatus from HPRT as it is now.
fn refreshStatus(host: *Host) void {
    const hprt = reg(host, dwc.HPRT).*;
    var status: u16 = 0;
    if (hprt & dwc.HPRT_PRTCONNSTS != 0) status |= d.USB_PORT_STAT_CONNECTION;
    if (hprt & dwc.HPRT_PRTENA != 0) status |= d.USB_PORT_STAT_ENABLE;
    if (hprt & dwc.HPRT_PRTSUSP != 0) status |= d.USB_PORT_STAT_SUSPEND;
    if (hprt & dwc.HPRT_PRTOVRCURRACT != 0) status |= d.USB_PORT_STAT_OVERCURRENT;
    if (hprt & dwc.HPRT_PRTRST != 0) status |= d.USB_PORT_STAT_RESET;
    if (hprt & dwc.HPRT_PRTPWR != 0) status |= d.USB_PORT_STAT_POWER;
    if (status & d.USB_PORT_STAT_ENABLE != 0) {
        const speed = (hprt >> dwc.HPRT_PRTSPD_SHIFT) & 3;
        if (speed == dwc.HPRT_SPD_LOW) status |= d.USB_PORT_STAT_LOW_SPEED;
        if (speed == dwc.HPRT_SPD_HIGH) status |= d.USB_PORT_STAT_HIGH_SPEED;
    }
    host.root.status = status;
}

/// What the interrupt saw at the port, as the hub's changes. A device
/// that went takes every transfer on the wire with it.
pub fn portChanged(host: *Host, events: u32) void {
    const was_enabled = host.root.status & d.USB_PORT_STAT_ENABLE != 0;
    refreshStatus(host);
    if (events & (dwc.HPRT_PRTCONNDET | _usbotg.event_disconnect) != 0) {
        host.root.change |= d.USB_PORT_STAT_C_CONNECTION;
    }
    // The port's enable changes when a reset ends too; only a port that
    // was enabled and is not any more is a change a hub reports.
    if (events & dwc.HPRT_PRTENCHNG != 0 and was_enabled and host.root.status & d.USB_PORT_STAT_ENABLE == 0) {
        host.root.change |= d.USB_PORT_STAT_C_ENABLE;
    }
    if (events & dwc.HPRT_PRTOVRCURRCHNG != 0) host.root.change |= d.USB_PORT_STAT_C_OVERCURRENT;
    if (events & _usbotg.event_disconnect != 0 or host.root.status & d.USB_PORT_STAT_CONNECTION == 0) {
        host_ops.failAll(host, usbhc.UHIOERR_DETACHED);
    }
    answerStatus(host);
}

/// The held status-change transfer answered, if the port has changed:
/// bit 1 for port 1.
fn answerStatus(host: *Host) void {
    if (host.root.change == 0) return;
    const req = host.root.waiting orelse return;
    host.root.waiting = null;
    give(req, &[_]u8{1 << 1});
    _usbotg.reply(host, req, 0);
}

/// The held transfer answered if AbortIO asked for it.
pub fn takeAbort(host: *Host) void {
    const req = host.root.waiting orelse return;
    if (req.hc_private[_usbotg.PRIV_ABORT] == 0) return;
    host.root.waiting = null;
    _usbotg.reply(host, req, exec.IOERR_ABORTED);
}

/// The held transfer answered as the controller stops.
pub fn stop(host: *Host) void {
    const req = host.root.waiting orelse return;
    host.root.waiting = null;
    _usbotg.reply(host, req, exec.IOERR_ABORTED);
}
