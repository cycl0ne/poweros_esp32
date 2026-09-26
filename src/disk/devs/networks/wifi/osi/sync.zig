// SPDX-License-Identifier: MIT
//! The adapter's locks: critical sections, counting semaphores, mutexes
//! and event groups, each a small object on exec's Disable with a list of
//! waiters (`_osi.waitUntil`).
//!
//! **A critical section is Disable.** The libraries take one around what
//! their interrupt handler also touches, from tasks and from the handler
//! itself; Disable nests and is safe in an interrupt, and on one core it
//! is all a spin lock would be. A "spin lock" is therefore only a token
//! the libraries hand back.
//!
//! **Mutexes are recursive.** The libraries take theirs recursively, so
//! both kinds they ask for are the same: an owner and a depth.
//!
//! **Semaphores and event groups can be given from an interrupt**: a
//! give only changes the count or the bits and wakes the waiters.

const sdk = @import("sdk");
const exec = sdk.exec;
const _osi = @import("_osi.zig");

// --- critical sections ----------------------------------------------------

pub fn spinLockCreate() callconv(.c) ?*anyopaque {
    _osi.trace("spin_lock_create");
    return _osi.alloc(4, true, true);
}

pub fn spinLockDelete(lock: ?*anyopaque) callconv(.c) void {
    _osi.free(lock);
}

pub fn intDisable(_: ?*anyopaque) callconv(.c) u32 {
    _osi.get().sys.Disable();
    return 0;
}

pub fn intRestore(_: ?*anyopaque, _: u32) callconv(.c) void {
    _osi.get().sys.Enable();
}

/// `phy_enter_critical`, which the PHY library calls by name.
pub fn phyEnterCritical() callconv(.c) u32 {
    _osi.get().sys.Disable();
    return 0;
}

pub fn phyExitCritical(_: u32) callconv(.c) void {
    _osi.get().sys.Enable();
}

// --- counting semaphores --------------------------------------------------

pub const Semaphore = struct {
    count: u32,
    max: u32,
    waiters: exec.List = .{},

    fn take(semaphore: *Semaphore) bool {
        if (semaphore.count == 0) return false;
        semaphore.count -= 1;
        return true;
    }
};

pub fn make(max: u32, initial: u32) ?*Semaphore {
    const memory = _osi.alloc(@sizeOf(Semaphore), true, false) orelse return null;
    const semaphore: *Semaphore = @ptrCast(@alignCast(memory));
    semaphore.* = .{ .count = initial, .max = max };
    semaphore.waiters.init(.unknown);
    return semaphore;
}

pub fn semphrCreate(max: u32, initial: u32) callconv(.c) ?*anyopaque {
    _osi.trace("semphr_create");
    return make(max, initial);
}

pub fn semphrDelete(semaphore: ?*anyopaque) callconv(.c) void {
    _osi.trace("semphr_delete");
    _osi.free(semaphore);
}

pub fn semphrTake(handle: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    const semaphore: *Semaphore = @ptrCast(@alignCast(handle.?));
    return @intFromBool(_osi.waitUntil(&semaphore.waiters, _osi.deadline(ticks), semaphore, Semaphore.take));
}

pub fn semphrGive(handle: ?*anyopaque) callconv(.c) i32 {
    const semaphore: *Semaphore = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    if (semaphore.count >= semaphore.max) return _osi.no;
    semaphore.count += 1;
    _osi.wakeAll(&semaphore.waiters);
    return _osi.yes;
}

/// The running thread's own binary semaphore, made empty on first use.
pub fn threadSemphrGet() callconv(.c) ?*anyopaque {
    const thread = _osi.current();
    if (thread.semaphore == null) thread.semaphore = make(1, 0);
    return thread.semaphore;
}

// --- mutexes --------------------------------------------------------------

pub const Mutex = struct {
    owner: ?*exec.Task = null,
    depth: u32 = 0,
    waiters: exec.List = .{},
};

const Take = struct {
    mutex: *Mutex,
    task: *exec.Task,

    fn attempt(take: Take) bool {
        if (take.mutex.owner != null and take.mutex.owner != take.task) return false;
        take.mutex.owner = take.task;
        take.mutex.depth += 1;
        return true;
    }
};

pub fn mutexCreate() callconv(.c) ?*anyopaque {
    _osi.trace("mutex_create");
    const memory = _osi.alloc(@sizeOf(Mutex), true, false) orelse return null;
    const mutex: *Mutex = @ptrCast(@alignCast(memory));
    mutex.* = .{};
    mutex.waiters.init(.unknown);
    return mutex;
}

pub fn mutexDelete(mutex: ?*anyopaque) callconv(.c) void {
    _osi.free(mutex);
}

pub fn mutexLock(handle: ?*anyopaque) callconv(.c) i32 {
    const mutex: *Mutex = @ptrCast(@alignCast(handle.?));
    const task = _osi.get().sys.FindTask(null).?;
    return @intFromBool(_osi.waitUntil(&mutex.waiters, null, Take{ .mutex = mutex, .task = task }, Take.attempt));
}

pub fn mutexUnlock(handle: ?*anyopaque) callconv(.c) i32 {
    const mutex: *Mutex = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    if (mutex.depth == 0) return _osi.no;
    mutex.depth -= 1;
    if (mutex.depth == 0) {
        mutex.owner = null;
        _osi.wakeAll(&mutex.waiters);
    }
    return _osi.yes;
}

// --- event groups ---------------------------------------------------------

pub const EventGroup = struct {
    bits: u32 = 0,
    waiters: exec.List = .{},
};

const Bits = struct {
    group: *EventGroup,
    wanted: u32,
    all: bool,
    clear: bool,
    /// What the bits were when the wait was met.
    seen: *u32,

    fn attempt(bits: Bits) bool {
        const have = bits.group.bits & bits.wanted;
        const met = if (bits.all) have == bits.wanted else have != 0;
        bits.seen.* = bits.group.bits;
        if (met and bits.clear) bits.group.bits &= ~bits.wanted;
        return met;
    }
};

pub fn eventGroupCreate() callconv(.c) ?*anyopaque {
    _osi.trace("event_group_create");
    const memory = _osi.alloc(@sizeOf(EventGroup), true, false) orelse return null;
    const group: *EventGroup = @ptrCast(@alignCast(memory));
    group.* = .{};
    group.waiters.init(.unknown);
    return group;
}

pub fn eventGroupDelete(group: ?*anyopaque) callconv(.c) void {
    _osi.free(group);
}

pub fn eventGroupSetBits(handle: ?*anyopaque, bits: u32) callconv(.c) u32 {
    const group: *EventGroup = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    group.bits |= bits;
    const after = group.bits;
    _osi.wakeAll(&group.waiters);
    return after;
}

pub fn eventGroupClearBits(handle: ?*anyopaque, bits: u32) callconv(.c) u32 {
    const group: *EventGroup = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    const before = group.bits;
    group.bits &= ~bits;
    return before;
}

pub fn eventGroupWaitBits(handle: ?*anyopaque, wanted: u32, clear_on_exit: c_int, wait_for_all: c_int, ticks: u32) callconv(.c) u32 {
    const group: *EventGroup = @ptrCast(@alignCast(handle.?));
    var seen: u32 = 0;
    _ = _osi.waitUntil(&group.waiters, _osi.deadline(ticks), Bits{
        .group = group,
        .wanted = wanted,
        .all = wait_for_all != 0,
        .clear = clear_on_exit != 0,
        .seen = &seen,
    }, Bits.attempt);
    return seen;
}
