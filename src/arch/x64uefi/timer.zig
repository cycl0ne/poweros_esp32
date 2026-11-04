// SPDX-License-Identifier: MPL-2.0
//! Time keeping. The core's timestamp counter runs from the machine's
//! start at a fixed rate whatever the core is doing, and is this machine's
//! wall clock and its cycle count both (sdk.hardware.cpu). Its rate is not
//! always told, so it is measured once against a clock whose rate the
//! architecture fixes - the machine's power-management timer, 3.579545 MHz
//! since there were PCs, whose port the firmware's tables name.
//!
//! Each core has one comparator - its local interrupt controller's timer -
//! which serves two: the kernel's tick, one period on each time, on every
//! core, and on the boot core the drivers' alarms
//! (sdk.hardware.systimer: timer.device's micro timer and VBLANK). It is
//! always set to the soonest of them; when it fires, every alarm that is
//! due raises its interrupt number through exec, and the tick, if it is
//! due, runs.
//!
//! **The comparator is set two ways.** Where the core can be told to fire
//! when its counter reaches a value - which is what the other two 64-bit
//! ports' comparators do, and what the alarms are written against - the
//! value is written to a model register and that is all. Where it cannot,
//! the controller's timer counts down from a number at a rate of its own,
//! and the kernel measures that rate and converts. The kernel says which
//! of the two it found.

const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const apic = @import("apic.zig");
const trap = @import("trap.zig");
const hardware = @import("sdk").hardware;
const lapic = hardware.apic;
const mmio = hardware.mmio;
const systimer = hardware.systimer;
const intbits = hardware.intbits;
const coretables = @import("coretables.zig");

/// The vector the tick comes in on, which is this machine's answer to the
/// interrupt a tick is on.
pub const tick_irq: u32 = apic.VECTOR_TICK;

/// The rate the power-management timer counts at, which the architecture
/// fixes.
pub const PM_TIMER_HZ: u32 = 3_579_545;

/// The counter's rate as measured at `measureTimebase`: this machine's
/// cycle count and its clock are the same counter, so this is both.
pub var measured_cpu_hz: u32 = 0;
pub var cpu_hz: u32 = 0;
pub var tick_hz: u32 = 0;
var period: u64 = 0;
/// Each core's ticks; core 0's are the system's.
var ticks: [*]u32 = &one_ticks;
var one_ticks: [1]u32 = .{0};
/// Each core's next tick, in the counter's units.
var next_tick: [*]u64 = &one_next_tick;
var one_next_tick: [1]u64 = .{0};

/// This chip's share of the cores' tables.
pub fn layTables(bump: *coretables.Bump, count: u32) void {
    if (bump.take(u32, count)) |at| ticks = at;
    if (bump.take(u64, count)) |at| next_tick = at;
}
/// Another core changed an alarm: core 0 sets its comparator again at its
/// cross-core interrupt.
var rethink_asked: u32 = 0;

/// Whether the core fires when its counter reaches a value written to a
/// model register, rather than counting a number down at a rate of its own.
pub var deadline_mode = false;
/// The controller timer's own rate, measured, where the core has no
/// deadline: 0 where it has.
pub var lapic_hz: u32 = 0;

/// The counter, in its own units.
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

/// The counter's rate, measured against the power-management timer at
/// `port`, whose counter is `bits` wide (24 or 32). Rounded to whole MHz,
/// which is what the division into microseconds wants. 0 where the machine
/// has no such timer, and then the board's figure stands.
///
/// It takes a twentieth of a second, and it is the only thing in the boot
/// that does: everything timed after this is timed by the counter.
pub fn measureTimebase(port: u16, bits: u8) u32 {
    if (port == 0 or bits < 24) return 0;
    const mask: u32 = if (bits >= 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(bits)) - 1;
    const want: u32 = PM_TIMER_HZ / 20;
    const first = mmio.in32(port) & mask;
    const began = cpu.cycles();
    var elapsed: u32 = 0;
    // The counter is 24 bits at its narrowest, which is 4.6 seconds: a
    // twentieth of one cannot wrap it.
    while (elapsed < want) elapsed = ((mmio.in32(port) & mask) -% first) & mask;
    const counted = cpu.cycles() -% began;
    const hz = counted * PM_TIMER_HZ / elapsed;
    return @intCast(@min((hz + 500_000) / 1_000_000 * 1_000_000, 0xFFFF_FFFF));
}

/// Core 0's tick at `hz` ticks a second. The counter's rate is already
/// measured (`measureTimebase`), since the log is timed by it from the
/// first line.
pub fn init(hz: u32) void {
    measured_cpu_hz = systimer.timebase_hz;
    cpu_hz = measured_cpu_hz;
    tick_hz = hz;
    period = systimer.timebase_hz / hz;
    systimer.rethink = &rethink;
    deadline_mode = hasDeadline();
    start();
}

