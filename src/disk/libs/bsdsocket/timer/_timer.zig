// SPDX-License-Identifier: MIT
//! The stack's deadlines: a heap of timers, earliest first, in the
//! stack's base. A timer is a field of what it belongs to - an ARP entry,
//! a datagram being put back together - so adding and removing one
//! allocates nothing, and a deadline exists only while something waits on
//! it: an idle stack has an empty heap and its task sleeps.
//!
//! Times are microseconds on the E-clock, which counts from the boot and
//! only rises - not the system time, which setting the date moves, and
//! which would run every deadline out at once. The stack task
//! keeps one timer.device request for the earliest deadline, and runs
//! every timer whose time has come when it is answered; whoever puts a
//! timer in front of the heap tells the task, which sets its request
//! again. Everything here runs under the stack's lock, and the functions
//! take `now` rather than reading the clock, so the tests can say what
//! time it is.

const sdk = @import("sdk");
const timer = sdk.devices.timer;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;

/// How many timers can wait at once.
pub const timers_max = 64;
/// A timer that is not in the heap.
const nowhere: u32 = 0xFFFF_FFFF;

pub const FireFn = *const fn (stack: *StackBase, fired: *Timer, now: u64) void;

pub const Timer = extern struct {
    deadline: u64 align(4) = 0,
    /// Where it is in the heap, or `nowhere`.
    index: u32 = nowhere,
    /// Run, under the lock, when the deadline has passed; the timer is
    /// out of the heap by then and may be set again.
    fire: ?FireFn = null,

    pub fn armed(entry: *const Timer) bool {
        return entry.index != nowhere;
    }
};

pub const Heap = extern struct {
    entries: [timers_max]?*Timer = @splat(null),
    count: u32 = 0,
};

/// `entry` set to fire at `deadline`, replacing an earlier setting. False when
/// the heap is full; the timer then does not fire.
pub fn set(stack: *StackBase, entry: *Timer, deadline: u64) bool {
    const heap = &stack.timers;
    if (entry.armed()) cancel(stack, entry);
    if (heap.count == timers_max) return false;
    entry.deadline = deadline;
    entry.index = heap.count;
    heap.entries[heap.count] = entry;
    heap.count += 1;
    up(heap, entry.index);
    if (entry.index == 0) stack.rethink();
    return true;
}

/// `entry` out of the heap, if it is in it.
pub fn cancel(stack: *StackBase, entry: *Timer) void {
    const heap = &stack.timers;
    if (!entry.armed()) return;
    const at = entry.index;
    heap.count -= 1;
    const last = heap.entries[heap.count].?;
    heap.entries[heap.count] = null;
    entry.index = nowhere;
    if (last == entry) return;
    heap.entries[at] = last;
    last.index = at;
    up(heap, at);
    down(heap, last.index);
}

/// The earliest deadline, if a timer waits.
pub fn earliest(stack: *StackBase) ?u64 {
    const heap = &stack.timers;
    if (heap.count == 0) return null;
    return heap.entries[0].?.deadline;
}

/// Every timer whose deadline is `now` or before, fired, earliest first.
pub fn run(stack: *StackBase, now: u64) void {
    const heap = &stack.timers;
    while (heap.count > 0) {
        const first = heap.entries[0].?;
        if (first.deadline > now) return;
        cancel(stack, first);
        if (first.fire) |fire| fire(stack, first, now);
    }
}

fn swap(heap: *Heap, a: u32, b: u32) void {
    const held = heap.entries[a].?;
    heap.entries[a] = heap.entries[b];
    heap.entries[b] = held;
    heap.entries[a].?.index = a;
    heap.entries[b].?.index = b;
}

fn up(heap: *Heap, from: u32) void {
    var at = from;
    while (at > 0) {
        const parent = (at - 1) / 2;
        if (heap.entries[parent].?.deadline <= heap.entries[at].?.deadline) return;
        swap(heap, parent, at);
        at = parent;
    }
}

fn down(heap: *Heap, from: u32) void {
    var at = from;
    while (true) {
        const left = 2 * at + 1;
        if (left >= heap.count) return;
        var smaller = left;
        const right = left + 1;
        if (right < heap.count and heap.entries[right].?.deadline < heap.entries[left].?.deadline) smaller = right;
        if (heap.entries[at].?.deadline <= heap.entries[smaller].?.deadline) return;
        swap(heap, at, smaller);
        at = smaller;
    }
}

/// The microseconds since the boot, on the E-clock, or 0 before the
/// stack has a timer. A stack that runs without its task has the time its
/// runner says.
pub fn clock(stack: *StackBase) u64 {
    if (stack.no_task != 0) return stack.fixed_time;
    const timer_base = stack.timer_base orelse return 0;
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}
