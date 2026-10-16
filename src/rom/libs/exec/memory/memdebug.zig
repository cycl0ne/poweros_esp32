// SPDX-License-Identifier: MPL-2.0
//! MemDebug: memory debugging switched on or off, its counts told, or every
//! wall and all free memory checked now.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemDamage = sdk.exec.MemDamage;
const MemDebugInfo = sdk.exec.MemDebugInfo;

/// Switches memory debugging, or checks what it guards.
///
/// SYNOPSIS:
/// ```zig
/// fn MemDebug(base: *ExecBase, action: u32, info: ?*MemDebugInfo,
///     found: ?[*]MemDamage, found_max: u32) u32
/// ```
///
/// SINCE: 1.12. LVO -560.
///
/// INPUTS:
/// - `action` - what to do:
///   - `MEMDEBUG_ASK` - nothing; only `info` is filled.
///   - `MEMDEBUG_ON` - on: every block allocated from here gets a wall,
///     and all free memory is filled with `MEM_PATTERN_FREED`.
///   - `MEMDEBUG_OFF` - off: new blocks get no wall. The counts stay.
///   - `MEMDEBUG_CHECK` - every wall and, while the mode is on, all free
///     memory looked at now.
/// - `info` - filled after the action with whether the mode is on and its
///   counts, or null.
/// - `found` - where MEMDEBUG_CHECK puts what it finds wrong, or null.
/// - `found_max` - how many fit in `found`.
///
/// RESULT:
/// For MEMDEBUG_CHECK, how many things are wrong, also those that did not
/// fit in `found`; 0 for the other actions.
///
/// BEHAVIOR:
/// While the mode is on, AllocMem puts a wall of `MEM_WALLSIZE` bytes
/// behind each block (`MEMBF_WALLED`), holding the size asked for and
/// `MEM_PATTERN_WALL` from there on, and fills the block with
/// `MEM_PATTERN_NEW` unless MEMF_CLEAR asked for zeros. FreeMem checks the
/// wall: one written over is told on the log, with the block, how far it
/// was written and its owner, by the recoverable alert `AN_MemWall`, and
/// counted (`MemDebugInfo.walls`); the block is freed all the same. Freed
/// memory is filled with `MEM_PATTERN_FREED`, and AllocMem checks that
/// the memory it hands out still holds it: what is not, was written after
/// its free, and is told on the log and counted
/// (`MemDebugInfo.freed_writes`).
///
/// A task started while the mode is on with a stack of 4 KiB or more gets
/// a wide stack guard (`TF_WIDEGUARD`), as does a stack `NewStackRun`
/// allocates.
///
/// MEMDEBUG_ON clears the counts, also when the mode is on already, and
/// makes the pattern in the free memory whole again. A block keeps its
/// wall when the mode is switched off, and FreeMem checks it then too;
/// blocks allocated before the mode was on have none.
///
/// MEMDEBUG_CHECK fills `found` with the first `found_max` things wrong,
/// in the order of exec's memory list, each with its kind
/// (`MemDamage.kind`): a walled block written past its end
/// (`MEMDAMAGE_WALL`, with the block's owner), free memory written after
/// its free (`MEMDAMAGE_FREED`), and a region whose blocks no longer
/// chain, where the walk of it stopped (`MEMDAMAGE_CHAIN`). The counts are
/// not changed by it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's memory lock.
/// - Locks: takes exec's memory lock for MEMDEBUG_ON and MEMDEBUG_CHECK;
///   no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `info` and `found` stay the caller's; they are written while exec's
/// memory lock is held, so they must not be memory the call itself could
/// be allocating or freeing.
///
/// NOTES:
/// MEMDEBUG_ON and MEMDEBUG_CHECK go through all memory with exec's
/// memory lock held - some megabytes - so every other core's AllocMem and
/// FreeMem waits meanwhile. The mode is for hunting a bug: walls and
/// patterns cost memory and time on every allocation.
///
/// The kernel built with `-Dmemdebug=true` switches the mode on as exec
/// starts, before anything but exec's own first tasks has allocated; the
/// serial console's `s3> memdebug` and `C:MemDebug` call this.
///
/// BUGS:
/// A write that jumps over the wall is not seen by it. One that lands in
/// the next block's MemBlock breaks the region's chain, which
/// MEMDEBUG_CHECK tells; one inside the next block is not found.
///
/// SEE ALSO:
/// `AllocMem`, `FreeMem`, `AddTask`, `NewStackRun`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.MemDebug(exec.MEMDEBUG_ON, null, null, 0);
/// runTheSuspect();
/// var found: [8]exec.MemDamage = undefined;
/// const wrong = sys.MemDebug(exec.MEMDEBUG_CHECK, null, &found, found.len);
/// ```
pub fn MemDebug(base: *ExecBase, action: u32, info: ?*MemDebugInfo, found: ?[*]MemDamage, found_max: u32) u32 {
    var wrong: u32 = 0;
    switch (action) {
        sdk.exec.MEMDEBUG_ON => _memory.debugOn(base),
        sdk.exec.MEMDEBUG_OFF => base.mem_debug.on = false,
        sdk.exec.MEMDEBUG_CHECK => {
            const into: []MemDamage = if (found) |many| many[0..found_max] else &.{};
            wrong = _memory.debugCheck(base, into);
        },
        else => {},
    }
    if (info) |state| state.* = base.mem_debug;
    return wrong;
}
