// SPDX-License-Identifier: MPL-2.0
//! WaitForAny: waits until one of several waitables is signalled, or a
//! time has gone by.

const sdk = @import("sdk");
const systimer = sdk.hardware.systimer;
const _waitable = @import("_waitable.zig");
const _locks = @import("../locks/_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Waitable = sdk.exec.Waitable;
const SIGF_SINGLE = sdk.exec.tasks.SIGF_SINGLE;
const WAIT_FOREVER = sdk.exec.WAIT_FOREVER;
const WAIT_TIMEOUT = sdk.exec.WAIT_TIMEOUT;

/// Waits until one of several waitables is signalled, or a time has gone
/// by.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitForAny(base: *ExecBase, waitables: [*]const *Waitable, count: u32, timeout_us: u64) i32
/// ```
///
/// SINCE: 1.14. LVO -572.
///
/// INPUTS:
/// - `waitables` - the waitables, one pointer each.
/// - `count` - how many: 1 to `WAIT_MAX`.
/// - `timeout_us` - how long to wait at most, in microseconds. 0 only
///   looks, and `WAIT_FOREVER` waits with no limit.
///
/// RESULT:
/// The place in `waitables` of the first that is signalled, or
/// `WAIT_TIMEOUT` when the time ran out first - and at once for a `count`
/// of 0 or more than `WAIT_MAX`.
///
/// BEHAVIOR:
/// One already signalled answers at once, without waiting: a waitable
/// stays signalled until it is reset, so one signalled before the call is
/// not missed. Nothing is reset here; that is the caller's, when it
/// wants to wait for the same thing again.
///
/// The time is kept by the system's tick, so the limit is met to within
/// one tick - 10 ms at the usual 100 Hz - and never short of it. While it
/// waits the task holds the processor no more than in `Wait`, and the
/// task waits on `SIGF_SINGLE`, which exec uses for its own waits.
///
/// CONTEXT:
/// - Waits: yes, unless one is signalled or `timeout_us` is 0.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The waitables stay their owners', and none may
/// go while the call waits on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SignalWaitable`, `ResetWaitable`, `Wait`
///
/// EXAMPLES:
/// ```zig
/// const which = sys.WaitForAny(&.{ &frame, &job.done }, 2, 50_000);
/// if (which == exec.WAIT_TIMEOUT) {
///     // neither within 50 ms
/// }
/// ```
pub fn WaitForAny(base: *ExecBase, waitables: [*]const *Waitable, count: u32, timeout_us: u64) i32 {
    if (count == 0 or count > sdk.exec.WAIT_MAX) return WAIT_TIMEOUT;
    if (_waitable.firstSignalled(waitables, count)) |first| return @intCast(first);
    if (timeout_us == 0) return WAIT_TIMEOUT;
    _locks.checkWait(base, @returnAddress());
    const sys = base.iface();
    var record = _waitable.Record{
        .task = sys.FindTask(null).?,
        .waitables = waitables,
        .count = count,
        .deadline = if (timeout_us == WAIT_FOREVER) WAIT_FOREVER else systimer.uptimeUs() +| timeout_us,
    };
    // Cleared before the record is seen, so a wake that comes after it
    // is kept for the Wait below.
    _ = sys.SetSignal(0, SIGF_SINGLE);
    sys.Disable();
    _waitable.enlist(base, &record);
    sys.Enable();
    var answer: i32 = WAIT_TIMEOUT;
    while (true) {
        if (_waitable.firstSignalled(waitables, count)) |first| {
            answer = @intCast(first);
            break;
        }
        if (@atomicLoad(bool, &record.timed_out, .acquire)) break;
        _ = sys.Wait(SIGF_SINGLE);
    }
    sys.Disable();
    _waitable.delist(base, &record);
    sys.Enable();
    _ = sys.SetSignal(0, SIGF_SINGLE);
    return answer;
}