/// Another core's tick, on that core: its own comparator, at core 0's
/// rate.
pub fn initCore1() void {
    start();
}

/// Leaf 1, ECX bit 24: the core's timer can be set to a value of the
/// counter.
fn hasDeadline() bool {
    if (hardware.cpu.highestLeaf() < 1) return false;
    return cpu.leaf(1, 0).ecx & (1 << 24) != 0;
}

/// What divides the controller timer's input where it counts down: 16, so
/// that a 32-bit count still covers a minute on the fastest bus.
const DIVIDE_BY_16: u32 = 0b0011;

fn start() void {
    const core = cpu.coreId();
    trap.setHandler(@intCast(apic.LINE_TICK), onTick);
    if (deadline_mode) {
        lapic.write(lapic.LAPIC_LVT_TIMER, lapic.TIMER_DEADLINE | apic.VECTOR_TICK);
    } else {
        lapic.write(lapic.LAPIC_TIMER_DIVIDE, DIVIDE_BY_16);
        lapic.write(lapic.LAPIC_LVT_TIMER, lapic.TIMER_ONE_SHOT | apic.VECTOR_TICK);
        if (lapic_hz == 0) lapic_hz = measureLapicHz();
    }
    next_tick[core] = now() + period;
    program(core);
}

/// The controller timer's rate, measured against the counter over ten
/// milliseconds: it counts down from the highest number it takes, and what
/// it has left says how fast. Rounded to whole kHz.
fn measureLapicHz() u32 {
    lapic.write(lapic.LAPIC_LVT_TIMER, lapic.LVT_MASKED | lapic.TIMER_ONE_SHOT | apic.VECTOR_TICK);
    lapic.write(lapic.LAPIC_TIMER_INITIAL, 0xFFFF_FFFF);
    const span = systimer.timebase_hz / 100;
    const began = now();
    while (now() -% began < span) {}
    const left = lapic.read(lapic.LAPIC_TIMER_CURRENT);
    lapic.write(lapic.LAPIC_TIMER_INITIAL, 0);
    lapic.write(lapic.LAPIC_LVT_TIMER, lapic.TIMER_ONE_SHOT | apic.VECTOR_TICK);
    const counted: u64 = 0xFFFF_FFFF - @as(u64, left);
    const hz = counted * 100;
    return @intCast(@min((hz + 500) / 1000 * 1000, 0xFFFF_FFFF));
}

/// This core's comparator at the soonest of its tick and, on core 0, the
/// alarms. Interrupts masked.
fn program(core: u32) void {
    var soonest = next_tick[core];
    if (core == 0) {
        for (&systimer.alarms) |*alarm| soonest = @min(soonest, alarm.target);
    }
    if (deadline_mode) {
        cpu.writeMsr(lapic.MSR_TSC_DEADLINE, soonest);
        return;
    }
    const at = now();
    // At most a second ahead, so the conversion cannot run away; a
    // comparator that is set short only fires sooner and sets itself again.
    // The bound is a 32-bit figure and `@min` answers in the narrower of
    // the two types, so it is widened before it is multiplied.
    const ahead: u64 = @min(if (soonest > at) soonest - at else 1, systimer.timebase_hz);
    const count = ahead * @as(u64, lapic_hz) / systimer.timebase_hz;
    lapic.write(lapic.LAPIC_TIMER_INITIAL, @intCast(@max(1, @min(count, 0xFFFF_FFFE))));
}

/// An alarm changed (systimer.setAlarm): core 0's comparator set again, by
/// core 0.
fn rethink() void {
    if (cpu.coreId() == 0) return program(0);
    @atomicStore(u32, &rethink_asked, 1, .release);
    apic.raiseCrossCore(0);
}

/// Core 0's part of its cross-core interrupt: an alarm another core set.
pub fn rethinkIfAsked() void {
    if (@atomicRmw(u32, &rethink_asked, .Xchg, 0, .acquire) != 0) program(0);
}

/// The comparator fired: on core 0 every alarm that is due marked, set one
/// period on or parked, and its interrupt raised; the tick if it is due -
/// one period on from where it was, so it keeps its rate, or from now if
/// the core fell more than a period behind - with the time slice and on
/// core 0 the log and the waiters' time limits (WaitForAny); then the
/// comparator set again.
fn onTick(_: u6) void {
    const core = cpu.coreId();
    const at = now();
    if (core == 0) {
        for (&systimer.alarms, 0..) |*alarm, n| {
            if (alarm.target > at) continue;
            alarm.target = if (alarm.period == 0) systimer.never else @max(alarm.target + alarm.period, at + 1);
            @atomicStore(u32, &alarm.fired, 1, .release);
            apic.dispatch(@intCast(intbits.INTB_ALARM0 + n));
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
