// SPDX-License-Identifier: MPL-2.0
//! exec.library as a library: its base and its four standard vectors.
//!
//! struct ExecBase is exec.library's base, and so SysBase. The Library
//! header comes first, as every base's does; everything after it is exec's
//! own, and opaque to a module - a module reaches exec through the jump
//! table only, with `iface()`.
//!
//! The four standard library vectors - Open, Close, Expunge and ExtFunc -
//! start every library's jump table: exec.library's own, and any library's
//! that needs nothing special, which puts them in its own table.
//! exec.library uses them all but the Expunge, and has its own here
//! instead: exec never goes. They are a library's vectors rather than
//! exec's calls, so each takes the library's own base first, as every
//! library vector does.

const builtin = @import("builtin");
const std = @import("std");
const sdk = @import("sdk");
const exec = @import("exec.zig");
const _interrupt = @import("interrupt/_interrupt.zig");
const _library = @import("library/_library.zig");
const _log = @import("log/_log.zig");
const _waitable = @import("waitable/_waitable.zig");
const _workers = @import("task/_workers.zig");
const _memory = @import("memory/_memory.zig");
const _failure = @import("failure/_failure.zig");

const interface = sdk.interface.exec;
const IntVector = sdk.exec.IntVector;
const Library = sdk.exec.Library;
const List = sdk.exec.List;
const Resident = sdk.exec.Resident;
const Task = sdk.exec.Task;

/// Whether this is the system's own code rather than a host build (the
/// tests): an ARM host is AArch64 too.
const on_machine = builtin.os.tag == .freestanding;

/// The core's cycle counter; none on the host.
pub inline fn cycles() u32 {
    if (comptime !on_machine) return 0;
    return sdk.hardware.cpu.ccount();
}

/// The core this code runs on: 0 or 1. On the Xtensa from PRID (0xCDCD
/// for core 0, 0xABAB for core 1 - bit 13 tells them apart), on the
/// ESP32-P4 from mhartid, under SBI firmware from tp, under PSCI firmware
/// from TPIDR_EL1, on x86-64 from the block GS points at. The host tests
/// have one.
pub inline fn coreId() u32 {
    switch (comptime builtin.cpu.arch) {
        .xtensa => {
            const prid = asm volatile ("rsr %[prid], prid"
                : [prid] "=r" (-> u32),
            );
            return (prid >> 13) & 1;
        },
        .riscv32 => return asm volatile ("csrr %[id], mhartid"
            : [id] "=r" (-> u32),
        ),
        // Supervisor mode cannot read mhartid, and a hart is not a core:
        // each core keeps its number in tp (src/arch/rv64sbi/cpu.zig).
        .riscv64 => return @truncate(asm volatile ("mv %[id], tp"
            : [id] "=r" (-> u64),
        )),
        // An AArch64 core keeps its number in TPIDR_EL1, which nothing
        // else uses at EL1 (src/arch/a64psci/cpu.zig).
        .aarch64 => {
            if (comptime !on_machine) return 0;
            return @truncate(asm volatile ("mrs %[id], tpidr_el1"
                : [id] "=r" (-> u64),
            ));
        },
        // An x86-64 core has no register that says which core it is: each
        // keeps its number in the block GS points at
        // (src/arch/x64uefi/cpu.zig).
        .x86_64 => {
            if (comptime !on_machine) return 0;
            return @truncate(asm volatile ("movq %%gs:0, %[id]"
                : [id] "=r" (-> u64),
            ));
        },
        else => return 0,
    }
}

/// Where a core's line on the raw port stands, as both exec's output and
/// the log write it: the next character starts a line, and gets the time
/// and the writer in front of it; a `LOG_MARK` started the line, so the
/// next character is its level; the line being written is below the level
/// kept, and goes nowhere.
pub const OutLine = extern struct {
    start: bool = true,
    marked: bool = false,
    dropping: bool = false,
};

