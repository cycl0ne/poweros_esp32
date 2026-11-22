// SPDX-License-Identifier: MIT
//! networks/mt7922.device: a MediaTek MT7922 Wi-Fi card on PCI Express,
//! as a wireless network device (sdk/devices/network.zig,
//! sdk/devices/wireless.zig). It is in DEVS:networks/; a machine without
//! the card gets no device.
//!
//! **One card, unit 0.** The init claims the card, maps its registers,
//! hooks its interrupt, sets aside the memory its rings take (below
//! 4 GiB) and starts the worker, a DOS process, which brings the card up
//! (bringup.zig): the chip's power, its reset, the DMA engine, the
//! firmware from `DEVS:networks/firmware/mt7922/` (firmware.zig), and
//! what the firmware says the card has - its address among it. The init
//! waits for that; a card that does not come up is given back and the
//! device refused.
//!
//! **The worker does everything** the chip is asked: the commands to its
//! firmware (mcu.zig) and the unit's requests (radio.zig). The interrupt
//! turns the chip's interrupts off and signals it; it reads the causes,
//! takes what the rings hold, and turns them on again.
//!
//! **The device goes** when the last opener has closed it and it is
//! expunged: the worker stops, the chip is left quiet - its engine
//! stopped, its Wi-Fi part reset - and everything is given back - so a new
//! version of the file is loaded at the next open.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const _mt = @import("_mt7922.zig");
const regs_file = @import("regs.zig");
const mcu = @import("mcu.zig");
const bringup = @import("bringup.zig");
const radio = @import("radio.zig");
const Mt7922Base = _mt.Mt7922Base;
const Work = _mt.Work;
const say = _mt.say;

pub const DEVICE_NAME = _mt.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "22.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The worker reads the firmware into memory of its own, so its stack is
/// what the calls take.
const worker_stack = 16384;
const worker_pri = 5;

// --- the worker ---------------------------------------------------------------

fn workerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *Mt7922Base = @ptrCast(@alignCast(me.user_data orelse return));
    const work = base.work.?;
    const int_signal = sys.AllocSignal(-1);
    const work_signal = sys.AllocSignal(-1);
    const timer_signal = sys.AllocSignal(-1);
    if (int_signal < 0 or work_signal < 0 or timer_signal < 0) return started(base, false);
    work.timer_port = .{ .flags = exec.PA_SIGNAL, .sig_bit = @intCast(timer_signal), .sig_task = me };
    work.timer_port.msg_list.init(.message);
    work.timer_io = .{};
    work.timer_io.node.message.reply_port = &work.timer_port;
    work.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &work.timer_io.node, 0) != 0) return started(base, false);
    work.timer_open = true;

    bringup.bringUp(work) catch |failure| {
        say(sys, "the card does not come up: %s", .{@as([*:0]const u8, @errorName(failure))});
        bringup.quiet(work);
        sys.CloseDevice(&work.timer_io.node);
        work.timer_open = false;
        return started(base, false);
    };
    const address = work.station;
    say(sys, "MT7922 revision %u, firmware %s, %u streams%s%s, %02x:%02x:%02x:%02x:%02x:%02x", .{
        work.revision,                          @as([*:0]const u8, &work.ram_build),
        @as(u32, work.streams),                 @as([*:0]const u8, if (work.has_5g) ", 5 GHz" else ""),
        @as([*:0]const u8, if (work.has_6g) ", 6 GHz" else ""),
        @as(u32, address[0]),
        @as(u32, address[1]),                   @as(u32, address[2]),
        @as(u32, address[3]),                   @as(u32, address[4]),
        @as(u32, address[5]),
    });

    base.int_mask = @as(u32, 1) << @intCast(int_signal);
    base.work_mask = @as(u32, 1) << @intCast(work_signal);
    sys.Disable();
    for ([_]*exec.MsgPort{ &base.commands, &base.unit.msg_port }) |port| {
        port.sig_bit = @intCast(work_signal);
        port.sig_task = me;
        port.flags = exec.PA_SIGNAL;
    }
    sys.Enable();
    base.worker = me;
    started(base, true);

    while (true) {
        const got = sys.Wait(base.int_mask | base.work_mask);
        if (got & base.int_mask != 0) serviceInterrupt(work);
        while (sys.GetMsg(&base.commands)) |message| {
            const command: *_mt.Command = @fieldParentPtr("message", message);
            switch (command.kind) {
                // The process ends; dos says so to the expunge with
                // `ended` once nothing of it runs any more.
                .quit => {
                    bringup.quiet(work);
                    sys.CloseDevice(&work.timer_io.node);
                    work.timer_open = false;
                    base.worker = null;
                    return;
                },
            }
        }
        while (sys.GetMsg(&base.unit.msg_port)) |message| {
            radio.request(work, _mt.sanaReq(_mt.requestOf(message)));
        }
    }
}

