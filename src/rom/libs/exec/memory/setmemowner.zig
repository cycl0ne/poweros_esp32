// SPDX-License-Identifier: MPL-2.0
//! SetMemOwner: a block given to another task, or to the system - what its
//! MemBlock says from then on.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");
const _task = @import("../task/_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemBlock = sdk.exec.MemBlock;
const Task = sdk.exec.Task;

/// Gives a block to another task, or to the system.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMemOwner(base: *ExecBase, memory_block: ?*anyopaque,
///     task: ?*Task) bool
/// ```
///
/// SINCE: 1.11. LVO -556.
///
/// INPUTS:
/// - `memory_block` - what `AllocMem` or `AllocVec` answered.
/// - `task` - the new owner, or null for the system. A task not started
///   yet will do: it is given its number here (`Task.id`), and `AddTask`
///   keeps it.
///
/// RESULT:
/// True when the block is marked; false for null and for a block that is
/// not one in use - in no region, freed already, or its MemBlock written
/// over.
///
/// BEHAVIOR:
/// The block's MemBlock is changed to name the new owner; its size and
/// MEMF_PRIVATE stay. Nothing else changes: the block stays where it is,
/// and whoever frees it frees it as before.
///
/// It is for memory one task makes for another: a parent laying out what
/// its child starts with - dos copies a new process's variables and path
/// so - or a block whose holder moves to another task. The tools that show
/// who holds what (`Avail OWNERS`, `MemMap`) then show it under the task
/// that holds it, and not under the one that allocated it, which may have
/// ended long before.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's memory lock.
/// - Locks: takes Disable when it numbers a task, then exec's memory lock;
///   no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands but the mark: the caller must hold the block, so
/// that nothing frees it meanwhile.
///
/// NOTES:
/// MEMOWNER_SYSTEM is what exec's own tasks have as their number, so a
/// block given to one of them is the system's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocMem`, `AddTask`, `BeginSystemMemory`
///
/// EXAMPLES:
/// ```zig
/// // What the child starts with is the child's, though made here.
/// _ = sys.SetMemOwner(startup, &child.task);
/// _ = sys.AddTask(&child.task, &childCode, null);
/// ```
pub fn SetMemOwner(base: *ExecBase, memory_block: ?*anyopaque, task: ?*Task) bool {
    const block = memory_block orelse return false;
    const sys = base.iface();
    var owner = sdk.exec.MEMOWNER_SYSTEM;
    if (task) |new_owner| {
        // A task not started yet has no number: it gets one now, which
        // AddTask keeps.
        if (new_owner.state == .invalid and new_owner.id == sdk.exec.MEMOWNER_SYSTEM) {
            sys.Disable();
            if (new_owner.id == sdk.exec.MEMOWNER_SYSTEM) new_owner.id = _task.nextTaskId(base);
            sys.Enable();
        }
        owner = new_owner.id;
    }
    sys.AcquireLock(&base.lock_memory);
    defer sys.ReleaseLock(&base.lock_memory);
    const header = MemBlock.of(block);
    _ = _memory.regionOf(base, @intFromPtr(header)) orelse return false;
    if (!header.inUse()) return false;
    _memory.setOwner(block, owner);
    return true;
}
