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

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    shell.print("port        name            pri  action   sig  task            queued\n", .{});
    sys.Forbid(); // no port comes or goes while we look
    defer sys.Permit();
    var it = shell.base.port_list.iterator();
    while (it.next()) |node| {
        const port: *sdk.exec.MsgPort = @fieldParentPtr("node", node);
        const action = port.flags & sdk.exec.PF_ACTION;
        const action_name = switch (action) {
            sdk.exec.PA_SIGNAL => "signal",
            sdk.exec.PA_SOFTINT => "softint",
            else => "ignore",
        };
        const owner: [*:0]const u8 = if (action == sdk.exec.PA_SIGNAL and port.sig_task != null)
            @as(*sdk.exec.Task, @ptrCast(@alignCast(port.sig_task.?))).name()
        else
            "-";
        var queued: usize = 0;
        var messages = port.msg_list.iterator();
        while (messages.next()) |_| queued += 1;
        shell.print("0x%08x  %-14s %4d  %-7s %4d  %-14s %d\n", .{
            @intFromPtr(port), _shell.nodeName(node), node.pri, action_name, port.sig_bit, owner, queued,
        });
    }
}
