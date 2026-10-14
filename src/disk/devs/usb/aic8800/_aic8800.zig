// SPDX-License-Identifier: MIT
//! usb/aic8800.device's own state: the base, the stick bound to it, and
//! the unit's link (sdk/devices/network/unit.zig) - the base itself.
//!
//! **One stick at a time.** Its bind (the bus's process) sets the stick's
//! device and pipes under the base's `lock` and hands the worker a
//! command; everything after runs on the worker, which owns the pipes.
//! `leaving`, set by the unbind, keeps the worker from sending anything
//! more before it lets the stick go.
//!
//! **What the Wi-Fi needs while it runs** - its buffers, the networks a
//! scan heard, the station's join - is the worker's block (radio.zig's
//! `Work`), allocated with the worker and found through `work`.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const timer = sdk.devices.timer;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const WPABase = sdk.interface.wpa.WPABase;
const unit_file = net.unit;
const radio = @import("radio.zig");

pub const DEVICE_NAME = "aic8800.device";

/// The stick's two roles: its boot ROM, which is given the firmware, and
/// the Wi-Fi the firmware is.
pub const VENDOR: u16 = 0xA69C;
pub const PRODUCT_BOOT: u16 = 0x8800;
pub const PRODUCT_WIFI: u16 = 0x8801;

pub const Unit = unit_file.Unit(AicBase);

/// A command from a bind or an unbind to the worker.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .load,

    pub const Kind = enum(u32) { load, start, let_go };
};

pub const AicBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    dos_base: ?*DosBase = null,
    /// utility.library, for the tag lists OpenDevice and the wireless
    /// requests are handed; wpa.library, for a protected network's keys,
    /// opened by the first join of one.
    utility: ?*UtilityBase = null,
    wpa_base: ?*WPABase = null,
    /// The worker: a DOS process, since the firmware is read from files,
    /// and its block (radio.zig).
    worker: ?*exec.Task = null,
    work: ?*anyopaque = null,
    /// The binds' commands, the pipes' and the timer's answers, and the
    /// unit's requests: the worker's, on one signal.
    commands: exec.MsgPort = .{},
    pipes: exec.MsgPort = .{},
    work_mask: u32 = 0,
    /// The DOS process that brings up the unit's interface (netif.zig),
    /// by its port; asked once, with `tell`.
    adder: ?*exec.MsgPort = null,
    tell: exec.Message = .{},
    asked: u8 = 0,
    pad3: [3]u8 = .{ 0, 0, 0 },
    /// The task that started the worker, and the signal it waits on until
    /// the worker is ready.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    ready: u8 = 0,
    timer_open: u8 = 0,
    pad: [1]u8 = .{0},
    /// For the system time and the waits: the worker's.
    timer_io: timer.TimeRequest = .{},
    /// Whether a stick is bound: taken by the binds and the worker.
    lock: exec.SignalSemaphore = .{},
    /// The stick: spoken for by a bind; being let go of.
    bound: u8 = 0,
    leaving: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
    device: ?*usb.USBDevice = null,
    bulk_in: ?*usb.USBPipe = null,
    bulk_out: ?*usb.USBPipe = null,
    /// The Wi-Fi's second endpoint out, its messages' own.
    msg_out: ?*usb.USBPipe = null,
    load: Command = .{},
    /// The exec unit the openers' requests name; its port is the worker's
    /// queue of them.
    unit: exec.Unit = .{},
    /// The requests' side.
    net: Unit,

    pub fn ub(base: *AicBase) *UsbBase {
        return base.usb_base.?;
    }

    // --- the unit's link ----------------------------------------------------
    //
    // radio.zig does the work; these hand over to it.

    /// One stream at 20 MHz, the most this stick is set up for.
    pub const bps: u64 = 72_200_000;

    /// The firmware answers to the address its interface was added with:
    /// another can't be given it while it runs.
    pub fn setStation(base: *AicBase, address: *const ethernet.Address) void {
        _ = base;
        _ = address;
    }

    /// The firmware takes the groups its network sends; the unit sorts out
    /// the ones it joined.
    pub fn setFilter(base: *AicBase, groups: []const unit_file.Group, promiscuous: bool) void {
        _ = base;
        _ = groups;
        _ = promiscuous;
    }

    pub fn setRunning(base: *AicBase, on: bool) void {
        radio.setRunning(base, on);
    }

    pub fn startWrites(base: *AicBase) void {
        radio.startWrites(base);
    }

    pub fn now(base: *AicBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }
};

pub fn aicBase(dev: *exec.Device) *AicBase {
    return @fieldParentPtr("dev", dev);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on a port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
