// SPDX-License-Identifier: MIT
//! wifi.device: the chip's radio as a station, on the network device API
//! (sdk/devices/network.zig). It is in DEVS:networks/, and the board's
//! system tag list says whether the board's module gives the radio an
//! antenna; a board without it gets no device.
//!
//! **Two halves.** The radio runs on its vendor's closed libraries - the
//! PHY, the MAC, the 802.11 state machine - linked into this file. They
//! run on an OS adapter of the device's own (`osi/`), which maps what they
//! ask for - tasks, locks, queues, timers, memory, an interrupt - onto
//! exec, and the device's side (`phy/`, `wpa/`, this file) gives them
//! power, clocks, calibration and keys.
//!
//! **Where it stands.** The device starts the radio: the power domain,
//! the libraries with the adapter, the station mode, and the start, whose
//! PHY calibration is the first thing that touches the radio itself. Every
//! adapter call is traced on the raw port while this is young
//! (`trace_calls`). It answers the network device API through the shared
//! unit (sdk/devices/network/unit.zig), whose link (`link.zig`) has a
//! carrier while the station is joined; it scans (S2_GETNETWORKS,
//! `scan.zig`) and joins and leaves (S2_SETOPTIONS, S2_GETNETWORKINFO,
//! `join.zig`), WPA2-Personal included: the key handshake is the
//! supplicant's (`wpa/`), and runs on the libraries' task.
//!
//! **Every request runs on the device's own task**, the one that started
//! the radio: BeginIO queues them to it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const _wifi = @import("_wifi.zig");
const WifiBase = _wifi.WifiBase;
const Work = _wifi.Work;
const _osi = @import("osi/_osi.zig");
const osi_timer = @import("osi/timer.zig");
const phy = @import("phy/phy.zig");
const efuse = @import("phy/efuse.zig");
const events = @import("events.zig");
const vendor = @import("vendor.zig");
const scan = @import("scan.zig");
const join = @import("join.zig");
const supplicant = @import("wpa/supplicant.zig");
const link = @import("link.zig");

comptime {
    _ = @import("libc.zig");
    _ = @import("regulatory.zig");
}

pub const DEVICE_NAME = _wifi.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "26.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The device's task calls the libraries, which go deep: internal memory,
/// and room.
const stack_size = 8192;
/// As the other network devices' tasks.
const task_pri = 5;
/// Every adapter call on the raw port.
const trace_calls = false;

// --- the task -------------------------------------------------------------

/// The init is waiting to hear how the radio's start went.
fn started(base: *WifiBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

fn fail(sys: *ExecBase, comptime what: [*:0]const u8) bool {
    sdk.exec.kprintf(sys, "%s: %s\n", .{ DEVICE_NAME, what });
    return false;
}

fn report(sys: *ExecBase, comptime what: [*:0]const u8, result: i32) bool {
    if (result == vendor.ok) return true;
    sdk.exec.kprintf(sys, "%s: %s failed: %ld\n", .{ DEVICE_NAME, what, @as(i64, result) });
    return false;
}

/// The radio started: the adapter's state, its timers, the power domain,
/// the libraries in station mode. False, and said on the raw port, at the
/// first step that fails.
fn startRadio(base: *WifiBase) bool {
    const sys = base.sys_base;
    const work = base.work.?;
    const state = &work.adapter;

    base.timer_io = .{};
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_ECLOCK, &base.timer_io.node, 0) != 0) return fail(sys, "no timer.device");
    const timer_base: *sdk.interface.timer.TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
    var clock: timer.EClockVal = .{};
    state.* = .{
        .sys = sys,
        .timer_base = timer_base,
        .eclock_hz = timer_base.ReadEClock(&clock),
        .trace = trace_calls,
        .mac = base.station,
    };
    state.ended.init(.unknown);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return fail(sys, "no signal for the radio's events");
    state.events.task = &base.task;
    state.events.signal = @as(u32, 1) << @intCast(signal);
    base.event_signal = signal;
    const frame_signal = sys.AllocSignal(-1);
    if (frame_signal < 0) return fail(sys, "no signal for the radio's frames");
    base.frame_mask = @as(u32, 1) << @intCast(frame_signal);
    state.device = base;
    _osi.adapter = state;
    if (trace_calls) sdk.exec.kprintf(sys, "%s: startRadio at 0x%lx\n", .{ DEVICE_NAME, @as(u64, @intFromPtr(&startRadio)) });

    if (_osi.adopt(&base.task) == null) return fail(sys, "no thread for the device's task");
    if (!osi_timer.startTask()) return fail(sys, "no timer task");
    phy.powerOn(&state.phy);

    const config: vendor.InitConfig = .{};
    if (!report(sys, "esp_wifi_init_internal", vendor.esp_wifi_init_internal(&config))) return false;
    if (!supplicant.register(base)) return fail(sys, "the supplicant's table was refused");
    if (!report(sys, "esp_wifi_set_mode", vendor.esp_wifi_set_mode(vendor.mode_sta))) return false;
    if (!report(sys, "esp_wifi_start", vendor.esp_wifi_start())) return false;
    return true;
}

