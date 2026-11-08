// SPDX-License-Identifier: MIT
//! DeleteUpdate: a run let go, with what it opened.

const UpdateBase = @import("../update_base.zig").UpdateBase;
const _run = @import("_run.zig");
const Run = _run.Run;

/// Lets a run go, with what it opened to read its package.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteUpdate(base: *UpdateBase, run: ?*Run) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `run` - from CreateUpdate, on the task that made it; null does
///   nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The HTTP client is deleted, http.library and bsdsocket.library are
/// closed where the package was an address, and the piece and the run
/// are freed. Nothing on a disk changes.
///
/// CONTEXT:
/// - Waits: yes - a connection the client holds is closed.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the Task that made the run, whose libraries these are.
///
/// OWNERSHIP:
/// The run is gone; an `UpdateInfo.source` read from it with it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateUpdate`
///
/// EXAMPLES:
/// ```zig
/// const run = upd.CreateUpdate(null) orelse return dos.RETURN_FAIL;
/// defer upd.DeleteUpdate(run);
/// ```
pub fn DeleteUpdate(_: *UpdateBase, run: ?*Run) void {
    _run.free(run orelse return);
}
