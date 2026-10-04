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

/// What is printed of one semaphore, copied out under exec's semaphore
/// lock.
const Row = struct {
    address: usize,
    name: [15]u8,
    owner: [15]u8,
    nest_count: i16,
    queue_count: i16,
    waiting: u32,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    const list = sys.LockExecList(sdk.exec.EXECLIST_SEMAPHORES).?;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == rows.len) {
            more += 1;
            continue;
        }
        const sem: *sdk.exec.SignalSemaphore = @fieldParentPtr("link", node);
        const owner: ?[*:0]const u8 = if (sem.queue_count < 0) "-" else if (sem.owner) |task| task.name() else "(shared)";
        var waiting: u32 = 0;
        var waiters = sem.wait_queue.iterator();
        while (waiters.next()) |_| waiting += 1;
        rows[count] = .{ .address = @intFromPtr(sem), .name = undefined, .owner = undefined, .nest_count = sem.nest_count, .queue_count = sem.queue_count, .waiting = waiting };
        _ = _shell.copyName(&rows[count].name, node.name);
        _ = _shell.copyName(&rows[count].owner, owner);
        count += 1;
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_SEMAPHORES);

    shell.print("semaphore   name            owner           nest  queue  waiting\n", .{});
    for (rows[0..count]) |*row| {
        shell.print("0x%08x  %-14s  %-14s %5d  %5d  %d\n", .{
            row.address,    @as([*:0]const u8, @ptrCast(&row.name)), @as([*:0]const u8, @ptrCast(&row.owner)),
            row.nest_count, row.queue_count,                         row.waiting,
        });
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
}
