// SPDX-License-Identifier: MIT
//! GetUpdateInfo: what a run's last DoUpdate came to.

const sdk = @import("sdk");
const update = sdk.update;
const UpdateBase = @import("../update_base.zig").UpdateBase;
const Run = @import("_run.zig").Run;

/// Says what a run's last DoUpdate came to.
///
/// SYNOPSIS:
/// ```zig
/// fn GetUpdateInfo(base: *UpdateBase, run: *Run, info: *UpdateInfo) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `run` - from CreateUpdate.
/// - `info` - filled in whole.
///
/// RESULT:
/// Nothing; `info` holds the package's name, what its list says it holds,
/// and the counts: files written (or, after `UPD_Check`, to be written)
/// and their bytes, paths deleted, files kept, drawers made, the files
/// the firmware reads in the package and those written, and the
/// partition the firmware was told to try.
///
/// BEHAVIOR:
/// The counts are those of the last DoUpdate, all 0 before the first.
/// `sdk.update.changes` says whether they change the system.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `info.source` is the run's, valid until
/// DeleteUpdate.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoUpdate`, `CreateUpdate`, `sdk.update`
///
/// EXAMPLES:
/// ```zig
/// var info: update.UpdateInfo = .{};
/// upd.GetUpdateInfo(run, &info);
/// if (update.changes(&info) and info.tried != 0) {
///     // restart with C:Reboot TRYBOOT to start the new kernel
/// }
/// ```
pub fn GetUpdateInfo(_: *UpdateBase, run: *Run, info: *update.UpdateInfo) void {
    info.* = .{
        .source = run.from,
        .files = run.files,
        .bytes = run.bytes,
        .written = run.written,
        .written_bytes = run.written_bytes,
        .deleted = run.deleted,
        .kept = run.kept,
        .made = run.made,
        .boot = run.boot,
        .boot_written = run.boot_written,
        .tried = run.tried,
    };
}
