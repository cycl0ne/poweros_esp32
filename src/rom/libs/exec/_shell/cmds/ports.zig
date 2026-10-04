// SPDX-License-Identifier: MPL-2.0
//! ports: the public message ports, who they signal and what is queued.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "ports";
pub const usage = "ports";
pub const help =
    \\  ports                public message ports
    \\
;

/// What is printed of one port, copied out under exec's port lock.
const Row = struct {
    address: usize,
    name: [15]u8,
    owner: [15]u8,
    pri: i8,
    action: u8,
    sig_bit: u8,
    queued: u32,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    // The port lock masks this core's interrupts: copy, print after.
    const list = sys.LockExecList(sdk.exec.EXECLIST_PORTS).?;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == rows.len) {
            more += 1;
            continue;
        }
        const port: *sdk.exec.MsgPort = @fieldParentPtr("node", node);
        const action = port.flags & sdk.exec.PF_ACTION;
        const owner: ?[*:0]const u8 = if (action == sdk.exec.PA_SIGNAL and port.sig_task != null)
            @as(*sdk.exec.Task, @ptrCast(@alignCast(port.sig_task.?))).name()
        else
            "-";
        var queued: u32 = 0;
        var messages = port.msg_list.iterator();
        while (messages.next()) |_| queued += 1;
        rows[count] = .{ .address = @intFromPtr(port), .name = undefined, .owner = undefined, .pri = node.pri, .action = action, .sig_bit = port.sig_bit, .queued = queued };
        _ = _shell.copyName(&rows[count].name, node.name);
        _ = _shell.copyName(&rows[count].owner, owner);
        count += 1;
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_PORTS);

    shell.print("port        name            pri  action   sig  task            queued\n", .{});
    for (rows[0..count]) |*row| {
        const action_name = switch (row.action) {
            sdk.exec.PA_SIGNAL => "signal",
            sdk.exec.PA_SOFTINT => "softint",
            else => "ignore",
        };
        shell.print("0x%08x  %-14s %4d  %-7s %4d  %-14s %d\n", .{
            row.address,                              @as([*:0]const u8, @ptrCast(&row.name)), row.pri, action_name, row.sig_bit,
            @as([*:0]const u8, @ptrCast(&row.owner)), row.queued,
        });
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
}
