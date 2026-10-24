// SPDX-License-Identifier: MPL-2.0
//! exec's ROM tag, and the init routine it names.
//!
//! The bootstrap (src/bootstrap.zig) finds the tag by its name, builds
//! exec.library from its InitTable - the jump table is exec_lvo.zig's - and
//! calls `initExec`, which makes the rest of the machine: the lists, exec
//! on the library list, the memory handler, the boot and idle tasks, and
//! then the system start: the ROM scan, the exec task and the residents of
//! each start class.
//!
//! The tag is an export in `.resident`, found there by its address, so
//! whoever compares a tag with it takes it from this file.

const std = @import("std");
const sdk = @import("sdk");
const exec = @import("exec.zig");
const exec_lvo = @import("exec_lvo.zig");
const _library = @import("library/_library.zig");
const _resident = @import("resident/_resident.zig");
const _task = @import("task/_task.zig");
const _workers = @import("task/_workers.zig");
const _locks = @import("locks/_locks.zig");

const ExecBase = exec.ExecBase;
const InitTable = sdk.exec.InitTable;
const Library = sdk.exec.Library;
const Resident = sdk.exec.Resident;
const vec = sdk.exec.vec;

/// What exec is on the library list as, and what `OpenLibrary` finds it
/// by. Nothing opens it in practice - every module is handed SysBase - but
/// it is on the list like everything else.
pub const LIBRARY_NAME = "exec.library";
pub const LIBRARY_VERSION = 1;
/// 1: end hooks in the TCB (AddTaskEndHook, RemTaskEndHook), run by
/// RemTask. 2: the system log's levels and settings (LogControl), its
/// ring as large as the board says, six followers. 3: spinlocks
/// (InitLock, AcquireLock, AttemptLock, ReleaseLock) and their rules,
/// checked on every call; the semaphores, the memory and the ports kept
/// under exec's own locks. 4: the second
/// core - its own state, its own dispatcher, HoldOtherCores and
/// ReleaseOtherCores, SetTaskAffinity and CoreTask. 5: each core's time
/// in tasks, idle and in interrupts (ReadCoreTimes). 6: every list under a
/// lock of its own - LockExecList and UnlockExecList for a program that
/// walks one, a library's own lock and pin around its vectors,
/// DetachLibrary - SetTaskEndMsg and RemoveMsg, and Forbid and Permit gone.
/// 7: SafePutToPort. 8: DoIO and SendIO keep the command's flags. 9: on a
/// RISC-V chip, every core fences its instruction fetch after the
/// instruction caches are invalidated (CacheClearU, CacheClearE). 10:
/// each task's own time (Task.timeRun), counted as the cores' are. 11:
/// every block has an owner (MemBlock), BeginSystemMemory,
/// EndSystemMemory, SetMemOwner, and memory debugging. 12: a task's end
/// gives back its semaphores (Task.holds) and its private memory; Kill
/// (the Software Failure requester, now exec's on every chip); MemDebug,
/// and memory debugging from the start (BOOTF_MEMDEBUG). 13: CopyMem,
/// CopyMemQuick and SetMem a word at a time, shifting where the two
/// areas are differently aligned; they are the kernel's memcpy, memmove
/// and memset, and a program's. 14: waitables - SignalWaitable,
/// ResetWaitable, and WaitForAny, which waits for any of several and for
/// no longer than it is told. 15: ShareWork, a job done by a worker task
/// on each core at once; CacheClearE, CachePreDMA and CachePostDMA share
/// a long range between them where the cores each drive the cache
/// controller, and on the JH7110 CacheClearE writes a range back once,
/// since its write-back drops the lines as well. 16: the Software Failure
/// requester's screen is brought in front of the others. 17: the ROM
/// debugger runs on a stack of its own and lists exec's lists - the rows
/// `s3>` shows, read with no lock and every node checked. 18: a released
/// semaphore's grant is the last thing the releaser touches of the
/// waiter's request, which is on the waiter's stack; a task alone on its
/// core has its stack checked as each slice ends, as a switch would. 19:
/// on an AArch64 machine whose devices see the caches (SYSTAG_DmaCoherent,
/// QEMU's virt), CacheClearE, CachePreDMA and CachePostDMA leave the data
/// caches alone.
pub const LIBRARY_REVISION = 19;
const BUILD_DATE = "24.10.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const exec_init_table = InitTable{
    .data_size = @sizeOf(ExecBase),
    .vectors = &exec_lvo.exec_vectors,
    .vector_count = exec_lvo.exec_vectors.len,
    .init = &initExec,
};

/// exec's own ROM tag. The bootstrap (src/bootstrap.zig, outside exec)
/// finds it by name and builds exec.library from its InitTable with
/// Allocate, since AllocMem needs a SysBase. It puts the memory regions on
/// MemList and calls initExec. RTF_AUTOINIT because rt_Init is an
/// InitTable. No start class: InitCode never starts it, and InitResident
/// refuses it.
pub export const exec_tag: Resident linksection(".resident") = .{
    .match_tag = &exec_tag,
    .flags = sdk.exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 126,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &exec_init_table,
};

