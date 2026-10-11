// SPDX-License-Identifier: MPL-2.0
//! Time keeping. SYSTIMER's unit 0 runs at a fixed 16 MHz and gives the
//! wall-clock time; its alarm 2, periodic on unit 0, drives the kernel's
//! tick. Alarms 0 and 1 are timer.device's, as on the ESP32-S3, and the
//! chip has no third: the one alarm is core 0's, and core 0's tick hands
//! core 1 its own through the cross-core interrupt (`takeCore1Tick`). Each
//! core's tick counts off its own time slice; core 0's keeps the log.
//!
//! The alarm's interrupt is a matrix source (SYSTIMER_TARGET2), routed to
//! core 0's tick line.

const clock = @import("clock.zig");
const cpu = @import("cpu.zig");
const cpu1 = @import("cpu1.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const intmatrix = @import("intmatrix.zig");
const trap = @import("trap.zig");
const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const systimer = hardware.systimer;

pub const systimer_hz = systimer.SYSTIMER_HZ;

/// The tick's interrupt line, each core's.
pub const tick_irq = trap.tick_line;
/// The CPU's clock as measured against SYSTIMER at `init`, and the one
/// the system times by: the configured one while the measurement agrees
/// with it within 5%, else the measured one.
pub var measured_cpu_hz: u32 = 0;
pub var cpu_hz: u32 = 0;
pub var tick_hz: u32 = 0;
var period: u32 = 0;
var ticks: u32 = 0;
var core1_ticks: u32 = 0;

/// SYSTIMER unit 0, in 1/16 us.
pub fn now() u64 {
    return systimer.readUnit0();
}

pub fn uptimeUs() u64 {
    return now() / (systimer_hz / 1_000_000);
}

/// `us` microseconds waited out without giving the CPU away.
pub fn spinUs(us: u64) void {
    const until = uptimeUs() + us;
    while (uptimeUs() < until) {}
}

pub fn tickCount() u32 {
    return @as(*volatile u32, &ticks).*;
}

/// Core 1's ticks.
pub fn core1TickCount() u32 {
    return @as(*volatile u32, &core1_ticks).*;
}

/// Core 1's tick is waiting for it: set by core 0's tick, taken in core
/// 1's cross-core interrupt.
var core1_tick_pending: u32 = 0;

/// Core 0's tick at `hz` ticks a second, and the CPU's clock measured.
pub fn init(hz: u32) void {
    measured_cpu_hz = measureCpuHz();
    const deviation = @abs(@as(i64, measured_cpu_hz) - clock.cpu_hz);
    cpu_hz = if (deviation * 20 <= clock.cpu_hz) clock.cpu_hz else measured_cpu_hz;
    tick_hz = hz;
    period = systimer_hz / hz;
    // Unit 0 (bit 31 clear), the period, then periodic.
    reg(systimer.CONF).* &= ~systimer.CONF_TARGET2_WORK_EN;
    reg(systimer.TARGET2_CONF).* = period;
    reg(systimer.COMP2_LOAD).* = 1;
    reg(systimer.TARGET2_CONF).* = period | systimer.TARGET_PERIOD_MODE;
    reg(systimer.COMP2_LOAD).* = 1;
    reg(systimer.CONF).* |= systimer.CONF_TARGET2_WORK_EN;
    reg(systimer.INT_CLR).* = systimer.INT_TARGET2;
    reg(systimer.INT_ENA).* |= systimer.INT_TARGET2;
    trap.setHandler(trap.tick_line, onTick);
    intmatrix.route(0, hardware.intbits.INTB_SYSTIMER_TARGET2, trap.tick_line);
    intmatrix.enableLine(trap.tick_line);
}

/// Core 1's tick, on core 1: nothing to set up, its ticks come from core
/// 0's.
pub fn initCore1() void {}

/// Core 1's part of its cross-core interrupt: the tick core 0 handed it,
/// if there is one.
pub fn takeCore1Tick() void {
    if (@atomicRmw(u32, &core1_tick_pending, .Xchg, 0, .acquire) == 0) return;
    core1_ticks +%= 1;
    exec.tickQuantum(exec.SysBase);
}

/// The cycle counter measured against SYSTIMER for 10 ms, rounded to whole
/// MHz.
fn measureCpuHz() u32 {
    const t0 = now();
    const c0 = cpu.ccount();
    var t1 = t0;
    while (t1 - t0 < systimer_hz / 100) t1 = now();
    const cycles = cpu.ccount() -% c0;
    const hz = @as(u64, cycles) * systimer_hz / (t1 - t0);
    return @intCast((hz + 500_000) / 1_000_000 * 1_000_000);
}

fn onTick(_: u6) void {
    reg(systimer.INT_CLR).* = systimer.INT_TARGET2;
    ticks +%= 1;
    if (cpu1.isUp()) {
        @atomicStore(u32, &core1_tick_pending, 1, .release);
        intmatrix.raiseCrossCore(1);
    }
    exec.tickQuantum(exec.SysBase);
    exec.tickLog(exec.SysBase);
}