/// The init told whether the worker came up.
fn started(base: *Mt7922Base, ready: bool) void {
    base.ready = @intFromBool(ready);
    if (base.starter) |starter| {
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
}

/// The causes read and cleared, what the rings hold taken, and the
/// interrupts on again.
fn serviceInterrupt(work: *Work) void {
    const regs = work.regs;
    const causes = regs.rd(regs_file.HOST_INT_STA);
    regs.wr(regs_file.HOST_INT_STA, causes);
    if (causes & regs_file.INT_MCU_CMD != 0) {
        const said = regs.rd(regs_file.MCU_CMD);
        regs.wr(regs_file.MCU_CMD, said);
    }
    _ = mcu.takeEvents(work, 0);
    regs.wr(regs_file.HOST_INT_ENA, work.int_enabled);
}

/// The card's interrupt: not this card's when none of the causes it
/// wants is raised; otherwise they are turned off and the worker
/// signalled.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *Mt7922Base = @ptrCast(@alignCast(is_data.?));
    const regs = base.chipRegs();
    const causes = regs.rd(regs_file.HOST_INT_STA);
    if (causes == 0xffffffff or causes & regs.rd(regs_file.HOST_INT_ENA) == 0) return 0;
    regs.wr(regs_file.HOST_INT_ENA, 0);
    if (base.worker) |worker| base.sys_base.Signal(worker, base.int_mask);
    return 1;
}

// --- the card -------------------------------------------------------------------

/// The card claimed, its registers switched on and its interrupt hooked.
fn claim(base: *Mt7922Base) bool {
    const sys = base.sys_base;
    const pb = base.pci_base.?;
    const function = pb.FindPCIDevice(null, _mt.VENDOR_MEDIATEK, _mt.DEVICE_MT7922) orelse return false;
    if (pb.ClaimPCIDevice(function, DEVICE_NAME)) |holder| {
        say(sys, "the card is %s's", .{holder});
        return false;
    }
    base.function = function;
    const bar = function.bars[0];
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) {
        say(sys, "the card has no registers in memory", .{});
        return false;
    }
    base.regs = @intCast(bar.address);
    var command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command);
    const lib: *exec.Library = @ptrCast(@alignCast(pb));
    base.coherent = @intFromBool(lib.revision >= 1 and function.dma_coherent);

    base.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = base,
        .code = @ptrCast(&intServer),
    };
    if (pb.AllocPCIVectors(function, 1) == 1 and pb.AddPCIVectorServer(function, 0, &base.int)) {
        base.signalling = if (function.vector_kind == pci.PCI_VECTORS_MSIX) .vector else .message;
        return true;
    }
    pb.FreePCIVectors(function);
    if (pb.AddPCIIntServer(function, &base.int)) {
        const now = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
        pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, now & ~@as(u32, pci.PCI_COMMAND_INTX_DISABLE));
        base.signalling = .line;
        return true;
    }
    say(sys, "the card has no interrupt to raise", .{});
    return false;
}

/// Everything the init took, given back: the interrupt, the memory, the
/// card, the libraries.
fn release(base: *Mt7922Base) void {
    const sys = base.sys_base;
    if (base.pci_base) |pb| {
        if (base.function) |function| {
            switch (base.signalling) {
                .vector, .message => {
                    pb.RemPCIVectorServer(function, 0, &base.int);
                    pb.FreePCIVectors(function);
                },
                .line => pb.RemPCIIntServer(function, &base.int),
                .none => {},
            }
            base.signalling = .none;
            pb.ReleasePCIDevice(function);
            base.function = null;
        }
        sys.CloseLibrary(@ptrCast(@alignCast(pb)));
        base.pci_base = null;
    }
    if (base.work) |work| {
        sys.FreeVec(work);
        base.work = null;
    }
    if (base.dma_memory) |memory| {
        sys.FreeMem(memory, base.dma_bytes);
        base.dma_memory = null;
    }
    if (base.dos_base) |dl| {
        sys.CloseLibrary(@ptrCast(@alignCast(dl)));
        base.dos_base = null;
    }
    if (base.utility) |utility| {
        sys.CloseLibrary(@ptrCast(@alignCast(utility)));
        base.utility = null;
    }
}

