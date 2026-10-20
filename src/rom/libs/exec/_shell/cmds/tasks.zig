// SPDX-License-Identifier: MPL-2.0
//! tasks: what each core runs, then the ready and waiting tasks - with the
//! core each runs on and the core it is pinned to - and how often exec has
//! dispatched and idled.
//!
//! The lists are copied out under Disable - it keeps them still on every
//! core - and printed after, so the output never holds them. The rows and
//! their lines are the ROM debugger's too (`debug/_lists.zig`).

const _shell = @import("../shell.zig");
const _lists = @import("../../debug/_lists.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "tasks";
pub const usage = "tasks";
pub const help =
    \\  tasks                list tasks
    \\
;

/// How many tasks are copied out; the rest are counted, not shown.
const max_shown = 40;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: _lists.Copied(_lists.tasks, max_shown) = .{};
    sys.Disable();
    _lists.tasks.each(.trusted, shell.base, &rows);
    const totals = _lists.tasks.totals(shell.base);
    sys.Enable();
    rows.print(shell);
    _lists.tasks.printTotals(shell, totals);
}
