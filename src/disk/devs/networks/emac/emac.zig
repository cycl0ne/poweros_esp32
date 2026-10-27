// SPDX-License-Identifier: MIT
//! emac.device: the chip's Ethernet MAC and the board's PHY as a network
//! device (sdk/devices/network.zig) - the ESP32-P4's 10/100 MAC on RMII,
//! or one of the JH7110's gigabit MACs on RGMII (_emac.zig has which
//! files are whose). Unit 0 is the port. It is in DEVS:networks/, and the
//! board's system tag list says whether there is a PHY on the chip's bus
//! for it and how it is wired; a board without one gets no device.
//!
//! What it answers is the network device API as that file describes it,
//! on an Ethernet link: 48-bit addresses, an MTU of 1500, 10 or 100 Mbit/s
//! and on the JH7110 1000. The station address is the one the board gives
//! the port (PART_StationAddress), else the one the factory burned into
//! the chip, else one made up from the clock, locally administered.
//!
//! **Every request runs on the device's own task**, except S2_DEVICEQUERY
//! and S2_GETSTATIONADDRESS, which touch no opener's buffers and are
//! answered where they are asked. The openers' copy calls are made only
//! on the task, so BeginIO queues the rest to it. The MAC's interrupt - a
//! frame received, a frame sent, no free receive descriptor - only
//! collects what the engine raised and signals the task, which does the
//! rest.
//!
//! **The cable.** The PHY's interrupt line, where a board has one, is not
//! used: the task asks the PHY every `link_poll_us` whether its link is
//! up and at what speed, and tells the unit, which goes on and off line
//! with it (`setCarrier`).
//!
//! **Starting the hardware** is the task's, which can wait: the port made
//! ready (`port.powerUp`: on the P4 the PHY held in reset while the pads
//! are set up and let go, on the JH7110 the MAC's clocks on and its
//! resets let go), the MAC reset - which only ends once the clocks the
//! PHY sends run - and set up, then the PHY reset, set up as the board's
//! wiring asks and told to negotiate. If any of it fails, the device says
//! so and refuses every OpenDevice.

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
const phy = @import("phy.zig");
const _emac = @import("_emac.zig");
const mac = _emac.mac;
const port = _emac.port;
const EmacBase = _emac.EmacBase;
const Work = _emac.Work;

pub const DEVICE_NAME = _emac.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 6;
const BUILD_DATE = "27.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for a request and the openers' copy calls; nothing here
/// recurses. Twice that on a 64-bit machine, whose frames are wider.
const stack_size = if (@sizeOf(usize) == 8) 8192 else 4096;
/// Where the block the engine and the interrupt reach comes from:
/// internal memory, and on a machine whose memory runs past 4 GiB the
/// part below (MEMF_DMA).
const work_memory: u32 = exec.MEMF_INTERNAL | if (sdk.hardware.chip == .rv64sbi) exec.MEMF_DMA else 0;
/// Above dos's processes, as the other devices' tasks are: a stack waits
/// on this, and frames should not wait in the chain for a shell.
const task_pri = 5;

/// How often the PHY is asked about its link.
const link_poll_us = 1_000_000;
/// The MAC's interrupt on a chip that numbers it once for every board;
/// null on one whose interrupt controller is wired by the board
/// (PART_Irq).
const fixed_irq: ?u32 = if (@hasDecl(intbits, "INTB_ETH_MAC")) intbits.INTB_ETH_MAC else null;
/// How long the PHY's own reset may take, asked every `phy_step_us`.
const phy_reset_steps = 10;
const phy_step_us = 10_000;

// --- the interrupt --------------------------------------------------------

/// The engine's interrupt: what it raised is taken and cleared here - the
/// source is a level, and would come straight back - and left for the task.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *EmacBase = @ptrCast(@alignCast(is_data.?));
    const work = base.work orelse return 0;
    const raised = mac.takeInterrupts();
    if (raised == 0) return 0;
    work.raised |= raised;
    base.sys_base.Signal(&base.task, base.int_mask);
    return 1;
}

/// What the engine raised since the task last looked, taken.
fn takeRaised(base: *EmacBase) u32 {
    const sys = base.sys_base;
    const work = base.work.?;
    sys.Disable();
    defer sys.Enable();
    const raised = work.raised;
    work.raised = 0;
    return raised;
}

// --- the task -------------------------------------------------------------

