// SPDX-License-Identifier: MPL-2.0
//! DetachLibrary: takes a library or device off exec's list, from its own
//! Expunge.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Takes a library or device off exec's list.
///
/// SYNOPSIS:
/// ```zig
/// fn DetachLibrary(base: *ExecBase, library: *Library) void
/// ```
///
/// SINCE: 1.6. LVO -532.
///
/// INPUTS:
/// - `library` - the library or device going: its own base, from inside
///   its Expunge vector.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It is the step an Expunge vector takes once it has decided to go, before
/// it frees its memory. exec runs that vector with nothing of its own held
/// (library/_library.zig), so the vector may close what it opened; the
/// list is changed here, under exec's library list.
///
/// One not on a list - never added, or detached already - is left alone,
/// so an init that failed before `AddLibrary` may share the Expunge's code.
/// A detached node's links are cleared, which is what says so.
///
/// exec reads from the library being off its list afterwards that it went.
///
/// CONTEXT:
/// - Waits: for exec's library list while another task holds it.
/// - Interrupts: no. It takes a semaphore.
/// - Locks: takes exec's library list, a semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The library is no longer the system's: nobody can find or open it, and
/// its memory is the Expunge's to free.
///
/// NOTES:
/// Only from the library's own Expunge vector, which exec has called. A
/// library taken off its list any other way is still expected to be
/// there by everyone who has it open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemLibrary`, `RemDevice`, `AddLibrary`
///
/// EXAMPLES:
/// ```zig
/// fn expunge(lib: *Library) callconv(.c) ?*anyopaque {
///     if (lib.open_cnt != 0) {
///         lib.flags |= LIBF_DELEXP;
///         return null;
///     }
///     const base: *MyBase = @fieldParentPtr("lib", lib);
///     const sys = base.sys_base;
///     sys.DetachLibrary(lib);
///     sys.FreeMem(@ptrFromInt(@intFromPtr(lib) - lib.neg_size), @as(usize, lib.neg_size) + lib.pos_size);
///     return null;
/// }
/// ```
pub fn DetachLibrary(base: *ExecBase, library: *Library) void {
    const sys = base.iface();
    sys.ObtainSemaphore(&base.sem_libraries);
    defer sys.ReleaseSemaphore(&base.sem_libraries);
    if (library.node.pred == null) return;
    sys.Remove(&library.node);
    library.node.succ = null;
    library.node.pred = null;
}
