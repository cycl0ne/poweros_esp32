// SPDX-License-Identifier: MPL-2.0
//! OpenLibrary: finds a library by name and version and hands the opener
//! to the library's own Open, which counts it.
//!
//! The library is found and pinned under exec's library list, and its Open
//! runs inside its own lock with the list let go (library/_library.zig).
//!
//! This searches the library list and nothing else. What loads a module
//! from LIBS: is ramlib.library, which replaces the slot in front of it.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Opens a library by name at a version, through its own Open vector.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenLibrary(base: *ExecBase, name: [*:0]const u8,
///     version: u32) ?*Library
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `name` - the library's name, as it is on its node. Matched exactly,
///   case included.
/// - `version` - the lowest version that will do. 0 takes whatever is there.
///
/// RESULT:
/// The library base to call through, or null: there is no library of that
/// name, it is older than `version`, or its Open vector refused.
///
/// BEHAVIOR:
/// The version check is here rather than in the library, so every library
/// gets it without writing it. It is also the only thing standing between a
/// caller and a slot that does not exist: a jump table only grows at the
/// end, so a library that is new enough has every slot an older one had.
/// A caller that asks for 0 and then calls a function only a later version
/// has has ignored the mechanism built for it.
///
/// The Open vector is what counts the opener. The standard one
/// (`libOpen`) raises `open_cnt` and clears `LIBF_DELEXP`, so a library
/// marked for expunging is reprieved by being opened again.
///
/// The library is found under exec's library list and *pinned* there, so
/// that nothing expunges it before its Open has run; the list is let go,
/// and the Open vector runs inside the library's own lock. Two opens of
/// one library never run at once, on either core; opens of different
/// libraries do. The vector holds nothing of exec's, so it may start a task
/// and wait for it, and that task may open other libraries. A library
/// being expunged is passed over, as if it were not there.
///
/// CONTEXT:
/// - Waits: for the library list and the library's lock, while another
///   task holds them; and with ramlib.library in front of it, the
///   replacement loads the module from LIBS:, which reaches a handler.
/// - Interrupts: no. It takes semaphores, and the Open vector may do
///   anything.
/// - Locks: takes exec's library list and the library's own lock, both
///   semaphores; no spinlock may be held.
/// - Process: a Task will do for exec's own. ramlib's replacement needs a
///   Process to load from a disk, and sends the work to its own when a bare
///   Task calls it.
///
/// OWNERSHIP:
/// The caller now holds an open count and must `CloseLibrary` it. Until
/// then the library cannot expunge.
///
/// NOTES:
/// exec's own search is the library list and nothing else. What loads a
/// module from LIBS: is ramlib.library, which replaces this slot with
/// `SetFunction` - which is the whole reason a module's own calls go
/// through the jump table.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseLibrary`, `OpenDevice`, `SetRamLib`
///
/// EXAMPLES:
/// ```zig
/// const ub = sys.OpenLibrary("utility.library", 1) orelse return;
/// defer sys.CloseLibrary(ub);
/// ```
pub fn OpenLibrary(base: *ExecBase, name: [*:0]const u8, version: u32) ?*Library {
    const sys = base.iface();
    sys.ObtainSemaphore(&base.sem_libraries);
    const lib = _library.findOpenable(&base.lib_list, name) orelse {
        sys.ReleaseSemaphore(&base.sem_libraries);
        return null;
    };
    if (lib.version < version) {
        sys.ReleaseSemaphore(&base.sem_libraries);
        return null;
    }
    lib.pins += 1;
    sys.ReleaseSemaphore(&base.sem_libraries);

    sys.ObtainSemaphore(&lib.lock);
    const opened = lib.vector(sdk.exec.OpenFn, sdk.exec.LIB_OPEN)(lib, version);
    sys.ReleaseSemaphore(&lib.lock);

    sys.ObtainSemaphore(&base.sem_libraries);
    lib.pins -= 1;
    sys.ReleaseSemaphore(&base.sem_libraries);
    return opened;
}
