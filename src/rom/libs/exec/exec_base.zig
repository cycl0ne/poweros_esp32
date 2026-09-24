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

const sdk = @import("sdk");
const exec = @import("exec.zig");
const _interrupt = @import("interrupt/_interrupt.zig");
const _library = @import("library/_library.zig");

const interface = sdk.interface.exec;
const IntVector = sdk.exec.IntVector;
const Library = sdk.exec.Library;
const List = sdk.exec.List;
const Resident = sdk.exec.Resident;
const Task = sdk.exec.Task;

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
    /// TDNestCnt: Forbid() nesting, -1 when task switching is allowed.
    tdn_nest_cnt: i8,
    /// IDNestCnt: Disable() nesting, -1 when interrupts are enabled.
    id_nest_cnt: i8,
    /// Interrupt state from the outermost Disable, put back by the
    /// outermost Enable - so an Enable never turns interrupts on in a
    /// context that had them off.
    id_saved: u32,
    /// IntVects: one per interrupt number.
    int_vects: [sdk.hardware.intbits.INTB_COUNT]IntVector,
    /// SoftInts: queued software interrupts, one list per priority
    /// (-32, -16, 0, 16, 32).
    soft_ints: [_interrupt.softint_priorities.len]List,
    /// ThisTask: the running task.
    this_task: *Task,
    /// TaskReady: ready tasks by priority. TaskWait: waiting tasks.
    task_ready: List,
    task_wait: List,
    /// Quantum: time slice in ticks. Elapsed: what is left of it.
    quantum: u16,
    elapsed: u16,
    /// SysFlags: SFF_SAR, SFF_TQE.
    sys_flags: u16,
    /// Exception nesting: the dispatcher runs only at the outermost
    /// exception exit, so an interrupt inside another cannot switch tasks.
    int_depth: u8,
    /// IdleCount, DispCount.
    idle_count: u32,
    disp_count: u32,
    /// ResModules: the resident modules by priority, null-terminated; set
    /// by initResidents.
    res_modules: ?[*]?*const Resident,
    /// The loader's base, kept for whatever loads libraries and devices
    /// from a disk. exec never looks at what it points to: it is one word
    /// a module has nowhere else to put, since this structure is opaque to
    /// it and a module keeps nothing in its own image. Null until
    /// SetRamLib is called.
    ram_lib: ?*anyopaque = null,

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
