// SPDX-License-Identifier: MPL-2.0
//! The system log: everything written to the raw port, kept in a ring.
//!
//! Every character that goes out through `putChar` (rawio/) - kprintf from
//! the kernel, RawPutChar from a module - is also kept here, from the first
//! byte of the boot. The ring is internal memory the kernel hands over
//! before it prints anything, as large as its board says
//! (`SYSTAG_LogSize`): it exists before SysBase does, so it is the
//! kernel's state rather than a part of the base, like `raw_ready` beside
//! it. Where a line starts the raw port puts its time and writer in front
//! (`[  12.345678 exec] `), so the ring holds what the serial line shows.
//!
//! **Settings** - the level kept, and whether the log goes to the USB
//! console - are here too, for the same reason: the raw port reads them
//! from the first byte on. `LogControl` changes them.
//!
//! **Every byte has a running number**, a 64-bit count that never wraps.
//! A reader keeps the number it has read up to and asks `ReadLog` for
//! what follows; one that fell further behind than the ring holds gets
//! the oldest byte still kept and sees from the number how much it
//! missed. Any number of readers read beside each other, and none of them
//! takes anything away.
//!
//! **Followers are woken by the tick**, not by the writer: `SetLogSignal`
//! names a task and a signal, and ten ticks after something new was kept
//! the tick signals each follower once. Writing therefore never signals -
//! it happens inside the scheduler, in interrupts and in a Guru.
//!
//! Writing masks interrupts at the CPU around the ring's index only,
//! through `interrupt_hardware` rather than `Disable`, since it runs before
//! there is an exec to call and after it has broken - and takes the ring's
//! own word lock meanwhile, as both cores write into it. A core that waits
//! for it answers a hold as it spins.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = exec.ExecBase;
const Task = sdk.exec.Task;

/// How many tasks may follow the log at once (`SetLogSignal`).
pub const max_followers = 6;

/// How many ticks apart followers are woken at most.
const signal_ticks = 10;

/// A task woken when the log grows, and the signals it is sent.
pub const Follower = extern struct {
    task: ?*Task = null,
    signal_mask: u32 = 0,
};

/// The bytes; byte number `n` is at `n % ring.len`. Empty until the
/// kernel hands one over, and nothing is kept until then; the host tests
/// have one of their own.
pub var ring: []u8 = if (builtin.is_test) &test_ring else &.{};
var test_ring: [16 * 1024]u8 = undefined;

/// The level kept: a line below it is not written (`LOGCTRL_LEVEL`).
pub var level: u32 = sdk.exec.LOG_INFO;
/// The log is wanted on the USB console (`LOGCTRL_MIRROR`), and the USB
/// port has a driver that copies it there (`LOGCTRL_USBPORT`); until it
/// has, the raw port writes the port itself.
pub var mirror_wanted = false;
pub var usb_taken = false;

/// The number the next byte gets: how many were ever kept.
var written: u64 = 0;

/// The ring's lock: the core holding it and one, or 0. Internal memory
/// (.bss), where the compare-and-set is atomic.
var ring_lock: u32 = 0;

/// The ring locked against the other core, with this core's interrupts
/// masked; answers the state `unlock` puts back.
pub fn lock() u32 {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    while (@cmpxchgWeak(u32, &ring_lock, 0, 1, .acquire, .monotonic) != null) hardware.park_if_asked();
    return state;
}

/// What `lock` took, let go.
pub fn unlock(state: u32) void {
    @atomicStore(u32, &ring_lock, 0, .release);
    _interrupt.interrupt_hardware.restore(state);
}

/// The time in front of a line, in microseconds since the boot. The kernel
/// puts its clock here before exec is made; without one (the host tests)
/// every line is at 0.
pub var clock: *const fn () u64 = noClock;

fn noClock() u64 {
    return 0;
}

/// Keeps one byte.
///
/// INPUTS:
/// - `character` - the byte, never a NUL.
pub fn keep(character: u8) void {
    if (ring.len == 0) return;
    const state = lock();
    ring[@intCast(written % ring.len)] = character;
    written += 1;
    unlock(state);
}

/// How many bytes were ever kept: the number the next one gets.
pub fn end() u64 {
    const state = lock();
    defer unlock(state);
    return written;
}

/// Copies what the ring holds from `position.*` on into `buffer` and moves
/// `position` past it. A position older than the oldest byte kept starts
/// at that byte; one past the end reads nothing. The caller holds the ring
/// (`lock`).
///
/// INPUTS:
/// - `position` - the number of the first byte wanted; moved past the
///   last one copied.
/// - `buffer` - where the bytes go.
///
/// RESULT:
/// How many bytes were copied.
pub fn copyOut(position: *u64, buffer: []u8) usize {
    if (ring.len == 0) return 0;
    const oldest = written -| ring.len;
    var from = position.*;
    if (from < oldest) from = oldest;
    if (from > written) from = written;
    const count: usize = @intCast(@min(written - from, buffer.len));
    const start: usize = @intCast(from % ring.len);
    const first = @min(count, ring.len - start);
    @memcpy(buffer[0..first], ring[start..][0..first]);
    @memcpy(buffer[first..count], ring[0 .. count - first]);
    position.* = from + count;
    return count;
}

/// The last of the log, from the start of a line, into `into`: what a dead
/// end keeps over the reset (the last words). Answers the part of `into`
/// that holds it.
///
/// INPUTS:
/// - `into` - where it goes; as much of the log's end as fits.
pub fn tail(into: []u8) []u8 {
    const state = lock();
    defer unlock(state);
    var position = written -| into.len;
    const whole_log = position == 0;
    const count = copyOut(&position, into);
    var text = into[0..count];
    // A part-line at the start says nothing; the log's first byte starts
    // one anyway.
    if (!whole_log) {
        var at: usize = 0;
        while (at < text.len and text[at] != '\n') at += 1;
        text = text[@min(at + 1, text.len)..];
    }
    return text;
}

/// The followers' part of the tick: every `signal_ticks` ticks, if
/// something was kept since the last time, each follower gets its
/// signals. The tick interrupt calls it.
///
/// INPUTS:
/// - `base` - exec: its followers and what they were last told of.
pub fn tickLog(base: *ExecBase) void {
    base.log_ticks +%= 1;
    if (base.log_ticks % signal_ticks != 0) return;
    const now = end();
    if (now == base.log_told) return;
    base.log_told = now;
    const sys = base.iface();
    for (&base.log_followers) |*follower| {
        if (follower.task) |task| sys.Signal(task, follower.signal_mask);
    }
}
