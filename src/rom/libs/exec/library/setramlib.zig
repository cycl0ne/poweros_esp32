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
/// exec stores the word and **never looks at what it points to**. It is one
/// pointer that a module has nowhere else to put.
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
/// - Forbid: not needed.
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