/// What each core has of its own: the task it runs, its Disable state and
/// its share of the system's two locks, its scheduling flags and time
/// slice, how deep it is in exceptions, its counts, and the spinlocks it
/// holds. A task reads its
/// core's state with the core's interrupts masked or in an exception, so
/// that it is not moved to the other core between finding the state and
/// using it.
pub const CpuState = extern struct {
    /// The tasks this core has: those ready to run, by priority, and
    /// those waiting for a signal. They are the core's own - a task is on
    /// the lists of the core that owns it (`Task.owner`), and the core
    /// takes the first of its ready list it may run. A core with nothing
    /// ready takes a task from another core's lists instead
    /// (`stealReady`), which is what spreads the work.
    ///
    /// First in the state, and a cache line of its own: each core's state
    /// is a whole number of lines and starts on one (`cpus_at`), so no
    /// two cores' locks share a line - a core taking its own would
    /// otherwise pull the line out from under the core beside it.
    tasks: sdk.exec.CoreTasks align(line) = .{},
    /// The lock over `tasks`: 0, or the core holding them plus one. The
    /// core's own dispatcher takes it, and so does another core signalling
    /// a task of this one's or taking one away. A core holds one core's
    /// lists at a time - its own or another's, never two - which is what
    /// keeps two cores from waiting on each other.
    tasks_lock: u32 = 0,
    /// How deep this core is in the lists it holds, 0 for none, and
    /// whose they are. **This is what says whether the core holds any**,
    /// rather than a lock word that every core writes.
    tasks_depth: u32 = 0,
    tasks_which: u32 = 0,
    /// The highest priority ready on this core, written by the core
    /// itself whenever its ready list changes (`noteReady`), below every
    /// priority when nothing is. It is what another core reads to see
    /// whether there is work here worth taking: a list it does not hold
    /// is not its to walk, since a node it read could be a task already
    /// freed, but one word of this core's says enough.
    ready_pri: i32 = -129,
    /// The priority of the task this core runs, written by the core
    /// itself as it takes one. Another core reads this word rather than
    /// the task behind `this_task`, which it does not hold the lock for:
    /// a task that is switched away from and ends is memory that core no
    /// longer owns, and one word of this core's says what is wanted.
    running_pri: i32 = -129,
    /// ThisTask: the task running on this core.
    this_task: *Task = undefined,
    /// The core's idle task, pinned to it, which runs when nothing else is
    /// ready: what its time is counted against (`time_idle`).
    idle_task: ?*Task = null,
    /// IDNestCnt: Disable() nesting, -1 when interrupts are enabled.
    id_nest_cnt: i8 = -1,
    /// Exception nesting: the dispatcher runs only at the outermost
    /// exception exit, so an interrupt inside another cannot switch tasks.
    int_depth: u8 = 0,
    /// Spinlocks this core holds: while there are any, its task is not
    /// switched away (AcquireLock).
    hold_count: u8 = 0,
    /// Interrupt state from the outermost Disable, put back by the
    /// outermost Enable - so an Enable never turns interrupts on in a
    /// context that had them off.
    id_saved: u32 = 0,
    /// The same for the task lists' lock, which is taken from task level
    /// as Disable is (`LockExecList`, Signal, Wait).
    lists_saved: u32 = 0,
    /// How often this core has taken the system's interrupt lock beyond
    /// the first: it nests, since an interrupt handler holds it and the
    /// code it runs takes it again. The core's, not a task's - it is
    /// taken with the core's interrupts masked.
    sys_nest: u32 = 0,
    /// SysFlags: SFF_SAR, SFF_TQE. Elapsed: what is left of the slice.
    sys_flags: u16 = 0,
    elapsed: u16 = 0,
    /// IdleCount, DispCount.
    idle_count: u32 = 0,
    disp_count: u32 = 0,
    /// The cache engine's lock as this core has seen it (`CacheClearE`):
    /// the longest it waited for it and the longest it held it, in cycles,
    /// and when it took it.
    engine_wait_max: u32 = 0,
    engine_held_max: u32 = 0,
    engine_taken_at: u32 = 0,
    /// Where the core's line on the raw port stands (`rawio/_rawio.zig`).
    out_line: OutLine = .{},
    /// The spinlocks the core holds, the latest last (AcquireLock): what
    /// the lock rules are checked against. They are the core's, not a
    /// task's - a holder is not switched away while it holds them.
    locks_held: [sdk.exec.locks.LOCKS_HELD_MAX]?*sdk.exec.Lock = @splat(null),
    lock_count: u32 = 0,
    /// Tasks that ended on the core, chained through their nodes, their
    /// memory still to be freed: at its next exception exit, the first
    /// moment it no longer runs on their stacks, or a later one if the
    /// memory lock is held then.
    reap: ?*Task = null,
    /// The core's time so far, in cycles of its clock: in tasks, in its
    /// idle task, in exceptions (`ReadCoreTimes`). Added to at the
    /// outermost exception entry and exit, from `time_mark`, the clock
    /// when the core last went from one to another.
    time_tasks: u64 align(4) = 0,
    time_idle: u64 align(4) = 0,
    time_interrupts: u64 align(4) = 0,
    time_mark: u32 = 0,
    /// How the system's interrupt lock fares on this core, in cycles, kept
    /// as the worst seen until `s3> cores reset`: the longest the core held
    /// it and the longest it waited for it, each with the code that took
    /// it (1 for an exception). These are what make an interrupt late.
    lock_held_max: u32 = 0,
    lock_held_where: usize = 0,
    lock_wait_max: u32 = 0,
    lock_wait_where: usize = 0,
    lock_taken_at: u32 = 0,
    lock_taker: usize = 0,
    /// How the task lists' lock fares on this core, kept the same way:
    /// the longest held and the longest waited for, each with the code
    /// that took it (1 for an exception's dispatcher, 2 for what a
    /// switch left behind, 3 for the time slice).
    lists_held_max: u32 = 0,
    lists_held_where: usize = 0,
    lists_wait_max: u32 = 0,
    lists_wait_where: usize = 0,
    lists_taken_at: u32 = 0,
    lists_taker: usize = 0,
    /// The core's task another core's RemTask is taking away, switched out
    /// at its next switch point; once it is, `stopped` until the next exit,
    /// which signals `stop_waiter`, the task taking it away.
    stopping: ?*Task = null,
    stopped: ?*Task = null,
    stop_waiter: ?*Task = null,
};

