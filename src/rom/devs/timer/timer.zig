// SPDX-License-Identifier: MPL-2.0
//! timer.device: time requests on the system timer.
//!
//! Five units on three delay lists:
//!
//!   TD_ECLOCKLIST   units 0, 2, 4 (MICROHZ, ECLOCK, WAITECLOCK): targets in
//!                   E-clock ticks. The micro timer, SYSTIMER alarm 0 in
//!                   one-shot mode, is always set to the first request
//!                   (RethinkMicroTimer); precise.
//!   TD_VBLANKLIST   unit 1 (VBLANK): targets in E-clock ticks, checked on
//!                   every VBLANK; cheap, resolution 1/50 s.
//!   TD_SYSTIMELIST  unit 3 (WAITUNTIL): targets in system time, checked
//!                   on every VBLANK.
//!
//! VBLANK is SYSTIMER alarm 1 in periodic mode at 50 Hz. Both alarms come
//! in through exec's AddIntServer. The interrupts take expired requests off
//! the list heads (IntCommon) and reply them after Enable (IntEnd).
//!
//! The E-clock is SYSTIMER unit 0 (16 MHz from boot). The device builds
//! against the SDK: it keeps the SysBase its init gets and calls exec
//! through the SDK's interface to exec's jump table.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const timeval = @import("timeval.zig");
const vec = exec.vec;

pub const TimeVal = timeval.TimeVal;
pub const EClockVal = timeval.EClockVal;

pub const DEVICE_NAME = sdk.devices.timer.TIMERNAME;
const DEVICE_VERSION = 0;
const DEVICE_REVISION = 1;
const BUILD_DATE = "1.1.2025";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

// The units and the commands are the SDK's (sdk/devices/timer.zig).
const types = sdk.devices.timer;
pub const UNIT_MICROHZ = types.UNIT_MICROHZ;
pub const UNIT_VBLANK = types.UNIT_VBLANK;
pub const UNIT_ECLOCK = types.UNIT_ECLOCK;
pub const UNIT_WAITUNTIL = types.UNIT_WAITUNTIL;
pub const UNIT_WAITECLOCK = types.UNIT_WAITECLOCK;
pub const TR_ADDREQUEST = types.TR_ADDREQUEST;
pub const TR_GETSYSTIME = types.TR_GETSYSTIME;
pub const TR_SETSYSTIME = types.TR_SETSYSTIME;
const unit_count = 5;

/// The E-clock's rate: SYSTIMER's.
pub const eclock_hz: u32 = systimer.SYSTIMER_HZ;
const ticks_per_us = eclock_hz / 1_000_000;
/// The VBLANK rate (PAL).
pub const vblank_hz: u32 = 50;

/// struct timerequest: the SDK's (sdk/devices/timer.zig).
pub const TimeRequest = types.TimeRequest;

/// The request a node on a delay list belongs to.
fn requestOf(node: *exec.Node) *TimeRequest {
    const msg: *exec.Message = @fieldParentPtr("node", node);
    const io: *exec.IORequest = @fieldParentPtr("message", msg);
    return @fieldParentPtr("node", io);
}

/// tr_time as the E-clock target the device keeps there while it waits.
fn eclockOf(req: *TimeRequest) *EClockVal {
    return @ptrCast(&req.time);
}

/// The device's own functions, after BeginIO and AbortIO, as the SDK has
/// them (sdk/fd/timer_lib.fd).
pub const interface = sdk.interface.timer;
pub const LVO = interface.LVO;

// The device implements the SDK's interface: every function in LVO is an
// lvo* function here, with the signature the SDK gives it (after the base),
// in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("timer.device's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("timer.device's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

/// TIMERUNIT: what io_Unit points to.
const TimerUnit = extern struct {
    unit: exec.Unit,
    /// TU_UNITLIST: the delay list the unit's requests wait on.
    list: *exec.List,
};

/// TIMERDEVICE: the device base.
const TimerBase = extern struct {
    dev: exec.Device,
    /// TD_SYSLIB: SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// TD_UNIT0 to TD_UNIT4.
    units: [unit_count]TimerUnit,
    /// TD_ECLOCKLIST, TD_VBLANKLIST, TD_SYSTIMELIST: by target, soonest
    /// first.
    eclock_list: exec.List,
    vblank_list: exec.List,
    systime_list: exec.List,
    /// TD_TERMIOQ: requests the interrupts took off, replied after Enable.
    term_queue: exec.List,
    /// TD_CIATJUMP (the micro timer) and TD_VBLANKINT.
    micro_int: exec.Interrupt,
    vblank_int: exec.Interrupt,
};

/// The system time minus the uptime, in µs (TR_SETSYSTIME).
var systime_offset: u64 = 0;
/// The last system time GetSysTime handed out: it only ever rises.
var last_systime: u64 = 0;

