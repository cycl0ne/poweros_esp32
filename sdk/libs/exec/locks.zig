// SPDX-License-Identifier: MIT
//! Spinlocks: exclusion that does not wait, for what an interrupt or
//! another core may touch.
//!
//! A semaphore puts a task to sleep until the holder lets go; a spinlock
//! never sleeps. Whoever finds it held tries again until it is free, so it
//! is held only for a few hundred cycles: long enough to change a list's
//! links or a driver's state, never long enough to wait for anything.
//!
//! **The rules**, which exec checks on every call:
//!
//! - Nothing that may wait is called while a lock is held: no `Wait`, and
//!   nothing that calls it - no `DoIO`, no `ObtainSemaphore`, no file.
//!   Task switching on the core stops while a lock is held, and a holder
//!   that waited would leave everyone else spinning. Nor `AllocMem`: when
//!   memory runs short it runs the low-memory handlers, which expunge
//!   libraries - other code at length, and exec's own locks again.
//! - Locks are taken in one order: each lock has its place
//!   (`LOCKORDER_*`), and a lock is taken only while every lock the core
//!   holds is earlier. Two cores that took two locks the other way round
//!   would each wait for the other for good; one order makes that
//!   impossible.
//! - A lock an interrupt takes is made with `LOCKF_INTERRUPT`, and every
//!   caller then takes it with this core's interrupts masked; a plain lock
//!   is never taken in an interrupt. Otherwise an interrupt could spin on
//!   a lock the code it interrupted holds.
//!
//! A broken rule is a recoverable alert naming the locks (`AN_LockRule`) -
//! but `Wait` with a lock held is a dead end (`AN_LockRule` with
//! `AT_DeadEnd`), as is a lock taken again on the core that holds it, which
//! would never end (`AN_LockDeadlock`).
//!
//! A lock may live anywhere. In internal memory it is one S32C1I; in
//! PSRAM, where this chip has no atomic store, exec takes it under one
//! guard word in internal memory instead, a few instructions with
//! interrupts masked.

const nodes = @import("nodes.zig");
const tasks = @import("tasks.zig");

/// A spinlock (InitLock, AcquireLock, AttemptLock, ReleaseLock).
pub const Lock = extern struct {
    /// ln_Name says what the lock guards, for the alerts that name it;
    /// ln_Type NT_LOCK. The lock is on no list.
    node: nodes.Node = .{ .type = .lock },
    /// 0 while free; while held, the holder's core and one. Changed only
    /// by exec.
    state: u32 = 0,
    /// The task that holds it, or null while it is free or held by an
    /// interrupt. For the alerts and the debugger.
    owner: ?*tasks.Task = null,
    /// Its place in the lock order (`LOCKORDER_*`).
    order: u16 = 0,
    /// `LOCKF_*`.
    flags: u16 = 0,
};

/// An interrupt takes this lock too: every caller takes it with this
/// core's interrupts masked, and gets them back on ReleaseLock.
pub const LOCKF_INTERRUPT: u16 = 1 << 0;

/// The lock order: a lock is taken only while every lock held has a
/// smaller order. A program's or a driver's own locks are from
/// LOCKORDER_DRIVER up to LOCKORDER_SYSTEM; exec's own are from
/// LOCKORDER_SYSTEM up, taken last of all, since a holder of any other
/// lock may still call exec (Signal, PutMsg) and exec's locks are held for
/// a few instructions only.
pub const LOCKORDER_DRIVER: u16 = 1000;
pub const LOCKORDER_SYSTEM: u16 = 50000;

/// How many locks a core may hold at once.
pub const LOCKS_HELD_MAX = 8;
