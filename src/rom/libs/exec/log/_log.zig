// SPDX-License-Identifier: MPL-2.0
//! The system log: everything written to the raw port, kept in a ring.
//!
//! Every character that goes out through `putChar` (rawio/) - kprintf from
//! the kernel, RawPutChar from a module - is also kept here, from the first
//! byte of the boot. The ring is a fixed 16 KiB of internal memory: it
//! exists before SysBase does, so it is the kernel's state rather than a
//! part of the base, like `raw_ready` beside it. Where a line starts the
//! raw port puts its time and writer in front (`[  12.345678 exec] `), so
//! the ring holds what the serial line shows.
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
//! there is an exec to call and after it has broken.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = exec.ExecBase;
const Task = sdk.exec.Task;

/// How many bytes the ring keeps.
pub const ring_size = 16 * 1024;

/// How many tasks may follow the log at once (`SetLogSignal`).
pub const max_followers = 4;

/// How many ticks apart followers are woken at most.
const signal_ticks = 10;

/// A task woken when the log grows, and the signals it is sent.
pub const Follower = extern struct {
    task: ?*Task = null,
    signal_mask: u32 = 0,
};

/// The bytes; byte number `n` is at `n % ring_size`.
var ring: [ring_size]u8 = undefined;

/// The number the next byte gets: how many were ever kept.
var written: u64 = 0;

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
    const state = _interrupt.interrupt_hardware.disable();
    ring[@intCast(written % ring_size)] = character;
    written += 1;
    _interrupt.interrupt_hardware.restore(state);
}

/// How many bytes were ever kept: the number the next one gets.
pub fn end() u64 {
    const state = _interrupt.interrupt_hardware.disable();
    defer _interrupt.interrupt_hardware.restore(state);
    return written;
}

/// Copies what the ring holds from `position.*` on into `buffer` and moves
/// `position` past it. A position older than the oldest byte kept starts
/// at that byte; one past the end reads nothing. The caller holds
/// interrupts off.
///
/// INPUTS:
/// - `position` - the number of the first byte wanted; moved past the
///   last one copied.
/// - `buffer` - where the bytes go.
///
/// RESULT:
/// How many bytes were copied.
pub fn copyOut(position: *u64, buffer: []u8) usize {
    const oldest = written -| ring_size;
    var from = position.*;
    if (from < oldest) from = oldest;
    if (from > written) from = written;
    const count: usize = @intCast(@min(written - from, buffer.len));
    const start: usize = @intCast(from % ring_size);
    const first = @min(count, ring_size - start);
    @memcpy(buffer[0..first], ring[start..][0..first]);
    @memcpy(buffer[first..count], ring[0 .. count - first]);
    position.* = from + count;
    return count;
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
    if (written == base.log_told) return;
    base.log_told = written;
    const sys = base.iface();
    for (&base.log_followers) |*follower| {
        if (follower.task) |task| sys.Signal(task, follower.signal_mask);
    }
}
