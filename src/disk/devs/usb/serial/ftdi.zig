// SPDX-License-Identifier: MIT
//! usb/ftdi.device: FTDI's USB serial chips - the FT232R and FT232BM,
//! the FT2232, FT232H and FT230X - as serial lines with serial.device's
//! API (sdk/devices/serial.zig); unit n is the nth adapter plugged in
//! (`_usbserial.zig`). A class driver matched by vendor and product, as
//! these chips say nothing of a class.
//!
//! **The line** is set by FTDI's vendor requests: the rate as a divisor
//! of a 3 MHz clock in eighths (`divisorOf`), the frame (bits, parity,
//! stop bits; mark and space parity too), xON/xOFF as the chip's own
//! flow control, DTR and RTS on while the adapter is bound. A break is
//! the frame's break bit, held for its time.
//!
//! **Input**: every packet the chip sends begins with two status bytes -
//! the modem lines (CTS, DSR, RI, carrier) and the line's errors (overrun,
//! parity, framing, break) - and the rest is data. The chip sends a
//! packet of status alone every latency interval while nothing comes;
//! the latency is set to its shortest that keeps the bus quiet, 4 ms.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const d = usb.descriptors;
const usbclass = sdk.devices.usbclass;
const serial = sdk.devices.serial;
const serialunit = sdk.devices.serialunit;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const _usbserial = @import("_usbserial.zig");
const divisorOf = @import("ftdi_rates.zig").divisorOf;

pub const DEVICE_NAME = "ftdi.device";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "12.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

// FTDI's vendor requests.
const REQ_RESET: u8 = 0;
const REQ_MODEM_CTRL: u8 = 1;
const REQ_SET_FLOW_CTRL: u8 = 2;
const REQ_SET_BAUD_RATE: u8 = 3;
const REQ_SET_DATA: u8 = 4;
const REQ_SET_LATENCY: u8 = 9;
const RESET_SIO: u16 = 0;
/// MODEM_CTRL: DTR and RTS, with the bits that say both are being set.
const MODEM_DTR_RTS_ON: u16 = 0x0303;
/// SET_DATA: parity (bits 8-10), stop bits (11-12), break (14).
const DATA_PARITY_ODD: u16 = 1 << 8;
const DATA_PARITY_EVEN: u16 = 2 << 8;
const DATA_PARITY_MARK: u16 = 3 << 8;
const DATA_PARITY_SPACE: u16 = 4 << 8;
const DATA_STOP_2: u16 = 2 << 11;
const DATA_BREAK: u16 = 1 << 14;
/// SET_FLOW_CTRL's index: the chip's own xON/xOFF.
const FLOW_XON_XOFF: u16 = 4 << 8;
/// The status bytes: the modem lines, and the line's errors.
const MODEM_CTS: u8 = 1 << 4;
const MODEM_DSR: u8 = 1 << 5;
const MODEM_RLSD: u8 = 1 << 7;
const LINE_OVERRUN: u8 = 1 << 1;
const LINE_PARITY: u8 = 1 << 2;
const LINE_FRAMING: u8 = 1 << 3;
const LINE_BREAK: u8 = 1 << 4;
/// The latency, in milliseconds.
const latency_ms: u16 = 4;

/// The chip's rate ranges: from the slowest divisor of 3 MHz to 3 MBd.
const min_baud = 183;
const max_baud = 3_000_000;

