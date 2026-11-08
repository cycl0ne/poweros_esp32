// SPDX-License-Identifier: MPL-2.0
//! CoreCount: how many cores the machine runs on, for a program that
//! shows or spreads work over them.

const ExecBase = @import("../exec.zig").ExecBase;

/// Tells how many cores the machine runs on.
///
/// SYNOPSIS:
/// ```zig
/// fn CoreCount(base: *ExecBase) u32
/// ```
///
/// SINCE: 1.33. LVO -592.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// How many cores the system runs on: their numbers are 0 to one less
/// than this. Never 0 - a machine runs on at least the core it started
/// on - and 1 on a machine with one core.
///
/// BEHAVIOR:
/// It is the number the kernel started the machine on, which the kernel
/// learned from the machine itself: the firmware's own tables on a
/// machine that has them, the device tree on one that is described by
/// one, the chip's own count on a chip whose cores are fixed. So a
/// program that asks it is right on every machine without knowing any of
/// them.
///
/// The number every other call about a core answers for is this one:
/// `ReadCoreTimes`, `CoreTask` and `LockCoreTasks` all answer for 0 to
/// one less than it and refuse anything above. A program that wants one
/// figure per core asks this first and makes room for that many, rather
/// than counting until one of them refuses - which stops at a number of
/// its own choosing, and shows a machine with sixteen cores as having
/// four.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// It does not change while the machine runs: the cores are started as
/// the system comes up and none is taken away afterwards.
///
/// How busy each of them is comes from `ReadCoreTimes`; which task each
/// is running from `CoreTask`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadCoreTimes`, `CoreTask`, `LockCoreTasks`, `SetTaskAffinity`,
/// `ShareWork`
///
/// EXAMPLES:
/// ```zig
/// const cores = sys.CoreCount();
/// const room = sys.AllocVec(cores * @sizeOf(sdk.exec.CoreTimes), exec.MEMF_CLEAR) orelse return;
/// const times: [*]sdk.exec.CoreTimes = @ptrCast(@alignCast(room));
/// for (0..cores) |core| _ = sys.ReadCoreTimes(@intCast(core), &times[core]);
/// ```
pub fn CoreCount(base: *ExecBase) u32 {
    return base.cores_running;
}
