// SPDX-License-Identifier: MIT
//! ObtainInterfaceList: the names of every interface there is.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// A list of every interface's name, the caller's to walk.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainInterfaceList(base: *SocketBase) ?*List
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// A list of `InterfaceNode`s - lo0 first, then the others in the order
/// they were added - or null with Errno() `ENOMEM`.
///
/// BEHAVIOR:
/// The list is a copy made at the call: interfaces added or taken away
/// afterwards do not change it. Each node's `ln_Name` points at its
/// `name`.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's, until ReleaseInterfaceList frees it.
///
/// NOTES:
/// QueryInterfaceTagList tells about each name.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseInterfaceList`, `QueryInterfaceTagList`
///
/// EXAMPLES:
/// ```zig
/// const list = sb.ObtainInterfaceList() orelse return;
/// defer sb.ReleaseInterfaceList(list);
/// var it = list.iterator();
/// while (it.next()) |node| _ = Printf(dl, "%s\n", .{node.name.?});
/// ```
pub fn ObtainInterfaceList(sb: *SocketBase) ?*exec.List {
    const stack = sb.stack;
    const sys = sb.sys_base;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    var count: usize = 0;
    for (&stack.interfaces) |*interface| count += interface.used;
    const bytes = @sizeOf(exec.List) + count * @sizeOf(bsd.InterfaceNode);
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = _socket.fail(sb, bsd.ENOMEM, "ObtainInterfaceList");
        return null;
    };
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const nodes: [*]bsd.InterfaceNode = @ptrFromInt(@intFromPtr(memory) + @sizeOf(exec.List));
    var index: usize = 0;
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0) continue;
        const node = &nodes[index];
        node.* = .{ .name = interface.name };
        node.node.name = @ptrCast(&node.name);
        sys.AddTail(list, &node.node);
        index += 1;
    }
    return list;
}
