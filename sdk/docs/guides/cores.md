# Work on more cores

A program that has more to do than one core gets through has three ways
to hand some of it to the others: a **task** of its own, a job cut into
**parts** that every core does at once (`ShareWork`), or a **job posted**
to run beside it while it goes on (`PostWork`). This guide is which to
take, what each costs, and what the code handed over may do. The calls
are in the reference, [exec](../autodocs/exec.md); how the cores share
the tasks, and what that changes for locking, is in
[Several cores](programs.md#several-cores).

- [Which one](#which-one)
- [A task of its own](#a-task-of-its-own)
- [A job in parts: ShareWork](#a-job-in-parts-sharework)
- [A job beside you: PostWork](#a-job-beside-you-postwork)
- [What the code handed over may do](#what-the-code-handed-over-may-do)
- [Cutting a job](#cutting-a-job)
- [Measuring](#measuring)

## Which one

| You want | Take | It costs, on the VisionFive 2 |
|---|---|---|
| work that runs for a while, waits, or uses files | a task, or a process | 14-25 us to start one and hear its end; a process that inherits its directories 71 us |
| one job done sooner, the caller waiting for it | `ShareWork` | 15 us for 4 parts of nothing |
| a job done while the caller does something else - waits for a device, serves the next request | `PostWork` | 8.3 us for a job of nothing posted and back; 3.9 us each for four at once |

What is handed over has to be worth more than that: a part or a job of a
few microseconds is slower shared than done. As a yardstick, a CRC-32C
of 4 KiB takes about 8 us on a U74.

exec keeps one **worker** task on each core, pinned to it, for
`ShareWork`'s parts and `PostWork`'s jobs alike. They cost nothing while
there is no work, and nothing has to be set up to use them. A kernel on
one core (`-Dcores=1`) has none, and both calls do the work on the
caller itself, so code written for them runs everywhere.

## A task of its own

A task (`CreateTask`, `AddTask`) is right for work that lives - a loop
that waits for messages, a timer, a device - or that waits at all. A
process (`CreateNewProc`) is right for work that uses files: only a
process may call dos. Starting one and hearing its end - its end message
replied once it is gone (`SetTaskEndMsg`) - takes 14 us with an 8 KiB
stack and 25 us with 32 KiB; a process 71 us, most of it locking its
current and home directory again and copying its variables, and 14 us
with `NP_CurrentDir` and `NP_HomeDir` 0 and `NP_CopyVars` FALSE.
[Tasks](exec.md#tasks) has how one is started and what its end gives
back.

A task runs on whichever core is free; a task of its own is not tied to
the caller's priority, and can be pinned (`SetTaskAffinity`).

h264.vcodec and vp8.vcodec keep a task on each core while a film is
open (the codec modules' `Team`): each decodes a picture of its own and
waits - by a waitable - for the rows of the pictures it refers to,
which a posted job may not do.

## A job in parts: ShareWork

`ShareWork(work, data, parts)` calls `work(data, part, parts)` once for
each part: the caller does part 0, and idle workers on the other cores a
part each, at the caller's priority. It returns when every part is done,
and answers how many there were - as many as were asked for and there
were idle workers, so the job's code works out its own piece from the
two numbers:

```zig
const Sums = struct {
    blocks: []const u8,
    crcs: []u32, // one for each 4 KiB block
};

fn sumBlocks(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const sums: *Sums = @ptrCast(@alignCast(data.?));
    const count = sums.crcs.len;
    const first = count * part / parts;
    const end = count * (part + 1) / parts;
    for (first..end) |index| sums.crcs[index] = crc32c(sums.blocks[index * 4096 ..][0..4096]);
}

var sums: Sums = .{ .blocks = buffer, .crcs = crcs };
_ = sys.ShareWork(&sumBlocks, &sums, 4);
```

One job is shared at a time, for the whole system. The caller does the
whole job itself, as `work(data, 0, 1)`, when another job is under way,
when every other worker is running posted jobs, on one core, and where
it may not wait - in an interrupt, inside `Disable`, holding a spinlock.
A job shared from inside a part is done by that part alone. So
`ShareWork` never fails and never deadlocks: at worst it is the plain
call it replaces.

exec uses it for GCM's GHASH, for its own long cache write-backs, in
fbboard's engine, and in facet's rasterizer.

## A job beside you: PostWork

`PostWork(job)` queues a `WorkJob` - a message the caller owns, with its
code and its data - and returns at once. A worker calls `job.work(job)`
and replies the job to its reply port; meanwhile the poster goes on, and
waits for the reply when it wants the result, with whatever else it
waits for:

```zig
const Run = struct {
    job: exec.WorkJob,
    bytes: []const u8,
    sum: u32 = 0,
};

fn sumRun(job: *exec.WorkJob) callconv(.c) void {
    const run: *Run = @fieldParentPtr("job", job);
    run.sum = crc32c(run.bytes);
}

const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
defer sys.DeleteMsgPort(port);
var run: Run = .{ .job = .{ .message = .{ .reply_port = port }, .work = &sumRun }, .bytes = block };
sys.PostWork(&run.job);
writeToDevice(block); // the device and the sum at the same time
_ = sys.WaitPort(port);
_ = sys.GetMsg(port); // run.sum is ready
```

The job is the first field of a struct of the caller's, which its code
finds with `@fieldParentPtr` - or `job.data` points at what it works on.
Several jobs can be out at once, each with its own `WorkJob`, all
replied to one port: the poster counts the replies.

**Who runs it, and when.** PostWork wakes an idle worker, another core's
before the poster's own, and the job runs at the **poster's priority**.
While every worker is busy the jobs queue, the highest priority first and
in the order posted among the same; a worker done with a job or a part
takes the next. A worker running jobs is not handed parts by `ShareWork`,
which does without it. On one core the poster runs the job itself and it
is replied before `PostWork` returns - the same reply, so the poster's
code does not change.

**The job is lent.** Until it is replied, the `WorkJob` and what its code
reads stay as they are: not changed, not freed, not posted again. Nothing
the job writes is looked at before the reply. A program's job must be
back before the program returns, since its code goes with it
([When the code goes](programs.md#when-the-code-goes)).

posfs-handler uses it for its checksums: the crcs of a run of blocks
are worked out in parts, one job each, while the run goes to the device,
and the blocks of a long read are checked the same way. It writes a
gigabyte to the VisionFive 2's NVMe at 240 MiB/s instead of 141, and the
handler's own share of a core went from 48% to 23%.

## What the code handed over may do

A part (but part 0) and a job run on a worker's task, not on the caller's:

| It may | It may not |
|---|---|
| read what the caller handed it, and write its own share | write memory another part writes - nor the same cache line where the caches are not kept in step |
| allocate and free memory | use dos, or anything that does: a worker is not a process |
| `Signal`, `PutMsg`, `ReplyMsg` | obtain a semaphore the caller may hold: it would wait for good |
| post jobs, share work | wait - for a signal, a port, a device: it keeps a core's worker from the queue |
| take a spinlock of its own, briefly | run longer than it is worth handing over |

Its stack is the worker's: 32 KiB on a 64-bit machine, 16 KiB on a
32-bit one. A job that has to wait, or open files, belongs in a task of
its own.

## Cutting a job

- **By what each part writes.** Cut the output, not the input: rows of a
  picture, blocks of a buffer, entries of a table. Each part writes only
  its own, and nothing needs a lock.
- **Into pieces worth handing over.** A piece of at least some tens of
  microseconds - posfs hands a part 32 KiB of checksums, about 70 us -
  and no more parts than cores; below that do it in the caller.
- **With the edges worked out from the numbers.** `count * part / parts`
  to `count * (part + 1) / parts` covers every item once whatever
  `parts` comes back, 1 included.
- **Alone first.** A job that is right with `parts` 1 is right shared,
  provided its parts write apart; test it alone on the host, where there
  are no workers, then on the board.

## Measuring

`C:test/TaskBench` times a task started and ended, a process, a job of
nothing posted and back, four at once, `ShareWork` in parts, and three
posters with `ShareWork` beside them, checking that every job ran once.
`C:Top` shows the workers as `exec worker 0` to `3`, with their share of
the time, beside the task that hands them work; `ReadCoreTimes` answers
how busy each core was.
