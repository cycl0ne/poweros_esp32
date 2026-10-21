// SPDX-License-Identifier: MIT
//! The machine's time as the drivers ask for it, under the ESP32s' name:
//! RISC-V's `time` counter, which runs from the machine's start at the
//! platform's timebase - 10 MHz on QEMU's virt, 4 MHz on the JH7110. The
//! kernel sets `timebase_hz` from the board before anything reads it.
//!
//! **The alarms.** Each hart has one comparator on `time`, which the
//! kernel's tick has; a driver's alarm (timer.device's micro timer and
//! VBLANK) is one of `alarms`, which the kernel keeps its comparator on
//! as well: set to the soonest of its next tick and every alarm. An
//! alarm that comes due is marked fired - and set one period on, or
//! parked - and raises its interrupt number (`intbits.INTB_ALARM0` + n)
//! through exec, to the servers AddIntServer put there. The alarms are
//! core 0's.

const cpu = @import("cpu.zig");

/// The rate `time` counts at, in Hz: a whole number of MHz.
pub var timebase_hz: u32 = 10_000_000;

/// The time since the machine came up, in the timebase's units.
pub inline fn read() u64 {
    return cpu.time();
}

/// The time since the machine came up, in microseconds.
pub inline fn uptimeUs() u64 {
    return read() / (timebase_hz / 1_000_000);
}

/// `us` microseconds in the timebase's units.
pub inline fn fromUs(us: u64) u64 {
    return us * (timebase_hz / 1_000_000);
}

/// Wait `us` microseconds without giving the CPU away: the wait for code
/// that may not Wait - holding a spinlock, before timer.device, in the
/// boot.
pub inline fn spinUs(us: u64) void {
    const until = uptimeUs() + us;
    while (uptimeUs() < until) {}
}

/// How many alarms there are.
pub const ALARMS = 2;
/// An alarm's target while it is parked.
pub const never: u64 = ~@as(u64, 0);

pub const Alarm = struct {
    /// When it comes due, in the timebase's units; `never` while parked.
    target: u64 = never,
    /// Periodic: how far on it is set each time it comes due. 0 for one
    /// shot, after which it is parked.
    period: u64 = 0,
    /// Set as it comes due; `takeAlarm` clears it.
    fired: u32 = 0,
};

pub var alarms: [ALARMS]Alarm = @splat(.{});

/// The kernel's comparator set again from the alarms: installed by the
/// kernel's timer, called by `setAlarm`.
pub var rethink: *const fn () void = &noRethink;

fn noRethink() void {}

/// Alarm `n` set to come due at `target` and then every `period` (0: once),
/// or parked with `never`. A target that is past already comes due at
/// once. With this hart's interrupts masked, so the kernel's timer never
/// sees it half set.
pub fn setAlarm(n: usize, target: u64, period: u64) void {
    const saved = asm volatile ("csrrci %[r], sstatus, 2"
        : [r] "=r" (-> usize),
        :
        : .{ .memory = true });
    alarms[n].target = target;
    alarms[n].period = period;
    rethink();
    if (saved & 2 != 0) asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}

/// Whether alarm `n` has come due since it was last asked; its server
/// asks, which clears it.
pub fn takeAlarm(n: usize) bool {
    return @atomicRmw(u32, &alarms[n].fired, .Xchg, 0, .acq_rel) != 0;
}
