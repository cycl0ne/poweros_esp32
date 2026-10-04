// SPDX-License-Identifier: MPL-2.0
//! tasks: what each core runs, then the ready and waiting tasks - with the
//! core each runs on and the core it is pinned to - and how often exec has
//! dispatched and idled.
//!
//! The lists are copied out under Disable - it keeps them still on both
//! cores, which Forbid does not - and printed after, so the output never
//! holds them.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const Task = sdk.exec.Task;

pub const name = "tasks";
pub const usage = "tasks";
pub const help =
    \\  tasks                list tasks
    \\
;

/// How many tasks are copied out; one more is counted, not shown.
const max_shown = 40;

/// A task as it was when it was copied.
const Entry = struct {
    address: usize,
    name: [16:0]u8,
    node_type: sdk.exec.NodeType,
    pri: i8,
    state: sdk.exec.TaskState,
    /// The core it runs on, for a running one.
    core: u8,
    /// The cores it may run on: its TF_CORE0 and TF_CORE1 flags.
    pins: u8,
    sig_wait: u32,
    sig_recvd: u32,
    sig_except: u32,
    user_data: usize,
    except_data: usize,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const base = shell.base;
    const sys = base.iface();
    var entries: [max_shown]Entry = undefined;
    var count: usize = 0;
    var missed: u32 = 0;
    var dispatches: u32 = 0;
    var idle_rounds: u32 = 0;

    sys.Disable();
    for (base.cpus[0..base.cores_running], 0..) |*cpu, core| {
        keep(&entries, &count, &missed, cpu.this_task, @intCast(core));
        dispatches +%= cpu.disp_count;
        idle_rounds +%= cpu.idle_count;
    }
    for ([_]*sdk.exec.List{ &base.task_ready, &base.task_wait }) |list| {
        var it = list.iterator();
        while (it.next()) |node| keep(&entries, &count, &missed, @fieldParentPtr("node", node), 0);
    }
    sys.Enable();

    shell.print("task        name             type     pri  state  core  pin  wait      recvd     except    userdata  excdata\n", .{});
    for (entries[0..count]) |*entry| {
        const core: [*:0]const u8 = if (entry.state != .run) "" else if (entry.core == 0) "0" else "1";
        const pin: [*:0]const u8 = switch (entry.pins) {
            sdk.exec.TF_CORE0 => "0",
            sdk.exec.TF_CORE1 => "1",
            else => "",
        };
        shell.print("0x%08x  %-16s %-7s %4d  %-6s %-4s  %-3s  %08x  %08x  %08x  %08x  %08x\n", .{
            entry.address,                                       @as([*:0]const u8, @ptrCast(&entry.name)),
            _shell.enumName(sdk.exec.NodeType, entry.node_type), entry.pri,
            _shell.enumName(sdk.exec.TaskState, entry.state),    core,
            pin,                                                 entry.sig_wait,
            entry.sig_recvd,                                     entry.sig_except,
            entry.user_data,                                     entry.except_data,
        });
    }
    if (missed != 0) shell.print("... and %u more\n", .{missed});
    shell.print("dispatches %u, idle loops %u\n", .{ dispatches, idle_rounds });
}

/// `task` copied into the next entry, or counted as missed when they are
/// all taken.
fn keep(entries: *[max_shown]Entry, count: *usize, missed: *u32, task: *const Task, core: u8) void {
    if (count.* == entries.len) {
        missed.* += 1;
        return;
    }
    const entry = &entries[count.*];
    count.* += 1;
    entry.* = .{
        .address = @intFromPtr(task),
        .name = @splat(0),
        .node_type = task.node.type,
        .pri = task.node.pri,
        .state = task.state,
        .core = core,
        .pins = task.flags & (sdk.exec.TF_CORE0 | sdk.exec.TF_CORE1),
        .sig_wait = task.sig_wait,
        .sig_recvd = task.sig_recvd,
        .sig_except = task.sig_except,
        .user_data = @intFromPtr(task.user_data),
        .except_data = @intFromPtr(task.except_data),
    };
    const text = task.name();
    const length = @min(text.len, entry.name.len);
    @memcpy(entry.name[0..length], text[0..length]);
}
