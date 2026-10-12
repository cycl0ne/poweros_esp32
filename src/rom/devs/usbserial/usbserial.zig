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
//!
//! **The system log's copy.** Until this device starts, the raw port
//! writes the log to the USB port itself where it is wanted there
//! (`LOGCTRL_MIRROR`); from then on the port is this device's, and a task
//! of its own - "usbserial log" - follows the log (`SetLogSignal`) and
//! writes what comes to the port, "\n" as "\r\n", between the console's
//! writes and never inside one. It starts where the raw port stopped, so
//! no line goes out twice or not at all. While the copy is not wanted it
//! reads past what comes, so turning it on starts with the lines after.
//! The task keeps the device open for good: it is not expunged under it.
//!
//! **The port.** The same task bids for the port with usbport.resource,
//! at USBPORTPRI_CONSOLE, the lowest priority: anyone else who wants it -
//! usbotg.device, as its bus starts on the ESP32-S3, whose one port both
//! use - has it. Told the port is wanted, the task holds the unit's
//! writes, so one under way goes out whole, and lets go; it stays a
//! bidder, and has the port back once the other is done. While the port
//! is away no host reads, and what is written is dropped, as it is with
//! no cable in.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const unit = @import("../serial/unit.zig");
const usbport = sdk.resources.usbport;
const UsbPortBase = usbport.UsbPortBase;

pub const DEVICE_NAME = sdk.devices.usbserial.USBSERIALNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 3;
const BUILD_DATE = "12.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const ports = [_]unit.Port{.usb};

/// What the log's copy and the port's bid need: their task, the stack it
/// runs on, the bid, where it has read the log to, and room to read and
/// to write. One block, made at init in internal memory.
const Mirror = struct {
    task: exec.Task = .{},
    dev: *exec.Device,
    /// The bid for the port, and the resource it is made with.
    port: usbport.USBPortHandle = .{},
    port_base: ?*UsbPortBase = null,
    /// The log's running number of the next byte to copy.
    position: u64 = 0,
    from_log: [256]u8 = undefined,
    /// What goes out: the log's bytes, a "\r" before every "\n".
    to_port: [512]u8 = undefined,
    stack: [mirror_stack]u8 = undefined,
};

const mirror_stack = 3 * 1024;
const mirror_pri = -1;

/// exec has copied the tag's name, version and ID string into the base.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    unit.initDevice(dev, sys_base, &ports);
    startMirror(dev, sys_base);
    return dev;
}

/// The log's copy taken over from the raw port: from the byte it would
/// have written next, so nothing is missed and nothing goes out twice.
fn startMirror(dev: *exec.Device, sys: *ExecBase) void {
    const memory = sys.AllocMem(@sizeOf(Mirror), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return;
    const mirror: *Mirror = @ptrCast(@alignCast(memory));
    mirror.* = .{ .dev = dev };
    sys.Disable();
    // A size of 0 reads nothing and moves the position to the log's end.
    mirror.position = std.math.maxInt(u64);
    _ = sys.ReadLog(&mirror.position, &mirror.from_log, 0);
    _ = sys.LogControl(exec.LOGCTRL_USBPORT, 1);
    sys.Enable();
    mirror.task = .{
        .node = .{ .type = .task, .pri = mirror_pri, .name = "usbserial" },
        .sp_lower = @intFromPtr(&mirror.stack),
        .sp_upper = @intFromPtr(&mirror.stack) + mirror_stack,
    };
    // The task writes to the port for good: the device stays open for it.
    dev.open_cnt += 1;
    _ = sys.AddTask(&mirror.task, &mirrorTask, null);
}

/// Bids for the port, follows the log and copies what comes to the port
/// while that is wanted, and lets the port go when someone else wants it.
fn mirrorTask(sys: *ExecBase) callconv(.c) void {
    const mirror: *Mirror = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return;
    const mask = @as(u32, 1) << @intCast(bit);
    if (!sys.SetLogSignal(null, mask)) return;
    const port_mask = bidForPort(sys, mirror);
    while (true) {
        const got = sys.Wait(mask | port_mask);
        if (got & port_mask != 0) letPortGo(mirror);
        if (got & mask == 0) continue;
        while (true) {
            const count = sys.ReadLog(&mirror.position, &mirror.from_log, mirror.from_log.len);
            if (count == 0) break;
            if (sys.LogControl(exec.LOGCTRL_MIRROR, exec.LOGCTRL_ASK) != 1) continue;
            var length: usize = 0;
            for (mirror.from_log[0..count]) |byte| {
                if (byte == '\n') {
                    mirror.to_port[length] = '\r';
                    length += 1;
                }
                mirror.to_port[length] = byte;
                length += 1;
            }
            unit.writeAside(mirror.dev, 0, mirror.to_port[0..length]);
        }
    }
}

/// The bid for the port, from the task: the signal it is told by, or 0
/// without the resource or a signal to spare.
fn bidForPort(sys: *ExecBase, mirror: *Mirror) u32 {
    const found = sys.OpenResource(usbport.USBPORTNAME) orelse return 0;
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return 0;
    const mask = @as(u32, 1) << @intCast(bit);
    const pb: *UsbPortBase = @ptrCast(@alignCast(found));
    mirror.port_base = pb;
    mirror.port = .{
        .node = .{ .pri = usbport.USBPORTPRI_CONSOLE, .name = DEVICE_NAME },
        .task = &mirror.task,
        .signals = mask,
        .controller = usbport.USBCTL_SERIALJTAG,
    };
    _ = pb.OwnUSBPort(&mirror.port);
    return mask;
}

/// The port given up if someone else wants it: between two writes, and
/// the bid kept, so it comes back.
fn letPortGo(mirror: *Mirror) void {
    const pb = mirror.port_base orelse return;
    if (mirror.port.state != usbport.USBPORT_WANTED) return;
    unit.holdWrites(mirror.dev, 0);
    defer unit.releaseWrites(mirror.dev, 0);
    pb.ReleaseUSBPort(&mirror.port, 0);
}

const init_table = exec.InitTable{
    .data_size = unit.dataSize(ports.len),
    .vectors = &unit.vectors,
    .vector_count = unit.vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: its one unit, the chip's USB-Serial-JTAG port.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_STREAM, sdk.expansion.devices.DEVIF_SERIAL, 0 };
const device_unit_labels = [_][*:0]const u8{"USB-Serial-JTAG"};

export const usbserial_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&usbserial_device_tag),
        .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .units = 1,
    .unit_labels = &device_unit_labels,
};
