// SPDX-License-Identifier: MIT
//! MemOwner: what a block of memory says about itself, and what exec does
//! with it.
//!
//!   MemOwner LEAK/S,WRONGSIZE/S,TWICE/S,OVERRUN/S,AFTERFREE/S,CRASH/S,ALERT/S,WAIT/S
//!
//! With no switch it allocates a shared block, a private one
//! (MEMF_PRIVATE), the system's (MEMF_SYSTEM), one inside a
//! BeginSystemMemory pair and a pool's first puddle, prints each one's
//! MemBlock - owner, size, private - beside this task's own number, frees
//! them all and checks the free memory came back to the byte.
//!
//! LEAK starts a task that allocates three blocks, one of them private,
//! and ends without freeing them; it says the task's number, under which
//! `Avail OWNERS`, `Top` and `MemMap` show what it left - the two shared
//! ones for good, until the next start: that is what a leak is. The
//! private one was freed as the task ended.
//!
//! WRONGSIZE frees a block with a size that is not its own, and TWICE frees
//! one twice: exec refuses both with an alert, and the block stays as it
//! was (the first is then freed right).
//!
//! With memory debugging on (`MemDebug ON`): OVERRUN writes one byte past
//! the end of a block of 100 and frees it, which FreeMem tells with an
//! alert; AFTERFREE writes near the end of a block of 64 KiB after freeing
//! it, which `MemDebug CHECK` finds, or AllocMem when it hands that memory
//! out again - near the end, so that what the shell allocates next takes
//! the block's front and leaves the write for a check to find. Without it
//! both say so and do nothing.
//!
//! CRASH takes a public semaphore ("MemOwner"), opens a window where
//! there is a screen and allocates 4096 private bytes, then reads an address nothing answers;
//! ALERT does the same and raises a dead-end alert instead. Either is a
//! Software Failure, and Kill on its requester (or `s3> kill`) ends the
//! task: the semaphore goes to whoever waits for it, the window closes,
//! the private memory is freed - each a line on the log. WAIT, in another
//! shell, waits for that semaphore, says when it has it, and takes it
//! away again.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Printf = dos.stdio.Printf;

const NAME = "MemOwner";
const VERSION_STRING = "\x00$VER: MemOwner 1.2 (16.10.2026)\r\n";
const TEMPLATE = "LEAK/S,WRONGSIZE/S,TWICE/S,OVERRUN/S,AFTERFREE/S,CRASH/S,ALERT/S,WAIT/S";
const arg_leak = 0;
const arg_wrong_size = 1;
const arg_twice = 2;
const arg_overrun = 3;
const arg_after_free = 4;
const arg_crash = 5;
const arg_alert = 6;
const arg_wait = 7;

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

/// What the leaking task left, for the program to say.
var leaked: [3]?*anyopaque = @splat(null);
var leaker_id: u32 = 0;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [8]usize = @splat(0);
    const rda = dl.ReadArgs(TEMPLATE, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_leak] != 0) return leak(sys, dl);
    if (argv[arg_crash] != 0 or argv[arg_alert] != 0) return crash(sys, dl, argv[arg_crash] != 0);
    if (argv[arg_wait] != 0) return wait(sys, dl);
    if (argv[arg_overrun] != 0 or argv[arg_after_free] != 0) return misuse(sys, dl, argv[arg_overrun] != 0);
    if (argv[arg_wrong_size] != 0 or argv[arg_twice] != 0) return refused(sys, dl, argv[arg_wrong_size] != 0);
    return blocks(sys, dl);
}

