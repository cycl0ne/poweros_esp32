// SPDX-License-Identifier: MIT
//! usbotg.device: the chip's USB OTG controllers (Synopsys DWC2) as USB
//! host controllers, speaking `DEVIF_USBHC` (sdk/devices/usbhc.zig) -
//! what usb.library runs a bus on. Unit n is the chip's controller n,
//! there when the board has a `PARTKIND_USB` part for it that may be a
//! host.
//!
//!   UHCMD_CONTROLXFER  a control transfer: setup, data, status
//!   UHCMD_BULKXFER     a bulk transfer, in rounds of the channel's buffer
//!   UHCMD_INTXFER      an interrupt transfer, asked every `interval` ms
//!                      until the device answers; the request's next
//!                      transfer not before `interval` after that
//!   UHCMD_ISOXFER      IOERR_NOCMD
//!   UHCMD_USBRESET     every transfer answered, the controller started
//!                      afresh
//!   UHCMD_USBSUSPEND,
//!   UHCMD_USBRESUME    IOERR_NOCMD
//!   UHCMD_QUERYDEVICE  what the controller is (`USBHCInfo`)
//!
//! A transfer to the root hub's address is the root hub's (roothub.zig);
//! everything else goes on the wire (host.zig). The unit's block, its
//! task and its interrupt are in _usbotg.zig's design.
//!
//! **A unit's life.** The first OpenDevice of a unit makes its block and
//! task and starts the controller: powered, reset, its root port powered,
//! a hub soldered on the board let out of reset. The last CloseDevice
//! stops it - every transfer answered, the port unpowered, the
//! controller held in reset - and the task waits for the next opener.
//! The block and the task stay: the task cannot give back the stack it
//! runs on, and the device itself stays once loaded.
//!
//! **The port.** A controller is given its USB port by usbport.resource:
//! a unit's start bids for it, at USBPORTPRI_HOST, and waits up to a
//! second for whoever has it to let go - on the ESP32-S3 the console's
//! USB-Serial-JTAG, whose port it is as the chip starts; then the
//! resource switches the port to the controller and sets its pads for a
//! host. A unit's stop gives it back. A board whose socket's lines are
//! switched between the port and something else (`PART_PinSwitch`, the
//! 7B's CH422G pin 5) has them switched to the port as a unit starts. On
//! the ESP32-P4 each controller has its port to itself, and the bid is
//! only on record.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const pads = sdk.hardware.gpio;
const usb_otg = sdk.hardware.usb_otg;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const expander_resource = sdk.resources.expander;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const usbport = sdk.resources.usbport;
const UsbPortBase = usbport.UsbPortBase;
const _usbotg = @import("_usbotg.zig");
const UsbOtgBase = _usbotg.UsbOtgBase;
const Host = _usbotg.Host;
const host_ops = @import("host.zig");
const roothub = @import("roothub.zig");

pub const DEVICE_NAME = _usbotg.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 6;
const BUILD_DATE = "17.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

const stack_size = 4096;
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
    const port_signal = sys.AllocSignal(-1);
    host.port = sys.CreateMsgPort();
    if (queue_signal < 0 or int_signal < 0 or abort_signal < 0 or command_signal < 0 or
        port_signal < 0 or host.port == null or !openTimers(host))
    {
        // Nothing can run here; whoever made the task is told so, and
        // the task sleeps for good.
        started(host);
        return;
    }
    host.int_signal = @as(u32, 1) << @intCast(int_signal);
    host.abort_signal = @as(u32, 1) << @intCast(abort_signal);
    host.command_signal = @as(u32, 1) << @intCast(command_signal);
    host.port_signal = @as(u32, 1) << @intCast(port_signal);
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
            if (got & host.int_signal != 0) host_ops.takeEvents(host);
            if (got & port_mask != 0) host_ops.tick(host);
            host_ops.takeRequests(host);
            if (got & host.abort_signal != 0) host_ops.takeAborts(host);
            host_ops.schedule(host);
        }

        host.ready = 0;
        stop(host);
        // Transfers that came in meanwhile are answered; BeginIO answers
        // any more itself while `ready` is clear.
        sys.Disable();
        host.unit.msg_port.flags = exec.PA_IGNORE;
        sys.Enable();
        while (sys.GetMsg(&host.unit.msg_port)) |msg| _usbotg.reply(host, _usbotg.requestOf(msg), usbhc.UHIOERR_HOSTERROR);
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

