// SPDX-License-Identifier: MPL-2.0
//! CloseLibrary: hands an opener back to the library's own Close, which
//! counts it; at the last close, exec finishes an expunge that was asked
//! for while it was open.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Closes a library opened with `OpenLibrary`, through its Close vector.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseLibrary(base: *ExecBase, library: ?*Library) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `library` - what `OpenLibrary` answered, or null, which does nothing. The
///   null case is so that a cleanup path need not test what it is closing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The Close vector runs inside the library's own lock, as its Open does.
/// The standard Close (`libClose`) drops `open_cnt`. When that has reached
/// zero and `LIBF_DELEXP` is set, exec expunges the library there and
/// then, still holding its lock - so a library marked for expunging while
/// it was open goes on its last close. A Close vector does not expunge its
/// library itself.
///
/// The seglist of a library that went is dropped: nothing here loads a
/// module, so nothing here unloads one.
///
/// A library whose Open hands each opener a base of its own (bsdsocket's
/// does) gets that base back here. It is on no list - its node has no
/// predecessor - so its Close runs with nothing of exec's held: it frees
/// the base, and keeps the library it came from under that library's own
/// lock, `RemLibrary` doing a delayed expunge.
///
/// CONTEXT:
/// - Waits: for the library's lock while another task holds it, and for
///   exec's library list at an expunge.
/// - Interrupts: no. It takes semaphores.
/// - Locks: takes the library's own lock, and exec's library list at an
///   expunge, both semaphores; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's open count is given up and the base must not be called
/// again. The library may be gone the moment this returns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLibrary`, `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// const ub = sys.OpenLibrary("utility.library", 1) orelse return;
/// defer sys.CloseLibrary(ub);
/// ```
pub fn CloseLibrary(base: *ExecBase, library: ?*Library) void {
    const lib = library orelse return;
    const sys = base.iface();
    if (lib.node.pred == null) {
        // An opener's own base: its Close frees it, so nothing here may
        // touch it after.
        _ = lib.vector(sdk.exec.CloseFn, sdk.exec.LIB_CLOSE)(lib);
        return;
    }
    sys.ObtainSemaphore(&lib.lock);
    _ = lib.vector(sdk.exec.CloseFn, sdk.exec.LIB_CLOSE)(lib);
    if (lib.open_cnt == 0 and lib.flags & sdk.exec.LIBF_DELEXP != 0) {
        // Gives the lock back, or takes it with the library.
        _ = _library.expungeHeld(base, lib, &base.lib_list);
        return;
    }
    sys.ReleaseSemaphore(&lib.lock);
}
