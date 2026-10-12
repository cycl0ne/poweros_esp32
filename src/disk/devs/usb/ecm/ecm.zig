// SPDX-License-Identifier: MIT
//! usb/ecm.device: USB Ethernet adapters of the communications class's
//! Ethernet Control Model (CDC-ECM) as a network device
//! (sdk/devices/network.zig); unit n is the nth adapter plugged in, and
//! `DEVS:NetInterfaces/USB0` puts unit 0 on bsdsocket.library when the
//! first adapter comes (netif.zig): nothing of this is loaded before.
//!
//! **Units are links, not adapters.** An adapter bound takes the lowest
//! free unit, and its Ethernet address becomes the unit's - unless an
//! opener configured the unit with another. Pulled out, it leaves the
//! unit without a carrier: off line, what was waiting answered, until
//! the next one comes. A unit may be opened and configured with nothing
//! plugged in.
//!
//! **Two interfaces**: the control interface it binds, with an interrupt
//! endpoint for notifications, and the data interface its union
//! descriptor names - claimed, so nothing else takes it - whose second
//! alternate setting has the bulk endpoints the frames go over. The bind
//! resets the data interface to its first setting and selects the second,
//! and reads the adapter's address from the string the Ethernet
//! functional descriptor names. The carrier is the adapter's
//! NETWORK_CONNECTION notification; an adapter with no notifications has
//! one while it is plugged in.
//!
//! **Every request runs on the device's own task**, except S2_DEVICEQUERY
//! and S2_GETSTATIONADDRESS, answered where they are asked. The pipes'
//! answers and the binds' commands come to the same task on the same
//! signal, so one Wait serves the openers, the adapters and the bus.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const usb = sdk.usb;
const d = usb.descriptors;
const usbclass = sdk.devices.usbclass;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const _ecm = @import("_ecm.zig");
const cdc = @import("cdc.zig");
const netif = @import("netif.zig");
const EcmBase = _ecm.EcmBase;
const Link = _ecm.Link;
const Command = _ecm.Command;

pub const DEVICE_NAME = _ecm.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "12.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for a request and the openers' copy calls; nothing here
/// recurses.
const stack_size = 4096;
/// As the other network devices' tasks.
const task_pri = 5;
/// The DOS process that brings up the interfaces: it runs a command.
const netif_stack = 8192;
const netif_pri = 4;

// --- the task -------------------------------------------------------------

