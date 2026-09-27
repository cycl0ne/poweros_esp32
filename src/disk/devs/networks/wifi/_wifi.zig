// SPDX-License-Identifier: MIT
//! wifi.device's own state: the base, and the block of internal memory
//! the radio's side lives in - the adapter's state, which the libraries'
//! interrupt handler reaches through the adapter's one global.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const _osi = @import("osi/_osi.zig");
const supplicant = @import("wpa/supplicant.zig");
const vendor = @import("vendor.zig");
const scan = @import("scan.zig");
const link = @import("link.zig");
const rejoin_file = @import("rejoin.zig");
const ethernet = net.ethernet;
const unit_file = net.unit;

pub const DEVICE_NAME = "wifi.device";

/// The block the adapter lives in: internal memory, allocated once and
/// never moved.
pub const Work = struct {
    adapter: _osi.Adapter,
    /// What the last scan found.
    networks: [scan.max_networks]vendor.ApRecord,
    /// Frames in, and the one being sent.
    frames: link.Frames,
    /// The station's keys and elements, and the key handshake that runs on
    /// the libraries' task (`wpa/supplicant.zig`).
    station: supplicant.Station,
    handshake: supplicant.Handshake,
};

pub const Unit = unit_file.Unit(WifiBase);

/// The device's base. One unit, whose port is the task's work queue.
pub const WifiBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit: exec.Unit,
    /// The task every request runs on, which also started the radio.
    task: exec.Task,
    stack: ?*anyopaque = null,
    work: ?*Work = null,
    /// timer.device, for the E-clock the adapter keeps time by.
    timer_io: timer.TimeRequest = .{},
    /// utility.library, for the tag lists requests carry.
    utility: ?*UtilityBase = null,
    /// crypto.library, for the key handshake's hashes and ciphers.
    crypto: ?*CryptoBase = null,
    /// The S2_GETNETWORKS waiting for the scan that runs.
    scans: exec.List = .{},
    /// The station's address, from eFuse.
    station: [6]u8 = @splat(0),
    /// Whether the radio came up.
    radio_up: u8 = 0,
    /// Whether a scan runs, and whether frames go in and out.
    scanning: u8 = 0,
    running: u8 = 0,
    pad: [3]u8 = @splat(0),
    /// The signal a received frame raises.
    frame_mask: u32 = 0,
    /// The signal the libraries' events raise.
    event_signal: i8 = -1,
    /// The task that started this one, and the signal it waits on until
    /// the task has tried the radio.
    start_signal: i8 = -1,
    starter: ?*exec.Task = null,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
    /// Joining again after coming off a wanted network.
    rejoin: rejoin_file.Rejoin = .{},
    /// The requests' side of the unit.
    net: Unit,

    // --- the unit's link --------------------------------------------------

    /// What the radio carries at its usual rate (802.11n, one stream,
    /// 20 MHz).
    pub const bps: u64 = 72_000_000;

    /// The radio answers to its own address only; another is noted and
    /// not taken.
    pub fn setStation(base: *WifiBase, address: *const ethernet.Address) void {
        for (address, base.station) |a, b| if (a != b) {
            sdk.exec.kprintf(base.sys_base, "%s: the radio keeps its own address\n", .{DEVICE_NAME});
            return;
        };
    }

    pub fn setRunning(base: *WifiBase, on: bool) void {
        const sys = base.sys_base;
        sys.Disable();
        base.running = @intFromBool(on);
        sys.Enable();
    }

    /// The radio takes every group its network sends; the unit sorts out
    /// the ones nobody joined.
    pub fn setFilter(_: *WifiBase, _: []const unit_file.Group, _: bool) void {}

    pub fn startWrites(base: *WifiBase) void {
        link.startWrites(base);
    }

    pub fn now(base: *WifiBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_io.node.device) |device| {
            const timer_base: *sdk.interface.timer.TimerBase = @ptrCast(@alignCast(device));
            timer_base.GetSysTime(&time);
        }
        return time;
    }
};

pub fn wifiBase(dev: *exec.Device) *WifiBase {
    return @fieldParentPtr("dev", dev);
}

/// The base of the request's unit.
pub fn baseOf(io: *exec.IORequest) *WifiBase {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the unit's port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
