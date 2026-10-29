// SPDX-License-Identifier: MIT
//! xhci.device: USB host controllers on PCI that speak xHCI, as
//! `DEVIF_USBHC` (sdk/devices/usbhc.zig) has a host controller - what
//! usb.library runs a bus on. Unit n is the nth xHCI function
//! pci.library found: the VisionFive 2's VL805, QEMU's qemu-xhci.
//!
//!   UHCMD_CONTROLXFER  a control transfer: setup, data, status
//!   UHCMD_BULKXFER     a bulk transfer, in rounds of 16 KiB
//!   UHCMD_INTXFER      an interrupt transfer, asked by the controller at
//!                      the endpoint's interval until the device answers
//!   UHCMD_ISOXFER      an isochronous transfer, OUT or IN: a TD a packet
//!                      in its frame, each packet told what became of
//!                      it, up to four requests on the endpoint's ring
//!                      at once
//!   UHCMD_USBRESET     every transfer answered, the controller started
//!                      afresh
//!   UHCMD_USBSUSPEND,
//!   UHCMD_USBRESUME    IOERR_NOCMD
//!   UHCMD_QUERYDEVICE  what the controller is (`USBHCInfo`)
//!
//! A transfer to the root hub's address is the root hub's (roothub.zig);
//! everything else goes to a device slot's endpoint (slots.zig,
//! transfer.zig). The unit's block, its task and its interrupt are in
//! _xhci.zig's design, the controller in controller.zig's.
//!
//! **A unit's life.** The first OpenDevice of a unit makes its block and
//! task, claims its PCI function and starts the controller: reset, its
//! rings set up, its interrupt hooked, run. The last CloseDevice stops
//! it - every transfer answered, the controller halted - and the task
//! waits for the next opener. The block, the task and the function stay
//! the device's: the task cannot give back the stack it runs on, and the
//! device stays once loaded.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const _xhci = @import("_xhci.zig");
const XhciBase = _xhci.XhciBase;
const Host = _xhci.Host;
const controller = @import("controller.zig");
const transfer = @import("transfer.zig");
const roothub = @import("roothub.zig");
const regs = @import("regs.zig");

pub const DEVICE_NAME = _xhci.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 10;
const BUILD_DATE = "29.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// Above dos's processes, as a disk's device is: a keyboard's keys and a
/// stick's blocks wait on it.
const task_pri = 6;

// --- the unit's task --------------------------------------------------------------

fn hostTask(sys: *ExecBase) callconv(.c) void {
    const host: *Host = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const queue_signal = sys.AllocSignal(-1);
    const int_signal = sys.AllocSignal(-1);
    const abort_signal = sys.AllocSignal(-1);
    const command_signal = sys.AllocSignal(-1);
    host.port = sys.CreateMsgPort();
    if (queue_signal < 0 or int_signal < 0 or abort_signal < 0 or command_signal < 0 or
        host.port == null or !openTimers(host))
    {
        // Nothing can run here; whoever made the task is told so, and
        // the task sleeps for good.
        started(host);
        return;
    }
    host.int_signal = @as(u32, 1) << @intCast(int_signal);
    host.abort_signal = @as(u32, 1) << @intCast(abort_signal);
    host.command_signal = @as(u32, 1) << @intCast(command_signal);
    const queue_mask = @as(u32, 1) << @intCast(queue_signal);
    const port_mask = host.port.?.sigMask();
    host.alive = 1;
    started(host);

    while (true) {
        // Stopped, until an opener asks for the controller.
        _ = sys.Wait(host.command_signal);
        if (!start(host)) {
            host.stopped = 1;
            started(host);
            continue;
        }
        sys.Disable();
        host.unit.msg_port.sig_bit = @intCast(queue_signal);
        host.unit.msg_port.sig_task = &host.task;
        host.unit.msg_port.flags = exec.PA_SIGNAL;
        sys.Enable();
        host.ready = 1;
        started(host);

        while (true) {
            const got = sys.Wait(queue_mask | host.int_signal | host.abort_signal | host.command_signal | port_mask);
            if (got & host.command_signal != 0) break;
            var aborts = got & host.abort_signal != 0;
            // A pass, again while one left something to do: what a
            // command's wait took in may want more commands.
            while (true) {
                controller.takeEvents(host);
                transfer.finishPosted(host);
                transfer.recover(host);
                transfer.tick(host);
                transfer.takeRequests(host);
                if (aborts) transfer.takeAborts(host);
                aborts = false;
                transfer.schedule(host);
                if (!transfer.pending(host)) break;
            }
            transfer.armTick(host);
        }

        host.ready = 0;
        stop(host);
        // Transfers that came in meanwhile are answered; BeginIO answers
        // any more itself while `ready` is clear.
        sys.Disable();
        host.unit.msg_port.flags = exec.PA_IGNORE;
        sys.Enable();
        while (sys.GetMsg(&host.unit.msg_port)) |msg| _xhci.reply(host, _xhci.requestOf(msg), usbhc.UHIOERR_HOSTERROR);
        host.stopped = 1;
        started(host);
    }
}

