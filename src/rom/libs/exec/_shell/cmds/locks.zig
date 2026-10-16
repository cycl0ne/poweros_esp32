// SPDX-License-Identifier: MPL-2.0
//! locks: which task holds which semaphore, from every task's table of
//! what it holds (`Task.holds`) - the semaphore, its name for a public
//! one, how often and whether shared - and the one each task waits for.
//! What a task's end gives back, seen before it ends; and where a hang is,
//! seen while it lasts.
//!
//! Copied out under Disable, which keeps the task lists still, and exec's
//! semaphore lock, which keeps the tables still; printed after.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const Task = sdk.exec.Task;

pub const name = "locks";
pub const usage = "locks";
pub const help =
    \\  locks                which task holds which semaphore, and what each waits for
    \\
;

/// One line: a hold, a wait, or holds a task's table had no room for.
const Row = struct {
    task: [21]u8,
    id: u32,
    semaphore: usize,
    name: [17]u8,
    count: u32,
    kind: Kind,
};

const Kind = enum { exclusive, shared, waits, lost };

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const base = shell.base;
    const sys = base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    sys.Disable();
    sys.AcquireLock(&base.lock_semaphores);
    for (base.cpus[0..base.cores_running]) |*cpu| take(&rows, &count, &more, cpu.this_task);
    for ([_]*sdk.exec.List{ &base.task_ready, &base.task_wait }) |list| {
        var it = list.iterator();
        while (it.next()) |node| take(&rows, &count, &more, @fieldParentPtr("node", node));
    }
    sys.ReleaseLock(&base.lock_semaphores);
    sys.Enable();

    if (count == 0 and more == 0) {
        shell.print("no task holds or waits for a semaphore\n", .{});
        return;
    }
    shell.print("task                   #id  semaphore   name              holds\n", .{});
    for (rows[0..count]) |*row| {
        const task: [*:0]const u8 = @ptrCast(&row.task);
        const sem_name: [*:0]const u8 = @ptrCast(&row.name);
        const address: u32 = @truncate(row.semaphore);
        switch (row.kind) {
            .exclusive => shell.print("%-20s %5u  0x%08x  %-16s  %u exclusive\n", .{ task, row.id, address, sem_name, row.count }),
            .shared => shell.print("%-20s %5u  0x%08x  %-16s  %u shared\n", .{ task, row.id, address, sem_name, row.count }),
            .waits => shell.print("%-20s %5u  0x%08x  %-16s  waits for it\n", .{ task, row.id, address, sem_name }),
            .lost => shell.print("%-20s %5u  %u more holds its table had no room for\n", .{ task, row.id, row.count }),
        }
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
}

/// A task's holds, its wait and its lost holds as rows.
fn take(rows: []Row, count: *usize, more: *u32, task: *Task) void {
    for (&task.holds) |*hold| {
        const sem = hold.semaphore orelse continue;
        add(rows, count, more, task, sem, hold.count, if (hold.shared) .shared else .exclusive);
    }
    if (task.waiting_for) |sem| add(rows, count, more, task, sem, 0, .waits);
    if (task.holds_lost != 0) add(rows, count, more, task, null, task.holds_lost, .lost);
}

fn add(rows: []Row, count: *usize, more: *u32, task: *Task, sem: ?*sdk.exec.SignalSemaphore, times: u32, kind: Kind) void {
    if (count.* == rows.len) {
        more.* += 1;
        return;
    }
    const row = &rows[count.*];
    row.* = .{ .task = undefined, .id = task.id, .semaphore = if (sem) |s| @intFromPtr(s) else 0, .name = undefined, .count = times, .kind = kind };
    _ = _shell.copyName(&row.task, task.node.name);
    _ = _shell.copyName(&row.name, if (sem) |s| (s.link.name orelse "-") else "-");
    count.* += 1;
}
