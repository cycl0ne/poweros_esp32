// SPDX-License-Identifier: MPL-2.0
//! The chip's RTC timer as the clock: a count of the slow clock's cycles
//! that a reset does not stop (sdk.hardware.rtc_timer), and a reckoning
//! kept in the RTC memory beside it that turns the count into the date.
//!
//! The reckoning is a count at which the date was known - where it was
//! last set, or where the resource last started - that date in
//! microseconds since 1 January 1978, and the slow clock's period. The
//! date now is the known date plus the cycles since, times the period.
//!
//! The slow clock is an RC oscillator, so its period is measured: at each
//! start over about 7.5 ms against the system timer, which runs from the
//! crystal, and again over the whole time since the start whenever the
//! clock is read or written later - the longer the span, the smaller the
//! error its two ends leave. A start carries the date over: the cycles
//! before it at the period the reckoning had, a new known date at the
//! start's count, the start's period after.
//!
//! A power-on clears the count and leaves the memory as it finds it; a
//! reckoning whose check sum fails, or that has seen a higher count than
//! the timer's now, holds no date.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const rtc_timer = sdk.hardware.rtc_timer;
const systimer = sdk.hardware.systimer;

/// The period's fraction bits.
pub const period_shift = 19;

/// What the RTC memory keeps.
pub const Reckoning = extern struct {
    magic: u32 = magic,
    /// The slow clock's period: microseconds per cycle, `period_shift`
    /// bits of them fraction.
    period: u32 = 0,
    /// The count at which the date was known, and that date, in
    /// microseconds since 1 January 1978.
    known_count: u64 = 0,
    known_date: i64 = 0,
    /// The highest count the reckoning has seen.
    seen: u64 = 0,
    checksum: u32 = 0,
};

const magic: u32 = 0x4243_4C4B; // "BCLK"

comptime {
    if (@sizeOf(Reckoning) > rtc_timer.clock_memory_size) @compileError("the reckoning does not fit the clock's memory");
}

/// FNV-1a over everything before the check sum.
fn checksumOf(reckoning: *const Reckoning) u32 {
    const bytes: [*]const u8 = @ptrCast(reckoning);
    var hash: u32 = 0x811C_9DC5;
    for (bytes[0..@offsetOf(Reckoning, "checksum")]) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    return hash;
}

/// The reckoning with its check sum.
pub fn sealed(reckoning: Reckoning) Reckoning {
    var with_sum = reckoning;
    with_sum.checksum = checksumOf(&with_sum);
    return with_sum;
}

/// Whether `reckoning` holds a date at count `now`.
pub fn holdsDate(reckoning: *const Reckoning, now: u64) bool {
    return reckoning.magic == magic and reckoning.checksum == checksumOf(reckoning) and
        reckoning.period != 0 and now >= reckoning.seen and reckoning.seen >= reckoning.known_count;
}

/// `cycles` of the slow clock in microseconds, at `period`. In two parts,
/// so that no product passes 64 bits.
pub fn microsOf(cycles: u64, period: u32) u64 {
    const whole = (cycles >> period_shift) * period;
    const part = ((cycles & ((1 << period_shift) - 1)) * period) >> period_shift;
    return whole + part;
}

/// The date at count `now`, in microseconds since 1 January 1978.
pub fn dateAt(reckoning: *const Reckoning, now: u64) i64 {
    return reckoning.known_date + @as(i64, @intCast(microsOf(now - reckoning.known_count, reckoning.period)));
}

/// A reckoning on which the date at count `now` is `micros`.
pub fn setTo(period: u32, now: u64, micros: i64) Reckoning {
    return sealed(.{ .period = period, .known_count = now, .known_date = micros, .seen = now });
}

/// `reckoning` carried over to a new `period` at count `now`: the date
/// now unchanged, the new period from here on.
pub fn carriedOver(reckoning: *const Reckoning, period: u32, now: u64) Reckoning {
    return setTo(period, now, dateAt(reckoning, now));
}

fn kept() *volatile Reckoning {
    return @ptrFromInt(rtc_timer.clock_memory);
}

fn load() Reckoning {
    return kept().*;
}

fn store(reckoning: Reckoning) void {
    kept().* = reckoning;
}

/// A moment the count moved on: the count, and the system timer then.
pub const Edge = struct { count: u64, ticks: u64 };

/// How many slow clock cycles the period is measured over at a start:
/// about 7.5 ms.
const cycles_measured = 1024;
/// How long a measurement may take before the timer counts as stopped.
const give_up_us = 50_000;
/// How long an edge is waited for with interrupts off: a cycle is about
/// 7.5 µs, so a timer that has not moved in this long does not count.
const edge_wait_us = 1_000;

/// The count when it has just moved on, and the system timer then; null
/// if it does not move within `edge_wait_us`. With interrupts off, so
/// that nothing comes between the two.
fn edge(sys: *ExecBase) ?Edge {
    sys.Disable();
    defer sys.Enable();
    const until = systimer.uptimeUs() + edge_wait_us;
    const before = rtc_timer.count();
    while (true) {
        const now = rtc_timer.count();
        const ticks = systimer.readUnit0();
        if (now != before) return .{ .count = now, .ticks = ticks };
        if (ticks / (systimer.SYSTIMER_HZ / 1_000_000) > until) return null;
    }
}

/// The period between two edges: microseconds per cycle, `period_shift`
/// bits of them fraction.
pub fn periodBetween(first: Edge, last: Edge) u32 {
    const cycles = last.count - first.count;
    const ticks = last.ticks - first.ticks;
    return @intCast((ticks << period_shift) / (cycles * (systimer.SYSTIMER_HZ / 1_000_000)));
}

/// The slow clock timed over `cycles_measured` of its cycles: the period,
/// and the edge it was timed from. Null when the timer does not count.
pub fn measure(sys: *ExecBase) ?struct { period: u32, first: Edge } {
    const until = systimer.uptimeUs() + give_up_us;
    const first = edge(sys) orelse return null;
    // Wait with interrupts on, then catch the next edge.
    while (rtc_timer.count() -% first.count < cycles_measured - 1) {
        if (systimer.uptimeUs() > until) return null;
    }
    const last = edge(sys) orelse return null;
    return .{ .period = periodBetween(first, last), .first = first };
}

/// The period timed over everything since `first`, the start's edge, once
/// that is more than the start's measurement had; `period` until then.
pub fn refine(sys: *ExecBase, first: Edge, period: u32) u32 {
    if (rtc_timer.count() -% first.count < 16 * cycles_measured) return period;
    const last = edge(sys) orelse return period;
    return periodBetween(first, last);
}

/// At the resource's start, with this start's `period`: a reckoning that
/// holds a date carried over to it.
pub fn start(period: u32) void {
    const now = rtc_timer.count();
    const reckoning = load();
    if (!holdsDate(&reckoning, now)) return;
    store(carriedOver(&reckoning, period, now));
}

/// The date the clock says, in microseconds since 1 January 1978, with
/// the period `period` since the date was last known; null when it holds
/// none. The period stays with the reckoning.
pub fn read(period: u32) ?i64 {
    const now = rtc_timer.count();
    var reckoning = load();
    if (!holdsDate(&reckoning, now)) return null;
    reckoning.period = period;
    reckoning.seen = now;
    store(sealed(reckoning));
    return dateAt(&reckoning, now);
}

/// The clock set to `micros` since 1 January 1978, with the period
/// `period` from here on.
pub fn write(period: u32, micros: i64) void {
    store(setTo(period, rtc_timer.count(), micros));
}
