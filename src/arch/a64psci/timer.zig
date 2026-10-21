// SPDX-License-Identifier: MPL-2.0
//! Time keeping. The generic timer's system counter runs at CNTFRQ_EL0
//! from the machine's start and gives the wall-clock time; each core has
//! a virtual timer of its own on it (CNTV_CVAL_EL0, CNTV_CTL_EL0), which
//! EL1 sets itself and which raises the core's PPI 11 (interrupt ID 27)
//! for as long as the counter has reached it. Setting it again lowers it.
//!
//! The comparator serves two: the kernel's tick, one period on each time,
//! on every core - each core's tick counts off its own time slice; core
//! 0's keeps the log - and on core 0 the drivers' alarms
//! (sdk.hardware.systimer: timer.device's micro timer and VBLANK). It is
//! always set to the soonest of them; when it fires, every alarm that is
//! due raises its interrupt number through exec, and the tick, if it is
//! due, runs.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const gic = @import("gic.zig");
const trap = @import("trap.zig");
const hardware = @import("sdk").hardware;
const systimer = hardware.systimer;
const intbits = hardware.intbits;
const max_cores = @import("../../rom/libs/exec/exec_base.zig").max_cores;

/// The virtual timer's PPI, each core's: its interrupt ID.
pub const tick_irq: u32 = 27;
/// CNTV_CTL_EL0: on, its interrupt not masked.
const CTL_ENABLE: u64 = 1 << 0;

/// The CPU's clock as measured against the counter at `init`: there is
/// no other word for it at EL1.
pub var measured_cpu_hz: u32 = 0;
pub var cpu_hz: u32 = 0;
pub var tick_hz: u32 = 0;
var period: u64 = 0;
/// Each core's ticks; core 0's are the system's.
var ticks: [max_cores]u32 = @splat(0);
/// Each core's next tick, in the timebase's units.
var next_tick: [max_cores]u64 = @splat(0);
/// Another core changed an alarm: core 0 sets its comparator again at
/// its cross-core interrupt.
var rethink_asked: u32 = 0;

/// The system counter, in the timebase's units.
pub fn now() u64 {
    return systimer.read();
}

pub fn uptimeUs() u64 {
    return systimer.uptimeUs();
}

/// `us` microseconds waited out without giving the CPU away.
pub fn spinUs(us: u64) void {
    systimer.spinUs(us);
}

pub fn tickCount() u32 {
    return coreTickCount(0);
}

/// Core 1's ticks.
pub fn core1TickCount() u32 {
    return coreTickCount(1);
}

/// Core `core`'s ticks.
pub fn coreTickCount(core: u32) u32 {
    return @atomicLoad(u32, &ticks[core], .monotonic);
}

/// Core 0's tick at `hz` ticks a second, and the CPU's clock measured.
pub fn init(hz: u32) void {
    measured_cpu_hz = measureCpuHz();
    cpu_hz = measured_cpu_hz;
    tick_hz = hz;
    period = systimer.timebase_hz / hz;
    systimer.rethink = &rethink;
    start();
}

/// Another core's tick, on that core: its own comparator, at core 0's
/// rate.
pub fn initCore1() void {
    start();
}

fn start() void {
    const core = cpu.coreId();
    next_tick[core] = now() + period;
    trap.setHandler(@intCast(tick_irq), onTick);
    program(core);
    asm volatile ("msr cntv_ctl_el0, %[ctl]; isb"
        :
        : [ctl] "r" (CTL_ENABLE),
        : .{ .memory = true });
    gic.enablePrivate(tick_irq);
}

/// This core's comparator at the soonest of its tick and, on core 0, the
/// alarms. Interrupts masked.
fn program(core: u32) void {
    var soonest = next_tick[core];
    if (core == 0) {
        for (&systimer.alarms) |*alarm| soonest = @min(soonest, alarm.target);
    }
    asm volatile ("msr cntv_cval_el0, %[at]; isb"
        :
        : [at] "r" (soonest),
        : .{ .memory = true });
}

/// An alarm changed (systimer.setAlarm): core 0's comparator set again,
/// by core 0.
fn rethink() void {
    if (cpu.coreId() == 0) return program(0);
    @atomicStore(u32, &rethink_asked, 1, .release);
    gic.raiseCrossCore(0);
}

/// Core 0's part of its cross-core interrupt: an alarm another core set.
pub fn rethinkIfAsked() void {
    if (@atomicRmw(u32, &rethink_asked, .Xchg, 0, .acquire) != 0) program(0);
}

/// The cycle counter measured against the system counter for 10 ms,
/// rounded to whole MHz.
fn measureCpuHz() u32 {
    const hz_time: u64 = systimer.timebase_hz;
    const t0 = now();
    const c0 = hardware.cpu.cycles();
    var t1 = t0;
    while (t1 - t0 < hz_time / 100) t1 = now();
    const cycles = hardware.cpu.cycles() -% c0;
    const hz = cycles / (t1 - t0) * hz_time + cycles % (t1 - t0) * hz_time / (t1 - t0);
    return @intCast(@min((hz + 500_000) / 1_000_000 * 1_000_000, 0xFFFF_FFFF));
}

/// The comparator fired: on core 0 every alarm that is due marked, set
/// one period on or parked, and its interrupt raised; the tick if it is
/// due - one period on from where it was, so it keeps its rate, or from
/// now if the core fell more than a period behind - with the time slice
/// and on core 0 the log and the waiters' time limits (WaitForAny); then
/// the comparator set again, which lowers the interrupt.
fn onTick(_: u6) void {
    const core = cpu.coreId();
    const at = now();
    if (core == 0) {
        for (&systimer.alarms, 0..) |*alarm, n| {
            if (alarm.target > at) continue;
            alarm.target = if (alarm.period == 0) systimer.never else @max(alarm.target + alarm.period, at + 1);
            @atomicStore(u32, &alarm.fired, 1, .release);
            gic.dispatch(@intCast(intbits.INTB_ALARM0 + n));
        }
    }
    if (at >= next_tick[core]) {
        next_tick[core] += period;
        if (next_tick[core] <= at) next_tick[core] = at + period;
        ticks[core] +%= 1;
        exec.tickQuantum(exec.SysBase);
        if (core == 0) {
            exec.tickLog(exec.SysBase);
            exec.tickWaitables(exec.SysBase);
        }
    }
    program(core);
}