/// The task's two timer requests, on its own port.
fn openTimers(host: *Host) bool {
    const sys = host.sys;
    for ([_]*timer.TimeRequest{ &host.tick_io, &host.delay_io }) |io| {
        io.* = .{};
        io.node.message.reply_port = host.port;
        io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &io.node, 0) != 0) return false;
    }
    return true;
}

/// The controller up: reset, its interrupt hooked, run. False if any of
/// it failed; then nothing is left running.
fn start(host: *Host) bool {
    const pb = host.dev_base.pci_base.?;
    host.stopped = 0;
    host.root = .{};
    if (!controller.bringUp(host)) return false;
    host.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = host,
        .code = &controller.intServer,
    };
    // A message of its own where the function and its host bridge have
    // them: no line shared with anything else.
    host.int_vector = pb.AllocPCIVectors(host.function, 1) == 1 and pb.AddPCIVectorServer(host.function, 0, &host.int);
    if (!host.int_vector) pb.FreePCIVectors(host.function);
    host.int_hooked = host.int_vector or pb.AddPCIIntServer(host.function, &host.int);
    if (!host.int_hooked) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: no interrupt; the controller is polled\n", .{ DEVICE_NAME, host.number });
    }
    if (!controller.run(host)) {
        controller.shutDown(host);
        unhook(host);
        return false;
    }
    transfer.armTick(host);
    return true;
}

fn unhook(host: *Host) void {
    if (!host.int_hooked) return;
    const pb = host.dev_base.pci_base.?;
    if (host.int_vector) {
        pb.RemPCIVectorServer(host.function, 0, &host.int);
        pb.FreePCIVectors(host.function);
    } else {
        pb.RemPCIIntServer(host.function, &host.int);
    }
    host.int_hooked = false;
    host.int_vector = false;
}

/// Everything stopped: the controller halted, the transfers answered, the
/// interrupt unhooked.
fn stop(host: *Host) void {
    controller.shutDown(host);
    transfer.failAll(host, exec.IOERR_ABORTED);
    roothub.stop(host);
    transfer.dropTick(host);
    unhook(host);
}

/// The opener waiting in `open` told the task has started or stopped.
fn started(host: *Host) void {
    const starter = host.starter orelse return;
    host.starter = null;
    host.sys.Signal(starter, @as(u32, 1) << @intCast(host.start_signal));
}