/// The kinds of block, each one's MemBlock printed, all freed again.
fn blocks(sys: *ExecBase, dl: *DosBase) i32 {
    const me = sys.FindTask(null).?;
    _ = Printf(dl, "This task: \"%s\", number %u\n\n", .{ @as([*:0]const u8, me.node.name orelse "?"), me.id });
    _ = dl.PutStr("Block       Asked   MemBlock: owner      size  private\n");
    const free_before = sys.AvailMem(exec.MEMF_ANY);

    const shared = sys.AllocMem(100, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    const private = sys.AllocMem(100, exec.MEMF_PRIVATE) orelse return dos.RETURN_FAIL;
    const system = sys.AllocMem(100, exec.MEMF_SYSTEM) orelse return dos.RETURN_FAIL;
    sys.BeginSystemMemory();
    const inside = sys.AllocVec(100, exec.MEMF_ANY);
    sys.EndSystemMemory();
    const pool = sys.CreatePool(exec.MEMF_ANY, 1024, 0) orelse return dos.RETURN_FAIL;
    _ = sys.AllocPooled(pool, 16);
    show(dl, "shared", shared);
    show(dl, "private", private);
    show(dl, "MEMF_SYSTEM", system);
    if (inside) |block| show(dl, "BeginSystemMemory", block);
    show(dl, "a pool", pool);

    sys.DeletePool(pool);
    sys.FreeVec(inside);
    sys.FreeMem(system, 100);
    sys.FreeMem(private, 100);
    sys.FreeMem(shared, 100);
    const free_after = sys.AvailMem(exec.MEMF_ANY);
    if (free_after != free_before) {
        _ = Printf(dl, "\nfree memory %zu before, %zu after: not all came back\n", .{ free_before, free_after });
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "\nall freed: %zu bytes free before and after\n", .{free_after});
    return dos.RETURN_OK;
}

/// One block's line: its address, what was asked, and its MemBlock.
fn show(dl: *DosBase, what: [*:0]const u8, block: *anyopaque) void {
    const header = exec.MemBlock.of(block);
    const owner: [*:0]const u8 = if (header.owner == exec.MEMOWNER_SYSTEM) "system" else "task";
    _ = Printf(dl, "0x%08x  %-18s %-6s %3u  %4u  %s\n", .{
        @as(u32, @truncate(@intFromPtr(block))),
        what,
        owner,
        header.owner,
        @as(u32, @intCast(header.bytes())),
        @as([*:0]const u8, if (header.private()) "yes" else "no"),
    });
}

/// A task that allocates and ends without freeing, waited for.
fn leak(sys: *ExecBase, dl: *DosBase) i32 {
    const ended = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(ended);
    var end_message: exec.Message = .{ .reply_port = ended };
    const task = sys.CreateTask("MemOwner leak", 0, &leakingTask, 4096) orelse return dos.RETURN_FAIL;
    sys.SetTaskEndMsg(task, &end_message);
    leaker_id = task.id;
    // Gone - its end message back - before this program's code, which it
    // runs, may be unloaded.
    _ = sys.WaitPort(ended);
    _ = sys.GetMsg(ended);
    _ = Printf(dl, "task \"MemOwner leak\", number %u, has ended without freeing three blocks:\n", .{leaker_id});
    for (leaked, [_][*:0]const u8{ "2000 bytes", "3000 bytes, private", "5000 bytes" }) |block, what| {
        const kept = block orelse continue;
        const header = exec.MemBlock.of(kept);
        // The private one went as the task ended: its MemBlock is free
        // space's now, or another block's.
        const left = header.inUse() and header.owner == leaker_id;
        _ = Printf(dl, "  0x%08x  %-20s %s\n", .{
            @as(u32, @truncate(@intFromPtr(kept))),
            what,
            @as([*:0]const u8, if (left) "left" else "freed as it ended"),
        });
    }
    _ = Printf(dl, "Avail OWNERS, Top and MemMap show them as an ended task's, number %u\n", .{leaker_id});
    return dos.RETURN_OK;
}

fn leakingTask(sys: *ExecBase) callconv(.c) void {
    leaked[0] = sys.AllocMem(2000, exec.MEMF_ANY);
    leaked[1] = sys.AllocMem(3000, exec.MEMF_PRIVATE);
    leaked[2] = sys.AllocVec(5000, exec.MEMF_CLEAR);
}

/// A block written past its end, or after its free - for memory
/// debugging to find. Without a wall the block was not allocated with it
/// on, and nothing is done.
fn misuse(sys: *ExecBase, dl: *DosBase, overrun: bool) i32 {
    const size: usize = if (overrun) 100 else after_free_size;
    const block = sys.AllocMem(size, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    const header = exec.MemBlock.of(block);
    if (!header.walled()) {
        sys.FreeMem(block, size);
        _ = dl.PutStr("memory debugging is off: MemDebug ON first\n");
        return dos.RETURN_WARN;
    }
    const bytes: [*]volatile u8 = @ptrCast(block);
    if (overrun) {
        _ = dl.PutStr("one byte written past the end of a block of 100: FreeMem tells\n");
        _ = dl.Flush(dl.Output());
        bytes[100] = 0;
        sys.FreeMem(block, 100);
        return dos.RETURN_OK;
    }
    sys.FreeMem(block, size);
    const at = after_free_size - 40;
    bytes[at] = 0x55;
    _ = Printf(dl, "0x%08x written after its free: MemDebug CHECK finds it\n", .{@as(u32, @truncate(@intFromPtr(block) + at))});
    return dos.RETURN_OK;
}

/// AFTERFREE's block: large enough that the next few allocations take its
/// front and leave the write near its end alone.
const after_free_size = 64 * 1024;

/// A block freed wrongly - with another size, or twice - and exec's
/// refusal checked: the free memory does not change.
fn refused(sys: *ExecBase, dl: *DosBase, wrong_size: bool) i32 {
    const block = sys.AllocMem(100, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    if (wrong_size) {
        const free_before = sys.AvailMem(exec.MEMF_ANY);
        _ = dl.PutStr("FreeMem with 200 bytes for a block of 100: exec refuses it\n");
        _ = dl.Flush(dl.Output());
        sys.FreeMem(block, 200);
        const kept = sys.AvailMem(exec.MEMF_ANY) == free_before and exec.MemBlock.of(block).inUse();
        sys.FreeMem(block, 100);
        _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (kept) "refused: the block stayed, and was then freed with its own size" else "NOT refused")});
        return if (kept) dos.RETURN_OK else dos.RETURN_ERROR;
    }
    sys.FreeMem(block, 100);
    const free_before = sys.AvailMem(exec.MEMF_ANY);
    _ = dl.PutStr("FreeMem of a block freed already: exec refuses it\n");
    _ = dl.Flush(dl.Output());
    sys.FreeMem(block, 100);
    const kept = sys.AvailMem(exec.MEMF_ANY) == free_before;
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (kept) "refused: the free memory did not change" else "NOT refused")});
    return if (kept) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// What CRASH holds, in one shared block that outlives it: the public
