// SPDX-License-Identifier: MPL-2.0
//! tasks: the running task, then the ready and waiting ones, and how often
//! exec has dispatched and idled.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "tasks";
pub const usage = "tasks";
pub const help =
    \\  tasks                list tasks
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    shell.print("task        name           type     pri  state   wait      recvd     except       count exc\n", .{});
    sys.Forbid(); // no task comes or goes while we look
    defer sys.Permit();
    printTask(shell, shell.base.this_task);
    for ([_]*sdk.exec.List{ &shell.base.task_ready, &shell.base.task_wait }) |list| {
        var it = list.iterator();
        while (it.next()) |node| printTask(shell, @fieldParentPtr("node", node));
    }
    shell.print("dispatches %d, idle loops %d\n", .{ shell.base.disp_count, shell.base.idle_count });
}

fn printTask(shell: *Shell, task: *const sdk.exec.Task) void {
    shell.print("0x%08x  %-14s %-7s %4d  %-7s %08x  %08x  %08x  %8d %3d\n", .{
        @intFromPtr(task),                               task.name(),                                     _shell.enumName(sdk.exec.NodeType, task.node.type), task.node.pri,
        _shell.enumName(sdk.exec.TaskState, task.state), task.sig_wait,                                   task.sig_recvd,                                     task.sig_except,
        if (task.user_data) |p| @intFromPtr(p) else 0,   if (task.except_data) |p| @intFromPtr(p) else 0,
    });
}
