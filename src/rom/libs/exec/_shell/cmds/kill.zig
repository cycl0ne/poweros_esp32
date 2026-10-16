// SPDX-License-Identifier: MPL-2.0
//! kill <number>: a task ended, as Kill on the Software Failure requester
//! ends it (`_task.killTask`): whatever it is doing is dropped, it lets go
//! of its semaphores, runs its final code and ends - its end hooks run,
//! its private memory is freed, and its Task stays. The number is the
//! task's (`Task.id`), as `memowners` and `locks` show it. Not this shell's
//! own task, and not one of exec's.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const _task = @import("../../task/_task.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "kill";
pub const usage = "kill <number>";
pub const help =
    \\  kill <number>        end a task as Kill on the Software Failure requester does
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const base = shell.base;
    const sys = base.iface();
    const id = try args.number();
    var task_name: [33]u8 = undefined;
    sys.Disable();
    const found = _task.findById(base, id);
    if (found) |task| _ = _shell.copyName(&task_name, task.node.name);
    sys.Enable();
    const task = found orelse {
        shell.print("kill: no task #%u\n", .{id});
        return;
    };
    if (!_task.killTask(base, task)) {
        shell.print("kill: #%u cannot be killed - this shell, or one of exec's own\n", .{id});
        return;
    }
    shell.print("kill: #%u \"%s\" ends\n", .{ id, @as([*:0]const u8, @ptrCast(&task_name)) });
}
