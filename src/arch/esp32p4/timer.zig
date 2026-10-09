// SPDX-License-Identifier: MPL-2.0
//! Time keeping. SYSTIMER's unit 0 runs at a fixed 16 MHz and gives the
//! wall-clock time; its alarms drive the kernel's tick - alarm 0 core 0's,
//! alarm 1 core 1's - both on unit 0, periodic, at one rate. Each core's
//! tick counts off its own time slice; core 0's keeps the log.
//!
//! An alarm's interrupt is a matrix source (SYSTIMER_TARGET<n>), routed to
//! the tick line of its core.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const intmatrix = @import("intmatrix.zig");
const trap = @import("trap.zig");
const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const systimer = hardware.systimer;

pub const systimer_hz = systimer.SYSTIMER_HZ;

/// The CPU's clock, measured against SYSTIMER at `init`.
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

/// Core 0's tick at `hz` ticks a second, and the CPU's clock measured.
pub fn init(hz: u32) void {
    cpu_hz = measureCpuHz();
    tick_hz = hz;
    period = systimer_hz / hz;
    start();
}

/// Core 1's tick, on core 1, at the rate `init` set.
pub fn initCore1() void {
    start();
}

/// The alarm of the core this runs on: on unit 0, periodic at `period`,
/// its interrupt on this core's tick line.
fn start() void {
    const core = cpu.coreId();
    const alarm_bit = @as(u32, 1) << @intCast(core);
    const work_en: u32 = if (core == 0) systimer.CONF_TARGET0_WORK_EN else systimer.CONF_TARGET1_WORK_EN;
    const conf = if (core == 0) systimer.TARGET0_CONF else systimer.TARGET1_CONF;
    const load = if (core == 0) systimer.COMP0_LOAD else systimer.COMP1_LOAD;
    reg(systimer.CONF).* &= ~work_en;
    // Unit 0 (bit 31 clear), the period, then periodic.
    reg(conf).* = period;
    reg(load).* = 1;
    reg(conf).* = period | systimer.TARGET_PERIOD_MODE;
    reg(load).* = 1;
    reg(systimer.CONF).* |= work_en;
    reg(systimer.INT_CLR).* = alarm_bit;
    reg(systimer.INT_ENA).* |= alarm_bit;
    trap.setHandler(trap.tick_line, onTick);
    intmatrix.route(core, hardware.intbits.INTB_SYSTIMER_TARGET0 + core, trap.tick_line);
    intmatrix.enableLine(trap.tick_line);
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
    const core = cpu.coreId();
    reg(systimer.INT_CLR).* = @as(u32, 1) << @intCast(core);
    if (core != 0) {
        core1_ticks +%= 1;
        exec.tickQuantum(exec.SysBase);
        return;
    }
    ticks +%= 1;
    exec.tickQuantum(exec.SysBase);
    exec.tickLog(exec.SysBase);
}
