// SPDX-License-Identifier: MPL-2.0
//! sems: the public semaphores, who holds them and who waits.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
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
    shell.print("semaphore   name            owner           nest  queue  waiting\n", .{});
    sys.Forbid();
    defer sys.Permit();
    var it = shell.base.sem_list.iterator();
    while (it.next()) |node| {
        const sem: *sdk.exec.SignalSemaphore = @fieldParentPtr("link", node);
        const owner: [*:0]const u8 = if (sem.queue_count < 0) "-" else if (sem.owner) |task| task.name() else "(shared)";
        var waiting: usize = 0;
        var waiters = sem.wait_queue.iterator();
        while (waiters.next()) |_| waiting += 1;
        shell.print("0x%08x  %-14s  %-14s %5d  %5d  %d\n", .{
            @intFromPtr(sem), _shell.nodeName(node), owner, sem.nest_count, sem.queue_count, waiting,
        });
    }
}
