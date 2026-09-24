// SPDX-License-Identifier: MIT
//! timer.device (devices/timer.h): its units, its commands, and the
//! structures its requests and functions use.

const exec = @import("../libs/exec/exec.zig");

/// The name to open it by.
pub const TIMERNAME = "timer.device";

/// The device's base, with its functions: io_Device of an open request.
pub const TimerBase = @import("../interface/timer.zig").TimerBase;

/// The units: how TR_ADDREQUEST reads tr_time. MICROHZ and VBLANK: a
/// TimeVal, how long.
pub const UNIT_MICROHZ: u32 = 0;
pub const UNIT_VBLANK: u32 = 1;
/// An EClockVal, how many E-clock ticks.
pub const UNIT_ECLOCK: u32 = 2;
/// A TimeVal, until which system time.
pub const UNIT_WAITUNTIL: u32 = 3;
/// An EClockVal, until which E-clock count.
pub const UNIT_WAITECLOCK: u32 = 4;

/// The commands after the standard ones: wait, read and set the system
/// time.
pub const TR_ADDREQUEST: u16 = exec.CMD_NONSTD;
pub const TR_GETSYSTIME: u16 = exec.CMD_NONSTD + 1;
pub const TR_SETSYSTIME: u16 = exec.CMD_NONSTD + 2;

/// struct timeval (tv_secs, tv_micro).
pub const TimeVal = extern struct {
    /// tv_secs
    secs: u32 = 0,
    /// tv_micro: 0 to 999999.
    micro: u32 = 0,

    pub fn fromMicros(us: u64) TimeVal {
        return .{ .secs = @truncate(us / 1_000_000), .micro = @intCast(us % 1_000_000) };
    }

    pub fn toMicros(tv: TimeVal) u64 {
        return @as(u64, tv.secs) * 1_000_000 + tv.micro;
    }
};

/// struct EClockVal: a 64-bit E-clock count.
pub const EClockVal = extern struct {
    /// ev_hi
    hi: u32 = 0,
    /// ev_lo
    lo: u32 = 0,

    pub fn fromTicks(ticks: u64) EClockVal {
        return .{ .hi = @truncate(ticks >> 32), .lo = @truncate(ticks) };
    }

    pub fn toTicks(ev: EClockVal) u64 {
        return @as(u64, ev.hi) << 32 | ev.lo;
    }
};

/// struct timerequest.
pub const TimeRequest = extern struct {
    /// tr_node
    node: exec.IORequest = .{},
    /// tr_time. While a TR_ADDREQUEST waits, the device keeps its target
    /// here. It comes back zeroed.
    time: TimeVal = .{},
};