/// A core's state is a whole number of cache lines and starts on one:
/// the aligned field in it says so, and the memory it is cut from is
/// lined up to match (`coresStateAt`).
const line = sdk.hardware.DCACHE_LINE_SIZE;

/// The memory `cores` core states take, with room to line the first one
/// up: what the kernel asks the allocator for before exec exists.
pub fn coresStateSize(cores: u32) usize {
    return cores * @sizeOf(CpuState) + line - 1;
}

/// The core states inside `block`, which `coresStateSize` asked for: the
/// first state on the first cache line in it, so that each core's lock
/// has lines no other core writes.
pub fn coresStateAt(block: *anyopaque) [*]CpuState {
    const at = (@intFromPtr(block) + line - 1) & ~@as(usize, line - 1);
    return @ptrFromInt(at);
}

/// struct ExecBase (the part that exists so far).
pub const ExecBase = extern struct {
    lib: Library,
    /// MemList: memory regions (MemHeader), by priority.
    mem_list: List,
    /// MemHandlers: low-memory handlers (Interrupt), by priority.
    mem_handlers: List,
    /// LibList
    lib_list: List,
    /// DeviceList: devices, by priority.
    device_list: List,
    /// ResourceList: resources (OpenResource), by priority.
    resource_list: List,
    /// PortList: public message ports (MsgPort), by priority.
    port_list: List,
    /// SemaphoreList: public signal semaphores, by priority.
    sem_list: List,
    /// IntVects: one per interrupt number.
    int_vects: [sdk.hardware.intbits.INTB_COUNT]IntVector,
    /// SoftInts: queued software interrupts, one list per priority
    /// (-32, -16, 0, 16, 32).
    soft_ints: [_interrupt.softint_priorities.len]List,
    /// The task the boot code became on core 0, "kernel".
    boot_task: ?*Task,
    /// The last number `AddTask` gave a task (`Task.id`); 0 before the
    /// first, which is MEMOWNER_SYSTEM and never given. Under Disable.
    task_ids: u32,
    /// Quantum: time slice in ticks.
    quantum: u16,
    /// ResModules: the resident modules by priority, null-terminated; set
    /// by initResidents.
    res_modules: ?[*]?*const Resident,
    /// The bytes `res_modules` was allocated with, so it is freed with
    /// them.
    res_modules_size: usize,
    /// The memory trace (`s3> memtrace`): what AllocMem and FreeMem have
    /// counted since it was started. All off until then, as the base is
    /// made cleared.
    mem_trace: _memory.Trace,
    /// Memory debugging (`MemDebug`): off until switched on, as the
    /// base is made cleared.
    mem_debug: _memory.Debug,
    /// The Software Failure requester (failure/_failure.zig): its helper
    /// task and the failure it asks about. Cleared with the base: no
    /// helper until the kernel starts it.
    failure: _failure.State,
    /// The loader's base, kept for whatever loads libraries and devices
    /// from a disk: one word a module has nowhere else to put, since this
    /// structure is opaque to it and a module keeps nothing in its own
    /// image. exec calls one function through it - ramlib.library's
    /// UnLoadModule, with the segments of a module that went. Null until
    /// SetRamLib is called.
    ram_lib: ?*anyopaque = null,
    /// The tasks woken when the system log grows (SetLogSignal).
    log_followers: [_log.max_followers]_log.Follower = @splat(.{}),
    /// How far the log was when the followers were last signalled, and the
    /// ticks that pace the signals.
    log_told: u64 align(4) = 0,
    log_ticks: u32 = 0,
    /// The tasks in WaitForAny, by a record on each one's stack
    /// (waitable/_waitable.zig). Under Disable.
    waiting: ?*_waitable.Record = null,
    /// The worker task on each core that ShareWork hands parts to
    /// (task/_workers.zig).
    workers: _workers.Pool = .{},
    /// exec's own spinlocks, a domain each (locks/_locks.zig): the
    /// semaphores - their counts and queues, and the public list; the
    /// memory - its regions and what is free in them.
    lock_semaphores: sdk.exec.Lock = .{},
    lock_memory: sdk.exec.Lock = .{},
    /// ... and the ports: every port's message list and the public list;
    /// a LOCKF_INTERRUPT lock, since interrupts send and reply.
    lock_ports: sdk.exec.Lock = .{},
    /// exec's semaphores, for the lists whose holder runs other code: the
    /// libraries, devices and resources (library/_library.zig) - each
    /// library has a lock of its own besides, for its vectors - and the
    /// memory handlers, which AllocMem runs when memory runs short.
    sem_libraries: sdk.exec.SignalSemaphore = .{},
    sem_memhandlers: sdk.exec.SignalSemaphore = .{},
    /// exec's own low-memory handler, on `mem_handlers`: libraries and
    /// devices nobody has open, expunged (`initExec` sets it up).
    library_flusher: sdk.exec.Interrupt = .{},
    /// The system's interrupt lock, the holding core and one or 0:
    /// Disable's and the interrupt dispatch's. A core holds it while one
    /// of its tasks is inside Disable, and while it runs an interrupt
    /// handler or a software interrupt, so a Disable on one core holds
    /// off what interrupts do on every other.
    disable_lock: u32 = 0,
    /// 0 until the kernel lets multitasking start (`startMultitasking`):
    /// until then no core switches away from a running task.
    multitasking: u32 = 0,
    /// How many cores are taking tasks, and whether the cores but core 0
    /// take any task rather than only those pinned to them. The kernel
    /// lets the others share once the system has started.
    cores_running: u32 = 1,
    share_cores: u32 = 0,
    /// The word a lock in PSRAM is taken under, where this chip has no
    /// atomic store (locks/_locks.zig). In internal memory, as the base
    /// is.
    lock_guard: u32 = 0,

    /// Each core's own state (CpuState), one for every core the system
    /// was started to run on: a block of its own, cut when exec was built,
    /// since how many cores a machine has is not known until the kernel
    /// has looked.
    cpus_at: [*]CpuState = undefined,
    /// What that was cut from, which is where it is given back: the
    /// states start on a cache line, and the memory under them starts
    /// wherever the allocator had room.
    cpus_block: ?*anyopaque = null,
    /// How many there are, which is the most `coreId` may answer.
    cores_state: u32 = 0,

    /// This core's own state. A task reads it with its interrupts masked,
    /// or holding a spinlock: otherwise it may be moved to the other core
    /// between asking which core it is on and reading.
    pub inline fn cpu(base: *ExecBase) *CpuState {
        return &base.cpus_at[coreId()];
    }

    /// Every core's state, as many as there are.
    pub inline fn cpus(base: *ExecBase) []CpuState {
        return base.cpus_at[0..base.cores_state];
    }

    /// exec through its own jump table, the way everything else calls it.
    pub fn iface(base: *ExecBase) *interface.ExecBase {
        return @ptrCast(base);
    }
};