// --- the device -------------------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const host = _xhci.hostOf(io);
    const req = _xhci.hcOf(io);
    io.err = 0;
    req.std.actual = 0;
    switch (io.command) {
        usbhc.UHCMD_CONTROLXFER, usbhc.UHCMD_BULKXFER, usbhc.UHCMD_INTXFER, usbhc.UHCMD_ISOXFER => {
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
            } else if (req.std.length != 0 and req.std.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (host.ready == 0) {
                io.err = usbhc.UHIOERR_HOSTERROR;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                req.hc_private[_xhci.PRIV_ABORT] = 0;
                host.sys.PutMsg(&host.unit.msg_port, &io.message);
                return;
            }
        },
        usbhc.UHCMD_QUERYDEVICE => {
            const info = usbhc.USBHCInfo{
                .name = "xhci",
                .speed = if (host.super_ports != 0) usbhc.USB_SPEED_SUPER else usbhc.USB_SPEED_HIGH,
                .channels = host.max_slots,
                .ports = host.ports,
                .frame = if (host.ready != 0) (_xhci.rt(host, regs.MFINDEX).* & 0x3FFF) >> 3 else 0,
            };
            if (req.std.data) |data| {
                const count = @min(@as(usize, @intCast(req.std.length)), @sizeOf(usbhc.USBHCInfo));
                const from: [*]const u8 = @ptrCast(&info);
                const into: [*]u8 = @ptrCast(data);
                @memcpy(into[0..count], from[0..count]);
                req.std.actual = count;
            } else {
                io.err = exec.IOERR_BADADDRESS;
            }
        },
        usbhc.UHCMD_USBRESET => restart(host),
        else => io.err = exec.IOERR_NOCMD,
    }
    host.sys.ReplyIO(io);
}

/// The controller stopped and started again, every transfer answered.
fn restart(host: *Host) void {
    const sys = host.sys;
    sys.ObtainSemaphore(&host.dev_base.open_lock);
    defer sys.ReleaseSemaphore(&host.dev_base.open_lock);
    _ = command(host);
    _ = command(host);
}

/// The task told to start the controller if it is stopped, or to stop
/// it if it runs, and waited for: whether it runs now.
fn command(host: *Host) bool {
    const sys = host.sys;
    const mine = sys.AllocSignal(-1);
    if (mine < 0) return false;
    defer sys.FreeSignal(mine);
    host.start_signal = mine;
    host.starter = sys.FindTask(null);
    sys.Signal(&host.task, host.command_signal);
    _ = sys.Wait(@as(u32, 1) << @intCast(mine));
    return host.ready != 0;
}

/// A transfer the task has not taken yet is taken off its port and
/// answered; one it has is marked, and the task answers it - its TD
/// taken back first.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    _ = dev;
    const host = _xhci.hostOf(io);
    const sys = host.sys;
    sys.Disable();
    var it = host.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_xhci.requestOf(msg) != _xhci.hcOf(io)) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    if (io.flags & exec.IOF_DONE != 0) return -1;
    _xhci.hcOf(io).hc_private[_xhci.PRIV_ABORT] = 1;
    sys.Signal(&host.task, host.abort_signal);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _xhci.baseOf(dev);
    const sys = base.sys_base;
    if (unit_number >= _xhci.max_units or unit_number >= base.units) return exec.IOERR_OPENFAIL;
    sys.ObtainSemaphore(&base.open_lock);
    defer sys.ReleaseSemaphore(&base.open_lock);
    const host = base.hosts[unit_number] orelse (makeHost(base, unit_number) orelse return exec.IOERR_OPENFAIL);
    if (host.unit.open_cnt == 0) {
        if (!command(host)) return exec.IOERR_OPENFAIL;
    }
    host.unit.open_cnt += 1;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = &host.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _xhci.baseOf(dev);
    const sys = base.sys_base;
    const host = _xhci.hostOf(io);
    sys.ObtainSemaphore(&base.open_lock);
    defer sys.ReleaseSemaphore(&base.open_lock);
    host.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    if (host.unit.open_cnt == 0) _ = command(host);
    io.unit = null;
    return null;
}

