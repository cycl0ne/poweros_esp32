// SPDX-License-Identifier: MPL-2.0
//! Time keeping. RISC-V's `time` counter runs at the platform's timebase
//! from the machine's start and gives the wall-clock time; each hart has
//! a comparator of its own on it, which supervisor mode sets through the
//! SBI firmware (`sbi.setTimer`) and which raises the hart's timer
//! interrupt (scause 5) once `time` reaches it.
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
const plic = @import("plic.zig");
const trap = @import("trap.zig");
const hardware = @import("sdk").hardware;
const sbi = hardware.sbi;
const systimer = hardware.systimer;
const intbits = hardware.intbits;
const max_cores = @import("../../rom/libs/exec/exec_base.zig").max_cores;

/// The tick's interrupt, each core's.
pub const tick_irq = trap.tick_line;
/// The CPU's clock as measured against `time` at `init`: there is no
/// other word for it in supervisor mode.
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

/// `time`, in the timebase's units.
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
    trap.setHandler(trap.tick_line, onTick);
    program(core);
    cpu.enableInterruptKinds(cpu.SIE_STIE);
}

/// This core's comparator at the soonest of its tick and, on core 0, the
/// alarms. Interrupts masked.
fn program(core: u32) void {
    var soonest = next_tick[core];
    if (core == 0) {
        for (&systimer.alarms) |*alarm| soonest = @min(soonest, alarm.target);
    }
    sbi.setTimer(soonest);
}

/// An alarm changed (systimer.setAlarm): core 0's comparator set again,
/// by core 0.
fn rethink() void {
    if (cpu.coreId() == 0) return program(0);
    @atomicStore(u32, &rethink_asked, 1, .release);
    plic.raiseCrossCore(0);
}

/// Core 0's part of its cross-core interrupt: an alarm another core set.
pub fn rethinkIfAsked() void {
    if (@atomicRmw(u32, &rethink_asked, .Xchg, 0, .acquire) != 0) program(0);
}

/// The cycle counter measured against `time` for 10 ms, rounded to whole
/// MHz.
fn measureCpuHz() u32 {
    const hz_time = systimer.timebase_hz;
    const t0 = now();
    const c0 = hardware.cpu.cycles();
    var t1 = t0;
    while (t1 - t0 < hz_time / 100) t1 = now();
    const cycles = hardware.cpu.cycles() -% c0;
    const hz = cycles * hz_time / (t1 - t0);
    return @intCast(@min((hz + 500_000) / 1_000_000 * 1_000_000, 0xFFFF_FFFF));
}

/// The comparator fired: on core 0 every alarm that is due marked, set
/// one period on or parked, and its interrupt raised; the tick if it is
/// due - one period on from where it was, so it keeps its rate, or from
/// now if the core fell more than a period behind - with the time slice
/// and on core 0 the log; then the comparator set again, which lowers the
/// interrupt.
fn onTick(_: u6) void {
    const core = cpu.coreId();
    const at = now();
    if (core == 0) {
        for (&systimer.alarms, 0..) |*alarm, n| {
            if (alarm.target > at) continue;
            alarm.target = if (alarm.period == 0) systimer.never else @max(alarm.target + alarm.period, at + 1);
            @atomicStore(u32, &alarm.fired, 1, .release);
            plic.dispatch(@intCast(intbits.INTB_ALARM0 + n));
        }
    }
    if (at >= next_tick[core]) {
        next_tick[core] += period;
        if (next_tick[core] <= at) next_tick[core] = at + period;
        ticks[core] +%= 1;
        exec.tickQuantum(exec.SysBase);
        if (core == 0) exec.tickLog(exec.SysBase);
    }
    program(core);
}