// SYSTIMER: alarm 0 is the micro timer (one-shot), alarm 1 is VBLANK
// (periodic). Both compare against unit 0.
const systimer = sdk.hardware.systimer;
const reg = sdk.hardware.mmio.reg;
/// ETS_SYSTIMER_TARGET0_INTR_SOURCE (57) and TARGET1 (58).
const micro_source: u32 = sdk.hardware.intbits.INTB_SYSTIMER_TARGET0;
const vblank_source: u32 = sdk.hardware.intbits.INTB_SYSTIMER_TARGET1;
const vblank_period: u32 = eclock_hz / vblank_hz;
/// How far ahead a micro timer target that is already past gets moved.
const min_ahead_ticks: u64 = 2 * ticks_per_us;
/// Where the micro timer waits while TD_ECLOCKLIST is empty.
const parked: u64 = (1 << 52) - 1;

fn timerBase(dev: *exec.Device) *TimerBase {
    return @fieldParentPtr("dev", dev);
}

fn timerUnit(unit: *exec.Unit) *TimerUnit {
    return @fieldParentPtr("unit", unit);
}

fn unitNumber(tb: *TimerBase, unit: *exec.Unit) u32 {
    return @intCast((@intFromPtr(timerUnit(unit)) - @intFromPtr(&tb.units[0])) / @sizeOf(TimerUnit));
}

fn sysTime() u64 {
    return systimer.uptimeUs() +% systime_offset;
}

/// The system time as GetSysTime hands it out. As in the ROM it only ever
/// rises and never repeats: a µs more than the last one if the clock
/// hasn't moved on since.
fn uniqueSysTime(tb: *TimerBase) u64 {
    tb.sys_base.Disable();
    defer tb.sys_base.Enable();
    const t = @max(sysTime(), last_systime + 1);
    last_systime = t;
    return t;
}

/// A request's target on `list`: E-clock ticks, or the system time on
/// TD_SYSTIMELIST.
fn keyOf(tb: *TimerBase, list: *exec.List, req: *TimeRequest) u64 {
    return if (list == &tb.systime_list) req.time.toMicros() else eclockOf(req).toTicks();
}

/// InsertReq: by target, after the requests with the same one. Disable
/// held.
fn insertReq(tb: *TimerBase, list: *exec.List, req: *TimeRequest) void {
    const key = keyOf(tb, list, req);
    var pred: ?*exec.Node = null;
    var it = list.iterator();
    while (it.next()) |node| {
        if (keyOf(tb, list, requestOf(node)) > key) break;
        pred = node;
    }
    tb.sys_base.Insert(list, &req.node.message.node, pred);
}

/// Set the micro timer to `ticks`. An alarm that is already past doesn't
/// fire on the chip, so it moves to just after now (as ESP-IDF does).
fn armMicroTimer(ticks: u64) void {
    var target = ticks;
    while (true) {
        reg(systimer.TARGET0_HI).* = @as(u32, @truncate(target >> 32)) & systimer.VALUE_HI_MASK;
        reg(systimer.TARGET0_LO).* = @truncate(target);
        reg(systimer.COMP0_LOAD).* = 1;
        if (target > systimer.readUnit0() or reg(systimer.INT_RAW).* & systimer.INT_TARGET0 != 0) return;
        target = systimer.readUnit0() + min_ahead_ticks;
    }
}

/// RethinkMicroTimer: the micro timer to the first request on
/// TD_ECLOCKLIST, or parked when there is none. Disable held.
fn rethinkMicroTimer(tb: *TimerBase) void {
    const node = tb.eclock_list.first() orelse return armMicroTimer(parked);
    armMicroTimer(eclockOf(requestOf(node)).toTicks());
}

/// TermIO: reply, unless the caller asked for IOF_QUICK.
fn termIO(tb: *TimerBase, io: *exec.IORequest) void {
    tb.sys_base.ReplyIO(io);
}

/// TermIOC: tr_time zeroed first ("tr_time will be zeroed").
fn termIOC(tb: *TimerBase, io: *exec.IORequest) void {
    const req: *TimeRequest = @fieldParentPtr("node", io);
    req.time = .{};
    termIO(tb, io);
}

