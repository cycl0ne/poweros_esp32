// SPDX-License-Identifier: MPL-2.0
//! SetRamLib: keeps the module loader's base for it, in exec's base.

const ExecBase = @import("../exec.zig").ExecBase;

/// Tells exec where the module loader's base is.
///
/// SYNOPSIS:
/// ```zig
/// fn SetRamLib(base: *ExecBase, loader: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -440.
///
/// INPUTS:
/// - `loader` - the loader's own base, or null to say there is none.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// exec stores the word. It is one pointer that a module has nowhere else
/// to put - and the loader's base, through which exec hands it the
/// segments of a module that went (`UnLoadModule`, SINCE 1.25): at a last
/// close, at an opener's base's close, in the low-memory flush. So it is a
/// library's base with that call in its jump table, ramlib.library's.
///
/// The reason it has nowhere else is worth stating, since it is the only
/// thing this call is for. ramlib.library replaces exec's `OpenLibrary` and
/// `OpenDevice` with `SetFunction`, and a replaced vector is handed exec's
/// base, not the replacement's - so it has no way to reach its own state.
/// It cannot keep that state in its own image either, since a ROM image is
/// read only. So exec holds the word.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It is one store.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and exec takes no responsibility for what the
/// pointer names.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RamLib`, `SetFunction`, `OpenLibrary`
///
/// EXAMPLES:
/// ```zig
/// sys.SetRamLib(base);
/// ```
pub fn SetRamLib(base: *ExecBase, loader: ?*anyopaque) void {
    base.ram_lib = loader;
}
