// SPDX-License-Identifier: MPL-2.0
//! The machine's clock as exec reads it: the kernel's own, for the chip
//! the kernel is built for - its counter's rate, which the kernel
//! learned as it started, the time since the machine came up, and the
//! wait that does not give the CPU away. exec's calls answer it to
//! every module (`GetTimeBase`, `UptimeUs`, `SpinUs`), and exec's own
//! waits read it here.
//!
//! The kernel's root puts its clock here before exec is made, as it
//! puts the log's (`exec.clock_hardware`). Until then, and in the host
//! tests, which have no chip, the rate is the ESP32-S3's, the time
//! stands still and a spin returns at once.

/// What exec's time calls read.
pub const Clock = struct {
    /// How many times a second the machine's counter counts.
    timebase: *const fn () u64 = &noTimebase,
    /// Microseconds since the machine came up.
    uptimeUs: *const fn () u64 = &noUptime,
    /// `us` microseconds waited out without giving the CPU away.
    spinUs: *const fn (us: u64) void = &noSpin,
};

/// The kernel's clock; nothing's, until the kernel's root sets it.
pub var clock: Clock = .{};

fn noTimebase() u64 {
    return 16_000_000;
}

fn noUptime() u64 {
    return 0;
}

fn noSpin(_: u64) void {}
