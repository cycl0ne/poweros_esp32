// SPDX-License-Identifier: MIT
//! Fences, semaphores and events: each an exec waitable (exec.Waitable) and
//! no more. The queue's task signals a fence when the submission it came
//! with is done; a program waits on it with WaitForFences, which is
//! WaitForAny. A semaphore is signalled the same way and waited for by
//! the queue's task before a submission is played, which takes the signal:
//! a semaphore signalled once lets one submission go.
//!
//! An event (since 1.129) is set by the host (SetEvent) or by a command
//! played (CmdSetEvent), and stays set until it is reset: a wait does not
//! take it. CmdWaitEvents has the queue's task wait until each event is
//! set. As lavapipe's queue plays a command buffer, one command after the
//! other, the work before a CmdSetEvent is done when it is played, and so
//! is every command a CmdWaitEvents comes after (handle_event_set2,
//! handle_event_reset2 and handle_wait_events2, lvp_execute.c:3401-3433).
//! Where lavapipe spins until the event is set, the task sleeps in
//! WaitForAny, which a SetEvent of the host wakes; Vulkan has an event the
//! host sets be set before the work that waits for it is submitted (its
//! queue forward progress section), and then the wait has nothing to wait
//! for.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _stream = @import("../command/_stream.zig");
const _command = @import("../command/_command.zig");

pub const Fence = struct {
    waitable: exec.Waitable = .{},
};

pub const Semaphore = struct {
    waitable: exec.Waitable = .{},
};

pub const Event = struct {
    waitable: exec.Waitable = .{},
};

/// SetEvent, and CmdSetEvent played: the event set, and a queue's task
/// waiting for it woken.
pub fn set(sys: *ExecBase, event: *Event) void {
    sys.SignalWaitable(&event.waitable);
}

/// ResetEvent, and CmdResetEvent played: the event reset.
pub fn reset(sys: *ExecBase, event: *Event) void {
    sys.ResetWaitable(&event.waitable);
}

/// CmdWaitEvents played: back once every one of `events` is set, which
/// each stays.
pub fn wait(sys: *ExecBase, events: []const *Event) void {
    for (events) |event| {
        const one = [1]*exec.Waitable{&event.waitable};
        _ = sys.WaitForAny(&one, 1, exec.WAIT_FOREVER);
    }
}

/// A command of events played, as either driver plays it: `head` starts a
/// CmdSetEvent, a CmdResetEvent or a CmdWaitEvents.
pub fn play(sys: *ExecBase, head: *const _stream.Head) void {
    switch (head.op) {
        .set_event => set(sys, _stream.as(_command.SetEvent, head).event),
        .reset_event => reset(sys, _stream.as(_command.ResetEvent, head).event),
        .wait_events => {
            const command = _stream.as(_command.WaitEvents, head);
            wait(sys, _stream.items(_command.WaitEvents, *Event, command, command.count));
        },
        else => unreachable,
    }
}

/// What is left of a limit in microseconds, `began` and `now` read from one
/// clock: none, once it has run out.
pub fn timeLeft(limit: u64, began: u64, now: u64) u64 {
    return limit -| (now -| began);
}

/// WaitForFences' nanoseconds as WaitForAny's microseconds, rounded up.
pub fn microseconds(nanoseconds: u64) u64 {
    if (nanoseconds == ~@as(u64, 0)) return exec.WAIT_FOREVER;
    return nanoseconds / 1000 + @intFromBool(nanoseconds % 1000 != 0);
}