// --- the standard library vectors -------------------------------------------

/// Standard Open: counts the opener and cancels a pending expunge, so a
/// library marked to go is reprieved by being opened again.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it.
/// - `version` - what the opener asked for; `OpenLibrary` has already
///   refused a library older than that, so it is not looked at here.
///
/// RESULT:
/// The library's base.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; `OpenLibrary` calls it inside the library's lock.
/// - Locks: called inside the library's own lock, which keeps every other Open
///   and Close of it out.
/// - Process: a Task will do.
pub fn libOpen(lib: *Library, version: u32) callconv(.c) ?*Library {
    _ = version;
    lib.open_cnt += 1;
    lib.flags &= ~sdk.exec.LIBF_DELEXP;
    return lib;
}

/// Standard Close: drops the open count. An expunge asked for while the
/// library was open is `CloseLibrary`'s to carry out once this has
/// answered - through the library's own Expunge vector, so a library that
/// replaced it is asked.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it.
///
/// RESULT:
/// Null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; `CloseLibrary` calls it inside the library's lock.
/// - Locks: called inside the library's own lock, which keeps every other Open
///   and Close of it out.
/// - Process: a Task will do.
pub fn libClose(lib: *Library) callconv(.c) ?*anyopaque {
    lib.open_cnt -= 1;
    return null;
}

