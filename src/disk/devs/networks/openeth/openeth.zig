// SPDX-License-Identifier: MIT
//! openeth.device: the emulator's OpenCores Ethernet MAC as a network
//! device (sdk/devices/network.zig). Unit 0 is the MAC. It is in
//! DEVS:networks/, and the board's system tag list says whether there is
//! one and where its registers are; a board without it gets no device.
//!
//! What it answers is the network device API as that file describes it,
//! on an Ethernet link: 48-bit addresses, an MTU of 1500, 100 Mbit/s.
//!
//! **Every request runs on the device's own task**, except S2_DEVICEQUERY
//! and S2_GETSTATIONADDRESS, which touch no opener's buffers and are
//! answered where they are asked. The openers' copy calls are made only
//! on the task, so BeginIO queues the rest to it. The MAC's interrupt - a
//! frame received, a frame sent, a frame lost for want of a buffer - only
//! collects what the MAC raised and signals the task, which does the
//! rest. Nothing polls.
//!
//! **The link is always up.** The MAC's PHY has no interrupt for a link
//! that changes and the device does not poll, so the unit reports going
//! online and offline as it is told to, and nothing of the cable.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const intbits = sdk.hardware.intbits;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const ethmac = @import("ethmac.zig");
const _openeth = @import("_openeth.zig");
const OpenethBase = _openeth.OpenethBase;
const Work = _openeth.Work;

pub const DEVICE_NAME = _openeth.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "25.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for a request and the openers' copy calls; nothing here
/// recurses.
const stack_size = 4096;
/// Above dos's processes, as the other devices' tasks are: a stack waits
/// on this, and frames should not wait in the ring for a shell.
const task_pri = 5;

// --- the interrupt --------------------------------------------------------

/// The MAC's interrupt: what it raised is taken and cleared here - the
/// source is a level, and would come straight back - and left for the task.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *OpenethBase = @ptrCast(@alignCast(is_data.?));
    const work = base.work orelse return 0;
    const raised = ethmac.takeInterrupts(base.mac);
    if (raised == 0) return 0;
    work.raised |= raised;
    base.sys_base.Signal(&base.task, base.int_mask);
    return 1;
}

/// What the MAC raised since the task last looked, taken.
fn takeRaised(base: *OpenethBase) u32 {
    const sys = base.sys_base;
    const work = base.work.?;
    sys.Disable();
    defer sys.Enable();
    const raised = work.raised;
    work.raised = 0;
    return raised;
}

// --- the task -------------------------------------------------------------

/// Every request, and every frame in and out. The port is given its
/// signal before the first message is taken, so a request that came in
/// while the device was starting is not missed.
fn netTask(sys: *ExecBase) callconv(.c) void {
    const base: *OpenethBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const queue_port = &base.unit.msg_port;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(base);
    sys.Disable();
    queue_port.sig_bit = @intCast(signal);
    queue_port.sig_task = &base.task;
    queue_port.flags = exec.PA_SIGNAL;
    sys.Enable();

    setUp(base);
    started(base);

    while (true) {
        const raised = takeRaised(base);
        if (raised & ethmac.int_busy != 0) base.net.overrun();
        if (raised & (ethmac.int_rxb | ethmac.int_busy) != 0) base.received();
        if (raised & ethmac.int_txb != 0) base.sent();
        while (sys.GetMsg(queue_port)) |msg| base.net.perform(_openeth.sanaReq(_openeth.requestOf(msg)));
        _ = sys.Wait(queue_port.sigMask() | base.int_mask);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(base: *OpenethBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

/// The interrupt's signal, the timer for the system time, and the
/// interrupt server. Without a timer the unit's start time stays 0;
/// without a signal nothing is hooked up and Open refuses.
fn setUp(base: *OpenethBase) void {
    const sys = base.sys_base;
    const int_signal = sys.AllocSignal(-1);
    if (int_signal < 0) return;
    base.int_mask = @as(u32, 1) << @intCast(int_signal);

    base.timer_io = .{};
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) base.timer_open = 1;

    sys.AddIntServer(intbits.INTB_WIFI_MAC, &base.work.?.int);
    base.hooked = 1;
}

// --- the device -----------------------------------------------------------

/// The commands the task answers.
fn queued(command: u16) bool {
    return switch (command) {
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
    _ = dev;
    const base = _openeth.baseOf(io);
    const req = _openeth.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => base.net.query(req),
        net.S2_GETSTATIONADDRESS => base.net.stationAddress(req),
        else => if (queued(io.command)) {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&base.unit.msg_port, &io.message);
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
    const base = _openeth.openethBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    var it = base.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_openeth.requestOf(msg) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (base.net.abort(_openeth.sanaReq(io))) 0 else -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _openeth.openethBase(dev);
    if (unit_number != 0 or base.hooked == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_openeth.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _openeth.baseOf(io);
    base.net.close(_openeth.sanaReq(io));
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, its interrupt and the MAC. The
/// seglist it was loaded from is kept in the base for the day it does go.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The MAC's registers, as the board's network part gives them: 0 if the
/// board has no such part.
fn findMac(sys: *ExecBase, utility: *UtilityBase) usize {
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return 0;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_NET, st.CHIP_OPENETH) orelse return 0;
    return utility.GetTagData(st.PART_Address, 0, part.tags);
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without the MAC, or a machine where it does not answer, gets
/// no device at all: null, before anything is taken but utility.library,
/// which is given back. Otherwise the MAC is reset, the block it and the
/// interrupt reach is allocated internal, and the task is started; this
/// waits until the task takes requests.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _openeth.openethBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    const utility: *UtilityBase = @ptrCast(utility_lib);
    base.mac = findMac(sys_base, utility);
    if (base.mac == 0) {
        sdk.exec.kprintf(sys_base, "%s: no Ethernet MAC on this board\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(utility_lib);
        return null;
    }
    if (!ethmac.present(base.mac)) {
        sdk.exec.kprintf(sys_base, "%s: the Ethernet MAC does not answer\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(utility_lib);
        return null;
    }
    base.utility = utility;

    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);

    ethmac.reset(base.mac);
    const factory = ethmac.stationAddress(base.mac);
    base.net.init(sys_base, base, &factory);

    const memory = sys_base.AllocMem(@sizeOf(Work), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        sdk.exec.kprintf(sys_base, "%s: no internal memory for the frame buffers\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    const work: *Work = @ptrCast(@alignCast(memory));
    base.work = work;
    work.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = base,
        .code = &intServer,
    };

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys_base.FreeMem(memory, @sizeOf(Work));
        base.work = null;
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };

    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        base.starter = sys_base.FindTask(null);
        base.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&base.task, &netTask, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
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
    .data_size = @sizeOf(OpenethBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, in DEVS:networks/,
/// and is made when something opens it - ramlib loads the file and hands
/// this tag to InitResident.
///
/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, whoever loads the file looks for it.
export const openeth_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &openeth_device_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 0,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A device is not a command. Whoever runs this file gets nothing done and
/// a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
