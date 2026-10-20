// SPDX-License-Identifier: MIT
//! Fences and semaphores: each an exec waitable (exec.Waitable) and no
//! more. The queue's task signals a fence when the submission it came with
//! is done; a program waits on it with WaitForFences, which is
//! WaitForAny. A semaphore is signalled the same way and waited for by
//! the queue's task before a submission is played, which takes the signal:
//! a semaphore signalled once lets one submission go.

const sdk = @import("sdk");
const exec = sdk.exec;

pub const Fence = struct {
    waitable: exec.Waitable = .{},
};

pub const Semaphore = struct {
    waitable: exec.Waitable = .{},
};

/// WaitForFences' nanoseconds as WaitForAny's microseconds, rounded up.
pub fn microseconds(nanoseconds: u64) u64 {
    if (nanoseconds == ~@as(u64, 0)) return exec.WAIT_FOREVER;
    return nanoseconds / 1000 + @intFromBool(nanoseconds % 1000 != 0);
}