/// semaphore WAIT waits for, and its name.
const Held = extern struct {
    semaphore: exec.SignalSemaphore = .{},
    name: [16]u8 = @splat(0),
};

const semaphore_name = "MemOwner";

/// A task that holds a semaphore, a window and private memory, and fails:
/// by a read from an address nothing answers, or a dead-end alert.
fn crash(sys: *ExecBase, dl: *DosBase, exception: bool) i32 {
    if (sys.FindSemaphore(semaphore_name) != null) {
        _ = dl.PutStr("the semaphore \"MemOwner\" is there already: MemOwner WAIT takes it away\n");
        return dos.RETURN_WARN;
    }
    const memory = sys.AllocMem(@sizeOf(Held), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    const held: *Held = @ptrCast(@alignCast(memory));
    held.* = .{};
    @memcpy(held.name[0..semaphore_name.len], semaphore_name);
    held.semaphore.link.name = @ptrCast(&held.name);
    sys.AddSemaphore(&held.semaphore);
    sys.ObtainSemaphore(&held.semaphore);
    const private = sys.AllocMem(4096, exec.MEMF_PRIVATE) orelse return dos.RETURN_FAIL;
    // A window where there is a screen for one; the failure comes anyway.
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0);
    const window = if (intuition_lib) |lib| @as(*IntuitionBase, @ptrCast(lib)).OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 80 },
        .{ .tag = wn.WA_Top, .data = 80 },
        .{ .tag = wn.WA_InnerWidth, .data = 320 },
        .{ .tag = wn.WA_InnerHeight, .data = 60 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("MemOwner: about to fail") },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{},
    }) else null;
    const me = sys.FindTask(null).?;
    _ = Printf(dl, "task %u holds the semaphore \"MemOwner\" at 0x%08x, %s, and 4096 private bytes at 0x%08x\n", .{
        me.id,
        @as(u32, @truncate(@intFromPtr(&held.semaphore))),
        @as([*:0]const u8, if (window != null) "a window" else "no window (no screen)"),
        @as(u32, @truncate(@intFromPtr(private))),
    });
    _ = Printf(dl, "%s in two seconds: Software Failure - Kill ends the task (or s3> kill %u)\n", .{
        @as([*:0]const u8, if (exception) "a read from an address nothing answers" else "a dead-end alert"),
        me.id,
    });
    _ = dl.Flush(dl.Output());
    dl.Delay(100); // two seconds: 50 ticks a second
    if (exception) {
        const nowhere: *const volatile u32 = @ptrFromInt(0x10);
        _ = nowhere.*;
    } else {
        sys.Alert(exec.AT_DeadEnd | exec.AN_ProgramPanic);
    }
    return dos.RETURN_FAIL;
}

/// The semaphore CRASH holds, waited for, and taken away once had.
fn wait(sys: *ExecBase, dl: *DosBase) i32 {
    const semaphore = sys.FindSemaphore(semaphore_name) orelse {
        _ = dl.PutStr("no semaphore \"MemOwner\": MemOwner CRASH makes it\n");
        return dos.RETURN_WARN;
    };
    _ = Printf(dl, "waiting for the semaphore \"MemOwner\" at 0x%08x\n", .{@as(u32, @truncate(@intFromPtr(semaphore)))});
    _ = dl.Flush(dl.Output());
    sys.ObtainSemaphore(semaphore);
    _ = dl.PutStr("got it: its holder let it go, or ended\n");
    sys.ReleaseSemaphore(semaphore);
    sys.RemSemaphore(semaphore);
    const held: *Held = @fieldParentPtr("semaphore", semaphore);
    sys.FreeMem(held, @sizeOf(Held));
    return dos.RETURN_OK;
}
