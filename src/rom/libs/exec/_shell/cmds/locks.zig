// SPDX-License-Identifier: MPL-2.0
//! locks: which task holds which semaphore, from every task's table of
//! what it holds (`Task.holds`) - the semaphore, its name for a public
//! one, how often and whether shared - and the one each task waits for.
//! What a task's end gives back, seen before it ends; and where a hang is,
//! seen while it lasts.
//!
//! Copied out under Disable, which keeps the task lists still, and exec's
//! semaphore lock, which keeps the queues and the grants still - a task's
//! own obtain or release changes its table without it, so a row is that
//! moment's; printed after. The rows
//! and their lines are the ROM debugger's too (`debug/_lists.zig`).

const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "locks";
pub const usage = "locks";
pub const help =
    \\  locks                which task holds which semaphore, and what each waits for
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const base = shell.base;
    const sys = base.iface();
    var rows: _lists.Copied(_lists.locks, _shell.max_rows) = .{};
    sys.Disable();
    sys.AcquireLock(&base.lock_semaphores);
    _lists.locks.each(.trusted, base, &rows);
    sys.ReleaseLock(&base.lock_semaphores);
    sys.Enable();
    rows.print(shell);
}
