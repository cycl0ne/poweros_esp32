// SPDX-License-Identifier: MPL-2.0
//! RamLib: the module loader's base, as `SetRamLib` left it.

const ExecBase = @import("../exec.zig").ExecBase;

/// The module loader's base, as `SetRamLib` left it.
///
/// SYNOPSIS:
/// ```zig
/// fn RamLib(base: *ExecBase) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -444.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// What `SetRamLib` was given, or null if it was never called - which means
/// nothing loads modules from a disk on this machine.
///
/// BEHAVIOR:
/// The replaced `OpenLibrary` calls this to find its own state, which is
/// the whole purpose of the pair.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It is one load.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetRamLib`
///
/// EXAMPLES:
/// ```zig
/// const rb: *RamLibBase = @ptrCast(@alignCast(sys.RamLib() orelse return));
/// ```
pub fn RamLib(base: *ExecBase) ?*anyopaque {
    return base.ram_lib;
}
