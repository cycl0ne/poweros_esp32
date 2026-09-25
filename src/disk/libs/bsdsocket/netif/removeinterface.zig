// SPDX-License-Identifier: MIT
//! RemoveInterface: an interface on a network device taken down.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");
const _task = @import("../task/_task.zig");

/// The interface called `name` taken down: off the routes, its device
/// closed, its slot free.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveInterface(base: *SocketBase, name: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `name` - an interface AddInterfaceTagList added.
///
/// RESULT:
/// 0, or -1 with Errno() `ENXIO`: there is no such interface, or it is
/// `lo0`, which cannot go.
///
/// BEHAVIOR:
/// The stack task does the work, since only it can wait for the device to
/// give back its requests: the routes through the interface and its ARP
/// entries go at once, then every request is taken back from the device,
/// what waited to be sent is dropped, and the device is closed. When it
/// was the last interface on a device, the task ends as well.
///
/// CONTEXT:
/// - Waits: yes, until the task has done it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The interface no longer holds the library in memory.
///
/// NOTES:
/// Sockets bound to the interface's address stay; what they send from
/// then on has no route and fails with `ENETUNREACH`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddInterfaceTagList`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.RemoveInterface("eth0");
/// ```
pub fn RemoveInterface(sb: *SocketBase, name: [*:0]const u8) i32 {
    const stack = sb.stack;
    const sys = sb.sys_base;
    const interface = blk: {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        const found = _netif.named(stack, name) orelse return _socket.fail(sb, bsd.ENXIO, "RemoveInterface");
        if (found.device == null) return _socket.fail(sb, bsd.ENXIO, "RemoveInterface");
        break :blk found;
    };
    const port = sys.CreateMsgPort() orelse return _socket.fail(sb, bsd.ENOMEM, "RemoveInterface");
    defer sys.DeleteMsgPort(port);
    var command: _task.Command = .{ .interface = interface };
    command.message.reply_port = port;
    command.message.length = @sizeOf(_task.Command);
    sys.PutMsg(&stack.commands, &command.message);
    _ = sys.WaitPort(port);
    _ = sys.GetMsg(port);
    return 0;
}
