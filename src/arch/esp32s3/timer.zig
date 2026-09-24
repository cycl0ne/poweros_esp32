// SPDX-License-Identifier: MPL-2.0
//! Time keeping. SYSTIMER runs at a fixed 16 MHz and gives us wall-clock
//! time; the core's CCOMPARE0 timer drives the periodic kernel tick.

const clock = @import("clock.zig");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const trap = @import("trap.zig");

const systimer = @import("sdk").hardware.systimer;

pub const systimer_hz = systimer.SYSTIMER_HZ;
/// Internal interrupt wired to CCOMPARE0 (level 1).
pub const tick_irq = 6;

/// CCOUNT rate measured against SYSTIMER, to check the clock setup.
pub var measured_cpu_hz: u32 = 0;
/// CPU clock the tick is based on: `clock.cpu_hz`, unless the measurement
/// disagrees with it by more than 5% (QEMU does not emulate the PLL).
pub var cpu_hz: u32 = 0;
pub var tick_hz: u32 = 0;
var period: u32 = 0;
var ticks: u32 = 0;

/// SYSTIMER unit 0, in 1/16 µs.
pub fn now() linksection(".iram.text") u64 {
    @setRuntimeSafety(false);
    return systimer.readUnit0();
}

pub fn uptimeUs() u64 {
    return now() / (systimer_hz / 1_000_000);
}

pub fn tickCount() u32 {
    return @as(*volatile u32, &ticks).*;
}

pub fn init(hz: u32) void {
    measured_cpu_hz = measureCpuHz();
    const deviation = @abs(@as(i64, measured_cpu_hz) - clock.cpu_hz);
    cpu_hz = if (deviation * 20 <= clock.cpu_hz) clock.cpu_hz else measured_cpu_hz;
    tick_hz = hz;
    period = cpu_hz / hz;
    trap.setHandler(tick_irq, onTick);
    cpu.setCcompare0(cpu.ccount() +% period);
    cpu.enableInterrupt(tick_irq);
}

/// Measure CCOUNT against SYSTIMER for 10 ms, rounded to whole MHz.
fn measureCpuHz() u32 {
    const t0 = now();
    const c0 = cpu.ccount();
    var t1 = t0;
    while (t1 - t0 < systimer_hz / 100) t1 = now();
    const cycles = cpu.ccount() -% c0;
    const hz = @as(u64, cycles) * systimer_hz / (t1 - t0);
    return @intCast((hz + 500_000) / 1_000_000 * 1_000_000);
}

fn onTick(_: u5) void {
    var next = cpu.ccompare0() +% period;
    // Fell behind (e.g. a long masked section): resynchronise.
    if (@as(i32, @bitCast(next -% cpu.ccount())) <= 0) next = cpu.ccount() +% period;
    cpu.setCcompare0(next);
    ticks +%= 1;
    exec.tickQuantum(exec.SysBase);
}
