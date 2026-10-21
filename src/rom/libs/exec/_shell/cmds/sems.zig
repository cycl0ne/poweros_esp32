// SPDX-License-Identifier: MPL-2.0
//! sems: the public semaphores, who holds them and who waits.
//!
//! The rows and their lines are the ROM debugger's too (`debug/_lists.zig`);
//! here they are copied out under exec's semaphore lock and printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "sems";
pub const usage = "sems";
pub const help =
    \\  sems                 public semaphores
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.semaphores, _shell.max_rows) = .{};
    _ = sys.LockExecList(sdk.exec.EXECLIST_SEMAPHORES).?;
    _lists.semaphores.each(.trusted, shell.base, &rows);
    sys.UnlockExecList(sdk.exec.EXECLIST_SEMAPHORES);
    rows.print(shell);
}
