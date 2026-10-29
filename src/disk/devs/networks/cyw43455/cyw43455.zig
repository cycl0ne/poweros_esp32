// SPDX-License-Identifier: MIT
//! cyw43455.device: the Raspberry Pi CM5's Wi-Fi, an Infineon CYW43455 on
//! the BCM2712's second SD host, as a network device. It is in
//! DEVS:networks/, and the board's system tag list says whether there is
//! one and how it is wired (a PARTKIND_NET part with CHIP_CYW43455); a
//! board without one gets no device.
//!
//! **The bring-up**: the host's lines and the radio's power (host.zig),
//! the card found on the bus and set up as Linux's brcmfmac sets it up -
//! four data lines at 25 MHz, function 1's blocks of 64 bytes and
//! function 2's of 512, function 1 enabled (sdio.zig) - the backplane's
//! clock brought up, the chip read and its cores listed (backplane.zig),
//! the firmware loaded and started (boot.zig), the firmware set up as
//! Linux sets it up, through its commands (bcdc.zig) in its frames
//! (sdpcm.zig) - the board's station address, the CLM blob, the events it
//! sends - and the radio brought up as a station (radio.zig): unit 0,
//! which scans, joins and leaves networks, and carries their frames.
//!
//! **Every access to the chip runs on the device's worker**, a DOS
//! process: the firmware is read from files. The unit's requests come to
//! the worker too, except S2_DEVICEQUERY and S2_GETSTATIONADDRESS,
//! answered where they are asked. The chip's interrupt - the card's, on
//! the SD host's line - wakes it: the server turns the card's interrupt
//! off and signals the worker, which answers the chip and turns it on
//! again before it waits.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const sdio = @import("sdio.zig");
const backplane = @import("backplane.zig");
const boot = @import("boot.zig");
const sdpcm = @import("sdpcm.zig");
const bcdc = @import("bcdc.zig");
const radio = @import("radio.zig");
const net = sdk.devices.network;
const CywBase = _cyw.CywBase;

pub const DEVICE_NAME = _cyw.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 1;
const BUILD_DATE = "29.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

const worker_stack = 16384;
const worker_pri = 5;

/// How long WL_REG_ON is held low, so the chip starts from its reset;
/// how long it takes to come up once high - the device tree's startup
/// delay - and how long the bus is powered, and clocked, before the
/// first command.
const power_off_us = 20_000;
const power_on_us = 150_000;
const bus_power_us = 10_000;
const first_clock_us = 10_000;
/// The card's clocks: while it is found, and after.
const identify_hz = 400_000;
const run_hz = 25_000_000;
/// The block size of the frames' function.
const f2_block_bytes = 512;

fn say(sys: *ExecBase, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

fn sayError(sys: *ExecBase, comptime text: [:0]const u8, err: host_file.Error) void {
    exec.kprintf(sys, "%s: " ++ text ++ ": %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, @errorName(err)) });
}

// --- the worker -------------------------------------------------------------

fn workerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *CywBase = @ptrCast(@alignCast(me.user_data orelse return));
    base.worker = me;
    const work = start(base);
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    if (work) |radio_work| radio.run(radio_work);
    // Without a radio nothing comes to the worker: the device opens no
    // unit.
    while (true) _ = sys.Wait(exec.SIGBREAKF_CTRL_C);
}

/// The chip brought up, its firmware started and set up, the radio up as
/// a station, the unit made with the firmware's station address, and the
/// worker's ports on its signal: the radio's block. Null, said, where it
/// stops.
fn start(base: *CywBase) ?*radio.Work {
    const sys = base.sys_base;
    if (!openTimer(base)) return null;
    if (!bringUp(base)) {
        host_file.power(sys, &base.host, false);
        return null;
    }
    base.found = 1;
    if (!boot.start(base)) return null;
    base.running = 1;
    say(sys, "the firmware runs");
    if (!talk(base) or !radio.setUp(base)) return null;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    const work = radio.makeWork(base) orelse return null;
    base.work_mask = @as(u32, 1) << @intCast(signal);
    sys.Disable();
    for ([_]*exec.MsgPort{ &base.poll_port, &base.unit.msg_port }) |port| {
        port.sig_bit = @intCast(signal);
        port.sig_task = base.worker;
        port.flags = exec.PA_SIGNAL;
    }
    sys.Enable();
    base.net.init(sys, base, &base.station);
    base.net.setCarrier(false);
    if (!hookInterrupt(base)) say(sys, "no interrupt; the chip is polled");
    base.ready = 1;
    say(sys, "the radio is up");
    return work;
}

/// The SD host's interrupt hooked, and the card's interrupts on at the
/// card: the worker turns them on at the host, where they reach the line,
/// once it waits. False where the board gives no interrupt, or the card
/// refuses.
fn hookInterrupt(base: *CywBase) bool {
    if (base.irq == 0) return false;
    sdio.enableInterrupts(&base.backplane.card) catch return false;
    base.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = base,
        .code = &intServer,
    };
    base.sys_base.AddIntServer(base.irq, &base.int);
    base.int_hooked = 1;
    return true;
}