/// exec's init routine. The bootstrap has built the
/// base from exec_tag (name, version and ID string are in) and put the
/// memory regions on MemList. This sets up the rest: the lists, exec on
/// LibList, the memory handler, the boot and idle tasks. With a BootInfo it
/// switches memory debugging on where BOOTF_MEMDEBUG asks, right after
/// those two tasks, and goes on with the system start.
fn initExec(lib: *Library, seg_list: ?*anyopaque, _: *exec.interface.ExecBase) callconv(.c) ?*Library {
    // First the raw serial port, for kprintf: nothing is printed before.
    // Direct, not through the table: SysBase is set further down, so there
    // is nothing to call a vector through yet (codex rule 1).
    const sys: *ExecBase = @fieldParentPtr("lib", lib);
    exec.RawIOInit(sys);
    // Every core's own state as it starts: no Disable, no locks held.
    sys.cpus = @splat(.{});
    sys.log_followers = @splat(.{});
    sys.log_told = 0;
    sys.log_ticks = 0;
    sys.lock_guard = 0;
    // One core running and nothing held: the base is allocated, not made
    // from the struct's defaults. A second core counts itself in when it
    // starts.
    sys.disable_lock = 0;
    sys.multitasking = 0;
    sys.cores_running = 1;
    sys.share_cores = 0;
    exec.InitLock(sys, &sys.lock_semaphores, "exec semaphores", _locks.order_semaphores, 0);
    exec.InitLock(sys, &sys.lock_memory, "exec memory", _locks.order_memory, 0);
    exec.InitLock(sys, &sys.lock_ports, "exec ports", _locks.order_ports, sdk.exec.LOCKF_INTERRUPT);
    exec.InitSemaphore(sys, &sys.sem_libraries);
    exec.InitSemaphore(sys, &sys.sem_memhandlers);
    sys.lib_list.init(.library);
    sys.device_list.init(.device);
    sys.resource_list.init(.resource);
    sys.port_list.init(.msgport);
    sys.sem_list.init(.signalsem);
    sys.mem_handlers.init(.interrupt);
    for (&sys.int_vects) |*v| v.servers.init(.interrupt);
    for (&sys.soft_ints) |*queue| queue.init(.softint);
    lib.revision = LIBRARY_REVISION;
    exec.SysBase = sys;
    // From here the table exists, so exec calls itself through it.
    const sys_base = sys.iface();
    // The tasks first: adding takes the library list's semaphore, and a
    // semaphore is held by a task.
    _task.initTasks(sys) catch return null;
    const boot_info: ?*const exec.BootInfo = @ptrCast(@alignCast(seg_list));
    // Memory debugging from here, where the kernel was built for it: the
    // first blocks walled are the library list's and the residents'.
    if (boot_info) |boot| {
        if (boot.flags & exec.BOOTF_MEMDEBUG != 0) _ = sys_base.MemDebug(sdk.exec.MEMDEBUG_ON, null, null, 0);
    }
    sys_base.AddLibrary(lib);
    // When memory runs out, the libraries and devices nobody has open are
    // expunged. Priority 0, so a handler that frees something cheaper - a
    // cache, a buffer - can be given a higher one and be asked first. It
    // finds exec's base in its data.
    sys.library_flusher = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "library flusher" },
        .data = sys,
        .code = vec(_library.flushLibraries),
    };
    sys_base.AddMemHandler(&sys.library_flusher);
    exec.initialized = true;
    const boot = boot_info orelse return lib;
    // Before any resident runs: from here code without a base finds exec.
    if (boot.abs_exec_base != 0) {
        const cell: *volatile *ExecBase = @ptrFromInt(boot.abs_exec_base);
        cell.* = sys;
    }
    startSystem(sys, boot) catch return null;
    return lib;
}

/// initExec's second half, the system start: scans the ROM tags, creates
/// the exec task, and starts the RTF_SINGLETASK residents. Multitasking is
/// not started yet (`ExecBase.multitasking`), so the exec task waits for
/// the kernel's `startMultitasking`.
///
/// INPUTS:
/// - `base` - exec, just made.
/// - `boot` - where the other ROM tags are.
pub fn startSystem(base: *ExecBase, boot: *const exec.BootInfo) error{OutOfMemory}!void {
    const sys_base = base.iface();
    base.multitasking = 0;
    try _resident.initResidents(base, boot.rom_start, boot.rom_end);
    const exec_task = sys_base.CreateTask("exec", exec_task_pri, &execTask, exec_task_stack) orelse
        return error.OutOfMemory;
    // It makes the COLDSTART residents: what they allocate is the system's.
    _task.makeSystemTask(exec_task);
    _ = sys_base.InitCode(sdk.exec.RTF_SINGLETASK, 0);
}

/// Above the boot task: the exec task runs as soon as multitasking starts.
const exec_task_pri = 5;
const exec_task_stack = 16 * 1024;

/// The exec task. It makes the workers ShareWork hands parts to, a task
/// on each core. The RTF_COLDSTART residents need multitasking and a
/// proper stack, so they start here. The last one is dos.library, whose
/// init starts the RTF_AFTERDOS residents. Then the task returns and ends
/// quietly: RemTask frees it.
pub fn execTask(_: *exec.interface.ExecBase) callconv(.c) void {
    _workers.setUp(exec.SysBase);
    _ = exec.SysBase.iface().InitCode(sdk.exec.RTF_COLDSTART, 0);
}
