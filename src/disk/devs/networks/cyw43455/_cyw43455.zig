// SPDX-License-Identifier: MIT
//! cyw43455.device's own state: the base, the board's wiring of the
//! radio, the card on the SD bus and the chip behind it, and the unit's
//! link (sdk/devices/network/unit.zig) - the base itself.
//!
//! **Everything the chip is asked runs on the worker**, a DOS process -
//! the firmware is read from files - which owns the host and the card:
//! the base's `host`, `backplane` and `chip` are its, set as it brings
//! the chip up. What the radio needs while it runs - the networks a scan
//! heard, the scans waiting - is the worker's block (radio.zig's `Work`),
//! found through `work`.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = sdk.interface.timer.TimerBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const host_file = @import("host.zig");
const backplane = @import("backplane.zig");
const sdpcm = @import("sdpcm.zig");
const radio = @import("radio.zig");
const unit_file = net.unit;

pub const DEVICE_NAME = "cyw43455.device";

pub const Unit = unit_file.Unit(CywBase);

pub const CywBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
    dos_base: ?*DosBase = null,
    /// utility.library, for the board's tag lists.
    utility: ?*UtilityBase = null,
    /// What the radio is wired to, from the board's part, and the station
    /// address the board gives it: all zero when it gives none.
    host: host_file.Host = .{},
    station: [6]u8 = @splat(0),
    pad1: [2]u8 = .{ 0, 0 },
    /// The card, the window into the chip's backplane, and the chip: its
    /// RAM's size and its PMU's revision.
    backplane: backplane.Backplane,
    chip: backplane.Chip = .{},
    ram_size: u32 = 0,
    pmu_rev: u32 = 0,
    /// The worker, and the timer it waits on.
    worker: ?*exec.Task = null,
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// Whether the chip answered on its backplane, whether its firmware
    /// runs, and whether the firmware turned save-restore on.
    found: u8 = 0,
    running: u8 = 0,
    save_restore: u8 = 0,
    /// The task that started the worker, and the signal it waits on until
    /// the worker is ready.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: u8 = 0,
    /// The last command's request ID, for its answer.
    command_id: u16 = 0,
    /// The frames to and from the firmware.
    bus: sdpcm.Bus = .{},
    /// Whether the worker runs the radio, and its block (radio.zig).
    ready: u8 = 0,
    pad3: [3]u8 = .{ 0, 0, 0 },
    work: ?*anyopaque = null,
    /// The poll timer's answers and the unit's requests: the worker's, on
    /// one signal - which the chip's interrupt sends it too.
    poll_port: exec.MsgPort = .{},
    work_mask: u32 = 0,
    /// The SD host's interrupt, as the board gives it, its server, and
    /// whether that is on the interrupt's chain.
    irq: u32 = 0,
    int_hooked: u8 = 0,
    pad4: [3]u8 = .{ 0, 0, 0 },
    int: exec.Interrupt = .{},
    /// The exec unit the openers' requests name; its port is the worker's
    /// queue of them.
    unit: exec.Unit = .{},
    /// The requests' side.
    net: Unit,

    /// `us` microseconds waited, on the worker's timer.
    pub fn delay(base: *CywBase, us: u64) void {
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(us);
        _ = base.sys_base.DoIO(&base.timer_io.node);
    }

    // --- the unit's link ----------------------------------------------------
    //
    // radio.zig does the work; these hand over to it.

    /// One stream at 20 MHz with a short guard interval: 802.11n's most
    /// for this radio's one antenna.
    pub const bps: u64 = 72_200_000;

    /// The firmware answers to the address it was given as it came up:
    /// another is not given it while it runs.
    pub fn setStation(base: *CywBase, address: *const ethernet.Address) void {
        _ = base;
        _ = address;
    }

    /// The firmware takes only the groups it is told of: the worker tells
    /// it the unit's (radio.filterDue), which are read there.
    pub fn setFilter(base: *CywBase, groups: []const unit_file.Group, promiscuous: bool) void {
        _ = groups;
        _ = promiscuous;
        radio.filterDue(base);
    }

    /// Frames flow whenever the station is on a network.
    pub fn setRunning(base: *CywBase, on: bool) void {
        _ = base;
        _ = on;
    }

    pub fn startWrites(base: *CywBase) void {
        radio.startWrites(base);
    }

    pub fn now(base: *CywBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }
};

pub fn cywBase(dev: *exec.Device) *CywBase {
    return @fieldParentPtr("dev", dev);
}

/// The waits sdio.zig and backplane.zig are handed: the worker's timer.
pub fn waitOn(context: *anyopaque, us: u64) void {
    const base: *CywBase = @ptrCast(@alignCast(context));
    base.delay(us);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on a port belongs to.
pub fn requestOf(message: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", message);
}