/// The controller up: a hub on the board held in reset, the controller
/// powered and given its port, the core brought up and its interrupt
/// hooked, the channels' buffers made, then the hub let go. False if any
/// of it failed; then nothing is left running and the port is given back.
fn start(host: *Host) bool {
    const sys = host.sys;
    host.stopped = 0;
    host.root = .{};
    host.port_events = 0;
    host.chan_events = @splat(0);
    hubReset(host, true);
    selectSocket(host);
    // Powered first: on the ESP32-S3 the port's pad settings are in a
    // block that is clocked and reset with the controller.
    usb_otg.powerOn(host.number);
    if (!takePort(host)) {
        usb_otg.powerOff(host.number);
        return false;
    }
    usb_otg.hostMode(host.number);
    if (!host_ops.bringUp(host)) {
        givePortBack(host);
        usb_otg.powerOff(host.number);
        return false;
    }
    if (host.bounce_memory == null) {
        // The high-speed controller's buffers larger; both in internal
        // memory.
        host.bounce_bytes = if (host.utmi != 0) _usbotg.hs_bounce_bytes else _usbotg.bounce_bytes;
        const memory = sys.AllocMem(bounceSize(host), exec.MEMF_INTERNAL | exec.MEMF_DMA | exec.MEMF_CLEAR) orelse {
            givePortBack(host);
            usb_otg.powerOff(host.number);
            return false;
        };
        host.bounce_memory = memory;
    }
    const aligned = (@intFromPtr(host.bounce_memory.?) + _usbotg.bounce_align - 1) & ~(_usbotg.bounce_align - 1);
    for (&host.channels, 0..) |*channel, n| {
        channel.* = .{ .bounce = @ptrFromInt(aligned + n * host.bounce_bytes) };
    }
    host.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = host,
        .code = &host_ops.intServer,
    };
    sys.AddIntServer(host.controller.interrupt, &host.int);
    host_ops.interruptsOn(host);
    _usbotg.delay(host, 10);
    hubReset(host, false);
    return true;
}

/// The bytes the channels' buffers take, with room to align them.
fn bounceSize(host: *const Host) u32 {
    return _usbotg.max_channels * host.bounce_bytes + _usbotg.bounce_align;
}

/// Everything stopped: the transfers answered, the interrupt unhooked,
/// the port given back and the controller held in reset, a hub on the
/// board held in reset too.
fn stop(host: *Host) void {
    const sys = host.sys;
    host_ops.failAll(host, exec.IOERR_ABORTED);
    roothub.stop(host);
    host_ops.dropTick(host);
    host_ops.shutDown(host);
    sys.RemIntServer(host.controller.interrupt, &host.int);
    givePortBack(host);
    usb_otg.powerOff(host.number);
    hubReset(host, true);
}

/// How long a start waits for the port's holder to let go.
const port_wait_us = 1_000_000;

/// The USB port the controller is on, bid for and waited for: whoever
/// has it lets go, and usbport.resource switches it to the controller.
/// False if it was not had within a second; then the bid is withdrawn.
/// True at once without the resource: the port is taken as it is.
fn takePort(host: *Host) bool {
    const sys = host.sys;
    const pb = host.dev_base.port_base orelse return true;
    host.port_bid = .{
        .node = .{ .pri = usbport.USBPORTPRI_HOST, .name = DEVICE_NAME },
        .task = &host.task,
        .signals = host.port_signal,
        .controller = usbport.USBCTL_OTG,
        .unit = @intCast(host.number),
        .role = st.USBROLE_HOST,
    };
    _ = sys.SetSignal(0, host.port_signal);
    if (pb.OwnUSBPort(&host.port_bid)) return true;
    // The holder told: its answer waited for, with the delay request as
    // the time limit. Its reply port is the task's own, which nothing
    // else uses while the controller is stopped.
    const timer_mask = host.port.?.sigMask();
    _ = sys.SetSignal(0, timer_mask);
    host.delay_io.node.command = timer.TR_ADDREQUEST;
    host.delay_io.time = timer.TimeVal.fromMicros(port_wait_us);
    sys.SendIO(&host.delay_io.node);
    while (host.port_bid.state == usbport.USBPORT_WAITING and sys.CheckIO(&host.delay_io.node) == null) {
        _ = sys.Wait(host.port_signal | timer_mask);
    }
    if (sys.CheckIO(&host.delay_io.node) == null) _ = sys.AbortIO(&host.delay_io.node);
    _ = sys.WaitIO(&host.delay_io.node);
    _ = sys.SetSignal(0, timer_mask);
    if (host.port_bid.state != usbport.USBPORT_WAITING) return true;
    sdk.exec.kprintf(sys, "%s: unit %d: its USB port was not given up\n", .{ DEVICE_NAME, host.number });
    pb.ReleaseUSBPort(&host.port_bid, usbport.USBPORTF_REMOVE);
    return false;
}