const Kind = struct {
    pub const default_baud = 115_200;
    pub const State = struct {
        /// SET_DATA's frame, kept so a break can be added to it.
        frame: u16 = 8,
    };

    pub const Driver = _usbserial.Driver(Kind);

    /// An FTDI chip's first interface: its bulk IN and OUT endpoints.
    pub fn accept(ub: *UsbBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) ?_usbserial.Endpoints {
        const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return null;
        const out = ub.FindUSBEndpoint(device, interface, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return null;
        return .{ .in = in.endpoint_address, .out = out.endpoint_address };
    }

    /// The chip reset, its latency set, the line set from the unit's
    /// parameters, DTR and RTS on.
    pub fn start(ub: *UsbBase, adapter: *Driver.Adapter, params: *const serialunit.Params) void {
        _ = vendor(ub, adapter, REQ_RESET, RESET_SIO, 0);
        _ = vendor(ub, adapter, REQ_SET_LATENCY, latency_ms, 0);
        setLine(ub, adapter, params);
        _ = vendor(ub, adapter, REQ_MODEM_CTRL, MODEM_DTR_RTS_ON, 0);
    }

    pub fn setLine(ub: *UsbBase, adapter: *Driver.Adapter, params: *const serialunit.Params) void {
        const divisor = divisorOf(params.baud);
        _ = vendor(ub, adapter, REQ_SET_BAUD_RATE, @truncate(divisor), @truncate(divisor >> 16));
        var frame: u16 = params.read_len;
        frame |= switch (params.parity()) {
            .none => 0,
            .odd => DATA_PARITY_ODD,
            .even => DATA_PARITY_EVEN,
            .mark => DATA_PARITY_MARK,
            .space => DATA_PARITY_SPACE,
        };
        if (params.stop_bits == 2) frame |= DATA_STOP_2;
        adapter.state.frame = frame;
        _ = vendor(ub, adapter, REQ_SET_DATA, frame, 0);
        // xON and xOFF in the value, the kind of flow control in the
        // index's high byte.
        const xon_xoff = params.xonXoff();
        const characters: u16 = @truncate(params.ctl_char >> 16);
        _ = vendor(ub, adapter, REQ_SET_FLOW_CTRL, if (xon_xoff) (characters >> 8) | (characters << 8) else 0, if (xon_xoff) FLOW_XON_XOFF else 0);
    }

    pub fn sendBreak(ub: *UsbBase, sys: *ExecBase, adapter: *Driver.Adapter, microseconds: u32) bool {
        if (!vendor(ub, adapter, REQ_SET_DATA, adapter.state.frame | DATA_BREAK, 0)) return false;
        _usbserial.delayMicros(sys, microseconds);
        _ = vendor(ub, adapter, REQ_SET_DATA, adapter.state.frame, 0);
        return true;
    }

    /// What the chip can do: 7 or 8 bits, one frame both ways, 1 or 2
    /// stop bits, its rates.
    pub fn check(x: *const serial.IOExtSer) i8 {
        if (x.read_len != x.write_len or x.read_len < 7 or x.stop_bits == 0) return serial.SerErr_InvParam;
        if (x.baud < min_baud or x.baud > max_baud) return serial.SerErr_InvParam;
        return 0;
    }

    /// A packet: its two status bytes into the line's state and events,
    /// the rest to the unit.
    pub fn received(adapter: *Driver.Adapter, packet: []const u8) void {
        if (packet.len < 2) return;
        const modem = packet[0];
        const line = packet[1];
        var bits: u16 = 0;
        if (modem & MODEM_CTS == 0) bits |= serial.IO_STATF_CTS;
        if (modem & MODEM_DSR == 0) bits |= serial.IO_STATF_DSR;
        if (modem & MODEM_RLSD == 0) bits |= serial.IO_STATF_CD;
        @atomicStore(u16, &adapter.modem, bits, .release);
        const events = serialunit.Events{
            .overflow = line & LINE_OVERRUN != 0,
            .parity_error = line & LINE_PARITY != 0,
            .frame_error = line & LINE_FRAMING != 0,
            .brk = line & LINE_BREAK != 0,
        };
        if (packet.len == 2 and line & (LINE_OVERRUN | LINE_PARITY | LINE_FRAMING | LINE_BREAK) == 0) return;
        adapter.unit.input(packet[2..], events);
    }

    /// The chip has no notification endpoint.
    pub fn notified(adapter: *Driver.Adapter, report: []const u8) void {
        _ = adapter;
        _ = report;
    }

    fn vendor(ub: *UsbBase, adapter: *Driver.Adapter, request: u8, value: u16, index: u16) bool {
        return Driver.control(ub, adapter, d.USB_DIR_OUT | d.USB_TYPE_VENDOR | d.USB_RECIP_DEVICE, request, value, index, null, 0);
    }
};

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    return Kind.Driver.init(dev, seg_list, sys);
}

fn lvoUSBClassBind(base: *Kind.Driver.Base, binding: *usb.USBBinding) callconv(.c) bool {
    return Kind.Driver.bind(base, binding);
}
fn lvoUSBClassUnbind(base: *Kind.Driver.Base, binding: *usb.USBBinding) callconv(.c) void {
    Kind.Driver.unbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("ftdi.device: a class call does not match the SDK's type");
}

const vectors = [_]*const anyopaque{
    vec(Kind.Driver.open),
    vec(Kind.Driver.close),
    vec(Kind.Driver.expunge),
    vec(exec.libExtFunc),
    vec(Kind.Driver.beginIO),
    vec(Kind.Driver.abortIO),
    vec(lvoUSBClassBind),
    vec(lvoUSBClassUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(Kind.Driver.Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_SERIAL, devices.DEVIF_USBCLASS, 0 };

fn product(id: u16) usbclass.USBMatch {
    return .{ .fields = usbclass.USBMATCH_VENDOR | usbclass.USBMATCH_PRODUCT, .vendor_id = 0x0403, .product_id = id };
}

/// What it drives: FTDI's chips, by product.
const matches = [_]usbclass.USBMatch{ product(0x6001), product(0x6010), product(0x6011), product(0x6014), product(0x6015), .{} };

const labels = [_][*:0]const u8{ "FTDI 0", "FTDI 1", "FTDI 2", "FTDI 3" };

export const ftdi_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&ftdi_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = _usbserial.max_units,
        .unit_labels = &labels,
    },
    .matches = &matches,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
