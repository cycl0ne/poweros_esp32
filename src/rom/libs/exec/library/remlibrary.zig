// SPDX-License-Identifier: MPL-2.0
//! RemLibrary: asks a library to expunge itself. The library's own Expunge
//! decides - it takes itself off the list when nobody has it open, and
//! otherwise marks itself to go at the last close.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Asks a library to go away, through its own Expunge vector.
///
/// SYNOPSIS:
/// ```zig
/// fn RemLibrary(base: *ExecBase, lib: *Library) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `lib` - a library on the library list.
///
/// RESULT:
/// What the Expunge vector answered: null, or the seglist of a loaded
/// module the caller should now unload. A module in the ROM always answers
/// null, since it has no segments.
///
/// BEHAVIOR:
/// It asks rather than tells, and the library decides. The standard
/// Expunge (`libExpunge`) takes the library off the list (`DetachLibrary`)
/// and frees it when nobody has it open, and otherwise only sets
/// `LIBF_DELEXP` so that it goes on its last `CloseLibrary`. A library in
/// the ROM keeps itself by answering without doing anything, and exec reads
/// that from the library still being on its list when the vector returns.
///
/// So a caller cannot conclude from the result that the library went. What
/// it went by is whether it is still on the list.
///
/// It takes the library's own lock, so no Open or Close of it is running.
/// One that is open has its vector run inside the lock, and is only
/// marked. One nobody has open is marked going (`LIBF_GOING`) under exec's
/// library list - from then on no Open finds it - and its vector runs with
/// nothing held, since it may close what it opened. A library an Open is
/// on its way to is left alone.
///
/// CONTEXT:
/// - Waits: for the library's lock and exec's library list while others
///   hold them; and the vector may close other libraries.
/// - Interrupts: no. It takes semaphores.
/// - Locks: takes the library's own lock and exec's library list, both
///   semaphores; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// If the library went, its memory is gone and the base must not be touched
/// again. A non-null result is a seglist the caller now owns.
///
/// NOTES:
/// This is also how memory is reclaimed under pressure:
/// `flushLibraries` (library/_library.zig) is a low-memory handler that
/// walks the library and device lists calling this on everything nobody
/// has open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddLibrary`, `CloseLibrary`, `RemDevice`
///
/// EXAMPLES:
/// ```zig
/// if (sys.RemLibrary(lib)) |seg_list| {
///     dos.UnLoadSeg(seg_list);
/// }
/// ```
pub fn RemLibrary(base: *ExecBase, lib: *Library) ?*anyopaque {
    base.iface().ObtainSemaphore(&lib.lock);
    return _library.expungeHeld(base, lib, &base.lib_list).seg_list;
}
