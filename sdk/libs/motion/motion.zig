// SPDX-License-Identifier: MIT
//! motion.library: a clock for things that move.
//!
//! One task with one clock runs every animation and timer in the system
//! that is due: a value going from one number to another over a time, or
//! a hook called after a time or every so often. The clock is
//! `timer.device`'s, read in microseconds; while nothing is due there is no
//! request out and the task sleeps. A step is worked out from the time
//! since its start, so a step that comes late lands further along and an
//! animation still ends when it should.
//!
//! The calls arrive with the animations and timers themselves.

/// The name to open it by.
pub const MOTIONNAME = "motion.library";