/// Every request, every pipe's answer and every bind, of every link.
fn ecmTask(sys: *ExecBase) callconv(.c) void {
    const base: *EcmBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(base);
    base.work_mask = @as(u32, 1) << @intCast(signal);
    sys.Disable();
    var ports: [2 + _ecm.max_units]*exec.MsgPort = undefined;
    ports[0] = &base.pipes;
    ports[1] = &base.commands;
    for (&base.links, 0..) |*link, index| ports[2 + index] = &link.unit.msg_port;
    for (ports) |port| {
        port.sig_bit = @intCast(signal);
        port.sig_task = &base.task;
        port.flags = exec.PA_SIGNAL;
    }
    sys.Enable();

    base.timer_io = .{};
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) base.timer_open = 1;
    base.ready = 1;
    started(base);

    const ub = base.ub();
    while (true) {
        // Every port looked at again after any work: one signal serves
        // them all, and a pipe waited for may take it from an answer that
        // came meanwhile.
        var worked = true;
        while (worked) {
            worked = false;
            while (sys.GetMsg(&base.commands)) |msg| {
                command(base, @fieldParentPtr("message", msg));
                worked = true;
            }
            while (sys.GetMsg(&base.pipes)) |msg| {
                for (&base.links) |*link| {
                    if (link.replied(ub, msg)) break;
                }
                worked = true;
            }
            for (&base.links) |*link| {
                link.refilter();
                while (sys.GetMsg(&link.unit.msg_port)) |msg| {
                    link.net.perform(_ecm.sanaReq(_ecm.requestOf(msg)));
                    worked = true;
                }
            }
        }
        _ = sys.Wait(base.work_mask);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(base: *EcmBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

/// A bind's adapter taken up, or an unbind's let go of and its waiter
/// answered.
fn command(base: *EcmBase, cmd: *Command) void {
    const link = cmd.link.?;
    switch (cmd.kind) {
        .start => link.attach(),
        .let_go => {
            link.letGo(base.ub());
            base.sys_base.ReplyMsg(&cmd.message);
        },
    }
}

// --- the class driver's calls -----------------------------------------------

/// A control interface of CDC-ECM: its data interface found and claimed,
/// reset and set to the setting with the bulk endpoints, the address read,
/// the pipes opened, the lowest free unit given it and the task handed
/// it.
fn bind(base: *EcmBase, binding: *usb.USBBinding) bool {
    const sys = base.sys_base;
    const ub = base.usb_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;

    const found = functionOf(ub, device, interface) orelse return false;
    var previous: ?*const d.InterfaceDescriptor = null;
    const data = while (ub.FindUSBInterface(device, previous, d.USB_CLASS_CDC_DATA, -1, -1)) |each| : (previous = each) {
        if (each.interface_number == found.data_number and
            ub.FindUSBEndpoint(device, each, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) != null) break each;
    } else return false;
    const in = ub.FindUSBEndpoint(device, data, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK).?;
    const out = ub.FindUSBEndpoint(device, data, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return false;
    const notify = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT);

    var text: [32]u8 = undefined;
    const length = ub.GetUSBString(device, found.address_string, &text, text.len);
    if (length < 0) return false;
    const address = cdc.addressOf(text[0..@intCast(length)]) orelse return false;

    if (!ub.ClaimUSBInterface(device, found.data_number, "usb/" ++ DEVICE_NAME)) return false;
    if (!setInterface(ub, device, found.data_number, 0) or
        !setInterface(ub, device, found.data_number, data.alternate_setting))
    {
        ub.ReleaseUSBInterface(device, found.data_number);
        return false;
    }

    const bulk_in = ub.OpenUSBPipe(device, in.endpoint_address, &base.pipes);
    const bulk_out = ub.OpenUSBPipe(device, out.endpoint_address, &base.pipes);
    const notify_pipe = if (notify) |endpoint| ub.OpenUSBPipe(device, endpoint.endpoint_address, &base.pipes) else null;
    sys.ObtainSemaphore(&base.lock);
    const link: ?*Link = if (bulk_in == null or bulk_out == null or (notify != null and notify_pipe == null)) null else for (&base.links) |*each| {
        if (each.bound == 0) break each;
    } else null;
    if (link) |taken| {
        taken.bound = 1;
        taken.leaving = 0;
        taken.device = device;
        taken.bulk_in = bulk_in;
        taken.bulk_out = bulk_out;
        taken.notify = notify_pipe;
        taken.address = address;
        taken.control_number = interface.interface_number;
    }
    sys.ReleaseSemaphore(&base.lock);
    const taken = link orelse {
        ub.CloseUSBPipe(bulk_in);
        ub.CloseUSBPipe(bulk_out);
        ub.CloseUSBPipe(notify_pipe);
        ub.ReleaseUSBInterface(device, found.data_number);
        return false;
    };
    binding.driver_data = taken;
    binding.unit = base.unitNumber(taken);
    taken.start = .{ .kind = .start, .link = taken };
    taken.start.message.length = @sizeOf(Command);
    sys.PutMsg(&base.commands, &taken.start.message);
    return true;
}

/// What the functional descriptors after a control interface say: the
/// data interface (the union's, or the next one) and the address's
/// string.
const Function = struct { data_number: u8, address_string: u8 };

fn functionOf(ub: *UsbBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) ?Function {
    var data_number = interface.interface_number + 1;
    var address_string: ?u8 = null;
    var at: ?*const d.DescriptorHeader = @ptrCast(interface);
    while (ub.NextUSBDescriptor(device, at, 0)) |next| : (at = next) {
        if (next.descriptor_type == d.USB_DT_INTERFACE) break;
        if (next.descriptor_type != d.USB_DT_CS_INTERFACE or next.length < 4) continue;
        const bytes: [*]const u8 = @ptrCast(next);
        switch (bytes[2]) {
            d.CDC_FD_UNION => if (next.length >= 5) {
                data_number = bytes[4];
            },
            d.CDC_FD_ETHERNET => address_string = bytes[3],
            else => {},
        }
    }
    return .{ .data_number = data_number, .address_string = address_string orelse return null };
}

/// SET_INTERFACE: whether the device took it.
fn setInterface(ub: *UsbBase, device: *usb.USBDevice, number: u8, alternate: u8) bool {
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_OUT | d.USB_TYPE_STANDARD | d.USB_RECIP_INTERFACE,
        .request = d.USB_REQ_SET_INTERFACE,
        .value = alternate,
        .index = number,
        .length = 0,
    };
    return ub.DoUSBControl(device, &setup, null, null) == 0;
}

/// An adapter let go of: its transfers aborted at once, then the task
/// waited for while it takes the adapter off its unit.
fn unbind(base: *EcmBase, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    const raw = binding.driver_data orelse return;
    const link: *Link = @ptrCast(@alignCast(raw));
    @atomicStore(u8, &link.leaving, 1, .release);
    _ = sys.AbortIO(&link.bulk_in.?.io.std.req);
    _ = sys.AbortIO(&link.bulk_out.?.io.std.req);
    if (link.notify) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var cmd = Command{ .kind = .let_go, .link = link };
    cmd.message.reply_port = reply;
    cmd.message.length = @sizeOf(Command);
    sys.PutMsg(&base.commands, &cmd.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    binding.driver_data = null;
}

// --- the device -----------------------------------------------------------

/// The commands the task answers.
fn queued(cmd: u16) bool {
    return switch (cmd) {
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_FLUSH,
        net.S2_CONFIGINTERFACE,
        net.S2_ADDMULTICASTADDRESS,
        net.S2_DELMULTICASTADDRESS,
        net.S2_MULTICAST,
        net.S2_BROADCAST,
        net.S2_TRACKTYPE,
        net.S2_UNTRACKTYPE,
        net.S2_GETTYPESTATS,
        net.S2_GETSPECIALSTATS,
        net.S2_GETGLOBALSTATS,
        net.S2_ONEVENT,
        net.S2_READORPHAN,
        net.S2_ONLINE,
        net.S2_OFFLINE,
        => true,
        else => false,
    };
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _ecm.ecmBase(dev);
    if (io.unit == null) {
        io.err = exec.IOERR_NOCMD;
        return base.sys_base.ReplyIO(io);
    }
    const link = _ecm.linkOf(io);
    const req = _ecm.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => link.net.query(req),
        net.S2_GETSTATIONADDRESS => link.net.stationAddress(req),
        else => if (queued(io.command)) {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&link.unit.msg_port, &io.message);
            }
        } else {
            io.err = exec.IOERR_NOCMD;
        },
    }
    base.sys_base.ReplyIO(io);
}

