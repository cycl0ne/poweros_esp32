// SPDX-License-Identifier: MIT
//! Waitables: something a task waits for together with others, and for no
//! longer than it says (WaitForAny).
//!
//! A signal is a task's: it says "look", and the task has to know where.
//! A waitable is the thing itself - a frame begun, a job done, a fence a
//! piece of hardware has passed - which whoever makes it happen signals
//! (SignalWaitable), an interrupt included. It stays signalled until it is
//! reset (ResetWaitable), so one that was signalled before anybody waited
//! is not missed, and every task waiting on it is woken.
//!
//! Its memory is its owner's: a waitable is made by clearing it - `.{}` -
//! and needs nothing given back. It must not go while a task waits on it.

/// A waitable. Made unsignalled by `.{}`.
pub const Waitable = extern struct {
    /// Not 0 once signalled, until it is reset. Read it, never write it:
    /// SignalWaitable is what wakes those waiting.
    signalled: u32 = 0,
    pad: u32 = 0,
};

/// WaitForAny's time limit for none: it waits until one is signalled.
pub const WAIT_FOREVER: u64 = ~@as(u64, 0);

/// WaitForAny's answer when the time ran out first.
pub const WAIT_TIMEOUT: i32 = -1;

/// The most waitables one WaitForAny takes.
pub const WAIT_MAX: u32 = 32;
