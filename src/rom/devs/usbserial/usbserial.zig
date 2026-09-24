// SPDX-License-Identifier: MPL-2.0
//! usbserial.device: the USB-Serial-JTAG port (../serial/usbjtag.zig) as a serial
//! line, with serial.device's API: IOExtSer requests, its commands, io_Status
//! and its errors (sdk/devices/serial.zig, sdk/devices/usbserial.zig), on
//! one unit, 0.
//!
//! The port has no line of its own. SDCMD_SETPARAMS checks the parameters
//! as serial.device does and keeps them; the buffer size and termination
//! characters count, the rest goes on no wire. SDCMD_BREAK is IOERR_NOCMD,
//! and io_Status's lines are always active. Output to a port no host reads
//! is dropped after a while, so writes don't stall.
//!
//! The unit's code is serial.device's (../serial/unit.zig).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const unit = @import("../serial/unit.zig");

pub const DEVICE_NAME = sdk.devices.usbserial.USBSERIALNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "15.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const ports = [_]unit.Port{.usb};

/// exec has copied the tag's name, version and ID string into the base.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    unit.initDevice(dev, sys_base, &ports);
    return dev;
}

const init_table = exec.InitTable{
    .data_size = unit.dataSize(ports.len),
    .vectors = &unit.vectors,
    .vector_count = unit.vectors.len,
    .init = &init,
};

export const usbserial_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &usbserial_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
