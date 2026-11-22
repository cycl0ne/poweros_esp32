// SPDX-License-Identifier: MIT
//! usb/bluetooth.device: Bluetooth controllers on USB - the interface of
//! class 224/1/1 that has an interrupt endpoint in and bulk endpoints in
//! and out - as HCI units (sdk/devices/hci.zig), one per controller
//! plugged in, for bluetooth.library.
//!
//! **A controller plugged in** is bound by usb.library on its bus's
//! process: the device takes a free unit, opens the controller's pipes -
//! its control endpoint for commands, the interrupt endpoint for events,
//! the bulk endpoints for ACL data - and hands the unit to its worker
//! (worker.zig). A MediaTek MT79xx is given its firmware first, from
//! `DEVS:usb/firmware/mediatek/` (mediatek.zig); every other controller
//! is taken as it is. The unit then opens, and is offered to
//! bluetooth.library with `AddBTController("usb/bluetooth.device", n)`.
//!
//! **Unplugged**, the unbind takes its transfers back and waits while the
//! worker answers everything the unit holds, takes the unit from
//! bluetooth.library and closes the pipes.
//!
//! HCICMD_QUERY is answered at once, in the caller's task; CMD_READ,
//! CMD_WRITE and CMD_FLUSH go to the worker. A unit whose controller is
//! being let go answers everything HCIERR_DETACHED. Its units come and go
//! with the controllers, so its ROM tag lists none.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const d = usb.descriptors;
const usbclass = sdk.devices.usbclass;
const hcidev = sdk.devices.hci;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const _bt = @import("_bluetooth.zig");
const worker = @import("worker.zig");
const mediatek = @import("mediatek.zig");
const BtBase = _bt.BtBase;
const Unit = _bt.Unit;

pub const DEVICE_NAME = _bt.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "22.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The worker reads a firmware file and runs the chip's setup; the
/// setup's packets are on its stack.
const worker_stack = 16384;
const worker_pri = 5;

// --- the class driver's calls -----------------------------------------------