/// The libraries opened, the card claimed, the rings' memory set aside
/// and the worker started; this waits until the card is up.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _mt.mtBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    if (!setUp(base)) {
        release(base);
        return null;
    }
    return dev;
}

fn setUp(base: *Mt7922Base) bool {
    const sys = base.sys_base;
    base.utility = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false);
    base.dos_base = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return false);
    base.pci_base = @ptrCast(sys.OpenLibrary(pci.PCINAME, 2) orelse {
        say(sys, "no pci.library on this machine", .{});
        return false;
    });
    if (!claim(base)) return false;

    base.dma_bytes = _mt.dmaBytes();
    base.dma_memory = sys.AllocMem(base.dma_bytes, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse {
        say(sys, "no memory for the rings", .{});
        return false;
    };
    const block = sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
    const work: *Work = @ptrCast(@alignCast(block));
    work.* = .{ .base = base, .sys = sys, .dl = base.dos_base.?, .regs = base.chipRegs() };
    work.layRings(@intFromPtr(base.dma_memory.?));
    base.work = work;

    // PA_IGNORE until the worker has a signal for them: whatever comes in
    // while the card comes up is queued, and the worker takes it then.
    base.commands = .{ .flags = exec.PA_IGNORE };
    base.commands.msg_list.init(.message);
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);

    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    // dos replies `ended` once the worker is gone and nothing of it runs:
    // only then may its code go.
    const end_port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(end_port);
    base.ended = .{ .reply_port = end_port };
    base.start_signal = signal;
    base.starter = sys.FindTask(null);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, DEVICE_NAME)) },
        .{ .tag = dos.NP_StackSize, .data = worker_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, worker_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&base.ended) },
        .{},
    };
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return false;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (base.ready == 0) {
        _ = sys.WaitPort(end_port);
        _ = sys.GetMsg(end_port);
        return false;
    }
    base.ended.reply_port = null;
    base.net.init(sys, base, &work.station);
    base.net.setCarrier(false);
    return true;
}

// --- the device's calls -----------------------------------------------------------

/// The requests answered where they are asked, and those the worker
/// takes.
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
        sdk.devices.wireless.S2_GETNETWORKS,
        sdk.devices.wireless.S2_SETOPTIONS,
        sdk.devices.wireless.S2_GETNETWORKINFO,
        sdk.devices.wireless.S2_GETSIGNALQUALITY,
        => true,
        else => false,
    };
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _mt.mtBase(dev);
    const req = _mt.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => base.net.query(req),
        net.S2_GETSTATIONADDRESS => base.net.stationAddress(req),
        else => if (queued(io.command)) {
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

/// A request the worker hasn't taken yet, or one waiting in the unit - a
/// read, a write, an event - is taken back and answered as aborted.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _mt.mtBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    var it = base.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        if (_mt.requestOf(message) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (base.net.abort(_mt.sanaReq(io))) 0 else -1;
}

fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _mt.mtBase(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_mt.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _mt.mtBase(dev);
    base.net.close(_mt.sanaReq(io));
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    if (dev.open_cnt == 0 and dev.flags & exec.LIBF_DELEXP != 0) return expunge(dev);
    return null;
}

/// The device goes once nobody has it open: the worker stopped - it
/// leaves the chip quiet - and everything given back.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    if (dev.open_cnt != 0) {
        dev.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _mt.mtBase(dev);
    const sys = base.sys_base;
    if (base.worker != null) {
        const port = sys.CreateMsgPort() orelse {
            dev.flags |= exec.LIBF_DELEXP;
            return null;
        };
        base.ended.reply_port = port;
        base.quit = .{ .kind = .quit };
        sys.PutMsg(&base.commands, &base.quit.message);
        _ = sys.WaitPort(port);
        _ = sys.GetMsg(port);
        sys.DeleteMsgPort(port);
    }
    const seg_list = base.seg_list;
    release(base);
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return seg_list;
}

/// The six standard vectors.
const vectors = [_]*const anyopaque{
    vec(openDevice),
    vec(closeDevice),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(Mt7922Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_SANA2, devices.DEVIF_WIRELESS, 0 };
const labels = [_][*:0]const u8{"Wi-Fi"};

/// No flags but AUTOINIT and DEVICEINFO: the device is on the disk, in
/// DEVS:networks/, and is made when something opens it. One unit, the
/// card's radio.
export const mt7922_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&mt7922_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &speaks,
    .units = 1,
    .unit_labels = &labels,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