/// What the libraries posted, acted on.
fn handleEvents(base: *WifiBase) void {
    const state = &base.work.?.adapter;
    while (events.take(&state.events, base.sys_base)) |event| switch (event.id) {
        events.sta_start => sdk.exec.kprintf(base.sys_base, "%s: the station is started\n", .{DEVICE_NAME}),
        events.scan_done => scan.done(base),
        events.sta_connected => {
            _ = vendor.esp_wifi_internal_set_sta_ip();
            link.hook(true);
            base.net.setCarrier(true);
        },
        events.sta_disconnected => {
            base.net.setCarrier(false);
            link.hook(false);
            join.left(base, event.data[0..event.length]);
        },
        else => {},
    };
}

fn wifiTask(sys: *ExecBase) callconv(.c) void {
    const base: *WifiBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const queue_port = &base.unit.msg_port;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(base);
    sys.Disable();
    queue_port.sig_bit = @intCast(signal);
    queue_port.sig_task = &base.task;
    queue_port.flags = exec.PA_SIGNAL;
    sys.Enable();

    if (startRadio(base)) base.radio_up = 1;
    started(base);

    const event_mask: u32 = if (base.event_signal >= 0) @as(u32, 1) << @intCast(base.event_signal) else 0;
    while (true) {
        if (base.radio_up != 0) {
            handleEvents(base);
            link.deliver(base);
        }
        while (sys.GetMsg(queue_port)) |msg| perform(base, _wifi.requestOf(msg));
        _ = sys.Wait(queue_port.sigMask() | event_mask | base.frame_mask);
    }
}

/// A request, on the task: answered here, or kept until the radio has
/// the answer.
fn perform(base: *WifiBase, io: *exec.IORequest) void {
    const sys = base.sys_base;
    const req = _wifi.sanaReq(io);
    switch (io.command) {
        wireless.S2_GETNETWORKS => {
            if (scan.begin(base, req)) return;
            io.err = net.S2ERR_SOFTWARE;
        },
        wireless.S2_SETOPTIONS => io.err = join.setOptions(base, req),
        wireless.S2_GETNETWORKINFO => io.err = join.networkInfo(base, req),
        else => return base.net.perform(req),
    }
    sys.ReplyMsg(&io.message);
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
        wireless.S2_GETNETWORKS,
        wireless.S2_SETOPTIONS,
        wireless.S2_GETNETWORKINFO,
        => true,
        else => false,
    };
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const base = _wifi.baseOf(io);
    const req = _wifi.sanaReq(io);
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

/// A request the task hasn't taken yet is taken back and answered as
/// aborted.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _wifi.wifiBase(dev);
    const sys = base.sys_base;
    sys.Disable();
    for ([_]*exec.List{ &base.unit.msg_port.msg_list, &base.scans }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const msg: *exec.Message = @alignCast(@fieldParentPtr("node", node));
            if (_wifi.requestOf(msg) != io) continue;
            sys.Remove(node);
            sys.Enable();
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    sys.Enable();
    return if (base.net.abort(_wifi.sanaReq(io))) 0 else -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _wifi.wifiBase(dev);
    if (unit_number != 0 or base.radio_up == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_wifi.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _wifi.baseOf(io);
    base.net.close(_wifi.sanaReq(io));
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: the libraries keep tasks, timers and an interrupt
/// that cannot all be taken back.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// Whether the board's module gives the radio an antenna.
fn hasRadio(sys: *ExecBase) bool {
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    return eb.FindBoardPart(null, st.PARTKIND_NET, st.CHIP_ESP32S3_RADIO) != null;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without the radio gets no device at all: null, before
/// anything is taken. Otherwise the block the adapter lives in is
/// allocated internal and the task is started; this waits until it has
/// tried the radio. A radio that did not start leaves a device every open
/// of which fails: what the libraries started by then - tasks, timers, an
/// interrupt - cannot be taken back, and the device keeps it all.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _wifi.wifiBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    if (!hasRadio(sys_base)) {
        sdk.exec.kprintf(sys_base, "%s: no radio on this board\n", .{DEVICE_NAME});
        return null;
    }
    base.station = efuse.stationAddress();
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.utility = @ptrCast(utility_lib);
    // crypto.library is the key handshake's engines. Without it the radio
    // still scans and joins a network with no security, so a board that has
    // not got it keeps a device that says so once.
    if (sys_base.OpenLibrary(sdk.crypto.CRYPTONAME, 1)) |crypto_lib| {
        base.crypto = @ptrCast(crypto_lib);
    } else {
        sdk.exec.kprintf(sys_base, "%s: no crypto.library, so no protected network\n", .{DEVICE_NAME});
    }
    base.scans.init(.message);

    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);
    // The unit has no carrier until the station joins a network.
    base.net.init(sys_base, base, &base.station);
    base.net.setCarrier(false);

    const memory = sys_base.AllocMem(@sizeOf(Work), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        sdk.exec.kprintf(sys_base, "%s: no internal memory for the radio\n", .{DEVICE_NAME});
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    base.work = @ptrCast(@alignCast(memory));

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
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
    _ = sys_base.AddTask(&base.task, &wifiTask, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
    if (base.radio_up == 0) sdk.exec.kprintf(sys_base, "%s: the radio did not start\n", .{DEVICE_NAME});
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
    .data_size = @sizeOf(WifiBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, in DEVS:networks/,
/// and is made when something opens it - ramlib loads the file and hands
/// this tag to InitResident.
export const wifi_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &wifi_device_tag,
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

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