/// The controller's interface: an interrupt endpoint in and bulk
/// endpoints in and out - the other interfaces of its class (SCO's, a
/// chip's own) are left. A free unit taken, the pipes opened, and the
/// worker handed the unit.
fn bind(base: *BtBase, binding: *usb.USBBinding) bool {
    const sys = base.sys_base;
    const ub = base.usb_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;
    const events = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse return false;
    const acl_in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return false;
    const acl_out = ub.FindUSBEndpoint(device, interface, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return false;
    sys.ObtainSemaphore(&base.lock);
    var free: ?*Unit = null;
    for (&base.units) |*unit| {
        if (unit.bound == 0) {
            unit.bound = 1;
            free = unit;
            break;
        }
    }
    sys.ReleaseSemaphore(&base.lock);
    const unit = free orelse {
        exec.kprintf(sys, "%s: no unit left for another controller\n", .{@as([*:0]const u8, DEVICE_NAME)});
        return false;
    };
    unit.control = ub.OpenUSBPipe(device, 0, &base.pipes);
    unit.events_in = ub.OpenUSBPipe(device, events.endpoint_address, &base.pipes);
    unit.acl_in = ub.OpenUSBPipe(device, acl_in.endpoint_address, &base.pipes);
    unit.acl_out = ub.OpenUSBPipe(device, acl_out.endpoint_address, &base.pipes);
    if (unit.control == null or unit.events_in == null or unit.acl_in == null or unit.acl_out == null) {
        ub.CloseUSBPipe(unit.control);
        ub.CloseUSBPipe(unit.events_in);
        ub.CloseUSBPipe(unit.acl_in);
        ub.CloseUSBPipe(unit.acl_out);
        sys.ObtainSemaphore(&base.lock);
        unit.control = null;
        unit.events_in = null;
        unit.acl_in = null;
        unit.acl_out = null;
        unit.bound = 0;
        sys.ReleaseSemaphore(&base.lock);
        return false;
    }
    unit.device = device;
    unit.vendor = if (mediatek.isMediaTek(device.descriptor.vendor_id, device.descriptor.product_id)) _bt.VENDOR_MEDIATEK else _bt.VENDOR_NONE;
    unit.chip[0] = 0;
    unit.firmware[0] = 0;
    unit.added = 0;
    @atomicStore(u8, &unit.ready, 0, .release);
    @atomicStore(u8, &unit.leaving, 0, .release);
    binding.driver_data = unit;
    binding.unit = unit.number;
    exec.kprintf(sys, "%s: unit %u: a controller, %04x:%04x\n", .{
        @as([*:0]const u8, DEVICE_NAME),
        unit.number,
        @as(u32, device.descriptor.vendor_id),
        @as(u32, device.descriptor.product_id),
    });
    unit.start = .{ .kind = .start, .unit = unit.number };
    unit.start.message.length = @sizeOf(_bt.Command);
    sys.PutMsg(&base.commands, &unit.start.message);
    return true;
}

/// The controller let go of: its transfers taken back at once, then the
/// worker waited for while it answers what the unit holds and closes the
/// pipes.
fn unbind(base: *BtBase, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    const unit: *Unit = @ptrCast(@alignCast(binding.driver_data orelse return));
    @atomicStore(u8, &unit.leaving, 1, .release);
    for ([_]?*usb.USBPipe{ unit.control, unit.events_in, unit.acl_in, unit.acl_out }) |pipe| {
        if (pipe) |open| _ = sys.AbortIO(&open.io.std.req);
    }
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var cmd = _bt.Command{ .kind = .let_go, .unit = unit.number };
    cmd.message.reply_port = reply;
    cmd.message.length = @sizeOf(_bt.Command);
    sys.PutMsg(&base.commands, &cmd.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    binding.driver_data = null;
}

// --- the device -----------------------------------------------------------

/// What the unit is: its bus, and the chip and firmware where it knows
/// them.
fn query(unit: *Unit, io: *exec.IORequest) void {
    const req = _bt.hciReq(io);
    if (req.std.data == null or req.std.length < @sizeOf(hcidev.HCIInfo)) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    const info: *hcidev.HCIInfo = @ptrCast(@alignCast(req.std.data.?));
    info.* = .{
        .bus = hcidev.HCIBUS_USB,
        .baud = 0,
        .chip = if (unit.chip[0] != 0) @ptrCast(&unit.chip) else null,
        .firmware = if (unit.firmware[0] != 0) @ptrCast(&unit.firmware) else null,
    };
    req.std.actual = @sizeOf(hcidev.HCIInfo);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _bt.btBase(dev);
    const sys = base.sys_base;
    if (io.unit == null) {
        io.err = exec.IOERR_NOCMD;
        return sys.ReplyIO(io);
    }
    const unit = _bt.unitOf(io);
    io.err = 0;
    switch (io.command) {
        hcidev.HCICMD_QUERY => query(unit, io),
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_FLUSH => {
            if (@atomicLoad(u8, &unit.leaving, .acquire) != 0 or @atomicLoad(u8, &unit.ready, .acquire) == 0) {
                io.err = hcidev.HCIERR_DETACHED;
            } else if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                // Answered by the worker: not quick.
                io.flags &= ~exec.IOF_QUICK;
                return sys.PutMsg(&unit.unit.msg_port, &io.message);
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// The request found where it waits - on the unit's port for the worker,
/// among the reads, among the writes not yet sent - taken off and
/// answered as aborted. A write being sent goes on to its end.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _bt.btBase(dev);
    const sys = base.sys_base;
    if (io.unit == null) return -1;
    const unit = _bt.unitOf(io);
    sys.Disable();
    for ([_]*exec.List{ &unit.unit.msg_port.msg_list, &unit.reads, &unit.writes }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const message: *exec.Message = @fieldParentPtr("node", node);
            if (_bt.requestOf(message) != io) continue;
            sys.Remove(node);
            sys.Enable();
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    sys.Enable();
    return -1;
}

/// usb.library's open for the class calls has no unit; a unit opens once
/// its controller is ready.
fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _bt.btBase(dev);
    if (unit_number == usbclass.USBCLASS_UNIT_BIND) {
        dev.open_cnt += 1;
        dev.flags &= ~exec.LIBF_DELEXP;
        io.unit = null;
        return 0;
    }
    if (unit_number >= _bt.UNITS) return exec.IOERR_OPENFAIL;
    const unit = &base.units[unit_number];
    if (@atomicLoad(u8, &unit.ready, .acquire) == 0 or @atomicLoad(u8, &unit.leaving, .acquire) != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(hcidev.IOHciReq)) return exec.IOERR_BADLENGTH;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    unit.unit.open_cnt += 1;
    io.unit = &unit.unit;
    return 0;
}

fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    if (io.unit != null) _bt.unitOf(io).unit.open_cnt -= 1;
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its worker.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The libraries opened, the units made - none bound - and the worker
/// started; this waits until it is ready.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _bt.btBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    sys.InitSemaphore(&base.lock);
    base.usb_base = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return null);
    base.dos_base = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return null);
    // PA_IGNORE until the worker has a signal for them: whatever comes in
    // while the device starts is queued, and the worker takes it then.
    for ([_]*exec.MsgPort{ &base.commands, &base.pipes }) |port| {
        port.* = .{ .flags = exec.PA_IGNORE };
        port.msg_list.init(.message);
    }
    for (&base.units, 0..) |*unit, number| {
        unit.* = .{ .number = @intCast(number) };
        unit.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
        unit.unit.msg_port.msg_list.init(.message);
        unit.reads.init(.message);
        unit.writes.init(.message);
    }
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    base.starter = sys.FindTask(null);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&worker.workerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, DEVICE_NAME)) },
        .{ .tag = dos.NP_StackSize, .data = worker_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, worker_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return null;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (base.ready == 0) return null;
    return dev;
}

fn lvoUSBClassBind(base: *BtBase, binding: *usb.USBBinding) callconv(.c) bool {
    return bind(base, binding);
}
fn lvoUSBClassUnbind(base: *BtBase, binding: *usb.USBBinding) callconv(.c) void {
    unbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("bluetooth.device: a class call does not match the SDK's type");
}

/// The six standard vectors, then the class driver's two.
const vectors = [_]*const anyopaque{
    vec(openDevice),
    vec(closeDevice),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoUSBClassBind),
    vec(lvoUSBClassUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(BtBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_HCI, devices.DEVIF_USBCLASS, 0 };

/// What it drives: the Bluetooth controller interface of USB's wireless
/// class.
const matches = [_]usbclass.USBMatch{
    .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL,
        .interface_class = d.USB_CLASS_WIRELESS_CONTROLLER,
        .interface_subclass = d.USB_SUBCLASS_RF_CONTROLLER,
        .interface_protocol = d.USB_PROTOCOL_BLUETOOTH,
    },
    .{},
};

/// AUTOINIT and DEVICEINFO: made when usb.library opens it, and its match
/// table read from the file without loading it.
export const bluetooth_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&bluetooth_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = 0,
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