/// The SD host's interrupt: the card's interrupt turned off and the
/// worker woken, if it is the card's.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *CywBase = @ptrCast(@alignCast(is_data.?));
    if (!host_file.cardInterrupting(&base.host)) return 0;
    host_file.cardInterrupt(&base.host, false);
    base.sys_base.Signal(base.worker.?, base.work_mask);
    return 1;
}

fn openTimer(base: *CywBase) bool {
    const sys = base.sys_base;
    base.timer_port = sys.CreateMsgPort();
    const port = base.timer_port orelse return false;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) return false;
    base.timer_open = 1;
    return true;
}

/// The chip powered up and found, and its backplane read: what it is and
/// what it is made of, on the log. False, said, at the first step that
/// fails.
fn bringUp(base: *CywBase) bool {
    const sys = base.sys_base;
    const host = &base.host;
    host_file.pinsUp(sys, host);
    if (!host_file.reset(host)) {
        say(sys, "the SD host stays in reset");
        return false;
    }
    host_file.power(sys, host, false);
    base.delay(power_off_us);
    host_file.power(sys, host, true);
    base.delay(power_on_us);
    host_file.busPower(host);
    base.delay(bus_power_us);
    _ = host_file.setClock(host, identify_hz) orelse {
        say(sys, "the SD host's clock does not settle");
        return false;
    };
    base.delay(first_clock_us);
    exec.kprintf(sys, "%s: SD host version %u, clocked at %u MHz\n", .{
        @as([*:0]const u8, DEVICE_NAME), host_file.version(host) + 1, host.base_hz / 1_000_000,
    });

    const card = sdio.identify(host, &_cyw.waitOn, base) catch |err| {
        sayError(sys, "no SDIO card answers", err);
        return false;
    };
    base.backplane = .{ .card = card };
    const bp = &base.backplane;
    setUpCard(base) catch |err| {
        sayError(sys, "the card cannot be set up", err);
        return false;
    };
    const hz = host_file.setClock(host, run_hz) orelse {
        say(sys, "the SD host's clock does not settle");
        return false;
    };
    exec.kprintf(sys, "%s: SDIO card %u with %u functions, four lines at %u kHz\n", .{
        @as([*:0]const u8, DEVICE_NAME), card.rca, card.functions, hz / 1000,
    });

    const clock = backplane.clockUp(bp, &_cyw.waitOn, base) catch |err| {
        sayError(sys, "the backplane's clock does not come", err);
        return false;
    };
    const known = backplane.scan(bp, &base.chip) catch |err| {
        sayError(sys, "the backplane cannot be read", err);
        return false;
    };
    const chip = &base.chip;
    exec.kprintf(sys, "%s: chip %x revision %u, ALP clock up (%02x), %u cores\n", .{
        @as([*:0]const u8, DEVICE_NAME), chip.id, chip.rev, @as(u32, clock), chip.core_count,
    });
    if (!known) {
        say(sys, "the chip's backplane is not one this knows");
        return false;
    }
    for (chip.cores[0..chip.core_count]) |core| {
        exec.kprintf(sys, "%s:   core %03x revision %u at %08x, wrapper %08x\n", .{
            @as([*:0]const u8, DEVICE_NAME), @as(u32, core.id), @as(u32, core.rev), core.base, core.wrap,
        });
    }
    return true;
}

/// The firmware spoken to, as Linux first speaks to it: the frames'
/// buffers taken, its coalescing of frames to the host turned off - what
/// Linux does for older SDIO cores, and all this reads - the board's
/// station address given to it, and the CLM blob; and what it is, its
/// station address - kept for the unit - and its CLM data on the log.
/// False, said, if it does not answer.
fn talk(base: *CywBase) bool {
    const sys = base.sys_base;
    if (!sdpcm.open(base)) {
        say(sys, "no memory for the firmware's frames");
        return false;
    }
    talkTo(base) catch |err| {
        sayError(sys, "the firmware does not answer", err);
        return false;
    };
    return true;
}

fn talkTo(base: *CywBase) host_file.Error!void {
    const sys = base.sys_base;
    try sdpcm.poll(base);
    const glom = try bcdc.setVar32(base, "bus:txglom", 0);
    if (glom != 0) sayStatus(sys, "bus:txglom", glom);
    if (!std.mem.allEqual(u8, &base.station, 0)) {
        const given = try bcdc.setVar(base, "cur_etheraddr", &base.station);
        if (given != 0) sayStatus(sys, "cur_etheraddr", given);
    }
    var address: [6]u8 = @splat(0);
    const known = try bcdc.getVar(base, "cur_etheraddr", &address);
    if (known == 0) {
        base.station = address;
        exec.kprintf(sys, "%s: station address %02x:%02x:%02x:%02x:%02x:%02x\n", .{
            @as([*:0]const u8, DEVICE_NAME),
            @as(u32, address[0]), @as(u32, address[1]), @as(u32, address[2]),
            @as(u32, address[3]), @as(u32, address[4]), @as(u32, address[5]),
        });
    } else sayStatus(sys, "cur_etheraddr", known);
    if (boot.loadClm(base)) say(sys, "the CLM blob is loaded");
    try sayText(base, "ver");
    try sayText(base, "clmver");
    // What it can do: "idsup" is its own key handshake, which joins use.
    try sayText(base, "cap");
}

