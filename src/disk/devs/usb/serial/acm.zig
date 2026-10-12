// SPDX-License-Identifier: MIT
//! usb/acm.device: serial lines of the communications class's Abstract
//! Control Model (CDC-ACM) - a microcontroller's USB serial port, a
//! modem, the ESP32-S3's own USB-Serial-JTAG port - with serial.device's
//! API (sdk/devices/serial.zig); unit n is the nth such line plugged in
//! (`_usbserial.zig`).
//!
//! **Two interfaces**: the control interface it binds, with an
//! interrupt endpoint for the line's state, and the data interface its
//! union descriptor names (or the next one), with the bulk endpoints the
//! bytes go over. The data interface is claimed as well, so nothing else
//! takes it.
//!
//! **The line** is the class's requests: SET_LINE_CODING for the rate
//! and the frame, SET_CONTROL_LINE_STATE for DTR and RTS - both on
//! together while the line is bound, so a board that resets on DTR
//! alone (an ESP32's) is not reset - and SEND_BREAK, which the device
//! times itself. The line's state comes as SERIAL_STATE notifications:
//! carrier and DSR, and a break, a framing, a parity error or an overrun
//! seen on the far side.

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

pub const DEVICE_NAME = "acm.device";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "12.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// SET_CONTROL_LINE_STATE's value: DTR and RTS.
const DTR_RTS: u16 = 0x0003;
/// SERIAL_STATE's bits.
const STATE_DCD: u16 = 1 << 0;
const STATE_DSR: u16 = 1 << 1;
const STATE_BREAK: u16 = 1 << 2;
const STATE_FRAMING: u16 = 1 << 4;
const STATE_PARITY: u16 = 1 << 5;
const STATE_OVERRUN: u16 = 1 << 6;