/// exec has copied the tag's name, version and ID string into the base.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    const tb = timerBase(dev);
    dev.revision = DEVICE_REVISION;
    tb.sys_base = sys_base;
    tb.eclock_list.init(.message);
    tb.vblank_list.init(.message);
    tb.systime_list.init(.message);
    tb.term_queue.init(.message);
    const unit_lists = [unit_count]*exec.List{ &tb.eclock_list, &tb.vblank_list, &tb.eclock_list, &tb.systime_list, &tb.eclock_list };
    for (&tb.units, unit_lists) |*tu, list| {
        tu.list = list;
        tu.unit.msg_port.flags = exec.PA_IGNORE; // the units only count openers
        tu.unit.msg_port.msg_list.init(.message);
    }

    // Both alarms quiet until their servers are in place: an interrupt
    // raised before its source is routed is lost, and the line stays high
    // with no new edge. The micro timer is parked; VBLANK runs periodically.
    reg(systimer.INT_ENA).* &= ~(systimer.INT_TARGET0 | systimer.INT_TARGET1);
    reg(systimer.TARGET0_CONF).* = 0; // one-shot, on unit 0
    armMicroTimer(parked);
    reg(systimer.TARGET1_CONF).* = systimer.TARGET_PERIOD_MODE | vblank_period; // periodic, on unit 0
    reg(systimer.COMP1_LOAD).* = 1;
    reg(systimer.CONF).* |= systimer.CONF_TARGET0_WORK_EN | systimer.CONF_TARGET1_WORK_EN;
    tb.micro_int = .{
        .node = .{ .type = .interrupt, .name = DEVICE_NAME },
        .data = tb,
        .code = vec(tick0),
    };
    tb.vblank_int = .{
        .node = .{ .type = .interrupt, .name = DEVICE_NAME },
        .data = tb,
        .code = vec(tick1),
    };
    sys_base.AddIntServer(micro_source, &tb.micro_int);
    sys_base.AddIntServer(vblank_source, &tb.vblank_int);
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0 | systimer.INT_TARGET1;
    reg(systimer.INT_ENA).* |= systimer.INT_TARGET0 | systimer.INT_TARGET1;
    return dev;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    if (unit >= unit_count) return exec.IOERR_OPENFAIL;
    const tb = timerBase(dev);
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    tb.units[unit].unit.open_cnt += 1;
    io.unit = &tb.units[unit].unit;
    return 0;
}

/// A request that is still waiting is aborted first, so no closed request
/// stays on a delay list. The last close of a device RemDevice marked
/// LIBF_DELEXP expunges it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const tb = timerBase(dev);
    _ = remTimer(tb, io);
    io.unit.?.open_cnt -= 1;
    dev.open_cnt -= 1;
    if (dev.open_cnt == 0 and dev.flags & exec.LIBF_DELEXP != 0) return expunge(dev);
    return null;
}

/// RemDevice's call (the ROM's is Null: timer.device stayed). While open it
/// only marks itself LIBF_DELEXP for the last close. Otherwise it stops
/// both alarms, takes out its interrupt servers (exec releases the
/// sources), leaves the device list and frees its base. InitResident can
/// make it again from the ROM tag.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    if (dev.open_cnt != 0) {
        dev.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const tb = timerBase(dev);
    const sys = tb.sys_base;
    sys.Disable();
    reg(systimer.INT_ENA).* &= ~(systimer.INT_TARGET0 | systimer.INT_TARGET1);
    reg(systimer.CONF).* &= ~(systimer.CONF_TARGET0_WORK_EN | systimer.CONF_TARGET1_WORK_EN);
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0 | systimer.INT_TARGET1;
    sys.Enable();
    sys.RemIntServer(micro_source, &tb.micro_int);
    sys.RemIntServer(vblank_source, &tb.vblank_int);
    sys.Remove(&dev.node);
    // The jump table and the base, as MakeLibrary allocated them.
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null; // no seglist: the code is in ROM
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const tb = timerBase(dev);
    io.err = 0;
    // As in the ROM: a request still marked NT_MESSAGE may be waiting; if
    // it is, it is aborted, not queued a second time.
    if (io.message.node.type == .message and remTimer(tb, io)) return;
    const req: *TimeRequest = @fieldParentPtr("node", io);
    // "needed for WaitIO": the request is ours until it is replied.
    if (io.command >= TR_ADDREQUEST and io.command <= TR_SETSYSTIME) io.message.node.type = .message;
    switch (io.command) {
        TR_ADDREQUEST => newTimer(tb, req),
        TR_GETSYSTIME => {
            req.time = TimeVal.fromMicros(uniqueSysTime(tb));
            termIO(tb, io);
        },
        TR_SETSYSTIME => {
            tb.sys_base.Disable();
            systime_offset = req.time.toMicros() -% systimer.uptimeUs();
            last_systime = req.time.toMicros(); // may go backwards
            tb.sys_base.Enable();
            termIOC(tb, io);
        },
        else => {
            io.err = exec.IOERR_NOCMD;
            termIO(tb, io);
        },
    }
}