/// A request the task hasn't taken yet, or one waiting in the unit - a
/// read, a write, an event - is taken back and answered as aborted. One
/// being sent can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const sys = _ecm.ecmBase(dev).sys_base;
    if (io.unit == null) return -1;
    const link = _ecm.linkOf(io);
    sys.Disable();
    var it = link.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_ecm.requestOf(msg) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (link.net.abort(_ecm.sanaReq(io))) 0 else -1;
}

/// usb.library's open for the class calls has no unit; every other opener
/// gets its record from the unit, adapter or not.
fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _ecm.ecmBase(dev);
    if (unit_number == usbclass.USBCLASS_UNIT_BIND) {
        dev.open_cnt += 1;
        dev.flags &= ~exec.LIBF_DELEXP;
        io.unit = null;
        return 0;
    }
    if (unit_number >= _ecm.max_units or base.ready == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const link = &base.links[unit_number];
    const refused = link.net.open(_ecm.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    link.unit.open_cnt += 1;
    io.unit = &link.unit;
    return 0;
}

fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    if (io.unit != null) {
        const link = _ecm.linkOf(io);
        link.net.close(_ecm.sanaReq(io));
        link.unit.open_cnt -= 1;
    }
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, and a unit may be held for good.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// usb.library opened, the links made - each without an adapter, so
/// without a carrier - and the task and the DOS process started; this
/// waits until both are ready.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _ecm.ecmBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    sys.InitSemaphore(&base.lock);

    base.utility = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null);
    base.usb_base = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return null);
    base.dos_base = @ptrCast(sys.OpenLibrary(sdk.dos.DOSNAME, 0) orelse return null);

    // PA_IGNORE until the task has a signal for them: whatever comes in
    // while the device starts is queued, and the task takes it then.
    for ([_]*exec.MsgPort{ &base.pipes, &base.commands }) |port| {
        port.* = .{ .flags = exec.PA_IGNORE };
        port.msg_list.init(.message);
    }
    const factory: [6]u8 = @splat(0);
    for (&base.links) |*link| {
        link.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
        link.unit.msg_port.msg_list.init(.message);
        link.base = base;
        link.filter_wanted = cdc.packetFilter(false, false);
        link.net.init(sys, link, &factory);
        link.net.setCarrier(false);
    }

    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse return null;
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    const wake = @as(u32, 1) << @intCast(signal);
    base.starter = sys.FindTask(null);
    _ = sys.AddTask(&base.task, &ecmTask, null);
    _ = sys.Wait(wake);
    if (base.ready == 0) return null;

    const tags = [_]sdk.utility.TagItem{
        .{ .tag = sdk.dos.NP_Entry, .data = @intFromPtr(&netif.netifProcess) },
        .{ .tag = sdk.dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, "ecm.device interfaces")) },
        .{ .tag = sdk.dos.NP_StackSize, .data = netif_stack },
        .{ .tag = sdk.dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, netif_pri))) },
        .{ .tag = sdk.dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    base.starter = sys.FindTask(null);
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return null;
    }
    _ = sys.Wait(wake);
    if (base.adder == null) return null;
    return dev;
}

fn lvoUSBClassBind(base: *EcmBase, binding: *usb.USBBinding) callconv(.c) bool {
    return bind(base, binding);
}
fn lvoUSBClassUnbind(base: *EcmBase, binding: *usb.USBBinding) callconv(.c) void {
    unbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("ecm.device: a class call does not match the SDK's type");
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
    .data_size = @sizeOf(EcmBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_SANA2, devices.DEVIF_USBCLASS, 0 };

/// What it drives: the communications class's Ethernet functions.
const matches = [_]usbclass.USBMatch{
    .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS,
        .interface_class = d.USB_CLASS_COMM,
        .interface_subclass = d.CDC_SUBCLASS_ECM,
    },
    .{},
};

const labels = [_][*:0]const u8{ "Ethernet 0", "Ethernet 1" };

export const ecm_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&ecm_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = _ecm.max_units,
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
