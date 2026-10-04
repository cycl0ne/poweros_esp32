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
const sdk = @import("sdk");
const exec = @import("exec.zig");
const _interrupt = @import("interrupt/_interrupt.zig");
const _library = @import("library/_library.zig");
const _log = @import("log/_log.zig");

const interface = sdk.interface.exec;
const IntVector = sdk.exec.IntVector;
const Library = sdk.exec.Library;
const List = sdk.exec.List;
const Resident = sdk.exec.Resident;
const Task = sdk.exec.Task;

/// How many cores exec keeps state for. A one-core ROM uses the first.
pub const max_cores = 2;

/// The core this code runs on: 0 or 1, from PRID (0xCDCD for core 0,
/// 0xABAB for core 1 - bit 13 tells them apart). The host tests have one.
pub inline fn coreId() u32 {
    if (comptime builtin.cpu.arch != .xtensa) return 0;
    const prid = asm volatile ("rsr %[prid], prid"
        : [prid] "=r" (-> u32),
    );
    return (prid >> 13) & 1;
}

/// What each core has of its own: the task it runs, its Forbid and
/// Disable state, its scheduling flags and time slice, how deep it is in
/// exceptions, its counts, and the spinlocks it holds. A task reads its
/// core's state with the core's interrupts masked or in an exception, so
/// that it is not moved to the other core between finding the state and
/// using it.
pub const CpuState = extern struct {
    /// ThisTask: the task running on this core.
    this_task: *Task = undefined,
    /// TDNestCnt: Forbid() nesting, -1 when task switching is allowed.
    tdn_nest_cnt: i8 = -1,
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
    /// SysFlags: SFF_SAR, SFF_TQE. Elapsed: what is left of the slice.
    sys_flags: u16 = 0,
    elapsed: u16 = 0,
    /// IdleCount, DispCount.
    idle_count: u32 = 0,
    disp_count: u32 = 0,
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
    /// The core's task another core's RemTask is taking away, switched out
    /// at its next switch point; once it is, `stopped` until the next exit,
    /// which signals `stop_waiter`, the task taking it away.
    stopping: ?*Task = null,
    stopped: ?*Task = null,
    stop_waiter: ?*Task = null,
};

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
    /// TaskReady: ready tasks by priority. TaskWait: waiting tasks.
    task_ready: List,
    task_wait: List,
    /// Quantum: time slice in ticks.
    quantum: u16,
    /// ResModules: the resident modules by priority, null-terminated; set
    /// by initResidents.
    res_modules: ?[*]?*const Resident,
    /// The loader's base, kept for whatever loads libraries and devices
    /// from a disk. exec never looks at what it points to: it is one word
    /// a module has nowhere else to put, since this structure is opaque to
    /// it and a module keeps nothing in its own image. Null until
    /// SetRamLib is called.
    ram_lib: ?*anyopaque = null,
    /// The tasks woken when the system log grows (SetLogSignal).
    log_followers: [_log.max_followers]_log.Follower = @splat(.{}),
    /// How far the log was when the followers were last signalled, and the
    /// ticks that pace the signals.
    log_told: u64 align(4) = 0,
    log_ticks: u32 = 0,
    /// exec's own spinlocks, a domain each (locks/_locks.zig): the
    /// semaphores - their counts and queues, and the public list; the
    /// memory - its regions and what is free in them.
    lock_semaphores: sdk.exec.Lock = .{},
    lock_memory: sdk.exec.Lock = .{},
    /// ... and the ports: every port's message list and the public list;
    /// a LOCKF_INTERRUPT lock, since interrupts send and reply.
    lock_ports: sdk.exec.Lock = .{},
    /// The system's two big locks, each the holding core and one or 0.
    /// `disable_lock` is Disable's and the interrupt dispatch's: a core
    /// holds it while one of its tasks is inside Disable or while it is in
    /// an exception, so a Disable on one core holds off what interrupts do
    /// on the other. `forbid_lock` is Forbid's: a core holds it while its
    /// task is inside Forbid, so two Forbid sections never run at once.
    disable_lock: u32 = 0,
    forbid_lock: u32 = 0,
    /// A bit per core that waits for `forbid_lock`: a task of it in
    /// Forbid, or a dispatcher that passed over a task inside Forbid. The
    /// Permit that lets the lock go pokes each of them.
    forbid_waiters: u32 = 0,
    /// How many cores are taking tasks, and whether core 1 takes any task
    /// rather than only those pinned to it. The kernel lets the second
    /// core share once the system has started.
    cores_running: u32 = 1,
    share_cores: u32 = 0,
    /// The word a lock in PSRAM is taken under, where this chip has no
    /// atomic store (locks/_locks.zig). In internal memory, as the base
    /// is.
    lock_guard: u32 = 0,

    /// Each core's own state (CpuState).
    cpus: [max_cores]CpuState = @splat(.{}),

    /// This core's own state. A task reads it with its interrupts masked,
    /// or inside Forbid: otherwise it may be moved to the other core
    /// between asking which core it is on and reading.
    pub inline fn cpu(base: *ExecBase) *CpuState {
        return &base.cpus[coreId()];
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
/// - Interrupts: no; `OpenLibrary` calls it under Forbid.
/// - Forbid: held by the caller.
/// - Process: a Task will do.
pub fn libOpen(lib: *Library, version: u32) callconv(.c) ?*Library {
    _ = version;
    lib.open_cnt += 1;
    lib.flags &= ~sdk.exec.LIBF_DELEXP;
    return lib;
}

/// Standard Close: drops the open count, and the last close carries out an
/// expunge that was asked for while the library was open - through the
/// library's own Expunge vector, so a library that replaced it is asked.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it.
///
/// RESULT:
/// What the Expunge answered when it ran - a seglist to unload - or null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; `CloseLibrary` calls it under Forbid.
/// - Forbid: held by the caller.
/// - Process: a Task will do.
pub fn libClose(lib: *Library) callconv(.c) ?*anyopaque {
    lib.open_cnt -= 1;
    if (lib.open_cnt == 0 and lib.flags & sdk.exec.LIBF_DELEXP != 0) {
        return lib.vector(sdk.exec.ExpungeFn, sdk.exec.LIB_EXPUNGE)(lib);
    }
    return null;
}

/// Standard Expunge: while open, only mark it for later (`LIBF_DELEXP`),
/// so the last `CloseLibrary` finishes the job; otherwise take it off the
/// library list and free it.
///
/// INPUTS:
/// - `lib` - the library, as every library vector gets it.
///
/// RESULT:
/// Null: a library in the ROM has no seglist to hand back.
///
/// CONTEXT:
/// - Waits: no, and it must not: `flushLibraries` reaches it from inside
///   `AllocMem`, where a low-memory handler may not wait.
/// - Interrupts: safe in itself, but it frees memory.
/// - Forbid: every caller holds it already; it does not take it.
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
    base.iface().Remove(&lib.node);
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
/// - Forbid: every caller holds it already; it does not take it.
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
/// - Forbid: not needed.
/// - Process: a Task will do.
pub fn libExtFunc(lib: *Library) callconv(.c) ?*anyopaque {
    _ = lib;
    return null;
}