/// The port given back, to whoever bids next - the console, on the
/// ESP32-S3 - or to the controller the chip starts with.
fn givePortBack(host: *Host) void {
    const pb = host.dev_base.port_base orelse return;
    pb.ReleaseUSBPort(&host.port_bid, usbport.USBPORTF_REMOVE);
}

/// The socket's lines switched to the USB port, on a board whose socket
/// shares them (`PART_PinSwitch`).
fn selectSocket(host: *Host) void {
    const line = BoardPin.of(host.dev_base.socket_switch[host.number]);
    const asserted = line.active_low == 0;
    switch (line.kind) {
        expansion.boardpin.BPIN_GPIO => {
            pads.toMatrix(line.number);
            pads.setLevel(line.number, asserted);
            pads.outputEnable(line.number, true);
        },
        expansion.boardpin.BPIN_EXPANDER => {
            const eb = host.dev_base.expander orelse return;
            _ = eb.SetPin(line.number, asserted);
        },
        else => {},
    }
}

/// A hub soldered on the board held in reset, or let go of.
fn hubReset(host: *Host, held: bool) void {
    const line = BoardPin.of(host.dev_base.hub_reset[host.number]);
    if (line.kind != expansion.boardpin.BPIN_GPIO) return;
    const asserted = line.active_low == 0;
    pads.toMatrix(line.number);
    pads.setLevel(line.number, if (held) asserted else !asserted);
    pads.outputEnable(line.number, true);
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
    const host = _usbotg.hostOf(io);
    const req = _usbotg.hcOf(io);
    io.err = 0;
    req.std.actual = 0;
    switch (io.command) {
        usbhc.UHCMD_CONTROLXFER, usbhc.UHCMD_BULKXFER, usbhc.UHCMD_INTXFER => {
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
            } else if (req.std.length != 0 and req.std.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (host.ready == 0) {
                io.err = usbhc.UHIOERR_HOSTERROR;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                req.hc_private[_usbotg.PRIV_ABORT] = 0;
                host.sys.PutMsg(&host.unit.msg_port, &io.message);
                return;
            }
        },
        usbhc.UHCMD_QUERYDEVICE => {
            const info = usbhc.USBHCInfo{
                .name = "dwc2",
                .speed = if (host.controller.utmi) usbhc.USB_SPEED_HIGH else usbhc.USB_SPEED_FULL,
                .channels = host.channel_count,
                .ports = 1,
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
        usbhc.UHCMD_USBRESET => {
            // A restart is a stop and a start, which only the opener's
            // side can wait for: done there, below.
            restart(host);
        },
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
/// answered; one it has is marked, and the task answers it - a channel
/// that has it is halted first.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    _ = dev;
    const host = _usbotg.hostOf(io);
    const sys = host.sys;
    sys.Disable();
    var it = host.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_usbotg.requestOf(msg) != _usbotg.hcOf(io)) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    if (io.flags & exec.IOF_DONE != 0) return -1;
    _usbotg.hcOf(io).hc_private[_usbotg.PRIV_ABORT] = 1;
    sys.Signal(&host.task, host.abort_signal);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _usbotg.baseOf(dev);
    const sys = base.sys_base;
    if (unit_number >= _usbotg.max_units or base.present & (@as(u32, 1) << @intCast(unit_number)) == 0) {
        return exec.IOERR_OPENFAIL;
    }
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
    const base = _usbotg.baseOf(dev);
    const sys = base.sys_base;
    const host = _usbotg.hostOf(io);
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

/// Unit `number`'s block and task, made and waited for until the task
/// has its signals; it starts the controller on the opener's command.
fn makeHost(base: *UsbOtgBase, number: u32) ?*Host {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Host), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return null;
    const host: *Host = @ptrCast(@alignCast(memory));
    const controller = usb_otg.controllers[number];
    host.* = .{
        .dev_base = base,
        .sys = sys,
        .number = number,
        .controller = controller,
        .regs = controller.base,
    };
    host.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    host.unit.msg_port.msg_list.init(.message);
    sys.NewList(&host.waiting);
    sys.NewList(&host.parked);
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys.FreeMem(memory, @sizeOf(Host));
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

/// Which of the chip's controllers the board has as hosts, and a hub
/// reset line for each.
fn findParts(base: *UsbOtgBase) void {
    const sys = base.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part = eb.FindBoardPart(null, st.PARTKIND_USB, st.CHIP_DWC2);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_USB, st.CHIP_DWC2)) {
        const roles = ub.GetTagData(st.PART_UsbRoles, st.USBROLE_HOST, it.tags);
        if (roles & st.USBROLE_HOST == 0) continue;
        const unit = ub.GetTagData(st.PART_BusUnit, 0, it.tags);
        if (unit >= _usbotg.max_units or unit >= usb_otg.controllers.len) continue;
        base.present |= @as(u32, 1) << @intCast(unit);
        base.hub_reset[unit] = ub.GetTagData(st.PART_PinReset, 0, it.tags);
        base.socket_switch[unit] = ub.GetTagData(st.PART_PinSwitch, 0, it.tags);
    }
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board with no USB controller as a host gets no device: null, before
/// anything is taken. A hub's reset line is the device's from here on.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _usbotg.baseOf(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    base.hosts = @splat(null);
    findParts(base);
    if (base.present == 0) {
        sdk.exec.kprintf(sys_base, "%s: no USB host socket on this board\n", .{DEVICE_NAME});
        return null;
    }
    sys_base.InitSemaphore(&base.open_lock);
    if (sys_base.OpenResource(usbport.USBPORTNAME)) |found| base.port_base = @ptrCast(@alignCast(found));
    claimLines(base, &base.hub_reset);
    claimLines(base, &base.socket_switch);
    return dev;
}

/// The board's lines in `lines` taken for the device - a pad from
/// gpio.resource, an expander's pin from expander.resource; one another
/// driver has is said on the raw port and left alone.
fn claimLines(base: *UsbOtgBase, lines: *[_usbotg.max_units]usize) void {
    const sys = base.sys_base;
    for (lines) |*line_data| {
        const line = BoardPin.of(line_data.*);
        switch (line.kind) {
            expansion.boardpin.BPIN_GPIO => {
                const found = sys.OpenResource(gpio_resource.GPIONAME) orelse continue;
                const gb: *GpioBase = @ptrCast(@alignCast(found));
                if (gb.AllocGPIO(line.number, DEVICE_NAME)) |holder| {
                    sdk.exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, @as(u32, line.number), holder });
                    line_data.* = 0;
                }
            },
            expansion.boardpin.BPIN_EXPANDER => {
                const found = sys.OpenResource(expander_resource.EXPANDERNAME) orelse {
                    line_data.* = 0;
                    continue;
                };
                const eb: *ExpanderBase = @ptrCast(@alignCast(found));
                if (!eb.ClaimPin(line.number, DEVICE_NAME)) {
                    const holder = eb.PinOwner(line.number) orelse "another driver";
                    sdk.exec.kprintf(sys, "%s: the expander's pin %d is %s's\n", .{ DEVICE_NAME, @as(u32, line.number), holder });
                    line_data.* = 0;
                    continue;
                }
                base.expander = eb;
            },
            else => {},
        }
    }
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
    .data_size = @sizeOf(UsbOtgBase),
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
export const usbotg_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&usbotg_device_tag),
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