/// Every request, every frame in and out, and the link. The port is given
/// its signal before the first message is taken, so a request that came
/// in while the device was starting is not missed.
fn netTask(sys: *ExecBase) callconv(.c) void {
    const base: *EmacBase = @fieldParentPtr("task", sys.FindTask(null).?);
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

    const timer_mask: u32 = if (base.timer_port) |timer_port| timer_port.sigMask() else 0;
    while (true) {
        const raised = takeRaised(base);
        if (raised & mac.int_bus_error != 0) restart(base);
        if (raised & (mac.int_receive | mac.int_receive_unavailable) != 0) {
            // What the MAC had no room for - its queue full while the
            // descriptors were all ours - taken with every pass, not only
            // when the ring ran dry: the counts hold 2047 at most.
            for (0..mac.takeMissed()) |_| base.net.overrun();
            base.received();
        }
        if (raised & mac.int_send != 0) base.sent();
        if (base.polling != 0 and sys.CheckIO(&base.timer_io.node) != null) {
            _ = sys.WaitIO(&base.timer_io.node);
            base.polling = 0;
            pollLink(base);
        }
        while (sys.GetMsg(queue_port)) |msg| base.net.perform(_emac.sanaReq(_emac.requestOf(msg)));
        _ = sys.Wait(queue_port.sigMask() | base.int_mask | timer_mask);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(base: *EmacBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

/// The interrupt's signal, the timer, the hardware, and the interrupt
/// server; then the first look at the link. Without any of them nothing
/// is hooked up, and Open refuses.
fn setUp(base: *EmacBase) void {
    const sys = base.sys_base;
    const int_signal = sys.AllocSignal(-1);
    if (int_signal < 0) return;
    base.int_mask = @as(u32, 1) << @intCast(int_signal);

    base.timer_port = sys.CreateMsgPort();
    if (base.timer_port == null) return;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = base.timer_port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) return;
    base.timer_open = 1;

    if (!startHardware(base)) return;

    sys.AddIntServer(base.irq, &base.work.?.int);
    base.hooked = 1;
    // The unit starts with a carrier; this one has none until the PHY
    // says so.
    base.net.setCarrier(false);
    pollLink(base);
}

/// The port ready, the MAC reset and set up, the PHY reset, set up and
/// negotiating.
fn startHardware(base: *EmacBase) bool {
    const sys = base.sys_base;
    if (!port.powerUp(&base.port, base)) {
        sdk.exec.kprintf(sys, "%s: the MAC stays in reset\n", .{DEVICE_NAME});
        return false;
    }
    if (!mac.reset()) {
        sdk.exec.kprintf(sys, "%s: no clock from the PHY\n", .{DEVICE_NAME});
        return false;
    }
    mac.setUp(_emac.buffer_bytes);
    mac.setStation(&base.net.station);

    if (!phy.present(base.phy_address)) {
        sdk.exec.kprintf(sys, "%s: no PHY answers at address %u\n", .{ DEVICE_NAME, base.phy_address });
        return false;
    }
    _ = phy.startReset(base.phy_address);
    var steps: u32 = 0;
    while (!phy.resetDone(base.phy_address)) : (steps += 1) {
        if (steps == phy_reset_steps) {
            sdk.exec.kprintf(sys, "%s: the PHY stays in reset\n", .{DEVICE_NAME});
            return false;
        }
        base.delay(phy_step_us);
    }
    phy.configure(base.phy_address, &base.wiring);
    return phy.negotiate(base.phy_address);
}

/// The PHY asked about its link: the line set up for the speed and duplex
/// it came up at, the unit told when it comes or goes; and the next look
/// set.
fn pollLink(base: *EmacBase) void {
    const sys = base.sys_base;
    const link = phy.link(base.phy_address);
    if (link.up and base.link_up == 0) {
        mac.setLine(link.mbits, link.full_duplex);
        sys.Disable();
        port.setSpeed(&base.port, link.mbits);
        sys.Enable();
        phy.settle(base.phy_address, link, &base.wiring);
        base.link_up = 1;
        const duplex: [*:0]const u8 = if (link.full_duplex) "full" else "half";
        sdk.exec.kprintf(sys, "%s: link up, %u Mbit/s %s duplex\n", .{ DEVICE_NAME, link.mbits, duplex });
        base.net.setCarrier(true);
    } else if (!link.up and base.link_up != 0) {
        base.link_up = 0;
        sdk.exec.kprintf(sys, "%s: link down\n", .{DEVICE_NAME});
        base.net.setCarrier(false);
    }
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = timer.TimeVal.fromMicros(link_poll_us);
    sys.SendIO(&base.timer_io.node);
    base.polling = 1;
}

/// A bus error stopped the engine: the chains set up afresh and started
/// again, if they ran.
fn restart(base: *EmacBase) void {
    sdk.exec.kprintf(base.sys_base, "%s: DMA bus error, restarting\n", .{DEVICE_NAME});
    base.net.event(net.S2EVENT_HARDWARE | net.S2EVENT_ERROR);
    if (base.running == 0) return;
    base.setRunning(false);
    base.setRunning(true);
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
    const base = _emac.baseOf(io);
    const req = _emac.sanaReq(io);
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
    const base = _emac.emacBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    var it = base.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_emac.requestOf(msg) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (base.net.abort(_emac.sanaReq(io))) 0 else -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _emac.emacBase(dev);
    if (unit_number != 0 or base.hooked == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_emac.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _emac.baseOf(io);
    base.net.close(_emac.sanaReq(io));
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, its interrupt and the MAC. The
/// seglist it was loaded from is kept in the base for the day it does go.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The board's Ethernet part on the chip's bus for it: its port, the
/// PHY's address and wiring, the interrupt, into the base, and the
/// station address into `station`. False if the board has none, or names
/// lines or a MAC this cannot use.
fn findPart(sys: *ExecBase, utility: *UtilityBase, base: *EmacBase, station: *[6]u8) bool {
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part = eb.FindBoardPart(null, st.PARTKIND_NET, st.CHIP_ANY);
    while (part) |one| {
        if (utility.GetTagData(st.PART_Bus, st.BUS_NONE, one.tags) != port.bus) {
            part = eb.FindBoardPart(one, st.PARTKIND_NET, st.CHIP_ANY);
            continue;
        }
        base.port = port.portOf(utility, one.tags) orelse {
            sdk.exec.kprintf(sys, "%s: the board's Ethernet port is wired where the MAC cannot use it\n", .{DEVICE_NAME});
            return false;
        };
        base.irq = @intCast(utility.GetTagData(st.PART_Irq, fixed_irq orelse 0, one.tags));
        if (base.irq == 0) return false;
        base.phy_address = @intCast(utility.GetTagData(st.PART_Address, 0, one.tags) & 0x1F);
        base.wiring = phy.wiringOf(utility, one.tags);
        station.* = stationOf(sys, utility, one.tags, &base.port);
        return true;
    }
    return false;
}

/// The port's station address: the board's, if it gives one, else the
/// chip's own, else one made up from the clock - locally administered,
/// and said on the log, since it is new at every start.
fn stationOf(sys: *ExecBase, utility: *UtilityBase, tags: ?[*]const sdk.utility.TagItem, at: *const port.Port) [6]u8 {
    if (utility.GetTagData(st.PART_StationAddress, 0, tags) != 0) {
        const given: *const [6]u8 = @ptrFromInt(utility.GetTagData(st.PART_StationAddress, 0, tags));
        if (!std.mem.allEqual(u8, given, 0)) return given.*;
    }
    if (port.factoryAddress(at)) |factory| return factory;
    const clock = sdk.hardware.cpu.ccount();
    const made = [6]u8{ 0x02, 0x00, @truncate(clock >> 24), @truncate(clock >> 16), @truncate(clock >> 8), @truncate(clock) };
    sdk.exec.kprintf(sys, "%s: the board gives no station address; %02x:%02x:%02x:%02x:%02x:%02x for now\n", .{
        DEVICE_NAME,       @as(u32, made[0]), @as(u32, made[1]), @as(u32, made[2]),
        @as(u32, made[3]), @as(u32, made[4]), @as(u32, made[5]),
    });
    return made;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without an Ethernet port gets no device at all: null, before
/// anything is taken but utility.library, which is given back. Otherwise
/// the block the engine and the interrupt reach is allocated internal
/// and written out of the cache, and the task is started, which starts
/// the hardware; this waits until the task takes requests.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _emac.emacBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    const utility: *UtilityBase = @ptrCast(utility_lib);
    var station: [6]u8 = undefined;
    if (!findPart(sys_base, utility, base, &station)) {
        sys_base.CloseLibrary(utility_lib);
        return null;
    }
    base.utility = utility;

    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);

    base.net.init(sys_base, base, &station);

    // Aligned to a cache line by hand: AllocMem's blocks are aligned less.
    const work_bytes = @sizeOf(Work) + _emac.line_bytes - 1;
    const memory = sys_base.AllocMem(work_bytes, work_memory | exec.MEMF_CLEAR) orelse {
        sdk.exec.kprintf(sys_base, "%s: no internal memory for the frame buffers\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    const aligned = (@intFromPtr(memory) + _emac.line_bytes - 1) & ~@as(usize, _emac.line_bytes - 1);
    const work: *Work = @ptrFromInt(aligned);
    base.work_memory = memory;
    base.work = work;
    // The clearing left the block's lines dirty in the cache: out with
    // them now, or one written back later would land on a frame.
    base.writeBack(work, @sizeOf(Work));
    work.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = base,
        .code = &intServer,
    };
    work.raised = 0;

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys_base.FreeMem(memory, work_bytes);
        base.work = null;
        base.work_memory = null;
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
    .data_size = @sizeOf(EmacBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: a unit per network part the board
/// lists - its Ethernet PHY.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_SANA2, 0 };

/// No flags but AUTOINIT: the device is on the disk, in DEVS:networks/,
/// and is made when something opens it - ramlib loads the file and hands
/// this tag to InitResident.
///
/// It is in `.resident`, which the link script KEEPs: nothing in the file
/// refers to the tag, whoever loads the file looks for it.
export const emac_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&emac_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .unit_part = sdk.expansion.systemtags.PARTKIND_NET,
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
/// it, so it needs an export and a section of its own that the link
/// script KEEPs.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