/// The firmware's text variable `name` on the log, on one line.
fn sayText(base: *CywBase, comptime name: [:0]const u8) host_file.Error!void {
    const sys = base.sys_base;
    var text: [512]u8 = @splat(0);
    const status = try bcdc.getVar(base, name, text[0 .. text.len - 1]);
    if (status != 0) return sayStatus(sys, name, status);
    var end = std.mem.indexOfScalar(u8, &text, 0).?;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    text[end] = 0;
    std.mem.replaceScalar(u8, text[0..end], '\n', ' ');
    exec.kprintf(sys, "%s: " ++ name ++ ": %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, @ptrCast(&text)) });
}

/// A variable the firmware refused, and its status, on the log.
fn sayStatus(sys: *ExecBase, comptime name: [:0]const u8, status: i32) void {
    exec.kprintf(sys, "%s: the firmware refuses " ++ name ++ ": %d\n", .{ @as([*:0]const u8, DEVICE_NAME), status });
}

/// The card's bus four lines wide on both sides, its functions' block
/// sizes, and function 1 - the backplane - enabled.
fn setUpCard(base: *CywBase) host_file.Error!void {
    const card = &base.backplane.card;
    try sdio.setWide(card);
    host_file.setBus(&base.host, true, false);
    try sdio.setBlockSize(card, 1, backplane.block_bytes);
    try sdio.setBlockSize(card, 2, f2_block_bytes);
    try sdio.enable(card, 1, &_cyw.waitOn, base);
}

// --- the device -------------------------------------------------------------

/// The requests the worker answers: the unit's that wait or change it,
/// and the wireless ones.
fn queued(command: u16) bool {
    if (radio.isWireless(command)) return true;
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
    const base = _cyw.cywBase(dev);
    const req = _cyw.sanaReq(io);
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

/// A request the worker hasn't taken yet, or one waiting in the unit - a
/// read, a write, an event - is taken back and answered as aborted. A
/// scan can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _cyw.cywBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    var it = base.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        if (_cyw.requestOf(message) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (base.net.abort(_cyw.sanaReq(io))) 0 else -1;
}

/// Unit 0, once the radio is up.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _cyw.cywBase(dev);
    if (unit_number != 0 or base.ready == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_cyw.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _cyw.cywBase(dev);
    base.net.close(_cyw.sanaReq(io));
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its worker owns the host and the chip.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The board's Wi-Fi part: the host it is on, its interrupt, its lines
/// and its power pin, into the base. False if the board has none, or wires it where
/// this cannot drive it.
fn findPart(sys: *ExecBase, utility: *UtilityBase, base: *CywBase) bool {
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_NET, st.CHIP_CYW43455) orelse return false;
    if (utility.GetTagData(st.PART_Bus, st.BUS_NONE, part.tags) != host_file.bus) return false;
    base.host = host_file.hostOf(utility, part.tags) orelse {
        say(sys, "the board's Wi-Fi is wired where this cannot drive it");
        return false;
    };
    const station = utility.GetTagData(st.PART_StationAddress, 0, part.tags);
    if (station != 0) base.station = @as(*const [6]u8, @ptrFromInt(station)).*;
    base.irq = @truncate(utility.GetTagData(st.PART_Irq, 0, part.tags));
    return true;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without the radio gets no device at all: null, before
/// anything is taken but what is given back. Otherwise the worker is
/// started, which brings the chip up; this waits until it has.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _cyw.cywBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    const utility: *UtilityBase = @ptrCast(utility_lib);
    if (!findPart(sys, utility, base)) {
        sys.CloseLibrary(utility_lib);
        return null;
    }
    base.utility = utility;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return null;
    base.dos_base = @ptrCast(dos_lib);
    // PA_IGNORE until the worker has a signal for them; the unit's is
    // opened only once it has.
    base.poll_port = .{ .flags = exec.PA_IGNORE };
    base.poll_port.msg_list.init(.message);
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);

    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    base.starter = sys.FindTask(null);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workerMain) },
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
    .data_size = @sizeOf(CywBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: a unit per network part the board
/// lists - its radio.
const device_speaks = [_]u32{ expansion.devices.DEVIF_SANA2, 0 };

/// No flags but AUTOINIT: the device is on the disk, in DEVS:networks/,
/// and is made when something opens it - ramlib loads the file and hands
/// this tag to InitResident.
export const cyw43455_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&cyw43455_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .unit_part = st.PARTKIND_NET,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