/// The device stays: its units' tasks and blocks stay once made.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The nth xHCI function, in pci.library's order.
fn functionOf(pb: *PCIBase, number: u32) ?*pci.PCIDevice {
    var n: u32 = 0;
    var it = pb.FindPCIClass(null, pci.PCI_CLASS_SERIAL_USB_XHCI, pci.PCI_CLASS_MASK);
    while (it) |function| : (it = pb.FindPCIClass(function, pci.PCI_CLASS_SERIAL_USB_XHCI, pci.PCI_CLASS_MASK)) {
        if (n == number) return function;
        n += 1;
    }
    return null;
}

/// Whether the controller sees the caches: pci.library says so from 2.1
/// on.
fn coherent(pb: *PCIBase, function: *pci.PCIDevice) bool {
    const lib: *exec.Library = @ptrCast(@alignCast(pb));
    return lib.revision >= 1 and function.dma_coherent;
}

/// Unit `number`'s block and task, made and waited for until the task
/// has its signals; it starts the controller on the opener's command.
/// Its PCI function is claimed for the device.
fn makeHost(base: *XhciBase, number: u32) ?*Host {
    const sys = base.sys_base;
    const pb = base.pci_base.?;
    const function = functionOf(pb, number) orelse return null;
    if (pb.ClaimPCIDevice(function, DEVICE_NAME)) |holder| {
        sdk.exec.kprintf(sys, "%s: unit %d: its PCI function is %s's\n", .{ DEVICE_NAME, number, holder });
        return null;
    }
    const memory = sys.AllocMem(@sizeOf(Host), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse {
        pb.ReleasePCIDevice(function);
        return null;
    };
    const host: *Host = @ptrCast(@alignCast(memory));
    host.* = .{ .dev_base = base, .sys = sys, .number = number, .function = function, .coherent = coherent(pb, function) };
    host.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    host.unit.msg_port.msg_list.init(.message);
    sys.NewList(&host.posted);
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse {
        sys.FreeMem(memory, @sizeOf(Host));
        pb.ReleasePCIDevice(function);
        return null;
    };
    host.stack = stack;
    host.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    // The task starts stopped, waiting for its first command; it answers
    // once its signals are there to be sent.
    host.stopped = 1;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, stack_size);
        sys.FreeMem(memory, @sizeOf(Host));
        pb.ReleasePCIDevice(function);
        return null;
    }
    host.start_signal = signal;
    host.starter = sys.FindTask(null);
    _ = sys.AddTask(&host.task, &hostTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    sys.FreeSignal(signal);
    // A task with no signals sleeps for good, and its block and stack
    // with it: there is nothing to take them back from it.
    if (host.alive == 0) return null;
    base.hosts[number] = host;
    return host;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A machine without PCI, or without an xHCI function on it, gets no
/// device: null, before anything is kept.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _xhci.baseOf(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    base.hosts = @splat(null);
    base.units = 0;
    const pci_lib = sys_base.OpenLibrary(pci.PCINAME, 2) orelse {
        sdk.exec.kprintf(sys_base, "%s: no %s\n", .{ DEVICE_NAME, pci.PCINAME });
        return null;
    };
    const pb: *PCIBase = @ptrCast(pci_lib);
    while (base.units < _xhci.max_units and functionOf(pb, base.units) != null) base.units += 1;
    if (base.units == 0) {
        sdk.exec.kprintf(sys_base, "%s: no xHCI controller on PCI\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(pci_lib);
        return null;
    }
    // Kept open: the device stays.
    base.pci_base = pb;
    sys_base.InitSemaphore(&base.open_lock);
    return dev;
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(XhciBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for a program that looks for a USB host
/// controller without opening one: its units are the board's USB parts.
const speaks = [_]u32{ expansion.devices.DEVIF_USBHC, 0 };

/// AUTOINIT and DEVICEINFO: made when something opens it - ramlib loads
/// the file and hands this tag to InitResident - and readable from the
/// file without loading it.
export const xhci_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&xhci_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &speaks,
    .unit_part = st.PARTKIND_USB,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