/// Standard Expunge: while open, only mark it for later (`LIBF_DELEXP`),
/// so the last `CloseLibrary` finishes the job; otherwise take it off the
/// library list (`DetachLibrary`) and free it.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it.
///
/// RESULT:
/// Null: a library in the ROM has no seglist to hand back.
///
/// CONTEXT:
/// - Waits: for exec's library list, at the detach; nothing else.
/// - Interrupts: no.
/// - Locks: called inside the library's own lock while it is open, and with
///   nothing held once it is marked going.
/// - Process: a Task will do.
///
/// BUGS:
/// It reaches exec through `SysBase`, the kernel's global: a library vector
/// is handed its own base, and a library keeps no pointer to exec's.
pub fn libExpunge(lib: *Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= sdk.exec.LIBF_DELEXP;
        return null;
    }
    const base = exec.SysBase;
    base.iface().DetachLibrary(lib);
    _library.freeLibraryMemory(base, lib);
    return null;
}

/// exec.library's Expunge: it refuses, always. exec is the machine - its
/// base, its jump table and every list it keeps - so there is nothing that
/// could go on running once it had gone.
///
/// The refusal is read from the library still being on the list, which is
/// how `flushLibraries` leaves exec.library where it is when memory runs
/// out, whatever its open count. `libExpunge` in its slot would free exec's
/// own base the first time the count stood at 0.
///
/// INPUTS:
/// - `lib` - exec.library, as every library vector gets it; not looked at.
///
/// RESULT:
/// Null: nothing was expunged, so there is no seglist to hand back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it touches nothing.
/// - Locks: none needed.
/// - Process: a Task will do.
pub fn execExpunge(lib: *Library) callconv(.c) ?*anyopaque {
    _ = lib;
    return null;
}

/// Standard ExtFunc: the reserved fourth vector, which does nothing.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it; not looked at.
///
/// RESULT:
/// Null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it touches nothing.
/// - Locks: none needed.
/// - Process: a Task will do.
pub fn libExtFunc(lib: *Library) callconv(.c) ?*anyopaque {
    _ = lib;
    return null;
}