/// NewTimer: the unit's target into tr_time, onto its list. As in the ROM
/// the request is always replied (IOF_QUICK is ignored).
fn newTimer(tb: *TimerBase, req: *TimeRequest) void {
    req.node.flags &= ~exec.IOF_QUICK;
    const unit = unitNumber(tb, req.node.unit.?);
    const now = systimer.readUnit0();
    switch (unit) {
        // CalcDelay0: relative time to an E-clock target.
        UNIT_MICROHZ, UNIT_VBLANK => eclockOf(req).* = EClockVal.fromTicks(now + req.time.toMicros() * ticks_per_us),
        // CalcUnit2: relative E-clock ticks to a target.
        UNIT_ECLOCK => eclockOf(req).* = EClockVal.fromTicks(now + eclockOf(req).toTicks()),
        // Absolute already: a system time, an E-clock count.
        else => {},
    }
    const list = timerUnit(req.node.unit.?).list;
    tb.sys_base.Disable();
    defer tb.sys_base.Enable();
    insertReq(tb, list, req);
    if (list == &tb.eclock_list) rethinkMicroTimer(tb);
}

/// RemTimer: a waiting request off its unit's list, replied with
/// IOERR_ABORTED. False if it isn't waiting.
fn remTimer(tb: *TimerBase, io: *exec.IORequest) bool {
    const unit = io.unit orelse return false;
    const list = timerUnit(unit).list;
    tb.sys_base.Disable();
    var it = list.iterator();
    const found = while (it.next()) |node| {
        if (node == &io.message.node) break true;
    } else false;
    if (found) {
        tb.sys_base.Remove(&io.message.node);
        if (list == &tb.eclock_list) rethinkMicroTimer(tb);
    }
    tb.sys_base.Enable();
    if (!found) return false;
    io.err = exec.IOERR_ABORTED;
    termIOC(tb, io);
    return true;
}

/// AbortIO: 0 if the request was aborted, -1 if it wasn't waiting.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    return if (remTimer(timerBase(dev), io)) 0 else -1;
}

/// IntCommon: the expired requests from the head of `list` onto the
/// TermIO queue. Disable held.
fn intCommon(tb: *TimerBase, list: *exec.List, now: u64) void {
    while (list.first()) |node| {
        if (keyOf(tb, list, requestOf(node)) > now) return;
        tb.sys_base.Remove(node);
        tb.sys_base.AddTail(&tb.term_queue, node);
    }
}

/// IntEnd: reply what IntCommon collected, outside Disable.
fn intEnd(tb: *TimerBase) void {
    while (true) {
        tb.sys_base.Disable();
        const node = tb.sys_base.RemHead(&tb.term_queue);
        tb.sys_base.Enable();
        termIOC(tb, &requestOf(node orelse return).node);
    }
}

/// Tick0: the micro timer's server (TD_ECLOCKLIST).
fn tick0(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    if (reg(systimer.INT_ST).* & systimer.INT_TARGET0 == 0) return 0; // not ours
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0;
    const tb: *TimerBase = @ptrCast(@alignCast(is_data.?));
    tb.sys_base.Disable();
    intCommon(tb, &tb.eclock_list, systimer.readUnit0());
    rethinkMicroTimer(tb);
    tb.sys_base.Enable();
    intEnd(tb);
    return 1;
}

/// Tick1: the VBLANK server (TD_VBLANKLIST and TD_SYSTIMELIST).
fn tick1(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    if (reg(systimer.INT_ST).* & systimer.INT_TARGET1 == 0) return 0; // not ours
    reg(systimer.INT_CLR).* = systimer.INT_TARGET1;
    const tb: *TimerBase = @ptrCast(@alignCast(is_data.?));
    tb.sys_base.Disable();
    intCommon(tb, &tb.vblank_list, systimer.readUnit0());
    intCommon(tb, &tb.systime_list, sysTime());
    tb.sys_base.Enable();
    intEnd(tb);
    return 1;
}

fn lvoAddTime(_: *TimerBase, dest: *TimeVal, src: *const TimeVal) callconv(.c) void {
    timeval.addTime(dest, src);
}

fn lvoSubTime(_: *TimerBase, dest: *TimeVal, src: *const TimeVal) callconv(.c) void {
    timeval.subTime(dest, src);
}

fn lvoCmpTime(_: *TimerBase, dest: *const TimeVal, src: *const TimeVal) callconv(.c) i32 {
    return timeval.cmpTime(dest, src);
}

/// The E-clock count now; returns the E-clock's rate.
fn lvoReadEClock(_: *TimerBase, dest: *EClockVal) callconv(.c) u32 {
    dest.* = EClockVal.fromTicks(systimer.readUnit0());
    return eclock_hz;
}

fn lvoGetSysTime(tb: *TimerBase, dest: *TimeVal) callconv(.c) void {
    dest.* = TimeVal.fromMicros(uniqueSysTime(tb));
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoAddTime),
    vec(lvoSubTime),
    vec(lvoCmpTime),
    vec(lvoReadEClock),
    vec(lvoGetSysTime),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(TimerBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

export const timer_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &timer_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .type = .device,
    .pri = 50,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
