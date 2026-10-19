// SPDX-License-Identifier: MPL-2.0
//! ShareWork: a job done by the cores at once, a part each.

const sdk = @import("sdk");
const _workers = @import("_workers.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const WorkFn = sdk.exec.WorkFn;

/// Does a job in parts, at once on several cores.
///
/// SYNOPSIS:
/// ```zig
/// fn ShareWork(base: *ExecBase, work: WorkFn, data: ?*anyopaque, parts: u32) u32
/// ```
///
/// SINCE: 1.15. LVO -576.
///
/// INPUTS:
/// - `work` - the job's code, called once for each part with `data`, the
///   part's number and how many parts there are.
/// - `data` - what `work` is given.
/// - `parts` - how many parts the job is worth at most.
///
/// RESULT:
/// How many parts it was done in: 1 when the caller did the whole job
/// itself.
///
/// BEHAVIOR:
/// exec keeps a worker task on each core, pinned to it. The job is cut
/// into as many parts as `parts` asks for and there are cores: the worker
/// of each core but the caller's does one, at the caller's priority, and
/// the caller does part 0. The call returns when every part is done.
///
/// The parts run at the same time, so `work` must cut the job so that no
/// two write the same memory - nor the same cache line, on a machine whose
/// caches are not kept in step for it. A part runs on a worker's task,
/// not the caller's: a semaphore the caller holds is not the part's, and
/// a part that obtains one would wait for good.
///
/// The caller does the whole job itself, as `work(data, 0, 1)`, when
/// `parts` is 1 or less, the machine has one core, another job is under
/// way, or the caller may not wait: in an interrupt, inside `Disable`,
/// holding a spinlock, before multitasking, or as a core's idle task. A
/// job shared from within a part is done by that part alone.
///
/// CONTEXT:
/// - Waits: for the workers, where it shares; never where it may not.
/// - Interrupts: yes - the job is then done in the interrupt, alone.
/// - Locks: any; with a spinlock held the job is done alone.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `data` stays the caller's; it is only used until
/// the call returns.
///
/// NOTES:
/// Handing a part out costs a few signals between the cores, some
/// microseconds: a job worth sharing takes much longer than that.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetTaskAffinity`, `CacheClearE`
///
/// EXAMPLES:
/// ```zig
/// fn clearRows(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
///     const picture: *Picture = @ptrCast(@alignCast(data.?));
///     const first = picture.height * part / parts;
///     const end = picture.height * (part + 1) / parts;
///     @memset(picture.rows(first, end), 0);
/// }
/// _ = sys.ShareWork(&clearRows, &picture, 4);
/// ```
pub fn ShareWork(base: *ExecBase, work: WorkFn, data: ?*anyopaque, parts: u32) u32 {
    return _workers.share(base, work, data, parts);
}
