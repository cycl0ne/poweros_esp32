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

const ExecBase = exec.ExecBase;
const Interrupt = sdk.exec.Interrupt;
const InitTable = sdk.exec.InitTable;
const Library = sdk.exec.Library;
const Resident = sdk.exec.Resident;
const vec = sdk.exec.vec;

/// What exec is on the library list as, and what `OpenLibrary` finds it
/// by. Nothing opens it in practice - every module is handed SysBase - but
/// it is on the list like everything else.
pub const LIBRARY_NAME = "exec.library";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "14.9.2026";
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
/// goes on with the system start.
fn initExec(lib: *Library, seg_list: ?*anyopaque, _: *exec.interface.ExecBase) callconv(.c) ?*Library {
    // First the raw serial port, for kprintf: nothing is printed before.
    // Direct, not through the table: SysBase is set further down, so there
    // is nothing to call a vector through yet (codex rule 1).
    const sys: *ExecBase = @fieldParentPtr("lib", lib);
    exec.RawIOInit(sys);
    sys.tdn_nest_cnt = -1;
    sys.id_nest_cnt = -1;
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
    sys_base.AddLibrary(lib);
    // The flusher finds exec's base in its data.
    library_flusher.data = sys;
    sys_base.AddMemHandler(&library_flusher);
    _task.initTasks(sys) catch return null;
    exec.initialized = true;
    const boot: *const exec.BootInfo = @ptrCast(@alignCast(seg_list orelse return lib));
    startSystem(sys, boot) catch return null;
    return lib;
}

/// initExec's second half, the system start: turns Forbid on and leaves it
/// on (the kernel's Permit starts multitasking), scans the ROM tags,
/// creates the exec task, and starts the RTF_SINGLETASK residents.
///
/// INPUTS:
/// - `base` - exec, just made.
/// - `boot` - where the other ROM tags are.
pub fn startSystem(base: *ExecBase, boot: *const exec.BootInfo) error{OutOfMemory}!void {
    const sys_base = base.iface();
    sys_base.Forbid();
    try _resident.initResidents(base, boot.rom_start, boot.rom_end);
    _ = sys_base.CreateTask("exec", exec_task_pri, &execTask, exec_task_stack) orelse
        return error.OutOfMemory;
    _ = sys_base.InitCode(sdk.exec.RTF_SINGLETASK, 0);
}

/// Above the boot task: the exec task runs as soon as Permit lets it.
const exec_task_pri = 5;
const exec_task_stack = 16 * 1024;

/// The exec task. The RTF_COLDSTART residents need multitasking and a
/// proper stack, so they start here. The last one is dos.library, whose
/// init starts the RTF_AFTERDOS residents. Then the task returns and ends
/// quietly: RemTask frees it.
pub fn execTask(_: *exec.interface.ExecBase) callconv(.c) void {
    _ = exec.SysBase.iface().InitCode(sdk.exec.RTF_COLDSTART, 0);
}

/// When memory runs out, expunge libraries and devices nobody has open.
/// Priority 0, so a handler that frees something cheaper - a cache, a
/// buffer - can be given a higher one and be asked first.
var library_flusher: Interrupt = .{
    .node = .{ .type = .interrupt, .pri = 0, .name = "library flusher" },
    .code = vec(_library.flushLibraries),
};
