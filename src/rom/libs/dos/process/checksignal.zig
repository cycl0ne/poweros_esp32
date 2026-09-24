// SPDX-License-Identifier: MPL-2.0
//! CheckSignal: which break signals have come, cleared.

const DosBase = @import("../dos_base.zig").DosBase;

/// Tells which of some signals have come, and clears them.
///
/// SYNOPSIS:
/// ```zig
/// fn CheckSignal(db: *DosBase, mask: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -508.
///
/// INPUTS:
/// - `mask` - the signals to look at, usually SIGBREAKF_CTRL_C ..
///   SIGBREAKF_CTRL_F.
///
/// RESULT:
/// The signals of `mask` that were set.
///
/// BEHAVIOR:
/// The signals in `mask` are read and cleared in one step; the others are
/// left alone. It doesn't wait.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Wait` (exec), `SetSignal` (exec)
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.CheckSignal(dos.SIGBREAKF_CTRL_C) != 0) {
///     _ = dos_lib.PrintFault(dos.ERROR_BREAK, null);
///     return;
/// }
/// ```
pub fn CheckSignal(db: *DosBase, mask: u32) u32 {
    const sys = db.sys_base;
    return sys.SetSignal(0, mask) & mask;
}