const Kind = struct {
    pub const default_baud = 115_200;
    pub const State = struct {};

    pub const Driver = _usbserial.Driver(Kind);

    /// The control interface's notification endpoint, and the data
    /// interface's bulk endpoints - that interface claimed.
    pub fn accept(ub: *UsbBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) ?_usbserial.Endpoints {
        const notify = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse return null;
        const data_number = dataInterfaceOf(ub, device, interface);
        var previous: ?*const d.InterfaceDescriptor = null;
        const data = while (ub.FindUSBInterface(device, previous, d.USB_CLASS_CDC_DATA, -1, -1)) |found| : (previous = found) {
            if (found.interface_number == data_number) break found;
        } else return null;
        const in = ub.FindUSBEndpoint(device, data, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return null;
        const out = ub.FindUSBEndpoint(device, data, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return null;
        if (!ub.ClaimUSBInterface(device, data_number, "usb/" ++ DEVICE_NAME)) return null;
        return .{ .in = in.endpoint_address, .out = out.endpoint_address, .notify = notify.endpoint_address };
    }

    /// The data interface the union descriptor after `interface` names,
    /// or the one after it.
    fn dataInterfaceOf(ub: *UsbBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) u8 {
        var at: ?*const d.DescriptorHeader = @ptrCast(interface);
        while (ub.NextUSBDescriptor(device, at, 0)) |next| : (at = next) {
            if (next.descriptor_type == d.USB_DT_INTERFACE) break;
            if (next.descriptor_type != d.USB_DT_CS_INTERFACE or next.length < 5) continue;
            const bytes: [*]const u8 = @ptrCast(next);
            if (bytes[2] == d.CDC_FD_UNION) return bytes[4];
        }
        return interface.interface_number + 1;
    }

    /// The line set from the unit's parameters, DTR and RTS on.
    pub fn start(ub: *UsbBase, adapter: *Driver.Adapter, params: *const serialunit.Params) void {
        setLine(ub, adapter, params);
        _ = class(ub, adapter, d.CDC_REQ_SET_CONTROL_LINE_STATE, DTR_RTS, null, 0);
        // The lines count as active until the device says otherwise.
        adapter.modem = 0;
    }

    pub fn setLine(ub: *UsbBase, adapter: *Driver.Adapter, params: *const serialunit.Params) void {
        var coding: [7]u8 = undefined;
        const rate = params.baud;
        coding[0] = @truncate(rate);
        coding[1] = @truncate(rate >> 8);
        coding[2] = @truncate(rate >> 16);
        coding[3] = @truncate(rate >> 24);
        coding[4] = if (params.stop_bits == 2) 2 else 0;
        coding[5] = switch (params.parity()) {
            .none => 0,
            .odd => 1,
            .even => 2,
            .mark => 3,
            .space => 4,
        };
        coding[6] = params.read_len;
        _ = class(ub, adapter, d.CDC_REQ_SET_LINE_CODING, 0, &coding, coding.len);
    }

    /// SEND_BREAK for the time, in milliseconds; the device ends it, and
    /// the break's time is waited out before SDCMD_BREAK is answered.
    pub fn sendBreak(ub: *UsbBase, sys: *ExecBase, adapter: *Driver.Adapter, microseconds: u32) bool {
        const ms: u16 = @intCast(@min(@max(microseconds / 1000, 1), 0xFFFE));
        if (!class(ub, adapter, d.CDC_REQ_SEND_BREAK, ms, null, 0)) return false;
        _usbserial.delayMicros(sys, microseconds);
        return true;
    }

    /// What the class can say: 5 to 8 bits, one frame both ways, 1 or 2
    /// stop bits.
    pub fn check(x: *const serial.IOExtSer) i8 {
        if (x.read_len != x.write_len or x.read_len < 5 or x.stop_bits == 0) return serial.SerErr_InvParam;
        return 0;
    }

    /// Bytes: to the unit as they are.
    pub fn received(adapter: *Driver.Adapter, bytes: []const u8) void {
        if (bytes.len == 0) return;
        adapter.unit.input(bytes, .{});
    }

    /// A SERIAL_STATE notification: carrier and DSR into the line's state,
    /// what went wrong on the far side to the unit.
    pub fn notified(adapter: *Driver.Adapter, report: []const u8) void {
        if (report.len < 10 or report[1] != d.CDC_NOTIFY_SERIAL_STATE) return;
        const state = @as(u16, report[8]) | @as(u16, report[9]) << 8;
        var bits: u16 = 0;
        if (state & STATE_DCD == 0) bits |= serial.IO_STATF_CD;
        if (state & STATE_DSR == 0) bits |= serial.IO_STATF_DSR;
        @atomicStore(u16, &adapter.modem, bits, .release);
        const events = serialunit.Events{
            .brk = state & STATE_BREAK != 0,
            .frame_error = state & STATE_FRAMING != 0,
            .parity_error = state & STATE_PARITY != 0,
            .overflow = state & STATE_OVERRUN != 0,
        };
        if (events.brk or events.frame_error or events.parity_error or events.overflow) adapter.unit.input(&.{}, events);
    }

    fn class(ub: *UsbBase, adapter: *Driver.Adapter, request: u8, value: u16, data: ?*anyopaque, length: u16) bool {
        return Driver.control(ub, adapter, d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE, request, value, adapter.interface_number, data, length);
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
        @compileError("acm.device: a class call does not match the SDK's type");
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

fn acmProtocol(protocol: u8) usbclass.USBMatch {
    return .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL,
        .interface_class = d.USB_CLASS_COMM,
        .interface_subclass = d.CDC_SUBCLASS_ACM,
        .interface_protocol = protocol,
    };
}

/// What it drives: the communications class's serial lines - with no
/// command protocol, or one of AT commands' - but not a vendor's own
/// protocol over the same interfaces (0xFF), which is RNDIS's and not a
/// serial line at all.
const matches = [_]usbclass.USBMatch{ acmProtocol(0), acmProtocol(1), acmProtocol(2), acmProtocol(3), acmProtocol(4), acmProtocol(5), acmProtocol(6), .{} };

const labels = [_][*:0]const u8{ "ACM 0", "ACM 1", "ACM 2", "ACM 3" };

export const acm_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&acm_device_tag),
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
